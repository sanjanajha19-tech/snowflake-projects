# Data Observability Health Dashboard - Streamlit in Snowflake
# Create in Snowsight: Projects > Streamlit > + Streamlit App
#   Location: ACCEL_DB.OBSERVABILITY, warehouse ACCEL_WH, owner role ACCEL_ADMIN.
# Paste this file. Packages: streamlit, pandas, altair (Anaconda channel defaults).
import decimal

import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Data Observability", layout="wide")
session = get_active_session()

SCHEMA = "ACCEL_DB.OBSERVABILITY"
SEVERITY_ORDER = ["CRITICAL", "HIGH", "MEDIUM", "LOW"]
HEALTH_COLORS = {
    "HEALTHY": "#2e7d32",
    "WARNING": "#f9a825",
    "HIGH": "#ef6c00",
    "CRITICAL": "#c62828",
    "NOT CHECKED": "#9e9e9e",
}


@st.cache_data(ttl=300, show_spinner=False)
def run(sql: str) -> pd.DataFrame:
    try:
        df = session.sql(sql).to_pandas()
    except Exception as exc:  # keep the rest of the app usable
        st.warning(f"Query failed: {exc}")
        return pd.DataFrame()
    return to_float(df)


def to_float(df: pd.DataFrame) -> pd.DataFrame:
    """NUMBER(p,s) can arrive as decimal.Decimal; charts need floats."""
    for col in df.columns:
        if df[col].dtype == object and df[col].notna().any():
            if df[col].dropna().map(lambda v: isinstance(v, decimal.Decimal)).all():
                df[col] = df[col].astype(float)
    return df


def sql_str(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


st.title("Data Observability")
st.caption("Freshness, volume and schema-change monitors over ACCEL_DB")

with st.sidebar:
    st.header("Actions")
    if st.button("Run checks now", type="primary"):
        with st.spinner("Snapshotting and evaluating monitors..."):
            try:
                msg = session.sql(f"CALL {SCHEMA}.EVALUATE_MONITORS()").collect()[0][0]
                st.success(msg)
            except Exception as exc:
                st.error(f"Evaluation failed: {exc}")
        st.cache_data.clear()
    if st.button("Refresh data"):
        st.cache_data.clear()
    days = st.selectbox("Incident lookback (days)", [1, 7, 30, 90], index=1)
    st.caption("Config: ACCEL_DB.OBSERVABILITY.MONITOR_CONFIG. Hourly task: TASK_OBS_EVALUATE. "
               "E-mail alert: OBS_NEW_INCIDENT_ALERT.")

health = run(f"SELECT * FROM {SCHEMA}.V_TABLE_HEALTH ORDER BY OPEN_INCIDENTS DESC, SCHEMA_NAME, TABLE_NAME")
open_inc = run(
    f"""SELECT INCIDENT_ID, DETECTED_AT, LAST_SEEN_AT, SCHEMA_NAME, TABLE_NAME, MONITOR_TYPE, SEVERITY,
               OBSERVED_VALUE, THRESHOLD, MESSAGE, STATUS, NOTIFIED_AT
        FROM {SCHEMA}.INCIDENTS
        WHERE STATUS IN ('OPEN', 'ACKNOWLEDGED')
        ORDER BY CASE SEVERITY WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 ELSE 4 END,
                 DETECTED_AT DESC"""
)

# KPIs
monitored = len(health)
healthy = int((health["HEALTH"] == "HEALTHY").sum()) if not health.empty else 0
n_open = len(open_inc)
n_crit = int((open_inc["SEVERITY"] == "CRITICAL").sum()) if not open_inc.empty else 0
last_check = health["LAST_CHECKED"].max() if not health.empty and "LAST_CHECKED" in health else None

c1, c2, c3, c4, c5 = st.columns(5)
c1.metric("Monitored tables", monitored)
c2.metric("Healthy", f"{healthy} / {monitored}")
c3.metric("Open incidents", n_open)
c4.metric("Critical", n_crit)
c5.metric("Last check", "never" if last_check is None or pd.isna(last_check) else str(last_check)[:16])

tab_health, tab_inc, tab_trend, tab_ddl, tab_cfg = st.tabs(
    ["Table health", "Incidents", "Volume trend", "DDL activity", "Configuration"]
)

with tab_health:
    if health.empty:
        st.info("No monitored tables yet. Run 01_monitor_config.sql and 02_snapshots_and_evaluation.sql.")
    else:
        counts = health.groupby("HEALTH").size().reset_index(name="TABLES")
        chart = (
            alt.Chart(counts)
            .mark_bar()
            .encode(
                x=alt.X("TABLES:Q", title="Tables"),
                y=alt.Y("HEALTH:N", sort=list(HEALTH_COLORS.keys()), title=None),
                color=alt.Color(
                    "HEALTH:N",
                    scale=alt.Scale(domain=list(HEALTH_COLORS.keys()), range=list(HEALTH_COLORS.values())),
                    legend=None,
                ),
                tooltip=["HEALTH", "TABLES"],
            )
            .properties(height=180)
        )
        st.altair_chart(chart, use_container_width=True)
        st.dataframe(
            health[
                [
                    "SCHEMA_NAME", "TABLE_NAME", "HEALTH", "OPEN_MONITORS", "ROW_COUNT",
                    "MINUTES_SINCE_CHANGE", "FRESHNESS_SLA_MINUTES", "MIN_ROWS",
                    "MAX_ROW_CHANGE_PCT", "COLUMN_COUNT", "OWNER", "LAST_CHECKED",
                ]
            ],
            use_container_width=True,
            hide_index=True,
        )

with tab_inc:
    st.subheader("Open and acknowledged incidents")
    if open_inc.empty:
        st.success("No open incidents.")
    else:
        sev = st.multiselect("Severity", SEVERITY_ORDER, default=SEVERITY_ORDER)
        view = open_inc[open_inc["SEVERITY"].isin(sev)]
        st.dataframe(view, use_container_width=True, hide_index=True)

        st.markdown("**Update an incident**")
        f1, f2, f3, f4 = st.columns([1, 1, 3, 1])
        inc_id = f1.selectbox("Incident", open_inc["INCIDENT_ID"].astype(int).tolist())
        new_status = f2.selectbox("Status", ["ACKNOWLEDGED", "RESOLVED", "OPEN"])
        note = f3.text_input("Note", value="")
        f4.write("")
        if f4.button("Apply"):
            try:
                res = session.sql(
                    f"CALL {SCHEMA}.SET_INCIDENT_STATUS({int(inc_id)}, {sql_str(new_status)}, {sql_str(note)})"
                ).collect()[0][0]
                st.success(res)
                st.cache_data.clear()
            except Exception as exc:
                st.error(f"Update failed: {exc}")

    st.subheader(f"Incidents detected in the last {days} days")
    hist = run(
        f"""SELECT DETECTED_AT::DATE AS DETECTED_DATE, MONITOR_TYPE, COUNT(*) AS INCIDENTS
            FROM {SCHEMA}.INCIDENTS
            WHERE DETECTED_AT >= DATEADD('day', -{int(days)}, CURRENT_TIMESTAMP())
            GROUP BY 1, 2 ORDER BY 1"""
    )
    if hist.empty:
        st.info("No incidents in this period.")
    else:
        st.altair_chart(
            alt.Chart(hist)
            .mark_bar()
            .encode(
                x=alt.X("DETECTED_DATE:T", title="Date"),
                y=alt.Y("INCIDENTS:Q", title="Incidents"),
                color=alt.Color("MONITOR_TYPE:N", title="Monitor"),
                tooltip=["DETECTED_DATE:T", "MONITOR_TYPE", "INCIDENTS"],
            )
            .properties(height=260),
            use_container_width=True,
        )

with tab_trend:
    if health.empty:
        st.info("No snapshots yet.")
    else:
        options = (health["SCHEMA_NAME"] + "." + health["TABLE_NAME"]).tolist()
        choice = st.selectbox("Table", options)
        sch, tbl = choice.split(".", 1)
        snaps = run(
            f"""SELECT SNAPSHOT_TS, ROW_COUNT, BYTES, COLUMN_COUNT
                FROM {SCHEMA}.TABLE_SNAPSHOTS
                WHERE SCHEMA_NAME = {sql_str(sch)} AND TABLE_NAME = {sql_str(tbl)}
                  AND SNAPSHOT_TS >= DATEADD('day', -{int(days)}, CURRENT_TIMESTAMP())
                ORDER BY SNAPSHOT_TS"""
        )
        if snaps.empty:
            st.info("No snapshots for this table in the selected period.")
        else:
            st.altair_chart(
                alt.Chart(snaps)
                .mark_line(point=True)
                .encode(
                    x=alt.X("SNAPSHOT_TS:T", title="Snapshot"),
                    y=alt.Y("ROW_COUNT:Q", title="Rows"),
                    tooltip=["SNAPSHOT_TS:T", "ROW_COUNT", "BYTES", "COLUMN_COUNT"],
                )
                .properties(height=300),
                use_container_width=True,
            )
            st.dataframe(snaps.sort_values("SNAPSHOT_TS", ascending=False), use_container_width=True, hide_index=True)

with tab_ddl:
    st.caption("ACCOUNT_USAGE.TABLES / COLUMNS, last 7 days, up to ~3 h latency")
    ddl = run(f"SELECT * FROM {SCHEMA}.V_DDL_ACTIVITY_7D ORDER BY CHANGED_AT DESC")
    if ddl.empty:
        st.info("No DDL activity recorded in ACCEL_DB in the last 7 days.")
    else:
        st.dataframe(ddl, use_container_width=True, hide_index=True)

with tab_cfg:
    cfg = run(f"SELECT * FROM {SCHEMA}.MONITOR_CONFIG ORDER BY SCHEMA_NAME, TABLE_NAME")
    st.dataframe(cfg, use_container_width=True, hide_index=True)
    st.caption("Edit thresholds with UPDATE ACCEL_DB.OBSERVABILITY.MONITOR_CONFIG ... (see 01_monitor_config.sql).")
    notif = run(f"SELECT * FROM {SCHEMA}.NOTIFICATION_LOG ORDER BY SENT_AT DESC LIMIT 20")
    st.markdown("**Recent notifications**")
    if notif.empty:
        st.info("No e-mails sent yet.")
    else:
        st.dataframe(notif, use_container_width=True, hide_index=True)
