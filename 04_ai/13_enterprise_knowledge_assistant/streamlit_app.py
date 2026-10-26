"""
ASSET 13 - Enterprise Knowledge Assistant (Streamlit in Snowflake)

RAG chat: Cortex Search (policies and/or support tickets) retrieves passages,
AI_COMPLETE writes the answer with numbered citations [n].

Create in Snowsight: Projects > Streamlit > + Streamlit App
  - App location: ACCEL_DB.KNOWLEDGE, warehouse ACCEL_WH
  - Packages (Packages menu, top of editor): add  snowflake.core
    (if it is missing the app falls back to SNOWFLAKE.CORTEX.SEARCH_PREVIEW)
  - Paste this file and click Run.
"""

import json

import streamlit as st
from snowflake.snowpark.context import get_active_session

try:
    from snowflake.core import Root
    HAS_SNOWFLAKE_CORE = True
except ImportError:  # package not added to the app
    HAS_SNOWFLAKE_CORE = False

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
DATABASE = "ACCEL_DB"
SCHEMA = "KNOWLEDGE"
SERVICES = {
    "Policies & SOPs": {
        "name": "KB_SEARCH",
        "columns": ["CHUNK_ID", "DOC_TITLE", "CATEGORY", "CHUNK_TEXT"],
        "text_col": "CHUNK_TEXT",
        "title_col": "DOC_TITLE",
        "id_col": "CHUNK_ID",
        "filter_col": "CATEGORY",
        "filter_values": ["All", "Travel", "IT Security", "Leave", "Procurement"],
    },
    "Support tickets": {
        "name": "SUPPORT_TICKET_SEARCH",
        "columns": ["TICKET_ID", "SUBJECT", "TICKET_TEXT", "PRIORITY", "STATUS", "CATEGORY", "CREATED_DATE"],
        "text_col": "TICKET_TEXT",
        "title_col": "SUBJECT",
        "id_col": "TICKET_ID",
        "filter_col": "PRIORITY",
        "filter_values": ["All", "Critical", "High", "Medium", "Low"],
    },
}
MODELS = [  # EDIT ME: first entry is the default; keep models available in your region
    "claude-sonnet-4-5",
    "claude-haiku-4-5",
    "llama3.3-70b",
    "mistral-large2",
]
HISTORY_TURNS = 3

session = get_active_session()
root = Root(session) if HAS_SNOWFLAKE_CORE else None

st.set_page_config(page_title="Enterprise Knowledge Assistant", layout="wide")
st.title("Enterprise Knowledge Assistant")
st.caption("Answers from company policies and support history, with citations. Powered by Cortex Search + AI_COMPLETE.")


# ----------------------------------------------------------------------------
# Retrieval
# ----------------------------------------------------------------------------
def search(service_key, query, limit, filter_value):
    cfg = SERVICES[service_key]
    search_filter = None
    if filter_value and filter_value != "All":
        search_filter = {"@eq": {cfg["filter_col"]: filter_value}}

    if HAS_SNOWFLAKE_CORE:
        svc = (root.databases[DATABASE]
               .schemas[SCHEMA]
               .cortex_search_services[cfg["name"]])
        kwargs = {"query": query, "columns": cfg["columns"], "limit": limit}
        if search_filter:
            kwargs["filter"] = search_filter
        resp = svc.search(**kwargs)
        results = getattr(resp, "results", None)
        if results is None:
            results = json.loads(resp.to_json()).get("results", [])
    else:
        payload = {"query": query, "columns": cfg["columns"], "limit": limit}
        if search_filter:
            payload["filter"] = search_filter
        # SEARCH_PREVIEW is meant for testing; fine for a demo fallback
        row = session.sql(
            "SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(?, ?) AS R",
            params=[f"{DATABASE}.{SCHEMA}.{cfg['name']}", json.dumps(payload)],
        ).collect()[0]
        results = json.loads(row["R"]).get("results", [])

    hits = []
    for r in results:
        r = {str(k).upper(): v for k, v in dict(r).items()}
        hits.append({
            "source": service_key,
            "id": str(r.get(cfg["id_col"], "")),
            "title": str(r.get(cfg["title_col"], "")),
            "text": str(r.get(cfg["text_col"], "")),
            "meta": {k: v for k, v in r.items()
                     if k not in (cfg["text_col"], cfg["title_col"], cfg["id_col"]) and not k.startswith("@")},
        })
    return hits


# ----------------------------------------------------------------------------
# Generation
# ----------------------------------------------------------------------------
def build_prompt(question, hits, history):
    context_lines = []
    for i, h in enumerate(hits, start=1):
        context_lines.append(f"[{i}] ({h['source']}: {h['title']} | id {h['id']})\n{h['text']}")
    context = "\n\n".join(context_lines) if context_lines else "(no passages found)"

    convo = ""
    if history:
        recent = history[-HISTORY_TURNS * 2:]
        convo = "\n".join(f"{m['role'].upper()}: {m['content']}" for m in recent)

    return (
        "You are the company's internal knowledge assistant. Answer the user's question using ONLY the "
        "numbered passages below. Cite every fact with its passage number in square brackets, e.g. [1] or [2][3]. "
        "If the passages do not contain the answer, say that you could not find it in the knowledge base and "
        "suggest who to contact (HR, IT Service Desk, Procurement or Finance). Keep the answer short: "
        "a direct answer first, then bullet points if useful. Do not invent policy numbers or amounts.\n\n"
        f"Conversation so far:\n{convo or '(none)'}\n\n"
        f"Passages:\n{context}\n\n"
        f"Question: {question}\n\nAnswer:"
    )


def complete(model, prompt):
    row = session.sql("SELECT AI_COMPLETE(?, ?) AS ANSWER", params=[model, prompt]).collect()[0]
    answer = row["ANSWER"]
    # AI_COMPLETE returns a string; strip JSON quoting if the driver returns it quoted
    if isinstance(answer, str) and answer.startswith('"') and answer.endswith('"'):
        try:
            answer = json.loads(answer)
        except ValueError:
            pass
    return answer


def render_sources(hits):
    if not hits:
        return
    with st.expander(f"Sources ({len(hits)})"):
        for i, h in enumerate(hits, start=1):
            st.markdown(f"**[{i}] {h['title']}** - {h['source']} - `{h['id']}`")
            if h["meta"]:
                st.caption(" | ".join(f"{k}: {v}" for k, v in h["meta"].items()))
            st.write(h["text"])
            st.divider()


# ----------------------------------------------------------------------------
# Sidebar
# ----------------------------------------------------------------------------
with st.sidebar:
    st.subheader("Settings")
    model = st.selectbox("LLM", MODELS, index=0)
    sources = st.multiselect("Search in", list(SERVICES.keys()), default=["Policies & SOPs"])
    filters = {}
    for key in sources:
        cfg = SERVICES[key]
        filters[key] = st.selectbox(f"{key}: {cfg['filter_col'].title()}", cfg["filter_values"], key=f"f_{key}")
    top_k = st.slider("Passages per source", 1, 10, 4)
    if not HAS_SNOWFLAKE_CORE:
        st.info("snowflake.core not installed - using SEARCH_PREVIEW fallback. Add the package for production.")
    st.divider()
    st.markdown("**Try:**")
    st.markdown("- Can I fly business class on a 12 hour flight?\n"
                "- Who approves a INR 40 lakh purchase and how many quotes do I need?\n"
                "- How long is paternity leave?\n"
                "- What should I do if I lose my laptop?\n"
                "- What are customers saying about late deliveries? (select Support tickets)")
    if st.button("Clear chat"):
        st.session_state.chat = []
        st.rerun()

if "chat" not in st.session_state:
    st.session_state.chat = []

for msg in st.session_state.chat:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])
        if msg["role"] == "assistant":
            render_sources(msg.get("hits", []))

question = st.chat_input("Ask about policies, procedures or customer issues...")
if question:
    with st.chat_message("user"):
        st.markdown(question)

    with st.chat_message("assistant"):
        if not sources:
            st.warning("Select at least one source in the sidebar.")
        else:
            try:
                with st.spinner("Searching..."):
                    hits = []
                    for key in sources:
                        hits.extend(search(key, question, top_k, filters.get(key)))
                with st.spinner("Writing answer..."):
                    history = [{"role": m["role"], "content": m["content"]} for m in st.session_state.chat]
                    answer = complete(model, build_prompt(question, hits, history))
                st.markdown(answer)
                render_sources(hits)
                st.session_state.chat.append({"role": "user", "content": question})
                st.session_state.chat.append({"role": "assistant", "content": answer, "hits": hits})
            except Exception as exc:
                st.error(f"Something went wrong: {exc}")
