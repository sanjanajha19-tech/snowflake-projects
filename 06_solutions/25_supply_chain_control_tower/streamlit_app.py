"""Supply Chain Control Tower - Streamlit in Snowflake app (asset 25).

Create in Snowsight: Projects > Streamlit > + Streamlit App,
location ACCEL_DB.SCT, warehouse ACCEL_WH, then paste this file.
Packages: streamlit, pandas, altair (pre-installed in Streamlit in Snowflake).
"""
import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Supply Chain Control Tower", layout="wide")
session = get_active_session()

DB = "ACCEL_DB.SCT"
RISK_ORDER = ["CRITICAL", "HIGH", "MEDIUM", "OK", "NO_DEMAND"]
RISK_COLORS = alt.Scale(domain=RISK_ORDER, range=["#b71c1c", "#ef6c00", "#f9a825", "#2e7d32", "#9e9e9e"])


@st.cache_data(ttl=300)
def load(query):
    return session.sql(query).to_pandas()


risk = load(f"SELECT * FROM {DB}.STOCKOUT_RISK")
if risk.empty:
    st.error("SCT.STOCKOUT_RISK is empty - run 01_config_and_core_views.sql first.")
    st.stop()

as_of = risk["AS_OF_DATE"].iloc[0]
st.title("Supply Chain Control Tower")
st.caption(f"As of {as_of} (latest inventory snapshot) · horizon {int(risk['HORIZON_DAYS'].iloc[0])} days")

# ---------------- filters ----------------
risk["PLANT_LABEL"] = risk["PLANT_NAME"].fillna(risk["PLANT_ID"].astype(str))
risk["PRODUCT_LABEL"] = risk["SKU"].fillna("").astype(str) + " · " + risk["PRODUCT_NAME"].fillna("")
with st.sidebar:
    st.header("Filters")
    plants = sorted(risk["PLANT_LABEL"].unique().tolist())
    sel_plants = st.multiselect("Plant", plants, default=plants)
    cats = sorted(risk["CATEGORY"].dropna().unique().tolist())
    sel_cats = st.multiselect("Product category", cats, default=cats)
    prod_search = st.text_input("Product contains")
    sel_levels = st.multiselect("Risk level", RISK_ORDER, default=["CRITICAL", "HIGH", "MEDIUM"])

f = risk[risk["PLANT_LABEL"].isin(sel_plants) & (risk["CATEGORY"].isin(sel_cats) | risk["CATEGORY"].isna())]
if prod_search:
    f = f[f["PRODUCT_LABEL"].str.contains(prod_search, case=False, na=False)]
plant_ids = f["PLANT_ID"].astype(str).unique().tolist()
product_ids = f["PRODUCT_ID"].astype(str).unique().tolist()

# ---------------- KPIs ----------------
suppliers = load(f"SELECT * FROM {DB}.SUPPLIER_SCORECARD")
late = load(f"SELECT * FROM {DB}.LATE_PO_IMPACT")
late["REVENUE_AT_RISK"] = late["REVENUE_AT_RISK"].astype(float)
late = late[late["PLANT_ID"].astype(str).isin(plant_ids) & late["PRODUCT_ID"].astype(str).isin(product_ids)]

k1, k2, k3, k4, k5 = st.columns(5)
k1.metric("Critical SKUs", int((f["RISK_LEVEL"] == "CRITICAL").sum()))
k2.metric("High-risk SKUs", int((f["RISK_LEVEL"] == "HIGH").sum()))
k3.metric("Revenue at risk", f"{float(f['REVENUE_AT_RISK'].sum()):,.0f}")
k4.metric("Late open POs", f"{len(late):,}")
k5.metric(
    "Supplier OTIF (wtd)",
    f"{(suppliers['OTIF_PCT'].astype(float) * suppliers['POS_RECEIVED'].astype(float)).sum() / max(float(suppliers['POS_RECEIVED'].sum()), 1.0):.1%}",
)

# ---------------- risk overview ----------------
c1, c2 = st.columns([3, 2])
with c1:
    st.subheader("Stockout risk by plant")
    by_plant = f.groupby(["PLANT_LABEL", "RISK_LEVEL"]).size().reset_index(name="SKUS")
    st.altair_chart(
        alt.Chart(by_plant)
        .mark_bar()
        .encode(
            y=alt.Y("PLANT_LABEL:N", title=None),
            x=alt.X("SKUS:Q", title="Plant-products"),
            color=alt.Color("RISK_LEVEL:N", scale=RISK_COLORS, sort=RISK_ORDER, title="Risk"),
            order=alt.Order("RISK_LEVEL:N"),
            tooltip=["PLANT_LABEL", "RISK_LEVEL", "SKUS"],
        )
        .properties(height=300),
        use_container_width=True,
    )
with c2:
    st.subheader("Revenue at risk by plant")
    rar = f.groupby("PLANT_LABEL")["REVENUE_AT_RISK"].sum().reset_index()
    rar["REVENUE_AT_RISK"] = rar["REVENUE_AT_RISK"].astype(float)
    st.altair_chart(
        alt.Chart(rar)
        .mark_bar(color="#b71c1c")
        .encode(
            y=alt.Y("PLANT_LABEL:N", sort="-x", title=None),
            x=alt.X("REVENUE_AT_RISK:Q", title="Revenue at risk"),
            tooltip=["PLANT_LABEL", alt.Tooltip("REVENUE_AT_RISK:Q", format=",.0f")],
        )
        .properties(height=300),
        use_container_width=True,
    )

# ---------------- risk table ----------------
st.subheader("At-risk plant-products")
cols = [
    "PLANT_LABEL", "SKU", "PRODUCT_NAME", "RISK_LEVEL", "ON_HAND_QTY", "SAFETY_STOCK", "REORDER_POINT",
    "AVG_WEEKLY_DEMAND", "DAYS_OF_SUPPLY", "INBOUND_IN_HORIZON_QTY", "LATE_OPEN_POS", "NEXT_INBOUND_DATE",
    "PROJECTED_ON_HAND", "SHORTFALL_QTY", "REVENUE_AT_RISK",
]
table = f[f["RISK_LEVEL"].isin(sel_levels)][cols].copy()
table["RISK_LEVEL"] = pd.Categorical(table["RISK_LEVEL"], categories=RISK_ORDER, ordered=True)
table["REVENUE_AT_RISK"] = table["REVENUE_AT_RISK"].astype(float)
table = table.sort_values(["RISK_LEVEL", "REVENUE_AT_RISK"], ascending=[True, False])
st.dataframe(table, use_container_width=True, hide_index=True)

# ---------------- inventory drill-down ----------------
st.subheader("Inventory history")
if not f.empty:
    options = (f["PLANT_LABEL"] + " | " + f["PRODUCT_LABEL"]).tolist()
    keys = list(zip(f["PLANT_ID"].astype(str), f["PRODUCT_ID"].astype(str)))
    idx = st.selectbox("Plant-product", range(len(options)), format_func=lambda i: options[i])
    plant_id, product_id = keys[idx]
    hist = session.sql(
        """
        SELECT SNAPSHOT_DATE, ON_HAND_QTY, REORDER_POINT, SAFETY_STOCK
        FROM ACCEL_DB.DEMO.INVENTORY_SNAPSHOTS
        WHERE TO_VARCHAR(PLANT_ID) = ? AND TO_VARCHAR(PRODUCT_ID) = ?
        ORDER BY SNAPSHOT_DATE
        """,
        params=[plant_id, product_id],
    ).to_pandas()
    if hist.empty:
        st.info("No snapshots for this plant-product.")
    else:
        long = hist.melt("SNAPSHOT_DATE", var_name="SERIES", value_name="QTY")
        long["SNAPSHOT_DATE"] = pd.to_datetime(long["SNAPSHOT_DATE"])
        st.altair_chart(
            alt.Chart(long)
            .mark_line()
            .encode(
                x=alt.X("SNAPSHOT_DATE:T", title=None),
                y=alt.Y("QTY:Q", title="Units"),
                color=alt.Color("SERIES:N", title=None),
            )
            .properties(height=260),
            use_container_width=True,
        )

# ---------------- late POs & suppliers ----------------
c3, c4 = st.columns(2)
with c3:
    st.subheader("Late POs and customer impact")
    st.dataframe(
        late.sort_values(["REVENUE_AT_RISK", "DAYS_LATE"], ascending=False)[
            [
                "PO_ID", "SUPPLIER_NAME", "PLANT_NAME", "PRODUCT_NAME", "DAYS_LATE", "LATE_QTY",
                "STOCKOUT_RISK_LEVEL", "OPEN_CUSTOMER_ORDERS", "CUSTOMERS_EXPOSED", "REVENUE_AT_RISK",
                "RECOMMENDED_ACTION",
            ]
        ],
        use_container_width=True,
        hide_index=True,
    )
with c4:
    st.subheader("Supplier scorecard")
    sc = suppliers.copy()
    for col in ["OTIF_PCT", "AVG_DELAY_DAYS", "SPEND", "RISK_SCORE"]:
        sc[col] = sc[col].astype(float)
    st.altair_chart(
        alt.Chart(sc)
        .mark_circle()
        .encode(
            x=alt.X("OTIF_PCT:Q", title="OTIF", axis=alt.Axis(format="%")),
            y=alt.Y("AVG_DELAY_DAYS:Q", title="Avg delay (days)"),
            size=alt.Size("SPEND:Q", title="Spend"),
            color=alt.Color(
                "COMPUTED_RISK_RATING:N",
                scale=alt.Scale(domain=["High", "Medium", "Low"], range=["#b71c1c", "#f9a825", "#2e7d32"]),
                title="Risk",
            ),
            tooltip=["SUPPLIER_NAME", "CATEGORY", alt.Tooltip("OTIF_PCT:Q", format=".1%"),
                     "AVG_DELAY_DAYS", "OPEN_LATE_POS", "COMPUTED_RISK_RATING", "MASTER_DATA_RISK_RATING"],
        )
        .properties(height=300),
        use_container_width=True,
    )

# ---------------- exception queue ----------------
st.subheader("Exception queue")
exc = load(f"SELECT * FROM {DB}.EXCEPTIONS WHERE STATUS <> 'Resolved'")
if exc.empty:
    st.info("No open exceptions. Run CALL SCT.REFRESH_EXCEPTIONS(); (03_exceptions_and_alert.sql).")
else:
    in_scope = exc["PLANT_ID"].isna() | exc["PLANT_ID"].astype(str).isin(plant_ids)
    exc = exc[in_scope]
    types = sorted(exc["EXCEPTION_TYPE"].unique().tolist())
    sel_types = st.multiselect("Exception type", types, default=types)
    sev_rank = {"Critical": 0, "High": 1, "Medium": 2}
    view = exc[exc["EXCEPTION_TYPE"].isin(sel_types)].copy()
    view["REVENUE_AT_RISK"] = view["REVENUE_AT_RISK"].astype(float)
    view["_r"] = view["SEVERITY"].map(sev_rank).fillna(9)
    view = view.sort_values(["_r", "REVENUE_AT_RISK"], ascending=[True, False]).drop(columns="_r")
    st.dataframe(
        view[["SEVERITY", "EXCEPTION_TYPE", "DESCRIPTION", "RECOMMENDED_ACTION", "REVENUE_AT_RISK",
              "OWNER", "STATUS", "DETECTED_AT"]],
        use_container_width=True,
        hide_index=True,
    )

alerts = load(f"SELECT * FROM {DB}.ALERT_LOG ORDER BY FIRED_AT DESC LIMIT 5")
if not alerts.empty:
    with st.expander("Recent critical-stockout alerts"):
        st.dataframe(alerts, use_container_width=True, hide_index=True)
