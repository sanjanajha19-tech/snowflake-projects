# 23 · Customer 360 & Entity Resolution

Resolves one customer seen in three systems (ERP, CRM and e-commerce) into a single **golden customer**. It then builds a Customer 360 view with orders, lifetime value, last order, open tickets and, optionally, ticket sentiment.

## What it does
| Step | Object(s) | Technique |
|---|---|---|
| Messy sources | `C360_CRM.CRM_ACCOUNTS`, `C360_ECOM.ECOM_CUSTOMERS` | Built from `DEMO.CUSTOMERS` with deterministic variations: typos, `Pvt Ltd` vs `Private Limited`, letter case, phone formats, missing emails and PANs, `+tag` emails, in-CRM duplicates, and 400 e-commerce guest shoppers |
| Standardise | `NORMALIZE_NAME`, `NAME_CORE`, `NORMALIZE_PHONE`, `PHONE_MATCH_KEY`, `NORMALIZE_EMAIL`, `NORMALIZE_PAN`, `NORMALIZE_CITY` (SQL UDFs), `CUSTOMER_RECORDS` | Regex clean-up, unified legal forms, digits-only phones, PAN format check. Includes UDF unit tests |
| Block | `CANDIDATE_PAIRS` | Exact email, phone key, PAN, SOUNDEX(name)+country, name prefix+city. Blocks larger than `MAX_BLOCK_SIZE` are skipped |
| Match | `MATCH_PAIRS`, `MATCH_CONFIG` | `JAROWINKLER_SIMILARITY` and `EDITDISTANCE` on the core name, plus exact email, phone, PAN and city. The weighted score only counts attributes that both records have. A conflicting PAN never auto-merges |
| Adjudicate (optional) | `ADJUDICATE_BORDERLINE_MATCHES(n)`, `MATCH_ADJUDICATIONS` | Sends borderline pairs to `AI_COMPLETE` in a batch capped at *n* pairs |
| Steward | `STEWARD_OVERRIDES`, `MATCH_PAIRS_FINAL` | A steward decision beats an AI decision, which beats the rules. Steward and AI decisions survive reruns |
| Cluster | `BUILD_CUSTOMER_CLUSTERS(max_iter)`, `CUSTOMER_XREF` | Connected components, found by iterative min-label propagation in Snowflake Scripting |
| Survivorship | `GOLDEN_CUSTOMER` | Name and phone: ERP > CRM > ECOM. Email and city: most recently updated. PAN: first valid one. Segment and credit limit: ERP only |
| 360 | `CUSTOMER_360`, `CUSTOMER_360_WITH_SENTIMENT` | Orders converted to INR, LTV, last-365-day revenue, last order, lifecycle stage, tickets, sentiment (from asset 24) |
| App | `streamlit_app.py` | Search, golden profile, source records, match evidence, orders, tickets |

## Prerequisites
- `00_setup` has been run: `ACCEL_ADMIN`, `ACCEL_WH`, `ACCEL_DB.DEMO.*`, Cortex user role.
- Step 04 needs Cortex AI functions in your region. If your region does not host the model, enable cross-region inference.
- Step 07 needs asset 24 (`ACCEL_DB.VOC.TICKET_ENRICHED`).

## Run order
1. `01_source_systems.sql` creates the CRM and e-commerce sources.
2. `02_standardization.sql` creates the UDFs and `CUSTOMER_RECORDS`. Check that every UDF test shows PASS.
3. `03_matching.sql` covers config, blocking, scoring and the final-decision view.
4. `04_ai_adjudication_optional.sql` is optional and uses AI credits. Rerun it to process more pairs.
5. `05_clustering_golden_record.sql` builds the clusters, `CUSTOMER_XREF` and `GOLDEN_CUSTOMER`, and runs the accuracy check.
6. `06_customer_360_view.sql` creates `CUSTOMER_360` and the grants.
7. `07_optional_voc_sentiment.sql` is optional and runs after asset 24.
8. Create a Streamlit app in `ACCEL_DB.C360` on `ACCEL_WH` and paste `streamlit_app.py`.

After you change `MATCH_CONFIG` or add steward overrides, rerun 03 (from section 2) → 05 → 06.

## Things to edit (`-- EDIT ME`)
- `MATCH_CONFIG`: weights, auto and review thresholds, maximum block size.
- `ADJUDICATE_BORDERLINE_MATCHES`: the model name (`llama3.1-70b` by default) and the batch size in the `CALL`.
- `FX_TO_INR`: rates are illustrative. Replace them with your treasury rates.

## Cost note
Steps 01–03 and 05–06 run in seconds on an XSMALL warehouse. Step 04 makes one short `AI_COMPLETE` call per borderline pair. Start with 50 pairs and check the result before you run larger batches.

## 5-step demo script
1. **The problem:** run the profile query at the end of `02`. You get about 13k source records for about 5k real customers, with missing emails and inconsistent phones. Show the same company spelled three ways in `CUSTOMER_RECORDS`.
2. **Explainable matching:** show the borderline query at the end of `03`, with Jaro-Winkler, edit distance, the evidence flags and the score for each pair. Change a weight in `MATCH_CONFIG` to show that the rules are tunable.
3. **AI as a second opinion:** run `CALL C360.ADJUDICATE_BORDERLINE_MATCHES(20);` and read the AI's reasons. Insert one `STEWARD_OVERRIDES` row to show that a human has the final say.
4. **Golden record:** run `05`. The accuracy check (possible because the data is synthetic) shows resolved, under-merged and over-merged counts.
5. **Customer 360 app:** search a name, open the customer and walk through LTV, last order, open tickets, the source records and *why* they were merged.

## Client value claim
A single, explainable customer identity gives sales, service and finance one shared view of the customer. Typical outcomes are 10–30% fewer duplicate customer records, more accurate LTV and churn targeting, and faster service. Every merge is traceable to evidence, AI reasoning or a steward decision. All of this runs inside Snowflake, with no data leaving the platform.
