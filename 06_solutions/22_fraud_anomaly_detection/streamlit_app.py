"""Fraud Case Review - Streamlit in Snowflake app (Accelerator 22).

Create in Snowsight: Projects > Streamlit > + Streamlit App,
location ACCEL_DB.FRAUD, warehouse ACCEL_WH. Paste this file.
Needs files 01-04 to have been run (FRAUD_CASES, SET_CASE_STATUS, V_TXN_RULE_SCORES).
"""

import datetime as dt

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

SCHEMA = "ACCEL_DB.FRAUD"
STATUSES = ["Open", "Investigating", "Confirmed fraud", "False positive"]

st.set_page_config(page_title="Fraud Case Review", layout="wide")
session = get_active_session()


@st.cache_data(ttl=300)
def run_query(sql: str, params: tuple = ()) -> pd.DataFrame:
    return session.sql(sql, params=list(params)).to_pandas()


def q_in(values) -> str:
    """Render a list of strings as a SQL IN list with escaped quotes."""
    escaped = ["'" + str(v).replace("'", "''") + "'" for v in values]
    return ", ".join(escaped) if escaped else "''"


def viewer_name() -> str:
    """Best-effort name of the person using the app (falls back to the session user)."""
    for attr in ("user", "experimental_user"):
        try:
            info = getattr(st, attr)
            name = info.get("user_name") or info.get("login_name") or info.get("email")
            if name:
                return str(name)
        except Exception:
            continue
    try:
        return str(session.sql("SELECT CURRENT_USER()").collect()[0][0])
    except Exception:
        return "unknown"


st.title("Fraud Case Review")
st.caption(
    "Cases combine rule flags (velocity, impossible travel, new high-risk merchant, amount spike, "
    "new device at night, card present abroad) with SNOWFLAKE.ML.ANOMALY_DETECTION on daily spend. "
    "Refresh with CALL ACCEL_DB.FRAUD.REFRESH_FRAUD_CASES()."
)

# ---------------------------------------------------------------- filters
meta = run_query(f"SELECT MIN(CASE_DATE) AS MIN_D, MAX(CASE_DATE) AS MAX_D, COUNT(*) AS N FROM {SCHEMA}.FRAUD_CASES")
if meta.empty or int(meta["N"].iloc[0]) == 0:
    st.warning("No cases yet. Run 04_alerts_and_cases.sql (CALL ACCEL_DB.FRAUD.REFRESH_FRAUD_CASES()).")
    st.stop()

min_d = pd.to_datetime(meta["MIN_D"].iloc[0]).date()
max_d = pd.to_datetime(meta["MAX_D"].iloc[0]).date()

with st.sidebar:
    st.header("Filters")
    date_range = st.date_input("Case date", value=(min_d, max_d), min_value=min_d, max_value=max_d)
    sel_status = st.multiselect("Status", STATUSES, default=["Open", "Investigating"])
    sel_bands = st.multiselect("Risk band", ["High", "Medium"], default=["High", "Medium"])
    sel_detect = st.multiselect("Detected by", ["Rules", "ML", "Rules + ML"], default=["Rules", "ML", "Rules + ML"])
    min_score = st.slider("Minimum risk score", 0, 100, 40)
    queued_only = st.checkbox("Only cases in the alert queue", value=False)
    search = st.text_input("Customer ID or name contains", "")
    if st.button("Refresh data"):
        st.cache_data.clear()
        st.rerun()

if isinstance(date_range, (tuple, list)) and len(date_range) == 2:
    d_from, d_to = date_range
else:
    d_from, d_to = min_d, max_d

where = [
    f"c.CASE_DATE BETWEEN '{d_from}' AND '{d_to}'",
    f"c.RISK_SCORE >= {int(min_score)}",
    f"c.STATUS IN ({q_in(sel_status)})",
    f"c.RISK_BAND IN ({q_in(sel_bands)})",
    f"c.DETECTED_BY IN ({q_in(sel_detect)})",
]
if queued_only:
    where.append("q.CASE_ID IS NOT NULL")
params: tuple = ()
if search.strip():
    where.append("(TO_VARCHAR(c.CUSTOMER_ID) = ? OR c.CUSTOMER_NAME ILIKE ?)")
    params = (search.strip(), f"%{search.strip()}%")
where_sql = " AND ".join(where)

cases = run_query(
    f"""
    SELECT c.CASE_ID, c.CASE_DATE, c.CUSTOMER_ID, c.CUSTOMER_NAME, c.SEGMENT, c.HOME_CITY, c.HOME_COUNTRY,
           c.RISK_SCORE, c.RISK_BAND, c.DETECTED_BY, c.RULE_SCORE, c.ML_ANOMALY,
           c.FLAGGED_TXNS, c.FLAGGED_AMOUNT_USD, c.DAY_TXNS, c.DAY_SPEND_USD,
           c.ML_EXPECTED_SPEND, c.ML_UPPER_BOUND, c.REASONS,
           c.STATUS, c.ASSIGNED_TO, c.ANALYST_NOTES, c.STATUS_UPDATED_AT, c.STATUS_UPDATED_BY,
           (q.CASE_ID IS NOT NULL) AS IN_QUEUE, q.QUEUED_AT, c.IS_FRAUD_INJECTED
    FROM {SCHEMA}.FRAUD_CASES c
    LEFT JOIN (SELECT CASE_ID, MIN(QUEUED_AT) AS QUEUED_AT FROM {SCHEMA}.CASE_QUEUE GROUP BY CASE_ID) q
           ON q.CASE_ID = c.CASE_ID
    WHERE {where_sql}
    ORDER BY c.RISK_SCORE DESC, c.FLAGGED_AMOUNT_USD DESC
    LIMIT 2000
    """,
    params,
)

# ---------------------------------------------------------------- KPIs
totals = run_query(
    f"""
    SELECT COUNT_IF(STATUS IN ('Open', 'Investigating'))                     AS OPEN_CASES,
           COUNT_IF(STATUS IN ('Open', 'Investigating') AND RISK_BAND = 'High') AS OPEN_HIGH,
           COUNT_IF(STATUS = 'Confirmed fraud')                               AS CONFIRMED,
           COUNT_IF(STATUS = 'False positive')                                AS FALSE_POS,
           SUM(IFF(STATUS IN ('Open', 'Investigating'), FLAGGED_AMOUNT_USD, 0)) AS OPEN_EXPOSURE
    FROM {SCHEMA}.FRAUD_CASES
    """
)
t = totals.iloc[0]
confirmed = int(t["CONFIRMED"] or 0)
false_pos = int(t["FALSE_POS"] or 0)
hit_rate = f"{100 * confirmed / (confirmed + false_pos):.0f}%" if (confirmed + false_pos) else "n/a"

k1, k2, k3, k4, k5 = st.columns(5)
k1.metric("Cases in view", f"{len(cases):,}")
k2.metric("Open / investigating", f"{int(t['OPEN_CASES'] or 0):,}")
k3.metric("Open high risk", f"{int(t['OPEN_HIGH'] or 0):,}")
k4.metric("Open exposure (USD)", f"{float(t['OPEN_EXPOSURE'] or 0):,.0f}")
k5.metric("Confirmed-fraud rate of closed", hit_rate)

tab_cases, tab_overview = st.tabs(["Case queue", "Overview"])

with tab_overview:
    c1, c2 = st.columns(2)
    by_day = run_query(
        f"SELECT CASE_DATE, RISK_BAND, COUNT(*) AS CASES FROM {SCHEMA}.FRAUD_CASES "
        f"GROUP BY 1, 2 ORDER BY 1"
    )
    with c1:
        st.subheader("Cases per day")
        if not by_day.empty:
            pivot = by_day.pivot_table(index="CASE_DATE", columns="RISK_BAND", values="CASES", fill_value=0)
            st.bar_chart(pivot)
    with c2:
        st.subheader("Status by detector")
        mix = run_query(
            f"SELECT DETECTED_BY, STATUS, COUNT(*) AS CASES FROM {SCHEMA}.FRAUD_CASES GROUP BY 1, 2 ORDER BY 1, 2"
        )
        st.dataframe(mix, use_container_width=True, hide_index=True)
    st.subheader("Rule performance vs injected ground truth")
    st.dataframe(run_query(f"SELECT * FROM {SCHEMA}.V_RULE_EVALUATION ORDER BY RULE_CODE"),
                 use_container_width=True, hide_index=True)

with tab_cases:
    if cases.empty:
        st.info("No cases match the filters.")
        st.stop()

    show_cols = ["CASE_ID", "CASE_DATE", "CUSTOMER_ID", "CUSTOMER_NAME", "RISK_SCORE", "RISK_BAND",
                 "DETECTED_BY", "FLAGGED_AMOUNT_USD", "STATUS", "ASSIGNED_TO", "IN_QUEUE", "REASONS"]
    st.dataframe(cases[show_cols], use_container_width=True, hide_index=True, height=320)

    case_id = st.selectbox("Open case", cases["CASE_ID"].tolist())
    case = cases[cases["CASE_ID"] == case_id].iloc[0]

    st.divider()
    h1, h2, h3, h4 = st.columns(4)
    h1.metric("Risk score", int(case["RISK_SCORE"]), help=f"Band: {case['RISK_BAND']}")
    h2.metric("Rule score", int(case["RULE_SCORE"]))
    h3.metric("Flagged amount (USD)", f"{float(case['FLAGGED_AMOUNT_USD'] or 0):,.2f}")
    if bool(case["ML_ANOMALY"]):
        h4.metric("Day spend vs ML expected (USD)",
                  f"{float(case['DAY_SPEND_USD'] or 0):,.0f}",
                  delta=f"{float(case['DAY_SPEND_USD'] or 0) - float(case['ML_EXPECTED_SPEND'] or 0):,.0f}",
                  delta_color="inverse")
    else:
        h4.metric("Day spend (USD)", f"{float(case['DAY_SPEND_USD'] or 0):,.0f}")

    left, right = st.columns([3, 2])
    with left:
        st.markdown(
            f"**{case['CUSTOMER_NAME']}** (customer {int(case['CUSTOMER_ID'])}, {case['SEGMENT']}), "
            f"home {case['HOME_CITY']}, {case['HOME_COUNTRY']}  \n"
            f"Case date **{case['CASE_DATE']}** · detected by **{case['DETECTED_BY']}** · "
            f"status **{case['STATUS']}**"
            + (f" · assigned to {case['ASSIGNED_TO']}" if pd.notna(case["ASSIGNED_TO"]) and case["ASSIGNED_TO"] else "")
        )
        st.markdown("**Why this case was raised**")
        for reason in (str(case["REASONS"]) if pd.notna(case["REASONS"]) else "").split("; "):
            if reason:
                st.markdown(f"- {reason}")
        with st.expander("Ground truth (demo only)"):
            st.write("Injected fraud on this day:", bool(case["IS_FRAUD_INJECTED"]))

    with right:
        st.markdown("**Update status**")
        note = st.text_area("Note (optional)", key=f"note_{case_id}", height=80)
        b1, b2 = st.columns(2)
        b3, b4 = st.columns(2)
        clicked = None
        if b1.button("Investigating", key=f"inv_{case_id}", use_container_width=True):
            clicked = "Investigating"
        if b2.button("Confirmed fraud", key=f"cf_{case_id}", type="primary", use_container_width=True):
            clicked = "Confirmed fraud"
        if b3.button("False positive", key=f"fp_{case_id}", use_container_width=True):
            clicked = "False positive"
        if b4.button("Reopen", key=f"ro_{case_id}", use_container_width=True):
            clicked = "Open"
        if clicked:
            result = session.call(f"{SCHEMA}.SET_CASE_STATUS", case_id, clicked, note or "", viewer_name())
            st.cache_data.clear()
            st.success(str(result))
            st.rerun()
        if pd.notna(case["ANALYST_NOTES"]) and case["ANALYST_NOTES"]:
            st.markdown("**Notes**")
            st.text(str(case["ANALYST_NOTES"]))

    # Customer's recent transactions around the case date
    st.subheader("Customer's recent transactions")
    window_days = st.slider("Days before the case date", 1, 60, 14, key=f"win_{case_id}")
    case_date = pd.to_datetime(case["CASE_DATE"]).date()
    txns = run_query(
        f"""
        SELECT TXN_ID, TXN_TS, MERCHANT_NAME, MERCHANT_CATEGORY, CHANNEL, AMOUNT_USD, TXN_CITY, TXN_COUNTRY,
               DEVICE_ID, RULE_SCORE, RULE_REASONS, AMOUNT_RATIO, TXN_COUNT_1H, IMPLIED_KMH
        FROM {SCHEMA}.V_TXN_RULE_SCORES
        WHERE CUSTOMER_ID = ?
          AND TXN_TS >= ?::DATE
          AND TXN_TS < ?::DATE
        ORDER BY TXN_TS DESC
        """,
        (
            int(case["CUSTOMER_ID"]),
            str(case_date - dt.timedelta(days=int(window_days))),
            str(case_date + dt.timedelta(days=1)),
        ),
    )
    if txns.empty:
        st.info("No transactions in this window.")
    else:
        txns["FLAGGED"] = txns["RULE_SCORE"].astype(float) > 0
        st.dataframe(txns, use_container_width=True, hide_index=True)
        daily = txns.assign(DAY=pd.to_datetime(txns["TXN_TS"]).dt.date).groupby("DAY")["AMOUNT_USD"].sum()
        st.bar_chart(daily.astype(float))

    history = run_query(
        f"SELECT CHANGED_AT, CHANGED_BY, OLD_STATUS, NEW_STATUS, NOTE FROM {SCHEMA}.FRAUD_CASE_HISTORY "
        f"WHERE CASE_ID = ? ORDER BY CHANGED_AT DESC",
        (case_id,),
    )
    if not history.empty:
        st.subheader("Status history")
        st.dataframe(history, use_container_width=True, hide_index=True)
