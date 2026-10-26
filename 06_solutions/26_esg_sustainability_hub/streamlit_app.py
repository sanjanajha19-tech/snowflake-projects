"""ESG & Sustainability dashboard - Streamlit in Snowflake app (asset 26).

Create in Snowsight: Projects > Streamlit > + Streamlit App,
location ACCEL_DB.ESG, warehouse ACCEL_WH, then paste this file.
Packages: streamlit, pandas, altair (pre-installed in Streamlit in Snowflake).
"""
import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="ESG & Sustainability Hub", layout="wide")
session = get_active_session()

DB = "ACCEL_DB.ESG"
SCOPE_COLORS = alt.Scale(
    domain=["Scope 1", "Scope 2", "Scope 3"], range=["#1b5e20", "#0277bd", "#9e9d24"]
)


@st.cache_data(ttl=600)
def load(query):
    return session.sql(query).to_pandas()


detail = load(
    f"""
    SELECT d.PLANT_ID::VARCHAR AS PLANT_ID, COALESCE(p.PLANT_NAME, d.PLANT_ID::VARCHAR) AS PLANT_NAME,
           d.PLANT_COUNTRY, d.PERIOD_MONTH, d.CALENDAR_YEAR, d.INDIAN_FY, d.SCOPE, d.GHG_CATEGORY,
           d.ACTIVITY_TYPE, d.SUB_TYPE, d.QUANTITY::FLOAT AS QUANTITY, d.UNIT, d.TCO2E::FLOAT AS TCO2E,
           d.DATA_QUALITY, d.DATA_STATUS, d.FACTOR_IS_PLACEHOLDER
    FROM {DB}.EMISSIONS_DETAIL d
    LEFT JOIN ACCEL_DB.DEMO.PLANTS p ON p.PLANT_ID = d.PLANT_ID
    """
)

st.title("ESG & Sustainability Hub")
if detail.empty:
    st.error("No emissions data. Run files 01-03 of asset 26 first.")
    st.stop()

if detail["FACTOR_IS_PLACEHOLDER"].any():
    st.warning(
        "This dashboard uses **placeholder emission factors** (ESG.EMISSION_FACTORS, IS_PLACEHOLDER = TRUE). "
        "Replace them with official values (e.g. CEA, DEFRA/DESNZ, IPCC, EEIO) before using any figure "
        "externally. Outputs support - and do not replace - assured reporting."
    )

with st.sidebar:
    st.header("Filters")
    include_projected = st.checkbox("Include projected months", value=False)
    years = sorted(detail["CALENDAR_YEAR"].unique().tolist())
    sel_years = st.multiselect("Calendar year", years, default=years)
    plants = sorted(detail["PLANT_NAME"].unique().tolist())
    sel_plants = st.multiselect("Plant", plants, default=plants)

df = detail[detail["CALENDAR_YEAR"].isin(sel_years) & detail["PLANT_NAME"].isin(sel_plants)]
if not include_projected:
    df = df[df["DATA_STATUS"] == "Actual"]
if df.empty:
    st.info("No data for this selection.")
    st.stop()

# ---------------- KPIs ----------------
by_scope = df.groupby("SCOPE")["TCO2E"].sum()
s1, s2, s3 = (float(by_scope.get(k, 0.0)) for k in ["Scope 1", "Scope 2", "Scope 3"])
inten = load(f"SELECT * FROM {DB}.INTENSITY_MONTHLY")
inten["PLANT_ID"] = inten["PLANT_ID"].astype(str)
inten = inten[
    inten["CALENDAR_YEAR"].isin(sel_years)
    & inten["PLANT_ID"].isin(df["PLANT_ID"].unique())
    & (inten["DATA_STATUS"].isin(["Actual", "Projected"] if include_projected else ["Actual"]))
]
units = float(inten["UNITS_PRODUCED"].astype(float).sum())
crore = float(inten["REVENUE_INR_CRORE"].astype(float).sum())

k1, k2, k3, k4, k5 = st.columns(5)
k1.metric("Scope 1 (tCO2e)", f"{s1:,.0f}")
k2.metric("Scope 2 location (tCO2e)", f"{s2:,.0f}")
k3.metric("Scope 3 cat 1+4 (tCO2e)", f"{s3:,.0f}")
k4.metric("S1+2 per unit (kgCO2e)", f"{(s1 + s2) / units * 1000:,.3f}" if units else "n/a")
k5.metric("S1+2 per INR crore (tCO2e)", f"{(s1 + s2) / crore:,.2f}" if crore else "n/a")

# ---------------- trend ----------------
st.subheader("Monthly emissions by scope")
trend = df.groupby(["PERIOD_MONTH", "SCOPE"])["TCO2E"].sum().reset_index()
trend["PERIOD_MONTH"] = pd.to_datetime(trend["PERIOD_MONTH"])
st.altair_chart(
    alt.Chart(trend)
    .mark_area()
    .encode(
        x=alt.X("PERIOD_MONTH:T", title=None),
        y=alt.Y("TCO2E:Q", title="tCO2e", stack=True),
        color=alt.Color("SCOPE:N", scale=SCOPE_COLORS, title=None),
        tooltip=["PERIOD_MONTH:T", "SCOPE", alt.Tooltip("TCO2E:Q", format=",.1f")],
    )
    .properties(height=300),
    use_container_width=True,
)

c1, c2 = st.columns(2)
with c1:
    st.subheader("By plant")
    plant = df.groupby(["PLANT_NAME", "SCOPE"])["TCO2E"].sum().reset_index()
    st.altair_chart(
        alt.Chart(plant)
        .mark_bar()
        .encode(
            y=alt.Y("PLANT_NAME:N", sort="-x", title=None),
            x=alt.X("TCO2E:Q", title="tCO2e"),
            color=alt.Color("SCOPE:N", scale=SCOPE_COLORS, title=None),
            tooltip=["PLANT_NAME", "SCOPE", alt.Tooltip("TCO2E:Q", format=",.1f")],
        )
        .properties(height=300),
        use_container_width=True,
    )
with c2:
    st.subheader("By source")
    src = df.groupby(["GHG_CATEGORY", "ACTIVITY_TYPE", "SUB_TYPE"])["TCO2E"].sum().reset_index()
    src["SOURCE"] = src["ACTIVITY_TYPE"] + " · " + src["SUB_TYPE"]
    top = src.sort_values("TCO2E", ascending=False).head(12)
    st.altair_chart(
        alt.Chart(top)
        .mark_bar(color="#455a64")
        .encode(
            y=alt.Y("SOURCE:N", sort="-x", title=None),
            x=alt.X("TCO2E:Q", title="tCO2e"),
            tooltip=["GHG_CATEGORY", "SOURCE", alt.Tooltip("TCO2E:Q", format=",.1f")],
        )
        .properties(height=300),
        use_container_width=True,
    )

# ---------------- intensity ----------------
st.subheader("Intensity trend (Scope 1+2)")
it = inten.copy()
for col in ["SCOPE1_TCO2E", "SCOPE2_LOCATION_TCO2E", "UNITS_PRODUCED", "REVENUE_INR_CRORE"]:
    it[col] = it[col].astype(float)
it = it.groupby("PERIOD_MONTH")[["SCOPE1_TCO2E", "SCOPE2_LOCATION_TCO2E", "UNITS_PRODUCED", "REVENUE_INR_CRORE"]].sum()
it["kgCO2e per unit"] = (it["SCOPE1_TCO2E"] + it["SCOPE2_LOCATION_TCO2E"]) / it["UNITS_PRODUCED"].where(it["UNITS_PRODUCED"] > 0) * 1000
it["tCO2e per INR crore"] = (it["SCOPE1_TCO2E"] + it["SCOPE2_LOCATION_TCO2E"]) / it["REVENUE_INR_CRORE"].where(it["REVENUE_INR_CRORE"] > 0)
it = it.reset_index()
it["PERIOD_MONTH"] = pd.to_datetime(it["PERIOD_MONTH"])
metric = st.radio("Intensity metric", ["kgCO2e per unit", "tCO2e per INR crore"], horizontal=True)
st.altair_chart(
    alt.Chart(it)
    .mark_line(point=True, color="#1b5e20")
    .encode(
        x=alt.X("PERIOD_MONTH:T", title=None),
        y=alt.Y(f"{metric}:Q", title=metric),
        tooltip=["PERIOD_MONTH:T", alt.Tooltip(f"{metric}:Q", format=",.3f")],
    )
    .properties(height=260),
    use_container_width=True,
)

# ---------------- disclosures ----------------
tab_brsr, tab_ghg, tab_dq, tab_fac = st.tabs(
    ["BRSR-style (P6)", "GHG summary", "Data quality & evidence", "Emission factors"]
)
with tab_brsr:
    brsr = load(f"SELECT * FROM {DB}.BRSR_P6_SUMMARY ORDER BY INDIAN_FY, SORT_ORDER")
    fys = brsr["INDIAN_FY"].unique().tolist()
    fy = st.selectbox("Financial year", fys, index=max(len(fys) - 1, 0)) if fys else None
    if fy:
        view = brsr[brsr["INDIAN_FY"] == fy].drop(columns=["SORT_ORDER"])
        st.caption(f"{view['COVERAGE'].iat[0]} · {view['FACTOR_STATUS'].iat[0]}")
        view = view.assign(VALUE=view["VALUE"].map(lambda v: f"{v:,.6g}" if pd.notna(v) else ""))
        st.dataframe(view[["REF", "INDICATOR", "VALUE", "UNIT", "EST_SHARE"]], use_container_width=True, hide_index=True)
    st.caption("BRSR-style layout for preparation support only - use the official SEBI format for filing.")
with tab_ghg:
    st.dataframe(
        load(f"SELECT * FROM {DB}.GHG_DISCLOSURE_SUMMARY ORDER BY CALENDAR_YEAR DESC, SCOPE, GHG_CATEGORY"),
        use_container_width=True,
        hide_index=True,
    )
with tab_dq:
    dq = load(f"SELECT * FROM {DB}.DATA_QUALITY_SUMMARY")
    dq = dq[dq["CALENDAR_YEAR"].isin(sel_years)]
    q1, q2, q3 = st.columns(3)
    q1.metric("Avg completeness", f"{dq['COMPLETENESS'].astype(float).mean():.0%}" if not dq.empty else "n/a")
    q2.metric("Evidence verified", f"{dq['EVIDENCE_VERIFIED_SHARE'].astype(float).mean():.0%}" if not dq.empty else "n/a")
    q3.metric("Evidence gaps", int(dq["EVIDENCE_GAPS"].sum()) if not dq.empty else 0)
    st.dataframe(dq.sort_values("EVIDENCE_GAPS", ascending=False), use_container_width=True, hide_index=True)
    st.markdown("**Open evidence items**")
    st.dataframe(
        load(
            f"""
            SELECT PLANT_ID, PERIOD_MONTH, ACTIVITY_TYPE, EVIDENCE_TYPE, STATUS, DATA_OWNER, NOTES
            FROM {DB}.EVIDENCE_TRACKER
            WHERE STATUS IN ('Pending', 'Rejected')
            ORDER BY PERIOD_MONTH DESC LIMIT 200
            """
        ),
        use_container_width=True,
        hide_index=True,
    )
with tab_fac:
    st.dataframe(
        load(f"SELECT * FROM {DB}.EMISSION_FACTORS ORDER BY ACTIVITY_TYPE, SUB_TYPE, COUNTRY"),
        use_container_width=True,
        hide_index=True,
    )
