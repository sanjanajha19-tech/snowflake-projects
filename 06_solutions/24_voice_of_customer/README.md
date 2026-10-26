# 24 · Voice of Customer (VoC)

Uses Cortex AI SQL functions to turn the free-text support tickets in `DEMO.SUPPORT_TICKETS` into structured insight. Each ticket gets sentiment (overall and by aspect), a topic, a root cause and the product mentioned. On top of that, the asset builds weekly AI theme summaries, a top-issues digest per topic, an escalation-risk list and a Streamlit dashboard.

## What it does
| Object | Built with |
|---|---|
| `VOC.TOPIC_TAXONOMY`, `VOC.SENTIMENT_ASPECTS` | Editable taxonomy: delivery, billing, quality, service, praise and other, each with a description |
| `VOC.ENRICH_TICKETS(batch)` → `VOC.TICKET_ENRICHED` | `AI_SENTIMENT(text, [aspects])` for overall and aspect sentiment, `SNOWFLAKE.CORTEX.SENTIMENT` for a numeric score, `AI_CLASSIFY` with label descriptions, and `AI_EXTRACT` for root cause and product mentioned. Only tickets not yet processed are sent, and the batch size caps the spend |
| `VOC.BUILD_WEEKLY_THEMES(weeks)` → `VOC.WEEKLY_THEMES` | `AI_SUMMARIZE_AGG` per week and product category |
| `VOC.BUILD_TOPIC_ISSUES(days)` → `VOC.TOPIC_ISSUES` | `AI_AGG` with an instruction to list the top 3 recurring issues and an action for each |
| `VOC.TICKET_ASPECT_SENTIMENT`, `SENTIMENT_TREND_WEEKLY`, `TOPIC_SUMMARY` | Reporting views |
| `VOC.ESCALATION_RISK` | Transparent 0–100 score for open tickets. It weighs sentiment, priority, topic, segment, repeat contacts, prior escalations and age |
| Stream `NEW_TICKETS_STREAM`, `PROCESS_NEW_TICKETS(n)`, tasks `ENRICH_NEW_TICKETS_TASK` (hourly, `WHEN SYSTEM$STREAM_HAS_DATA`) and `WEEKLY_THEMES_TASK` (Mondays) | Incremental processing: the task only runs when new tickets have arrived, and each ticket is enriched exactly once |
| `streamlit_app.py` | Dashboard with sentiment trend, topics, aspect sentiment, AI top issues, weekly themes and escalation risk |

## Prerequisites
- `00_setup` has been run. The role needs `SNOWFLAKE.CORTEX_USER`, which setup grants.
- Your region must support the Cortex AI functions. If it does not, enable cross-region inference (`ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';` as ACCOUNTADMIN).
- File 05 needs `EXECUTE TASK` for `ACCEL_ADMIN` (granted by `00_setup`). If you rerun `00_setup`, `DEMO.SUPPORT_TICKETS` is recreated and the stream goes stale, so rerun 05.

## Run order
1. `01_setup_taxonomy.sql`
2. `02_enrich_tickets.sql` processes the first 200 tickets. Check the results and the cost, then uncomment the larger `CALL`s to finish the backlog.
3. `03_weekly_themes.sql`
4. `04_views_escalation_risk.sql`
5. `05_incremental_tasks.sql`. This step is optional for a one-off demo. Suspend the tasks afterwards.
6. Create a Streamlit app in `ACCEL_DB.VOC` on `ACCEL_WH` and paste `streamlit_app.py`.

## Cost note
- Enrichment makes 4 AI calls per ticket on about 100 tokens of text. The 2,000 demo tickets come to roughly 8,000 short calls, which is small but not free. Use `BATCH_SIZE` to control spend.
- Theme summaries make one aggregate call per week and category group, about 100 calls for 12 weeks. Top issues make one call per topic.
- Tickets are never reprocessed. To force a full rerun, `TRUNCATE TABLE VOC.TICKET_ENRICHED`.
- To see actual spend, query `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY` (the query is at the bottom of 02).
- The dashboard only reads stored results and makes no AI calls.

## Things to edit (`-- EDIT ME`)
- The taxonomy labels and descriptions, and the sentiment aspects. They are kept in the tables in 01 **and** in the literal arrays in 02, so change both together.
- The batch sizes, the theme window in weeks, the top-issues window in days, and the task schedules.
- The escalation-risk weights in 04.

## 5-step demo script
1. Show three raw tickets, then run `CALL VOC.ENRICH_TICKETS(50);` and show the same tickets with sentiment, aspects, topic, root cause and product. Point out that no model hosting or data movement was needed.
2. In the dashboard, show the sentiment trend and the topic mix. Filter to one product category.
3. Open *Top issues*. AI has written the three biggest problems per topic, with corrective actions.
4. Open *Weekly themes* and read last week's AI summary for one category, the kind of text that goes into a weekly ops review.
5. Show *Escalation risk*. Open tickets ranked by an explainable score give team leads a call list. The hourly task keeps it current.

## Client value claim
Every ticket, call note and chat is read and tagged within an hour of arriving, instead of a few being sampled by hand. Typical outcomes are a 20–40% reduction in manual tagging effort, earlier detection of emerging product or delivery issues (days instead of the next monthly review), and fewer escalations, because high-risk tickets surface while they can still be saved. Governed SQL keeps the data in Snowflake, and the batch size gives predictable cost.
