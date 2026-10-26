"""GST reconciliation workbench - Streamlit in Snowflake app (asset 27).

Create in Snowsight: Projects > Streamlit > + Streamlit App,
location ACCEL_DB.GST, warehouse ACCEL_WH, then paste this file.
Packages: streamlit, pandas, altair (pre-installed in Streamlit in Snowflake).
Tax rates and rules in this demo are illustrative - not tax advice.
"""
import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="GST Reconciliation Workbench", layout="wide")
session = get_active_session()

DB = "ACCEL_DB.GST"
CATEGORIES = ["Matched", "Mismatch-amount", "Probable match", "Missing in 2B", "Missing in books"]
CAT_COLORS = alt.Scale(domain=CATEGORIES, range=["#2e7d32", "#ef6c00", "#f9a825", "#c62828", "#6a1b9a"])
MONEY_COLS = [
    "TAXABLE_BOOKS", "TAXABLE_2B", "TAX_BOOKS", "TAX_2B", "TAXABLE_DIFF", "TAX_DIFF",
    "ITC_CLAIMED", "ITC_AT_RISK", "ITC_UNCLAIMED_POTENTIAL",
]


@st.cache_data(ttl=300)
def load(query):
    return session.sql(query).to_pandas()


st.title("GST reconciliation workbench")
st.caption("Purchase register vs GSTR-2B · demo data · rates, rules and tolerances are illustrative")

with st.sidebar:
    st.header("Actions")
    if st.button("Re-run reconciliation"):
        with st.spinner("Reconciling..."):
            msg = session.sql("CALL ACCEL_DB.GST.RUN_GST_RECONCILIATION()").collect()[0][0]
        st.cache_data.clear()
        st.success(msg)
    st.header("Validate a GSTIN")
    gstin_in = st.text_input("GSTIN", placeholder="27AAPFU0939F1ZV")
    if gstin_in:
        err = session.sql(
            "SELECT ACCEL_DB.GST.GSTIN_VALIDATION_ERROR(?) AS E", params=[gstin_in]
        ).collect()[0]["E"]
        if err is None:
            st.success("Valid GSTIN (format, state code and check digit)")
        else:
            st.error(f"Invalid: {err}")

res = load(f"SELECT * FROM {DB}.RECON_RESULTS")
if res.empty:
    st.warning("No results yet - run 03_reconciliation.sql.")
    st.stop()
for col in MONEY_COLS:
    res[col] = pd.to_numeric(res[col], errors="coerce")

# ---------------- filters ----------------
with st.sidebar:
    st.header("Filters")
    periods = sorted(res["RETURN_PERIOD"].dropna().unique().tolist(), key=lambda p: (p[2:], p[:2]))
    sel_periods = st.multiselect("Return period (MMYYYY)", periods, default=periods[-6:] if len(periods) > 6 else periods)
    suppliers = sorted(res["SUPPLIER_NAME"].dropna().unique().tolist())
    sel_sup = st.multiselect("Supplier", suppliers)
    sel_cat = st.multiselect("Category", CATEGORIES, default=CATEGORIES)

f = res[res["RETURN_PERIOD"].isin(sel_periods) & res["MATCH_CATEGORY"].isin(sel_cat)]
if sel_sup:
    f = f[f["SUPPLIER_NAME"].isin(sel_sup)]
if f.empty:
    st.info("Nothing for this selection.")
    st.stop()

# ---------------- KPIs ----------------
k1, k2, k3, k4, k5 = st.columns(5)
k1.metric("Invoices", f"{len(f):,}")
k2.metric("Match rate", f"{(f['MATCH_CATEGORY'] == 'Matched').mean():.1%}")
k3.metric("ITC claimed (INR)", f"{f['ITC_CLAIMED'].sum():,.0f}")
k4.metric("ITC at risk (INR)", f"{f['ITC_AT_RISK'].sum():,.0f}")
k5.metric("Potentially unclaimed ITC (INR)", f"{f['ITC_UNCLAIMED_POTENTIAL'].sum():,.0f}")

c1, c2 = st.columns([2, 3])
with c1:
    st.subheader("Result categories")
    cat = f.groupby("MATCH_CATEGORY").agg(INVOICES=("MATCH_CATEGORY", "size"), ITC_AT_RISK=("ITC_AT_RISK", "sum")).reset_index()
    st.altair_chart(
        alt.Chart(cat)
        .mark_arc(innerRadius=60)
        .encode(
            theta="INVOICES:Q",
            color=alt.Color("MATCH_CATEGORY:N", scale=CAT_COLORS, title=None),
            tooltip=["MATCH_CATEGORY", "INVOICES", alt.Tooltip("ITC_AT_RISK:Q", format=",.0f")],
        )
        .properties(height=280),
        use_container_width=True,
    )
with c2:
    st.subheader("ITC at risk by return period")
    per = f.groupby(["RETURN_PERIOD", "MATCH_CATEGORY"])["ITC_AT_RISK"].sum().reset_index()
    per = per[per["ITC_AT_RISK"] > 0]
    per["PERIOD_SORT"] = per["RETURN_PERIOD"].str[2:] + per["RETURN_PERIOD"].str[:2]
    st.altair_chart(
        alt.Chart(per)
        .mark_bar()
        .encode(
            x=alt.X("RETURN_PERIOD:N", sort=alt.EncodingSortField("PERIOD_SORT"), title="Return period"),
            y=alt.Y("ITC_AT_RISK:Q", title="ITC at risk (INR)"),
            color=alt.Color("MATCH_CATEGORY:N", scale=CAT_COLORS, title=None),
            tooltip=["RETURN_PERIOD", "MATCH_CATEGORY", alt.Tooltip("ITC_AT_RISK:Q", format=",.0f")],
        )
        .properties(height=280),
        use_container_width=True,
    )

# ---------------- supplier view ----------------
st.subheader("ITC at risk by supplier")
sup = (
    f.groupby(["SUPPLIER_ID", "SUPPLIER_NAME"], dropna=False)
    .agg(
        INVOICES=("MATCH_CATEGORY", "size"),
        MATCHED=("MATCH_CATEGORY", lambda s: int((s == "Matched").sum())),
        EXCEPTIONS=("MATCH_CATEGORY", lambda s: int((s != "Matched").sum())),
        ITC_CLAIMED=("ITC_CLAIMED", "sum"),
        ITC_AT_RISK=("ITC_AT_RISK", "sum"),
        UNCLAIMED=("ITC_UNCLAIMED_POTENTIAL", "sum"),
    )
    .reset_index()
    .sort_values("ITC_AT_RISK", ascending=False)
)
sup["AT_RISK_SHARE"] = (sup["ITC_AT_RISK"] / sup["ITC_CLAIMED"].where(sup["ITC_CLAIMED"] > 0)).round(3)
st.dataframe(sup, use_container_width=True, hide_index=True)

# ---------------- work queue ----------------
st.subheader("Exception work queue")
queue = f[f["MATCH_CATEGORY"] != "Matched"].sort_values("ITC_AT_RISK", ascending=False)
tabs = st.tabs(CATEGORIES[1:])
cols = [
    "SUPPLIER_NAME", "GSTIN_BOOKS", "GSTIN_2B", "GSTIN_2B_VALIDATION_ERROR", "INVOICE_NO_BOOKS", "INVOICE_NO_2B",
    "INVOICE_DATE_BOOKS", "INVOICE_DATE_2B", "TAXABLE_BOOKS", "TAXABLE_2B", "TAX_BOOKS", "TAX_2B",
    "TAX_DIFF", "ITC_AT_RISK", "ITC_UNCLAIMED_POTENTIAL", "MATCH_METHOD", "RECOMMENDED_ACTION",
]
for tab, category in zip(tabs, CATEGORIES[1:]):
    with tab:
        q = queue[queue["MATCH_CATEGORY"] == category]
        st.caption(f"{len(q):,} invoices · ITC at risk INR {q['ITC_AT_RISK'].sum():,.0f}")
        st.dataframe(q[cols], use_container_width=True, hide_index=True)
        st.download_button(
            f"Download {category} (CSV)",
            q[cols].to_csv(index=False).encode("utf-8"),
            file_name=f"gst_{category.lower().replace(' ', '_').replace('-', '_')}.csv",
            mime="text/csv",
            key=f"dl_{category}",
        )

with st.expander("Matched invoices with date differences"):
    md = f[(f["MATCH_CATEGORY"] == "Matched") & (f["DATE_MISMATCH"] == True)]  # noqa: E712
    st.dataframe(md[cols + ["DATE_DIFF_DAYS"]], use_container_width=True, hide_index=True)

with st.expander("Demo: matcher accuracy vs injected scenarios"):
    st.dataframe(load(f"SELECT * FROM {DB}.RECON_ACCURACY_DEMO ORDER BY 1, 3 DESC"), use_container_width=True, hide_index=True)

with st.expander("Run history"):
    st.dataframe(load(f"SELECT * FROM {DB}.RECON_RUN_LOG ORDER BY RUN_AT DESC LIMIT 20"), use_container_width=True, hide_index=True)
