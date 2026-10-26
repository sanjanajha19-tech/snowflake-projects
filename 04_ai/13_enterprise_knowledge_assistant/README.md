# 13 - Enterprise Knowledge Assistant (RAG)

A chat assistant that answers employee questions from company policies and SOPs, and from support-ticket history, with numbered citations. It is built on Cortex Search (hybrid vector and keyword retrieval) and `AI_COMPLETE`, and all content stays inside Snowflake.

## What it builds (schema `ACCEL_DB.KNOWLEDGE`)
| Object | Purpose |
|---|---|
| `POLICY_DOCS_STAGE` | Internal stage (SNOWFLAKE_SSE, directory table) for policy and SOP PDFs |
| `DOC_CHUNKS` | Chunk table: chunk id, document, title, category, source (SEED/UPLOAD), chunk text. Seeded with **16 synthetic chunks** from the travel, IT security, leave and procurement policies, so the demo works without any uploads. |
| `INGEST_POLICY_DOCS()` | For new PDFs: `AI_PARSE_DOCUMENT` (LAYOUT, which gives markdown), then `AI_CLASSIFY` (category), then `SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER` (1,500 characters with 200 overlap), then insert into `DOC_CHUNKS` |
| `KB_SEARCH` | Cortex Search over `DOC_CHUNKS.CHUNK_TEXT`. Filterable by `CATEGORY` and `SOURCE`. |
| `SUPPORT_TICKET_SEARCH` | Cortex Search over ticket subject + body. Filterable by `PRIORITY`, `STATUS`, `CHANNEL` and `CATEGORY`. Also used by the asset 10 agent. |
| `streamlit_app.py` | RAG chat. Uses the Python Search API (`snowflake.core.Root ... cortex_search_services[...].search()`), then `AI_COMPLETE` with citations, a model picker and source filters. |

## Prerequisites
- `00_setup` run.
- Cortex Search and `AI_COMPLETE` available. The default model is `claude-sonnet-4-5`; switch to `llama3.3-70b` or `mistral-large2`, or enable cross-region inference, if Claude is not in your region.

## Run order
1. `01_knowledge_base.sql`. Creates the stage and table, seeds the chunks, creates the ingestion procedure and runs it.
2. `02_search_services.sql`. Creates both search services, runs smoke tests, and ends with a one-shot RAG query in pure SQL.
3. **Streamlit app (UI steps):** Snowsight > **Projects > Streamlit > + Streamlit App**, location `ACCEL_DB.KNOWLEDGE`, warehouse `ACCEL_WH`. In the editor's **Packages** menu add `snowflake.core`. Paste `streamlit_app.py` and click **Run**.
4. Optional, to add your own PDFs: upload them to `POLICY_DOCS_STAGE` (**Data > Databases > ACCEL_DB > KNOWLEDGE > Stages > POLICY_DOCS_STAGE > + Files**), then run `CALL ACCEL_DB.KNOWLEDGE.INGEST_POLICY_DOCS();`. `KB_SEARCH` picks the new chunks up within its `TARGET_LAG` (1 hour). Force it sooner with `ALTER CORTEX SEARCH SERVICE ACCEL_DB.KNOWLEDGE.KB_SEARCH REFRESH;`.

## 5-step demo script
1. `SELECT * FROM DOC_CHUNKS;` shows the knowledge base. Explain chunking and that PDFs can be added with one call.
2. In the app, ask "Can I fly business class on a 12 hour flight?" The answer cites the travel policy [n]. Expand **Sources**.
3. Ask "Who approves a INR 40 lakh purchase and how many quotes do I need?" The answer combines two procurement chunks. Then set the filter to *Procurement* to show filtered retrieval.
4. Add **Support tickets** as a source and ask "What are customers saying about late deliveries?" This gives grounded answers citing ticket IDs.
5. Ask something that is not covered, such as "What is the dress code?" The assistant says it could not find it. That shows the guardrail against hallucination.

## Client value
- Employees get policy answers in seconds, deflecting 20-40% of routine HR, IT and procurement tickets.
- Answers are grounded and cited, so they are auditable. There is no copy of the data in an external vector database or LLM vendor.
- The same search services feed agents (asset 10), Snowflake Intelligence and apps. Governance is ordinary Snowflake RBAC: `USAGE` on the service.

## Notes
- The ticket service is `IF NOT EXISTS`, so it stays shared with asset 10. `KB_SEARCH` is `CREATE OR REPLACE`.
- The app falls back to `SNOWFLAKE.CORTEX.SEARCH_PREVIEW` when `snowflake.core` is not installed. That function is meant for testing, so add the package for real use.
- Cost: search serving is billed per GB-month indexed, indexing uses `ACCEL_AI_WH`, and `AI_COMPLETE` is billed per token (prompt plus answer). `HISTORY_TURNS` and "Passages per source" control prompt size.
- Chunk size and overlap are marked `EDIT ME` in `INGEST_POLICY_DOCS()`.
