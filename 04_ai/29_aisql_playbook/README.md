# 29 - AI SQL Playbook

One script that demonstrates every Cortex AI SQL function on the demo support tickets. Each function is framed as a business scenario that an analyst can copy into production SQL, dbt models or dynamic tables.

| # | Scenario | Function(s) |
|---|---|---|
| 1 | Voice of customer: overall and aspect sentiment (Delivery, Product quality, Billing, Support), issue category with label descriptions, multi-label tags | `AI_SENTIMENT`, `AI_CLASSIFY` (single and `output_mode: multi`) |
| 2 | Product quality review: complaint summary per product category | `AI_SUMMARIZE_AGG` |
| 3 | Refund exposure: find tickets asking for refunds or credit notes | `AI_FILTER` with `PROMPT()` |
| 4 | Global support desk: translate tickets to Hindi, Japanese and German | `AI_TRANSLATE` (source auto-detected) |
| 5 | Auto-triage: issue type, urgency, intent, callback flag, churn risk and a suggested reply as typed JSON | `AI_COMPLETE` with `response_format` (JSON schema) |
| 6 | Duplicate tickets: embeddings, vector cosine similarity for candidate pairs, then confirmation | `AI_EMBED`, `VECTOR_COSINE_SIMILARITY`, `AI_SIMILARITY` |
| 7 | Executive insight: top issues with actions, overall and per region | `AI_AGG` |
| 8 | Cost tracking query (commented) | `ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY` |

Objects are created in `ACCEL_DB.AISQL`: `TICKET_SAMPLE`, `TICKET_ENRICHED`, `TICKET_TRIAGE` and `TICKET_EMBEDDINGS`.

## Prerequisites
- `00_setup` run. The role needs `SNOWFLAKE.CORTEX_USER`, which `00_setup` grants to all ACCEL roles.
- The model in `LLM_MODEL` must be available in your region. The default is `claude-sonnet-4-5`; alternatives are `claude-haiku-4-5`, `llama3.3-70b` and `mistral-large2`. You can also enable cross-region inference (see `00_setup/01_account_setup.sql`).

## Run order
1. `01_aisql_playbook.sql`. Run it top to bottom, or one section at a time while presenting. Set `LLM_MODEL` and `SAMPLE_SIZE` at the top (both marked `EDIT ME`).

## Cost awareness
- Every AI function is billed per token, per row. The playbook works on a **100-ticket sample**, and `AI_COMPLETE` triage is limited to **20 rows**, so a full run costs well under a credit. Scale up `SAMPLE_SIZE` deliberately.
- Enrichment is materialised once (`TICKET_ENRICHED`, `TICKET_TRIAGE`, `TICKET_EMBEDDINGS`) and later queries reuse it. Do the same in production: enrich incrementally (a stream plus a task, or a dynamic table) rather than calling AI functions from dashboards.
- Use the cheapest function that fits the task. `AI_FILTER`, `AI_CLASSIFY` and `AI_SENTIMENT` are cheaper and more consistent than prompting `AI_COMPLETE`.
- For duplicate detection, embed once and compare vectors with `VECTOR_COSINE_SIMILARITY`, which costs no AI credits. Only the top pairs are confirmed with `AI_SIMILARITY`.
- Monitor spend with the query in section 8. `ACCOUNT_USAGE` can lag by a few hours.

## 5-step demo script
1. Run section 0 and section 1. Show the sentiment-by-aspect table: "Delivery is where the negative sentiment concentrates."
2. Section 2: `AI_SUMMARIZE_AGG` gives a one-paragraph complaint summary per product category, ready for the quality review meeting.
3. Section 3: `AI_FILTER` finds refund requests with a plain-English WHERE clause, with no keyword lists.
4. Section 5: `AI_COMPLETE` structured output fills typed triage columns, including a suggested reply. Show where AI urgency disagrees with the assigned priority.
5. Sections 6 and 7: show the duplicate ticket pairs, then the `AI_AGG` executive summary per region. Close on the point that this is all SQL, governed, and never leaves Snowflake.

## Client value
- Unstructured text (tickets, emails, reviews, call notes) becomes structured, analysable columns with SQL skills alone, so no separate NLP stack is needed.
- Typical uses: 30-50% faster ticket triage, early churn and escalation signals, multilingual support, and automated weekly VOC reporting.
- Governance stays in place: RBAC through `CORTEX_USER`, the data stays in the account, and usage and cost are visible in `ACCOUNT_USAGE`.

## Notes
- AI function outputs are wrapped in `PARSE_JSON(TO_VARCHAR(...))` so the JSON paths work whether a function returns an OBJECT or a JSON string.
- With `response_format`, `AI_COMPLETE` returns an object that follows the schema. `required` and `additionalProperties: false` are included so the same schema also works with OpenAI models.
- The demo tickets are synthetic and partly templated, so the duplicate-detection section finds near-identical texts easily.
