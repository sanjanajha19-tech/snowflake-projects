"""
ASSET 10 - Talk to your Data (Streamlit in Snowflake)

Chat UI over Cortex Analyst using the semantic view
ACCEL_DB.SEMANTIC.SALES_SEMANTIC_VIEW. Shows the analyst's interpretation,
the generated SQL, the result table and an automatic chart.

Create in Snowsight: Projects > Streamlit > + Streamlit App
  - App location: ACCEL_DB.SEMANTIC, warehouse ACCEL_WH, run on the
    WAREHOUSE runtime (the _snowflake module is used for the REST call)
  - Paste this file, click Run. No extra packages are needed.
"""

import json

import pandas as pd
import streamlit as st
import _snowflake  # available in Streamlit in Snowflake (warehouse runtime)
from snowflake.snowpark.context import get_active_session

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
SEMANTIC_VIEW = "ACCEL_DB.SEMANTIC.SALES_SEMANTIC_VIEW"  # EDIT ME
API_ENDPOINT = "/api/v2/cortex/analyst/message"
API_TIMEOUT_MS = 50000
MAX_ROWS_DISPLAY = 1000

SAMPLE_QUESTIONS = [
    "What was revenue by region by quarter in 2026?",
    "Why did South region revenue drop in Q2 2026?",
    "What is gross margin % by product category in 2025?",
    "Show monthly revenue and order count for the E-commerce channel",
    "Which 10 customers had the highest revenue in 2026?",
    "What is the average order value by segment?",
]

session = get_active_session()

st.set_page_config(page_title="Talk to your Sales Data", layout="wide")
st.title("Talk to your Sales Data")
st.caption(f"Cortex Analyst over semantic view `{SEMANTIC_VIEW}`")


# ----------------------------------------------------------------------------
# Cortex Analyst call
# ----------------------------------------------------------------------------
def call_analyst(messages):
    """Send the conversation to Cortex Analyst. Returns (response_dict, error_str)."""
    request_body = {
        "messages": messages,
        "semantic_view": SEMANTIC_VIEW,
    }
    resp = _snowflake.send_snow_api_request(
        "POST",            # method
        API_ENDPOINT,      # path
        {},                # headers
        {},                # params
        request_body,      # body
        None,              # request_guid
        API_TIMEOUT_MS,    # timeout in milliseconds
    )
    try:
        parsed = json.loads(resp["content"])
    except (TypeError, ValueError):
        return None, f"Unexpected response from Cortex Analyst (HTTP {resp.get('status')})."
    if resp["status"] < 400:
        return parsed, None
    request_id = parsed.get("request_id", "n/a") if isinstance(parsed, dict) else "n/a"
    message = parsed.get("message", str(parsed)) if isinstance(parsed, dict) else str(parsed)
    return None, f"Cortex Analyst error (HTTP {resp['status']}, request_id {request_id}): {message}"


def run_sql(sql):
    """Run generated SQL and return a pandas DataFrame."""
    df = session.sql(sql.rstrip().rstrip(";")).limit(MAX_ROWS_DISPLAY).to_pandas()
    return df


# ----------------------------------------------------------------------------
# Automatic chart
# ----------------------------------------------------------------------------
def auto_chart(df):
    """Pick a sensible chart: line for time series, bar for one category + numbers."""
    if df is None or df.empty or len(df.columns) < 2 or len(df) < 2:
        return
    data = df.copy()
    numeric_cols = [c for c in data.columns if pd.api.types.is_numeric_dtype(data[c])]
    date_cols = []
    for c in data.columns:
        if pd.api.types.is_datetime64_any_dtype(data[c]):
            date_cols.append(c)
        elif data[c].dtype == object and c not in numeric_cols:
            sample = data[c].dropna().head(5)
            if len(sample) > 0 and all(hasattr(v, "year") and hasattr(v, "month") for v in sample):
                data[c] = pd.to_datetime(data[c])
                date_cols.append(c)
    category_cols = [c for c in data.columns if c not in numeric_cols and c not in date_cols]

    if not numeric_cols:
        return

    if date_cols:
        x = date_cols[0]
        if category_cols and len(numeric_cols) >= 1:
            # one line per category for the first metric
            pivot = data.pivot_table(index=x, columns=category_cols[0],
                                     values=numeric_cols[0], aggfunc="sum").sort_index()
            st.line_chart(pivot)
        else:
            st.line_chart(data.set_index(x)[numeric_cols].sort_index())
    elif category_cols:
        x = category_cols[0]
        if len(category_cols) >= 2:
            pivot = data.pivot_table(index=x, columns=category_cols[1],
                                     values=numeric_cols[0], aggfunc="sum")
            st.bar_chart(pivot)
        else:
            st.bar_chart(data.set_index(x)[numeric_cols[:3]])


# ----------------------------------------------------------------------------
# Render one analyst message
# ----------------------------------------------------------------------------
def render_content(content, message_index):
    for item_index, item in enumerate(content):
        item_type = item.get("type")
        if item_type == "text":
            st.markdown(item.get("text", ""))
        elif item_type == "suggestions":
            st.markdown("**Did you mean one of these?**")
            for s_index, suggestion in enumerate(item.get("suggestions", [])):
                if st.button(suggestion, key=f"sugg_{message_index}_{item_index}_{s_index}"):
                    st.session_state.pending_question = suggestion
                    st.rerun()
        elif item_type == "sql":
            sql = item.get("statement", "")
            with st.expander("Generated SQL", expanded=False):
                st.code(sql, language="sql")
            cache_key = f"df_{message_index}_{item_index}"
            if cache_key not in st.session_state:
                try:
                    st.session_state[cache_key] = run_sql(sql)
                except Exception as exc:  # show SQL errors to the user
                    st.session_state[cache_key] = None
                    st.error(f"Query failed: {exc}")
            df = st.session_state.get(cache_key)
            if df is not None:
                tab_table, tab_chart = st.tabs(["Results", "Chart"])
                with tab_table:
                    st.dataframe(df, use_container_width=True)
                with tab_chart:
                    auto_chart(df)


# ----------------------------------------------------------------------------
# Conversation state
# ----------------------------------------------------------------------------
if "messages" not in st.session_state:
    st.session_state.messages = []          # Cortex Analyst format
if "pending_question" not in st.session_state:
    st.session_state.pending_question = None

with st.sidebar:
    st.subheader("Try asking")
    for q_index, q in enumerate(SAMPLE_QUESTIONS):
        if st.button(q, key=f"sample_{q_index}"):
            st.session_state.pending_question = q
    st.divider()
    if st.button("Clear conversation"):
        for key in list(st.session_state.keys()):
            del st.session_state[key]
        st.rerun()

for idx, msg in enumerate(st.session_state.messages):
    with st.chat_message("user" if msg["role"] == "user" else "assistant"):
        render_content(msg["content"], idx)

question = st.chat_input("Ask a question about sales...")
if st.session_state.pending_question and not question:
    question = st.session_state.pending_question
st.session_state.pending_question = None

if question:
    user_message = {"role": "user", "content": [{"type": "text", "text": question}]}
    st.session_state.messages.append(user_message)
    with st.chat_message("user"):
        st.markdown(question)

    with st.chat_message("assistant"):
        with st.spinner("Cortex Analyst is thinking..."):
            response, error = call_analyst(st.session_state.messages)
        if error:
            st.error(error)
            # keep the conversation valid (user/analyst must alternate)
            st.session_state.messages.pop()
        else:
            analyst_message = {
                "role": "analyst",
                "content": response["message"]["content"],
            }
            st.session_state.messages.append(analyst_message)
            render_content(analyst_message["content"], len(st.session_state.messages) - 1)
            warnings = response.get("warnings") or []
            for w in warnings:
                st.warning(w.get("message", str(w)))
