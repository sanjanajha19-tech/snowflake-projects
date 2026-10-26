# 10 - Talk to your Data Agent

Business users ask sales questions in plain English. The agent answers with numbers (Cortex Analyst over a governed semantic view) and explains them with customer complaints (Cortex Search over support tickets).

## What it builds
| Object | Purpose |
|---|---|
| `ACCEL_DB.SEMANTIC.SALES_ORDERS_V`, `SALES_ORDER_LINES_V`, `SALES_CUSTOMERS_V`, `SALES_PRODUCTS_V` | GOLD-like sales views over `DEMO`. Revenue excludes cancelled and returned orders. No PII columns. |
| `ACCEL_DB.SEMANTIC.SALES_SEMANTIC_VIEW` | Semantic view: 4 tables, 3 relationships, facts, dimensions with synonyms and descriptions. Metrics: revenue, COGS, gross margin, margin %, units, discount, order count, fulfilled orders, cancellation rate, customer count, AOV (derived). Also 2 verified queries and SQL-generation instructions. |
| `ACCEL_DB.KNOWLEDGE.SUPPORT_TICKET_SEARCH` | Cortex Search service over ticket subject + body. This is the same service asset 13 builds; file 03 creates it only if it does not exist. |
| `ACCEL_DB.SEMANTIC.SALES_INSIGHTS_AGENT` | Cortex Agent with two tools: `SalesAnalyst` (text-to-SQL) and `TicketSearch`. Includes instructions and sample questions. |
| `streamlit_app.py` | Streamlit in Snowflake chat over Cortex Analyst. Shows the generated SQL, a results table and an automatic chart. |

## Prerequisites
- `00_setup` run (roles, `ACCEL_WH`, `ACCEL_AI_WH`, `ACCEL_DB.DEMO` data).
- Cortex Analyst, Cortex Search and Cortex Agents available in your region. If the agent's model is not available in your region, ask ACCOUNTADMIN to enable cross-region inference (see `00_setup/01_account_setup.sql`).
- File 05 only: ACCOUNTADMIN.

## Run order
1. `01_sales_model_views.sql`
2. `02_sales_semantic_view.sql`. Ends with a `SEMANTIC_VIEW()` smoke query.
3. `03_ticket_search_service.sql`. Skip it if asset 13 already ran; it does no harm either way.
4. `04_sales_agent.sql`
5. Optional: `05_publish_to_snowflake_intelligence.sql` (ACCOUNTADMIN), to show the agent in Snowflake Intelligence / CoWork.
6. Streamlit app. These are UI steps:
   - Snowsight > **Projects > Streamlit > + Streamlit App**.
   - Name `TALK_TO_YOUR_DATA`, location `ACCEL_DB.SEMANTIC`, warehouse `ACCEL_WH`, **warehouse runtime**.
   - Replace the sample code with `streamlit_app.py` and click **Run**. No extra packages are needed.

## Using the agent (UI steps)
- **Test in Snowsight:** **AI & ML > Agents**, then open `SALES_INSIGHTS_AGENT` and use the chat panel on the right. From here you can also edit instructions, tools and sample questions.
- **Snowflake Intelligence / CoWork:** run file 05, or do it in the UI: **AI & ML > Agents > Snowflake CoWork** tab > **Open settings**, then add `SALES_INSIGHTS_AGENT`. Users with `ACCEL_ANALYST` then open **https://ai.snowflake.com**, sign in, pick *Sales Insights Agent* and chat. Each user needs a default warehouse they can use, such as `ACCEL_WH`.
- **REST:** apps can also call the agent through the Cortex Agents REST API (`/api/v2/databases/ACCEL_DB/schemas/SEMANTIC/agents/SALES_INSIGHTS_AGENT:run`).

## Demo questions
1. "What were revenue, gross margin % and AOV by region in 2026?"
2. "Why did South region revenue drop in Q2 2026?" The agent compares Q1 to Q2 by region, segment, channel and category, then searches tickets for South-region issues.
3. "Show monthly revenue trend for the E-commerce channel." The Streamlit app draws a line chart.
4. "Which product categories have the lowest margin %?"
5. "What are customers complaining about in the top revenue category?" This uses Analyst and then Search.

## 5-step demo script
1. In a worksheet, show `DESCRIBE SEMANTIC VIEW SALES_SEMANTIC_VIEW`. Point out that metrics are defined once, carry business synonyms, and that the view exposes no PII.
2. Open the Streamlit app and ask question 1. Expand **Generated SQL** to show it is real, auditable SQL, then open the **Chart** tab.
3. Ask a follow-up such as "only Enterprise segment". Cortex Analyst keeps the context.
4. Open the agent in Snowflake Intelligence and ask "Why did South region revenue drop in Q2 2026?" Show the numbers breakdown followed by cited ticket IDs.
5. Show that the same governed metric (revenue) gives identical numbers in SQL, the app and the agent. One definition serves every channel.

## Client value
- Self-service answers in seconds instead of analyst tickets that take days. Typical BI request queues shrink by 30-50%.
- One governed metric layer (the semantic view) across BI, AI and apps, so there is no "two versions of revenue".
- "Why" answers combine structured KPIs with unstructured customer voice, all inside Snowflake's security perimeter. Data never leaves the account.

## Notes and limits
- Amounts are treated as being in a single reporting currency. For production, add FX conversion in `SALES_ORDER_LINES_V`.
- Verified queries in `AI_VERIFIED_QUERIES` use the semantic view's logical table names (`orders`, `order_lines`). Add more of them from real user questions; they make Cortex Analyst both more accurate and faster.
- The demo data is synthetic, so a "drop" may or may not exist in a given quarter. The agent still explains what changed.
- Cost: Cortex Analyst is billed per message. Search bills for indexing and serving. The agent bills the tokens its model uses.
