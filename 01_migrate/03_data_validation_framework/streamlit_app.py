# Data Validation sign-off dashboard - Streamlit in Snowflake
# Create in Snowsight: Projects > Streamlit > + Streamlit App
#   Location: ACCEL_DB.VALIDATION, Warehouse: ACCEL_WH; paste this file.
# Needs: 01_framework.sql, 02_demo_setup.sql (or your own config) and at least one run.

import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Migration Data Validation", layout="wide")
session = get_active_session()

SCHEMA = "ACCEL_DB.VALIDATION"
STATUS_COLORS = {"PASS": "#2e8b57", "FAIL": "#c0392b", "WARN": "#e6a23c", "ERROR": "#7f8c8d"}
DECISIONS = ["APPROVED", "APPROVED_WITH_EXCEPTIONS", "REJECTED"]


@st.cache_data(ttl=120)
def run_query(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()


def safe_query(sql: str) -> pd.DataFrame:
    try:
        return run_query(sql)
    except Exception:
        return pd.DataFrame()


def sql_str(value) -> str:
    return "'" + str(value).replace("\\", "\\\\").replace("'", "''") + "'"


def viewer_name() -> str:
    try:
        user = getattr(st, "experimental_user", None)
        if user is not None:
            name = user.get("user_name") or user.get("login_name") or user.get("email")
            if name:
                return str(name)
    except Exception:
        pass
    try:
        return str(session.sql("SELECT CURRENT_USER()").collect()[0][0])
    except Exception:
        return ""


def rerun():
    st.cache_data.clear()
    if hasattr(st, "rerun"):
        st.rerun()
    else:
        st.experimental_rerun()


def color_status(val):
    color = STATUS_COLORS.get(str(val))
    return f"color: {color}; font-weight: 600" if color else ""


st.title("Migration Data Validation - Sign-off")
st.caption("Source vs target: row counts, null and distinct counts, min/max, sums and HASH_AGG checksums")

top_l, top_r = st.columns([3, 1])
with top_r:
    if st.button("Run validation now", type="primary", use_container_width=True):
        with st.spinner("Validating all active pairs..."):
            try:
                out = session.sql(f"CALL {SCHEMA}.SP_RUN_VALIDATION()").collect()[0][0]
                st.success("Run finished")
                st.code(str(out), language="json")
            except Exception as exc:
                st.error(f"Run failed: {exc}")
        st.cache_data.clear()

runs = safe_query(f"SELECT * FROM {SCHEMA}.V_VALIDATION_SUMMARY ORDER BY RUN_TS DESC")
if runs.empty:
    st.warning("No validation runs yet. Run 01_framework.sql, 02_demo_setup.sql and "
               "03_run_and_schedule.sql, or press 'Run validation now'.")
    st.stop()

with top_l:
    run_labels = [f"{pd.Timestamp(r.RUN_TS).strftime('%Y-%m-%d %H:%M')}  |  {r.RUN_ID[:8]}  |  "
                  f"{int(r.PAIRS_PASSED)}/{int(r.PAIRS)} passed" for r in runs.itertuples()]
    run_idx = st.selectbox("Validation run", range(len(run_labels)), format_func=lambda i: run_labels[i])
run_id = runs.iloc[run_idx]["RUN_ID"]
run_lit = sql_str(run_id)

pairs = safe_query(f"""
    SELECT p.PAIR_ID, p.PAIR_NAME, p.STATUS, p.SOURCE_TABLE, p.TARGET_TABLE, p.SOURCE_ROWS, p.TARGET_ROWS,
           p.TARGET_ROWS - p.SOURCE_ROWS AS ROW_VARIANCE, p.CHECKS_RUN, p.CHECKS_FAILED, p.CHECKS_WARNED,
           p.ERROR_MESSAGE, p.DURATION_SEC, c.DATA_OWNER,
           s.DECISION AS SIGNOFF, s.SIGNED_BY, s.SIGNED_AT, s.COMMENTS
    FROM {SCHEMA}.VALIDATION_PAIR_RUNS p
    LEFT JOIN {SCHEMA}.VALIDATION_CONFIG c ON c.PAIR_ID = p.PAIR_ID
    LEFT JOIN (SELECT * FROM {SCHEMA}.VALIDATION_SIGNOFF
               QUALIFY ROW_NUMBER() OVER (PARTITION BY PAIR_ID, RUN_ID ORDER BY SIGNED_AT DESC) = 1) s
           ON s.PAIR_ID = p.PAIR_ID AND s.RUN_ID = p.RUN_ID
    WHERE p.RUN_ID = {run_lit}
    ORDER BY p.PAIR_ID""")
results = safe_query(f"SELECT * FROM {SCHEMA}.VALIDATION_RESULTS WHERE RUN_ID = {run_lit}")

if pairs.empty:
    st.info("This run has no pair results.")
    st.stop()

# ---------------------------------------------------------------- KPIs
n_pairs = len(pairs)
n_pass = int((pairs["STATUS"] == "PASS").sum())
n_fail = int((pairs["STATUS"] == "FAIL").sum())
n_err = int((pairs["STATUS"] == "ERROR").sum())
n_signed = int(pairs["SIGNOFF"].isin(["APPROVED", "APPROVED_WITH_EXCEPTIONS"]).sum())
checks = results[results["CHECK_TYPE"] != "ROW_DIFF"] if not results.empty else results
k1, k2, k3, k4, k5 = st.columns(5)
k1.metric("Table pairs", n_pairs)
k2.metric("Passed", f"{n_pass} / {n_pairs}")
k3.metric("Failed / error", n_fail + n_err)
k4.metric("Checks failed", int((checks["STATUS"] == "FAIL").sum()) if not checks.empty else 0,
          help=f"out of {len(checks)} checks")
k5.metric("Signed off", f"{n_signed} / {n_pairs}")

if n_signed == n_pairs:
    st.success("All pairs in this run are signed off.")

tab_status, tab_detail, tab_history = st.tabs(["Pair status", "Pair drill-down", "Run history"])

# ---------------------------------------------------------------- status
with tab_status:
    show = pairs[["PAIR_ID", "PAIR_NAME", "STATUS", "SOURCE_ROWS", "TARGET_ROWS", "ROW_VARIANCE",
                  "CHECKS_RUN", "CHECKS_FAILED", "CHECKS_WARNED", "DATA_OWNER", "SIGNOFF", "SIGNED_BY"]]
    st.dataframe(show.style.map(color_status, subset=["STATUS"]) if hasattr(show.style, "map")
                 else show.style.applymap(color_status, subset=["STATUS"]),
                 use_container_width=True, hide_index=True)

    if not checks.empty:
        failed = checks[checks["STATUS"] != "PASS"]
        if not failed.empty:
            st.subheader("Exceptions by check type")
            agg = failed.groupby(["PAIR_NAME", "CHECK_TYPE", "STATUS"], as_index=False).size()
            agg = agg.rename(columns={"size": "CHECKS"})
            st.altair_chart(
                alt.Chart(agg)
                .mark_bar(cornerRadiusEnd=3)
                .encode(
                    y=alt.Y("PAIR_NAME:N", title=None),
                    x=alt.X("sum(CHECKS):Q", title="Checks not passing"),
                    color=alt.Color("CHECK_TYPE:N", title="Check type"),
                    tooltip=["PAIR_NAME", "CHECK_TYPE", "STATUS", "CHECKS"],
                )
                .properties(height=60 + 40 * agg["PAIR_NAME"].nunique()),
                use_container_width=True,
            )
        else:
            st.success("Every check passed in this run.")

# ---------------------------------------------------------------- drill-down
with tab_detail:
    pair_names = pairs["PAIR_NAME"].tolist()
    choice = st.selectbox("Table pair", pair_names)
    prow = pairs[pairs["PAIR_NAME"] == choice].iloc[0]
    pair_id = int(prow["PAIR_ID"])

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Status", prow["STATUS"])
    c2.metric("Source rows", f"{int(prow['SOURCE_ROWS']):,}" if pd.notna(prow["SOURCE_ROWS"]) else "-")
    c3.metric("Target rows", f"{int(prow['TARGET_ROWS']):,}" if pd.notna(prow["TARGET_ROWS"]) else "-",
              delta=None if pd.isna(prow["ROW_VARIANCE"]) else int(prow["ROW_VARIANCE"]), delta_color="off")
    c4.metric("Checks failed", f"{int(prow['CHECKS_FAILED'])} / {int(prow['CHECKS_RUN'])}")
    st.caption(f"{prow['SOURCE_TABLE']}  ->  {prow['TARGET_TABLE']}")
    if prow["STATUS"] == "ERROR":
        st.error(prow["ERROR_MESSAGE"])

    pres = results[results["PAIR_ID"] == pair_id] if not results.empty else results
    if not pres.empty:
        only_issues = st.toggle("Show only failed / warning checks", value=True) if hasattr(st, "toggle") \
            else st.checkbox("Show only failed / warning checks", value=True)
        view = pres[pres["STATUS"] != "PASS"] if only_issues else pres
        view = view[["CHECK_TYPE", "COLUMN_NAME", "SOURCE_VALUE", "TARGET_VALUE", "VARIANCE",
                     "VARIANCE_PCT", "STATUS", "DETAIL"]].sort_values(["STATUS", "CHECK_TYPE", "COLUMN_NAME"])
        if view.empty:
            st.success("No exceptions for this pair.")
        else:
            st.dataframe(view.style.map(color_status, subset=["STATUS"]) if hasattr(view.style, "map")
                         else view.style.applymap(color_status, subset=["STATUS"]),
                         use_container_width=True, hide_index=True)

    diffs = safe_query(f"""
        SELECT DIFF_TYPE, KEY_VALUES::VARCHAR AS KEY_VALUES, ARRAY_TO_STRING(DIFF_COLUMNS, ', ') AS DIFF_COLUMNS,
               SOURCE_ROW::VARCHAR AS SOURCE_ROW, TARGET_ROW::VARCHAR AS TARGET_ROW
        FROM {SCHEMA}.VALIDATION_ROW_DIFFS
        WHERE RUN_ID = {run_lit} AND PAIR_ID = {pair_id}
        ORDER BY DIFF_TYPE""")
    if not diffs.empty:
        st.subheader("Row-level differences (sample)")
        st.dataframe(diffs, use_container_width=True, hide_index=True)
    elif prow["STATUS"] == "FAIL":
        st.info(f"No row diff captured. Run CALL {SCHEMA}.SP_ROW_DIFF('{run_id}', {pair_id});")

    st.subheader("Sign-off")
    if pd.notna(prow["SIGNOFF"]):
        st.write(f"Current decision: **{prow['SIGNOFF']}** by {prow['SIGNED_BY']} "
                 f"on {pd.Timestamp(prow['SIGNED_AT']).strftime('%Y-%m-%d %H:%M')} - {prow['COMMENTS'] or ''}")
    with st.form(f"signoff_{pair_id}_{run_id}"):
        default_decision = 0 if prow["STATUS"] == "PASS" else 2
        decision = st.radio("Decision", DECISIONS, index=default_decision, horizontal=True)
        signer = st.text_input("Signed by", value=viewer_name())
        comments = st.text_area("Comments", placeholder="e.g. 0.01 rounding variance accepted by Finance")
        submitted = st.form_submit_button("Record sign-off")
    if submitted:
        if not signer.strip():
            st.error("Enter a name for the sign-off.")
        elif decision != "REJECTED" and prow["STATUS"] != "PASS" and not comments.strip():
            st.error("Approving a pair that did not pass needs a comment explaining the exception.")
        else:
            session.sql(
                f"INSERT INTO {SCHEMA}.VALIDATION_SIGNOFF (PAIR_ID, RUN_ID, DECISION, SIGNED_BY, COMMENTS) "
                f"VALUES ({pair_id}, {run_lit}, {sql_str(decision)}, {sql_str(signer.strip())}, "
                f"{sql_str(comments.strip())})"
            ).collect()
            st.success("Sign-off recorded.")
            rerun()

# ---------------------------------------------------------------- history
with tab_history:
    hist = runs.copy()
    hist["RUN_TS"] = pd.to_datetime(hist["RUN_TS"])
    hist["PASS_RATE_PCT"] = hist["PASS_RATE_PCT"].astype(float)
    st.altair_chart(
        alt.Chart(hist)
        .mark_line(point=True, color="#2a78d6")
        .encode(
            x=alt.X("RUN_TS:T", title="Run"),
            y=alt.Y("PASS_RATE_PCT:Q", title="Pairs passing (%)", scale=alt.Scale(domain=[0, 100])),
            tooltip=[alt.Tooltip("RUN_TS:T", format="%Y-%m-%d %H:%M"), "PAIRS", "PAIRS_PASSED",
                     "PAIRS_FAILED", "CHECKS_FAILED"],
        )
        .properties(height=260),
        use_container_width=True,
    )
    st.dataframe(
        hist[["RUN_TS", "TRIGGERED_BY", "PAIRS", "PAIRS_PASSED", "PAIRS_FAILED", "PAIRS_ERROR",
              "CHECKS_RUN", "CHECKS_FAILED", "DURATION_SEC", "RUN_ID"]],
        use_container_width=True, hide_index=True,
    )

    st.subheader("Sign-off audit trail")
    audit = safe_query(f"""
        SELECT s.SIGNED_AT, c.PAIR_NAME, s.DECISION, s.SIGNED_BY, s.COMMENTS, s.RUN_ID
        FROM {SCHEMA}.VALIDATION_SIGNOFF s
        LEFT JOIN {SCHEMA}.VALIDATION_CONFIG c ON c.PAIR_ID = s.PAIR_ID
        ORDER BY s.SIGNED_AT DESC LIMIT 200""")
    if audit.empty:
        st.caption("No sign-offs recorded yet.")
    else:
        st.dataframe(audit, use_container_width=True, hide_index=True)
