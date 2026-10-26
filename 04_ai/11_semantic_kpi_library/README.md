# 11 - Semantic KPI Library

A library of reusable semantic views for four domains, plus a KPI catalog that documents each KPI. Every KPI is defined once in Snowflake and then reused by Cortex Analyst, Cortex Agents, Snowflake Intelligence, BI tools (via `SEMANTIC_VIEW()` SQL) and Streamlit apps.

## What it builds (schema `ACCEL_DB.KPI_LIBRARY`)
| Domain | Semantic view | KPIs (metric names) |
|---|---|---|
| Finance | `FINANCE_SEMANTIC_VIEW` (over `FIN_GL_PNL_V`) | revenue, cogs, gross_margin, gross_margin_pct, opex, depreciation_amortisation, ebitda_proxy, ebitda_margin_pct, opex_ratio_pct. Sliced by entity, month, quarter, year, cost center, account and source. |
| Supply chain | `SUPPLY_CHAIN_SEMANTIC_VIEW` (over `SC_PURCHASE_ORDERS_V`, `SC_INVENTORY_DOS`, SUPPLIERS, PLANTS, PRODUCTS) | po_count, po_spend, otif_pct, late_po_pct, avg_delivery_delay_days, avg_lead_time_days, total_on_hand, days_of_supply, stockout_risk_pct, below_safety_stock_pct |
| HR | `HR_SEMANTIC_VIEW` (over `HR_EMPLOYEES_V`, no PII) | headcount, exits, attrition_rate_pct, avg_tenure_years, salary_cost, avg_salary |
| Customer service | `CUSTOMER_SERVICE_SEMANTIC_VIEW` (over `CS_TICKETS_V`, CUSTOMERS, PRODUCTS) | ticket_count, open_tickets, avg_resolution_hours, median_resolution_hours, escalation_rate_pct, sla_breach_rate_pct |
| Catalog | `KPI_CATALOG` table and `KPI_CATALOG_V` view | 22 KPIs, each with definition, formula, unit, good direction, grain, semantic view, metric name, owner and caveats |

## Prerequisites
- `00_setup` run (`ACCEL_DB.DEMO` populated).
- A role that can create semantic views. `ACCEL_ADMIN` owns the schema, so it can.

## Run order
1. `01_kpi_base_views.sql`. Builds the standardised KPI logic: sign conventions, OTIF and late flags, days of supply, tenure and SLA.
2. `02_finance_semantic_view.sql`
3. `03_supply_chain_semantic_view.sql`
4. `04_hr_semantic_view.sql`
5. `05_customer_service_semantic_view.sql`
6. `06_kpi_catalog.sql`

Each semantic view file ends with a `SEMANTIC_VIEW()` smoke query. Files 02-05 are independent of each other.

## Using the library
```sql
-- SQL / BI tools
SELECT * FROM SEMANTIC_VIEW(
  ACCEL_DB.KPI_LIBRARY.FINANCE_SEMANTIC_VIEW
  DIMENSIONS gl.entity, gl.fiscal_month
  METRICS gl.revenue, gl.ebitda_proxy, gl.ebitda_margin_pct
  WHERE gl.fiscal_year = 2026);
```
- **Cortex Analyst:** point the REST API's `semantic_view` at any of the views. The asset 10 `streamlit_app.py` works if you change `SEMANTIC_VIEW`.
- **Agents / Snowflake Intelligence:** add a `cortex_analyst_text_to_sql` tool per domain to an agent, following asset 10 `04_sales_agent.sql`. In the UI: **AI & ML > Agents >** agent **> Edit > Tools > + Cortex Analyst**, then choose the semantic view.
- **Snowsight:** **AI & ML > Cortex Analyst** lists the semantic views. You can test questions there and add verified queries in the UI.

## 5-step demo script
1. `SELECT * FROM KPI_CATALOG_V;` shows the business glossary, with owner, formula and grain for every KPI.
2. Run the finance smoke query to show revenue, GM % and EBITDA proxy by entity and year.
3. Open **AI & ML > Cortex Analyst**, select `SUPPLY_CHAIN_SEMANTIC_VIEW` and ask "Which high-risk suppliers have the worst OTIF?"
4. On `HR_SEMANTIC_VIEW`, ask "Attrition rate and average tenure by department". Point out that no names or emails can be returned.
5. On `CUSTOMER_SERVICE_SEMANTIC_VIEW`, ask "Escalation rate by product category for critical tickets". Close on the point that the same definitions serve every tool.

## Client value
- One certified definition per KPI ends conflicting numbers across finance, operations and HR decks.
- The library is AI-ready from day one: semantic views make Cortex Analyst and agents accurate, since they carry synonyms, descriptions and the right join paths.
- The catalog gives a governance hook for KPI ownership, change control and audit.
- New domains reuse the pattern: base view, then semantic view, then a catalog row.

## Assumptions and caveats (demo data)
- **GL sign:** debit is positive and credit negative, so revenue = -SUM(amount). D&A is identified by account name containing "depreciation" or "amorti". Change `FIN_GL_PNL_V` if the client uses account ranges.
- **OTIF:** the demo PO table has no received quantity, so "in full" is assumed. Add a received-quantity condition for real data.
- **Days of supply:** demand is trailing 91-day units ordered from the plant (excluding cancelled orders). `SC_INVENTORY_DOS` is a table; rerun file 01 to refresh it, or turn it into a dynamic table in production.
- **Attrition:** there is no exit date, so the rate is cumulative (exited / all employees on file).
- **Currencies:** finance amounts are in ledger currency per entity. HR salaries are mixed by location.
