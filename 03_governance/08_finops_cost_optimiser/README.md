# 08 · FinOps Cost Optimizer

Shows where Snowflake credits go, flags waste, estimates savings in currency, sets budgets and gives showback by cost center. Everything is built on `SNOWFLAKE.ACCOUNT_USAGE`, with no external tools.

## What it does
| File | Objects (schema `ACCEL_DB.FINOPS`) |
|---|---|
| `01_finops_views.sql` | `FINOPS_CONFIG` (credit and storage price, `-- EDIT ME`). Views: `V_SPEND_DAILY_BY_SERVICE` (METERING_DAILY_HISTORY), `V_SPEND_DAILY_BY_WAREHOUSE` (incl. idle credits = compute − `CREDITS_ATTRIBUTED_COMPUTE_QUERIES`), `V_IDLE_WAREHOUSES`, `V_TOP_QUERIES` / `V_TOP_USERS` (QUERY_ATTRIBUTION_HISTORY, grouped by `QUERY_PARAMETERIZED_HASH`), `V_SPILLING_QUERIES`, `V_STORAGE_DAILY`, `V_TABLE_STORAGE`, `V_UNUSED_TABLES` (ACCESS_HISTORY, 90 days), `V_AI_SPEND_DAILY`, `V_AI_SPEND_BY_FUNCTION_MODEL` (CORTEX_AI_FUNCTIONS_USAGE_HISTORY), `V_AI_SPEND_OTHER_SERVICES` (Cortex Analyst, Search, Agents) |
| `02_warehouse_guardrails.sql` | `SNAPSHOT_WAREHOUSES()` writes SHOW WAREHOUSES output to `WAREHOUSE_CONFIG`. `V_WAREHOUSE_GUARDRAILS` flags AUTO_SUSPEND > 300 s or disabled, no resource monitor, auto-resume off and high max clusters |
| `03_cost_center_attribution.sql` | `COST_CENTER` tag (allowed values) on warehouses (and users, as a template). `V_COST_BY_CENTER_WAREHOUSE` and `V_COST_BY_CENTER_QUERY` attribute cost by user tag, then `QUERY_TAG` (`cost_center=...`), then warehouse tag |
| `04_recommendations.sql` | `GENERATE_RECOMMENDATIONS()` applies 9 rules (idle compute, auto-suspend, missing monitors, expensive query shapes, remote spilling, unused tables, Time Travel churn, AI model right-sizing, cloud services). Results land in `FINOPS_RECOMMENDATIONS` with severity, estimated monthly credits/USD saved and fix SQL. `TASK_FINOPS_WEEKLY` is created suspended |
| `05_budgets.sql` | Activates the account budget (`SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET`) with a spending limit. Creates a custom budget `ACCEL_BUDGET` (`SNOWFLAKE.CORE.BUDGET`) covering both ACCEL warehouses plus everything tagged `COST_CENTER = 'CC-DATA-PLATFORM'`. Includes a commented e-mail notification integration template |
| `streamlit_app.py` | Tabs: Overview / Warehouses / Queries / Storage / AI spend / Recommendations |

## Prerequisites
- `00_setup` (ACCEL_ADMIN has `IMPORTED PRIVILEGES` on the SNOWFLAKE database).
- Enterprise edition for `ACCESS_HISTORY` (unused tables). On Standard, `V_UNUSED_TABLES` returns an error; the rest works.
- ACCOUNTADMIN for `05_budgets.sql` (account budget activation, budget creation in the shared schema, integrations). Optionally also for the account-wide warehouse snapshot in file 02.
- ACCOUNT_USAGE lags by 45 minutes to 3 hours. A brand-new account shows little data on day one. The views are fully populated after a few days of real use.

## Run order
1. `01_finops_views.sql` (first set `CREDIT_PRICE_USD` and `STORAGE_PRICE_USD_TB_MONTH`)
2. `02_warehouse_guardrails.sql`
3. `03_cost_center_attribution.sql`
4. `04_recommendations.sql`
5. `05_budgets.sql` (ACCOUNTADMIN; fill in the e-mail template if you want alerts)
6. Streamlit: Snowsight » Projects » Streamlit » + Streamlit App. Choose database `ACCEL_DB`, schema `FINOPS`, warehouse `ACCEL_WH`, then paste `streamlit_app.py`.

## 5-step demo script
1. **Overview tab**: spend for the period vs the prior period, the split by service type (warehouses vs serverless vs AI), and the idle cost KPI.
2. **Warehouses tab**: busy vs idle credits per warehouse. Guardrail flags show which warehouses have AUTO_SUSPEND > 300 s or no resource monitor.
3. **Queries tab**: the most expensive *query shapes*, not single runs (QUERY_ATTRIBUTION_HISTORY + parameterized hash), the top users, and spilling.
4. **AI spend tab**: Cortex AI functions by model and user, plus Analyst, Search and Agents. Point out that AI cost is now visible at the same grain as warehouse cost.
5. **Recommendations tab**: click "Re-run". Show the total estimated monthly savings, filter by category and copy the fix SQL. Finish with the budget (file 05) and the cost-center showback view.

## Client value
"See every credit, attribute it to an owner, and act on it." Typical first-pass savings are 15–30% of warehouse spend from auto-suspend, consolidation and query tuning alone. Budgets and cost-center tags give finance predictable, attributable spend.

## Notes
- Savings are heuristic estimates (e.g. 50% of idle credits, 25% of a tuned query's credits). Validate them with the query profile before acting.
- QUERY_ATTRIBUTION_HISTORY excludes warehouse idle time and very short queries (≈ ≤ 100 ms). Idle time is reported separately.
- `SNAPSHOT_WAREHOUSES()` only sees warehouses visible to the calling role. Run it as ACCOUNTADMIN, or grant MONITOR, for full coverage.
- Rerunning `05_budgets.sql` re-adds resources that are already linked. If a call reports the resource as already added, that is expected.
