# FinOps Cost Optimizer - Streamlit in Snowflake
# Create in Snowsight: Projects > Streamlit > + Streamlit App
#   Location: ACCEL_DB.FINOPS, warehouse ACCEL_WH, app role ACCEL_ADMIN (or ACCEL_ANALYST).
# Paste this file. Packages: streamlit, pandas, altair (Anaconda channel defaults).
import decimal

import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="FinOps Cost Optimizer", layout="wide")
session = get_active_session()

SCHEMA = "ACCEL_DB.FINOPS"


@st.cache_data(ttl=900, show_spinner=False)
def run(sql: str) -> pd.DataFrame:
    try:
        df = session.sql(sql).to_pandas()
    except Exception as exc:  # show the error but keep the rest of the app usable
        st.warning(f"Query failed: {exc}")
        return pd.DataFrame()
    return to_float(df)


def to_float(df: pd.DataFrame) -> pd.DataFrame:
    """NUMBER(p,s) can arrive as decimal.Decimal objects; charts need floats."""
    for col in df.columns:
        if df[col].dtype == object and df[col].notna().any():
            if df[col].dropna().map(lambda v: isinstance(v, decimal.Decimal)).all():
                df[col] = df[col].astype(float)
    return df


def metric_value(df: pd.DataFrame, col: str) -> float:
    if df.empty or col not in df.columns or pd.isna(df[col].iloc[0]):
        return 0.0
    return float(df[col].iloc[0])


st.title("FinOps Cost Optimizer")
days = st.sidebar.selectbox("Lookback (days)", [7, 30, 90, 180, 365], index=1)
st.sidebar.caption("ACCOUNT_USAGE data lags 45 min to 3 h. Prices come from ACCEL_DB.FINOPS.FINOPS_CONFIG.")
if st.sidebar.button("Refresh data"):
    st.cache_data.clear()

tab_over, tab_wh, tab_q, tab_sto, tab_ai, tab_rec = st.tabs(
    ["Overview", "Warehouses", "Queries", "Storage", "AI spend", "Recommendations"]
)

# ----------------------------------------------------------------------------- Overview
with tab_over:
    totals = run(f"""
        SELECT SUM(CREDITS_BILLED) AS CREDITS, SUM(COST_USD) AS COST_USD
        FROM {SCHEMA}.V_SPEND_DAILY_BY_SERVICE
        WHERE USAGE_DATE >= DATEADD('day', -{days}, CURRENT_DATE())""")
    prev = run(f"""
        SELECT SUM(COST_USD) AS COST_USD
        FROM {SCHEMA}.V_SPEND_DAILY_BY_SERVICE
        WHERE USAGE_DATE >= DATEADD('day', -{2 * days}, CURRENT_DATE())
          AND USAGE_DATE <  DATEADD('day', -{days}, CURRENT_DATE())""")
    savings = run(f"SELECT SUM(EST_MONTHLY_USD_SAVED) AS USD FROM {SCHEMA}.V_RECOMMENDATIONS_LATEST")
    idle = run(f"SELECT SUM(IDLE_COST_USD_30D) AS USD FROM {SCHEMA}.V_IDLE_WAREHOUSES")

    cost_now = metric_value(totals, "COST_USD")
    cost_prev = metric_value(prev, "COST_USD")
    c1, c2, c3, c4 = st.columns(4)
    c1.metric(f"Spend, last {days} d (USD)", f"{cost_now:,.0f}",
              delta=f"{cost_now - cost_prev:,.0f} vs prior period", delta_color="inverse")
    c2.metric("Credits billed", f"{metric_value(totals, 'CREDITS'):,.1f}")
    c3.metric("Idle warehouse cost, 30 d (USD)", f"{metric_value(idle, 'USD'):,.0f}")
    c4.metric("Est. monthly savings (USD)", f"{metric_value(savings, 'USD'):,.0f}")

    daily = run(f"""
        SELECT USAGE_DATE, SERVICE_TYPE, SUM(COST_USD) AS COST_USD
        FROM {SCHEMA}.V_SPEND_DAILY_BY_SERVICE
        WHERE USAGE_DATE >= DATEADD('day', -{days}, CURRENT_DATE())
        GROUP BY 1, 2""")
    if not daily.empty:
        st.subheader("Daily spend by service type")
        chart = alt.Chart(daily).mark_bar().encode(
            x=alt.X("USAGE_DATE:T", title="Date"),
            y=alt.Y("COST_USD:Q", title="USD"),
            color=alt.Color("SERVICE_TYPE:N", title="Service"),
            tooltip=["USAGE_DATE:T", "SERVICE_TYPE:N", alt.Tooltip("COST_USD:Q", format=",.2f")],
        )
        st.altair_chart(chart, use_container_width=True)
    else:
        st.info("No metering data yet for this period.")

    cc = run(f"""
        SELECT COST_CENTER, SUM(COST_USD) AS COST_USD
        FROM {SCHEMA}.V_COST_BY_CENTER_WAREHOUSE
        WHERE MONTH >= DATE_TRUNC('month', DATEADD('day', -{days}, CURRENT_DATE()))
        GROUP BY 1 ORDER BY 2 DESC""")
    if not cc.empty:
        st.subheader("Warehouse spend by COST_CENTER tag")
        st.bar_chart(cc, x="COST_CENTER", y="COST_USD")

# ----------------------------------------------------------------------------- Warehouses
with tab_wh:
    wh = run(f"""
        SELECT WAREHOUSE_NAME, SUM(CREDITS_USED) AS CREDITS, SUM(CREDITS_IDLE) AS CREDITS_IDLE,
               SUM(COST_USD) AS COST_USD
        FROM {SCHEMA}.V_SPEND_DAILY_BY_WAREHOUSE
        WHERE USAGE_DATE >= DATEADD('day', -{days}, CURRENT_DATE())
        GROUP BY 1 ORDER BY COST_USD DESC""")
    if not wh.empty:
        st.subheader("Credits by warehouse (busy vs idle)")
        wh["CREDITS_BUSY"] = (wh["CREDITS"] - wh["CREDITS_IDLE"]).clip(lower=0)
        melted = wh.melt(id_vars="WAREHOUSE_NAME", value_vars=["CREDITS_BUSY", "CREDITS_IDLE"],
                         var_name="KIND", value_name="CREDITS_VALUE")
        chart = alt.Chart(melted).mark_bar().encode(
            x=alt.X("CREDITS_VALUE:Q", title="Credits"),
            y=alt.Y("WAREHOUSE_NAME:N", sort="-x", title=None),
            color=alt.Color("KIND:N", title=None),
            tooltip=["WAREHOUSE_NAME", "KIND", alt.Tooltip("CREDITS_VALUE:Q", format=",.2f")],
        )
        st.altair_chart(chart, use_container_width=True)
    st.subheader("Guardrail flags")
    st.dataframe(run(f"SELECT * FROM {SCHEMA}.V_WAREHOUSE_GUARDRAILS ORDER BY CREDITS_IDLE_30D DESC NULLS LAST"),
                 use_container_width=True)
    st.caption("Settings snapshot from CALL ACCEL_DB.FINOPS.SNAPSHOT_WAREHOUSES().")

# ----------------------------------------------------------------------------- Queries
with tab_q:
    st.subheader("Most expensive query shapes (last 30 days)")
    st.dataframe(run(f"""
        SELECT SAMPLE_QUERY_TEXT, EXECUTIONS, ROUND(CREDITS, 3) AS CREDITS, ROUND(COST_USD, 2) AS COST_USD,
               SAMPLE_WAREHOUSE, WAREHOUSE_SIZE, SAMPLE_USER, MOST_EXPENSIVE_QUERY_ID, LAST_RUN
        FROM {SCHEMA}.V_TOP_QUERIES ORDER BY CREDITS DESC LIMIT 50"""), use_container_width=True)
    col_a, col_b = st.columns(2)
    with col_a:
        st.subheader("Top users (30 days)")
        users = run(f"SELECT USER_NAME, CREDITS, COST_USD, QUERIES FROM {SCHEMA}.V_TOP_USERS ORDER BY CREDITS DESC LIMIT 20")
        if not users.empty:
            st.bar_chart(users, x="USER_NAME", y="COST_USD")
        st.dataframe(users, use_container_width=True)
    with col_b:
        st.subheader("Queries spilling to storage")
        st.dataframe(run(f"""
            SELECT WAREHOUSE_NAME, WAREHOUSE_SIZE, COUNT(*) AS QUERIES,
                   SUM(GB_SPILLED_LOCAL) AS GB_LOCAL, SUM(GB_SPILLED_REMOTE) AS GB_REMOTE
            FROM {SCHEMA}.V_SPILLING_QUERIES GROUP BY 1, 2 ORDER BY GB_REMOTE DESC, GB_LOCAL DESC"""),
            use_container_width=True)

# ----------------------------------------------------------------------------- Storage
with tab_sto:
    sto = run(f"""
        SELECT USAGE_DATE, SUM(DATABASE_TB + FAILSAFE_TB) AS TB
        FROM {SCHEMA}.V_STORAGE_DAILY GROUP BY 1 ORDER BY 1""")
    if not sto.empty:
        st.subheader("Total storage (TB, incl. Fail-safe)")
        st.line_chart(sto, x="USAGE_DATE", y="TB")
    st.subheader("Largest tables")
    st.dataframe(run(f"""
        SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, ACTIVE_GB, TIME_TRAVEL_GB, FAILSAFE_GB,
               CLONE_RETAINED_GB, ROUND(EST_MONTHLY_COST_USD, 2) AS EST_MONTHLY_COST_USD
        FROM {SCHEMA}.V_TABLE_STORAGE ORDER BY EST_MONTHLY_COST_USD DESC LIMIT 50"""), use_container_width=True)
    st.subheader("Tables not read for 90 days")
    st.dataframe(run(f"""
        SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_OWNER, SIZE_GB, LAST_ALTERED,
               ROUND(EST_MONTHLY_COST_USD, 2) AS EST_MONTHLY_COST_USD
        FROM {SCHEMA}.V_UNUSED_TABLES ORDER BY SIZE_GB DESC LIMIT 200"""), use_container_width=True)

# ----------------------------------------------------------------------------- AI spend
with tab_ai:
    ai_daily = run(f"""
        SELECT USAGE_DATE, SERVICE_TYPE, COST_USD FROM {SCHEMA}.V_AI_SPEND_DAILY
        WHERE USAGE_DATE >= DATEADD('day', -{days}, CURRENT_DATE())""")
    if not ai_daily.empty:
        st.subheader("AI services spend per day")
        chart = alt.Chart(ai_daily).mark_area().encode(
            x=alt.X("USAGE_DATE:T", title="Date"),
            y=alt.Y("COST_USD:Q", title="USD"),
            color=alt.Color("SERVICE_TYPE:N", title=None),
        )
        st.altair_chart(chart, use_container_width=True)
    else:
        st.info("No AI services usage in this period.")
    by_model = run(f"""
        SELECT FUNCTION_NAME, COALESCE(MODEL_NAME, '(default)') AS MODEL_NAME,
               SUM(QUERIES) AS QUERIES, SUM(CREDITS) AS CREDITS, SUM(COST_USD) AS COST_USD
        FROM {SCHEMA}.V_AI_SPEND_BY_FUNCTION_MODEL
        WHERE USAGE_DATE >= DATEADD('day', -{days}, CURRENT_DATE())
        GROUP BY 1, 2 ORDER BY CREDITS DESC""")
    col_a, col_b = st.columns(2)
    with col_a:
        st.subheader("By AI function and model")
        st.dataframe(by_model, use_container_width=True)
    with col_b:
        st.subheader("By user")
        st.dataframe(run(f"""
            SELECT COALESCE(USER_NAME, '(unknown)') AS USER_NAME, SUM(CREDITS) AS CREDITS, SUM(COST_USD) AS COST_USD
            FROM {SCHEMA}.V_AI_SPEND_BY_FUNCTION_MODEL
            WHERE USAGE_DATE >= DATEADD('day', -{days}, CURRENT_DATE())
            GROUP BY 1 ORDER BY CREDITS DESC"""), use_container_width=True)
    st.subheader("Cortex Analyst, Search and Agents")
    st.dataframe(run(f"""
        SELECT SERVICE, DETAIL, SUM(CREDITS) AS CREDITS
        FROM {SCHEMA}.V_AI_SPEND_OTHER_SERVICES
        WHERE USAGE_DATE >= DATEADD('day', -{days}, CURRENT_DATE())
        GROUP BY 1, 2 ORDER BY CREDITS DESC"""), use_container_width=True)

# ----------------------------------------------------------------------------- Recommendations
with tab_rec:
    if st.button("Re-run recommendations now"):
        try:
            msg = session.sql(f"CALL {SCHEMA}.GENERATE_RECOMMENDATIONS()").collect()[0][0]
            st.success(msg)
            st.cache_data.clear()
        except Exception as exc:
            st.error(f"Could not run GENERATE_RECOMMENDATIONS: {exc}")
    rec = run(f"""
        SELECT SEVERITY, CATEGORY, OBJECT_NAME, FINDING, RECOMMENDATION,
               EST_MONTHLY_CREDITS_SAVED, EST_MONTHLY_USD_SAVED, FIX_SQL, RUN_TS
        FROM {SCHEMA}.V_RECOMMENDATIONS_LATEST
        ORDER BY EST_MONTHLY_USD_SAVED DESC""")
    if rec.empty:
        st.info("No recommendations yet. Run CALL ACCEL_DB.FINOPS.GENERATE_RECOMMENDATIONS().")
    else:
        categories = sorted(rec["CATEGORY"].dropna().unique().tolist())
        chosen = st.multiselect("Category", categories, default=categories)
        view = rec[rec["CATEGORY"].isin(chosen)]
        st.metric("Estimated monthly savings (USD)", f"{view['EST_MONTHLY_USD_SAVED'].fillna(0).sum():,.0f}")
        st.dataframe(view, use_container_width=True)
        fixes = view["FIX_SQL"].dropna().tolist()
        if fixes:
            st.subheader("Fix statements (review before running)")
            st.code("\n".join(fixes), language="sql")
