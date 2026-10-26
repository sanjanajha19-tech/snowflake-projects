"""Journal Entry Risk Review - Streamlit in Snowflake app (Accelerator 21).

Create in Snowsight: Projects > Streamlit > + Streamlit App,
location ACCEL_DB.JE_ANALYTICS, warehouse ACCEL_WH. Paste this file.
"""

import datetime as dt
import json

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

SCHEMA = "ACCEL_DB.JE_ANALYTICS"
REVIEW_STATUSES = ["Open", "Explained", "Exception raised", "Closed"]

st.set_page_config(page_title="Journal Entry Risk Review", layout="wide")
session = get_active_session()


@st.cache_data(ttl=600)
def run_query(sql: str, params: tuple = ()) -> pd.DataFrame:
    return session.sql(sql, params=list(params)).to_pandas()


def q_in(values) -> str:
    """Render a list of strings as a SQL IN list with escaped quotes."""
    escaped = ["'" + str(v).replace("'", "''") + "'" for v in values]
    return ", ".join(escaped) if escaped else "''"


st.title("Journal Entry Risk Review")
st.caption(
    "Rule-based risk scoring of every journal: timing, amounts, segregation of duties, "
    "unusual accounts, Benford and user-behaviour tests. Configure rules in JE_RISK_RULES "
    "and rerun CALL SP_SCORE_JOURNALS()."
)

# ---------------------------------------------------------------- filters
meta = run_query(
    f"SELECT MIN(POSTING_DATE) AS MIN_D, MAX(POSTING_DATE) AS MAX_D, "
    f"ARRAY_AGG(DISTINCT ENTITY) AS ENTITIES, ARRAY_AGG(DISTINCT SOURCE) AS SOURCES "
    f"FROM {SCHEMA}.JE_RISK_SCORES"
)
rules = run_query(f"SELECT RULE_CODE, RULE_NAME FROM {SCHEMA}.JE_RISK_RULES ORDER BY WEIGHT DESC")
users = run_query(f"SELECT DISTINCT CREATED_BY FROM {SCHEMA}.JE_RISK_SCORES ORDER BY 1")

min_d = pd.to_datetime(meta["MIN_D"].iloc[0]).date()
max_d = pd.to_datetime(meta["MAX_D"].iloc[0]).date()
entities = sorted(json.loads(meta["ENTITIES"].iloc[0]))
sources = sorted(json.loads(meta["SOURCES"].iloc[0]))

with st.sidebar:
    st.header("Filters")
    date_range = st.date_input("Posting date", value=(max(min_d, max_d - dt.timedelta(days=365)), max_d),
                               min_value=min_d, max_value=max_d)
    sel_bands = st.multiselect("Risk band", ["High", "Medium", "Low", "None"], default=["High", "Medium"])
    sel_entities = st.multiselect("Entity", entities, default=entities)
    sel_sources = st.multiselect("Source", sources, default=sources)
    sel_rules = st.multiselect("Rule triggered (any of)", rules["RULE_CODE"].tolist(), default=[])
    sel_users = st.multiselect("Created by", users["CREATED_BY"].tolist(), default=[])
    min_score = st.slider("Minimum score", 0, 100, 0)
    if st.button("Refresh data"):
        st.cache_data.clear()

if isinstance(date_range, (tuple, list)) and len(date_range) == 2:
    d_from, d_to = date_range
else:
    d_from, d_to = min_d, max_d

where = [
    f"s.POSTING_DATE BETWEEN '{d_from}' AND '{d_to}'",
    f"s.RISK_SCORE >= {int(min_score)}",
    f"s.RISK_BAND IN ({q_in(sel_bands)})",
    f"s.ENTITY IN ({q_in(sel_entities)})",
    f"s.SOURCE IN ({q_in(sel_sources)})",
]
if sel_rules:
    where.append(f"ARRAYS_OVERLAP(s.RULE_CODES, ARRAY_CONSTRUCT({q_in(sel_rules)}))")
if sel_users:
    where.append(f"s.CREATED_BY IN ({q_in(sel_users)})")
where_sql = " AND ".join(where)

flagged = run_query(
    f"""
    SELECT s.JOURNAL_ID, s.POSTING_DATE, s.ENTITY, s.SOURCE, s.CREATED_BY, s.APPROVED_BY,
           s.TOTAL_DEBIT, s.CURRENCY, s.TOTAL_DEBIT_USD, s.RISK_SCORE, s.RISK_BAND, s.RULES_HIT,
           s.REASONS, s.DESCRIPTION, s.ORIGIN,
           COALESCE(r.STATUS, 'Open') AS REVIEW_STATUS
    FROM {SCHEMA}.JE_RISK_SCORES s
    LEFT JOIN (
        SELECT JOURNAL_ID, STATUS FROM {SCHEMA}.JE_REVIEW
        QUALIFY ROW_NUMBER() OVER (PARTITION BY JOURNAL_ID ORDER BY UPDATED_AT DESC) = 1
    ) r ON r.JOURNAL_ID = s.JOURNAL_ID
    WHERE {where_sql}
    ORDER BY s.RISK_SCORE DESC, s.TOTAL_DEBIT_USD DESC
    LIMIT 5000
    """
)

# ---------------------------------------------------------------- KPIs
k1, k2, k3, k4, k5 = st.columns(5)
k1.metric("Journals in view", f"{len(flagged):,}")
k2.metric("High risk", f"{int((flagged['RISK_BAND'] == 'High').sum()):,}")
k3.metric("Value in view (USD)", f"{flagged['TOTAL_DEBIT_USD'].astype(float).sum():,.0f}")
k4.metric("Self-approved", f"{int(flagged['REASONS'].fillna('').str.contains('SELF_APPROVAL').sum()):,}")
k5.metric("Still open", f"{int((flagged['REVIEW_STATUS'] == 'Open').sum()):,}")

tab_list, tab_rules, tab_users, tab_benford = st.tabs(
    ["Flagged journals", "Rules", "Users", "Benford"]
)

with tab_rules:
    rule_summary = run_query(f"SELECT * FROM {SCHEMA}.V_JE_RULE_SUMMARY ORDER BY JOURNALS_FLAGGED DESC")
    c1, c2 = st.columns([2, 3])
    with c1:
        st.bar_chart(rule_summary.set_index("RULE_CODE")["JOURNALS_FLAGGED"])
    with c2:
        st.dataframe(rule_summary, use_container_width=True, hide_index=True)
    st.caption("SEEDED_CASES_FLAGGED shows the known test cases each rule caught, as evidence that the rule works.")

with tab_users:
    user_risk = run_query(f"SELECT * FROM {SCHEMA}.V_JE_USER_RISK ORDER BY HIGH_RISK DESC, AVG_SCORE DESC")
    st.dataframe(user_risk, use_container_width=True, hide_index=True)

with tab_benford:
    ben_users = run_query(
        f"SELECT CREATED_BY, N_LINES, MAD, NIGRINI_BAND, IS_FLAGGED FROM {SCHEMA}.JE_USER_BENFORD "
        f"ORDER BY MAD DESC"
    )
    st.dataframe(ben_users, use_container_width=True, hide_index=True)
    if not ben_users.empty:
        b_user = st.selectbox("User", ben_users["CREATED_BY"].tolist())
        digits = run_query(
            f"SELECT DIGIT, OBSERVED_PCT, BENFORD_PCT FROM {SCHEMA}.JE_BENFORD_DIGITS "
            f"WHERE CREATED_BY = ? ORDER BY DIGIT",
            (b_user,),
        )
        chart = digits.set_index("DIGIT")[["OBSERVED_PCT", "BENFORD_PCT"]].astype(float)
        st.line_chart(chart)
        st.caption("First significant digit: observed share vs Benford's law. MAD above 0.015 = nonconformity (Nigrini).")

with tab_list:
    if flagged.empty:
        st.info("No journals match the filters.")
        st.stop()

    by_month = flagged.assign(MONTH=pd.to_datetime(flagged["POSTING_DATE"]).dt.to_period("M").dt.to_timestamp())
    st.bar_chart(by_month.groupby(["MONTH", "RISK_BAND"]).size().unstack(fill_value=0))

    st.dataframe(
        flagged[["JOURNAL_ID", "POSTING_DATE", "ENTITY", "SOURCE", "CREATED_BY", "APPROVED_BY",
                 "TOTAL_DEBIT_USD", "RISK_SCORE", "RISK_BAND", "REVIEW_STATUS", "REASONS"]],
        use_container_width=True, hide_index=True,
    )

    st.subheader("Drill-down")
    journal_ids = flagged["JOURNAL_ID"].astype(int).tolist()
    sel_journal = st.selectbox("Journal", journal_ids[:500],
                               format_func=lambda j: f"{j} - score "
                               f"{int(flagged.loc[flagged['JOURNAL_ID'] == j, 'RISK_SCORE'].iloc[0])}")
    row = flagged.loc[flagged["JOURNAL_ID"] == sel_journal].iloc[0]

    d1, d2 = st.columns([3, 2])
    with d1:
        st.markdown(
            f"**{row['DESCRIPTION']}**  \n"
            f"Entity {row['ENTITY']} | source {row['SOURCE']} | posted {row['POSTING_DATE']} | "
            f"created by `{row['CREATED_BY']}` | approved by `{row['APPROVED_BY']}` | origin {row['ORIGIN']}"
        )
        lines = run_query(
            f"SELECT LINE_NO, ACCOUNT_CODE, ACCOUNT_NAME, ACCOUNT_TYPE, COST_CENTER, AMOUNT, CURRENCY, "
            f"ENTRY_TIMESTAMP FROM {SCHEMA}.V_GL_SCOPE WHERE JOURNAL_ID = ? ORDER BY LINE_NO",
            (int(sel_journal),),
        )
        st.dataframe(lines, use_container_width=True, hide_index=True)

        hits = run_query(
            f"SELECT h.RULE_CODE, r.RULE_NAME, h.WEIGHT, h.DETAIL FROM {SCHEMA}.JE_RULE_HITS h "
            f"JOIN {SCHEMA}.JE_RISK_RULES r ON r.RULE_CODE = h.RULE_CODE "
            f"WHERE h.JOURNAL_ID = ? ORDER BY h.WEIGHT DESC",
            (int(sel_journal),),
        )
        st.markdown(f"**Risk score {int(row['RISK_SCORE'])} ({row['RISK_BAND']})**")
        st.dataframe(hits, use_container_width=True, hide_index=True)

        history = run_query(
            f"SELECT DATE_TRUNC('MONTH', POSTING_DATE) AS MONTH, COUNT(*) AS JOURNALS, "
            f"SUM(TOTAL_DEBIT_USD) AS USD FROM {SCHEMA}.JE_RISK_SCORES WHERE CREATED_BY = ? "
            f"GROUP BY 1 ORDER BY 1",
            (row["CREATED_BY"],),
        )
        if not history.empty:
            st.caption(f"Monthly posting volume (USD) of {row['CREATED_BY']}")
            st.area_chart(history.set_index("MONTH")["USD"].astype(float))

    with d2:
        ai = run_query(
            f"SELECT EXPLANATION, MODEL, GENERATED_AT FROM {SCHEMA}.JE_AI_EXPLANATIONS "
            f"WHERE JOURNAL_ID = ? ORDER BY GENERATED_AT DESC LIMIT 1",
            (int(sel_journal),),
        )
        st.markdown("**AI reviewer note**")
        if ai.empty:
            st.info("No AI note for this journal. Run 03_ai_explanations.sql (top 50 journals).")
        else:
            st.write(ai["EXPLANATION"].iloc[0])
            st.caption(f"{ai['MODEL'].iloc[0]} - {ai['GENERATED_AT'].iloc[0]}. AI-generated, verify before use.")

        st.markdown("**Review**")
        review_hist = run_query(
            f"SELECT STATUS, REVIEWER, NOTES, UPDATED_AT FROM {SCHEMA}.JE_REVIEW "
            f"WHERE JOURNAL_ID = ? ORDER BY UPDATED_AT DESC",
            (int(sel_journal),),
        )
        with st.form("review_form", clear_on_submit=True):
            status = st.selectbox("Status", REVIEW_STATUSES)
            notes = st.text_area("Notes")
            submitted = st.form_submit_button("Save review")
        if submitted:
            session.sql(
                f"INSERT INTO {SCHEMA}.JE_REVIEW (JOURNAL_ID, STATUS, REVIEWER, NOTES, UPDATED_AT) "
                f"SELECT ?, ?, CURRENT_USER(), ?, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ",
                params=[int(sel_journal), status, notes],
            ).collect()
            st.cache_data.clear()
            st.success("Review saved.")
            if hasattr(st, "rerun"):
                st.rerun()
            else:
                st.experimental_rerun()
        if not review_hist.empty:
            st.dataframe(review_hist, use_container_width=True, hide_index=True)
