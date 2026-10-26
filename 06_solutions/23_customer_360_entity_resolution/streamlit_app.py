"""Customer 360 lookup - Streamlit in Snowflake app (asset 23).

Create in Snowsight: Projects > Streamlit > + Streamlit App,
location ACCEL_DB.C360, warehouse ACCEL_WH, then paste this file.
Packages: streamlit, pandas (both pre-installed).
"""
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Customer 360", layout="wide")
session = get_active_session()

DB = "ACCEL_DB.C360"


def run(query, params=None):
    """Run a parameterised query and return a pandas DataFrame."""
    return session.sql(query, params=params or []).to_pandas()


@st.cache_data(ttl=600)
def has_sentiment_view():
    try:
        session.sql(f"SELECT 1 FROM {DB}.CUSTOMER_360_WITH_SENTIMENT LIMIT 1").collect()
        return True
    except Exception:  # view is optional (needs asset 24)
        return False


@st.cache_data(ttl=600)
def headline():
    return run(
        f"""
        SELECT (SELECT COUNT(*) FROM {DB}.CUSTOMER_RECORDS) AS SOURCE_RECORDS,
               (SELECT COUNT(*) FROM {DB}.GOLDEN_CUSTOMER) AS GOLDEN_CUSTOMERS,
               (SELECT COUNT(*) FROM {DB}.GOLDEN_CUSTOMER WHERE SOURCE_COUNT > 1) AS MULTI_SOURCE,
               (SELECT COUNT(*) FROM {DB}.MATCH_PAIRS_FINAL WHERE FINAL_DECISION = 'UNRESOLVED') AS PENDING_REVIEW
        """
    )


view_name = "CUSTOMER_360_WITH_SENTIMENT" if has_sentiment_view() else "CUSTOMER_360"

st.title("Customer 360 lookup")
st.caption("Golden customer records resolved across ERP, CRM and e-commerce sources.")

h = headline()
c1, c2, c3, c4 = st.columns(4)
c1.metric("Source records", f"{int(h.SOURCE_RECORDS[0]):,}")
c2.metric("Golden customers", f"{int(h.GOLDEN_CUSTOMERS[0]):,}")
c3.metric("Seen in 2+ sources", f"{int(h.MULTI_SOURCE[0]):,}")
c4.metric("Pairs awaiting review", f"{int(h.PENDING_REVIEW[0]):,}")

term = st.text_input("Search by name, email, phone, PAN or golden ID", placeholder="e.g. sharma, 98450, GC-")

if not term or len(term.strip()) < 2:
    st.info("Type at least 2 characters to search.")
    st.stop()

pattern = f"%{term.strip()}%"
digits = "".join(ch for ch in term if ch.isdigit())
phone_pattern = f"%{digits}%" if len(digits) >= 4 else "__no_phone_search__"

matches = run(
    f"""
    SELECT DISTINCT g.GOLDEN_ID, g.CUSTOMER_NAME, g.CITY, g.COUNTRY, g.SEGMENT, g.SOURCE_COUNT, g.RECORD_COUNT
    FROM {DB}.GOLDEN_CUSTOMER g
    JOIN {DB}.CUSTOMER_XREF x ON x.GOLDEN_ID = g.GOLDEN_ID
    JOIN {DB}.CUSTOMER_RECORDS r ON r.RECORD_KEY = x.RECORD_KEY
    WHERE r.RAW_NAME ILIKE ? OR r.EMAIL_STD ILIKE ? OR r.PAN_STD ILIKE ?
       OR g.GOLDEN_ID ILIKE ? OR r.PHONE_STD LIKE ?
    ORDER BY g.SOURCE_COUNT DESC, g.CUSTOMER_NAME
    LIMIT 200
    """,
    [pattern, pattern, pattern, pattern, phone_pattern],
)

if matches.empty:
    st.warning("No customers found.")
    st.stop()

st.dataframe(matches, use_container_width=True, hide_index=True)

options = matches["GOLDEN_ID"] + "  |  " + matches["CUSTOMER_NAME"].fillna("")
choice = st.selectbox("Open customer", options)
golden_id = choice.split("  |  ")[0]

profile = run(f"SELECT * FROM {DB}.{view_name} WHERE GOLDEN_ID = ?", [golden_id])
if profile.empty:
    st.stop()
p = profile.iloc[0]

st.subheader(f"{p.CUSTOMER_NAME}  ·  {golden_id}")
st.caption(
    f"{p.SEGMENT or 'Segment n/a'} · {p.INDUSTRY or 'Industry n/a'} · {p.CITY or ''}, {p.COUNTRY or ''} "
    f"· lifecycle: {p.LIFECYCLE_STAGE}"
)

k1, k2, k3, k4, k5 = st.columns(5)
k1.metric("Lifetime value (INR)", f"{float(p.LIFETIME_VALUE_INR):,.0f}")
k2.metric("Orders", int(p.ORDER_COUNT))
k3.metric("Last order", str(p.LAST_ORDER_DATE) if pd.notna(p.LAST_ORDER_DATE) else "none")
k4.metric("Open tickets", int(p.OPEN_TICKETS))
if "RELATIONSHIP_HEALTH" in profile.columns:
    k5.metric("Relationship health", p.RELATIONSHIP_HEALTH)
else:
    k5.metric("E-com spend (INR)", f"{float(p.ECOM_LIFETIME_SPEND_INR):,.0f}")

with st.expander("Golden record attributes", expanded=True):
    st.dataframe(profile.T.rename(columns={0: "value"}).astype(str), use_container_width=True)

tab_src, tab_match, tab_orders, tab_tix = st.tabs(
    ["Source records", "Match evidence", "Recent orders", "Tickets"]
)

with tab_src:
    st.dataframe(
        run(
            f"""
            SELECT r.SOURCE_SYSTEM, r.SOURCE_ID, r.RAW_NAME, r.RAW_EMAIL, r.RAW_PHONE, r.RAW_PAN,
                   r.RAW_CITY, r.LAST_UPDATED_AT
            FROM {DB}.CUSTOMER_XREF x JOIN {DB}.CUSTOMER_RECORDS r ON r.RECORD_KEY = x.RECORD_KEY
            WHERE x.GOLDEN_ID = ? ORDER BY r.SOURCE_PRIORITY, r.LAST_UPDATED_AT DESC
            """,
            [golden_id],
        ),
        use_container_width=True,
        hide_index=True,
    )

with tab_match:
    st.dataframe(
        run(
            f"""
            SELECT m.NAME_A, m.NAME_B, m.NAME_JW, m.NAME_EDIT_DISTANCE, m.EMAIL_MATCH, m.PHONE_MATCH,
                   m.PAN_MATCH, m.MATCH_SCORE, m.RULE_DECISION, m.AI_DECISION, m.AI_REASON,
                   m.FINAL_DECISION, m.DECIDED_BY
            FROM {DB}.MATCH_PAIRS_FINAL m
            WHERE m.RECORD_KEY_A IN (SELECT RECORD_KEY FROM {DB}.CUSTOMER_XREF WHERE GOLDEN_ID = ?)
               OR m.RECORD_KEY_B IN (SELECT RECORD_KEY FROM {DB}.CUSTOMER_XREF WHERE GOLDEN_ID = ?)
            ORDER BY m.MATCH_SCORE DESC
            """,
            [golden_id, golden_id],
        ),
        use_container_width=True,
        hide_index=True,
    )

with tab_orders:
    orders = run(
        f"""
        SELECT ORDER_ID, ORDER_DATE, CHANNEL, STATUS, CURRENCY, ORDER_TOTAL, ROUND(ORDER_TOTAL_INR, 2) AS ORDER_TOTAL_INR
        FROM {DB}.CUSTOMER_ORDERS_BY_GOLDEN WHERE GOLDEN_ID = ?
        ORDER BY ORDER_DATE DESC LIMIT 100
        """,
        [golden_id],
    )
    if orders.empty:
        st.info("No ERP orders for this customer.")
    else:
        monthly = orders.assign(MONTH=pd.to_datetime(orders["ORDER_DATE"]).dt.to_period("M").dt.to_timestamp())
        st.bar_chart(monthly.groupby("MONTH")["ORDER_TOTAL_INR"].sum())
        st.dataframe(orders, use_container_width=True, hide_index=True)

with tab_tix:
    st.dataframe(
        run(
            f"""
            SELECT TICKET_ID, CREATED_AT, CHANNEL, PRIORITY, STATUS, SUBJECT, RESOLVED_AT
            FROM {DB}.CUSTOMER_TICKETS_BY_GOLDEN WHERE GOLDEN_ID = ?
            ORDER BY CREATED_AT DESC LIMIT 100
            """,
            [golden_id],
        ),
        use_container_width=True,
        hide_index=True,
    )
