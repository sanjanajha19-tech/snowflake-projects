"""Data Health Checker - Streamlit UI running inside the Native App."""

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()

st.set_page_config(page_title="Data Health Checker", layout="wide")
st.title("Data Health Checker")
st.caption("Profiles one table you choose: completeness, uniqueness, value ranges and an overall health score.")


def reference_is_bound() -> bool:
    """True when the consumer has bound a table to the 'consumer_table' reference."""
    try:
        session.sql("SELECT 1 FROM reference('consumer_table') LIMIT 1").collect()
        return True
    except Exception:  # noqa: BLE001 - any failure means "not usable yet"
        return False


def load_runs() -> pd.DataFrame:
    return session.sql(
        "SELECT RUN_ID, RUN_TS, ROW_COUNT, COLUMN_COUNT, DUPLICATE_ROWS_EST, "
        "AVG_NULL_PCT, COLUMNS_WITH_ISSUES, HEALTH_SCORE "
        "FROM DATA.PROFILE_RUNS ORDER BY RUN_TS DESC LIMIT 50"
    ).to_pandas()


def load_columns(run_id: str) -> pd.DataFrame:
    return session.sql(
        "SELECT ORDINAL, COLUMN_NAME, DATA_TYPE, NULL_COUNT, NULL_PCT, DISTINCT_EST, "
        "DISTINCT_PCT, MIN_VALUE, MAX_VALUE, ISSUES "
        "FROM DATA.COLUMN_PROFILES WHERE RUN_ID = ? ORDER BY ORDINAL",
        params=[run_id],
    ).to_pandas()


if not reference_is_bound():
    st.warning("No table is bound yet. Grant the app access to the table you want to profile.")
    st.markdown(
        """
**Option 1 - Snowsight:** open this app, go to the **Security** (or *Privileges*) tab and
grant **Table to profile**. Pick any table.

**Option 2 - SQL** (run as the app owner role in a worksheet; replace the names):
```sql
CALL <APP_NAME>.CORE.REGISTER_SINGLE_REFERENCE(
  'consumer_table', 'ADD',
  SYSTEM$REFERENCE('TABLE', 'MY_DB.MY_SCHEMA.MY_TABLE', 'PERSISTENT', 'SELECT'));
```
Then reload this page.
"""
    )
    st.stop()

col_run, col_info = st.columns([1, 3])
with col_run:
    if st.button("Run profile now", type="primary"):
        with st.spinner("Profiling..."):
            result = session.sql("CALL CORE.PROFILE_TABLE()").collect()[0][0]
        st.success("Profile complete")
        st.code(str(result))
with col_info:
    st.info("The app only has SELECT on the single table you granted. Results are stored inside the app.")

runs = load_runs()
if runs.empty:
    st.write("No profile runs yet. Click **Run profile now**.")
    st.stop()

latest = runs.iloc[0]
k1, k2, k3, k4, k5 = st.columns(5)
k1.metric("Health score", f"{float(latest['HEALTH_SCORE']):.1f} / 100")
k2.metric("Rows", f"{int(latest['ROW_COUNT']):,}")
k3.metric("Columns", int(latest["COLUMN_COUNT"]))
k4.metric("Avg null %", f"{float(latest['AVG_NULL_PCT']):.2f}")
k5.metric("Est. duplicate rows", f"{int(latest['DUPLICATE_ROWS_EST']):,}")

run_labels = [f"{r.RUN_TS} | score {float(r.HEALTH_SCORE):.1f}" for r in runs.itertuples()]
choice = st.selectbox("Profile run", options=list(range(len(runs))), format_func=lambda i: run_labels[i])
cols = load_columns(str(runs.iloc[choice]["RUN_ID"]))

only_issues = st.checkbox("Show only columns with issues", value=False)
view = cols[cols["ISSUES"].notna()] if only_issues else cols

st.subheader("Column profile")
st.dataframe(view, use_container_width=True)

st.subheader("Null % by column")
chart_df = cols[["COLUMN_NAME", "NULL_PCT"]].set_index("COLUMN_NAME")
chart_df["NULL_PCT"] = chart_df["NULL_PCT"].astype(float)
st.bar_chart(chart_df)

if len(runs) > 1:
    st.subheader("Health score trend")
    trend = runs[["RUN_TS", "HEALTH_SCORE"]].sort_values("RUN_TS").set_index("RUN_TS")
    trend["HEALTH_SCORE"] = trend["HEALTH_SCORE"].astype(float)
    st.line_chart(trend)
