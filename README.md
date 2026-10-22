# Snowflake Assets & Accelerators

29 paste-ready accelerators for building a Snowflake practice. Each folder holds numbered SQL scripts, a `README.md` (purpose, run order, 5-step demo script, client value), and Streamlit apps where relevant. All objects live in one database, `ACCEL_DB`, and use shared synthetic demo data, so nothing touches client data.

## How to run
1. **Run setup first.** Open `00_setup/01_account_setup.sql` in a Snowsight worksheet, set the `-- EDIT ME` values, run it as ACCOUNTADMIN. Then run `00_setup/02_demo_data.sql`.
2. **Pick any accelerator.** Run its `.sql` files in number order (01, 02, 03...). Each file sets its own role, warehouse and schema.
3. **Streamlit apps.** In Snowsight: Projects → Streamlit → + Streamlit App → choose `ACCEL_DB`, the asset's schema and `ACCEL_WH` → paste `streamlit_app.py` → Run. Add packages (e.g. `plotly`) from the Packages menu if the app imports them.
4. **Search for `-- EDIT ME`** before running: emails, account names, credit price, model names, budgets.
5. **Clean up** with `00_setup/99_teardown.sql`.

Read `CONVENTIONS.md` for names of roles, warehouses, schemas and demo tables.

## Before a client demo
- Scripts were written against current Snowflake documentation but not yet run on a live account. Run each one end to end on the build account once and fix any small errors before showing it.
- Cortex AI features depend on region and model availability. If a model is unavailable, change the `-- EDIT ME` model name or enable cross-region inference (see `00_setup/01_account_setup.sql`).
- Some features need a higher edition: failover (19) needs Business Critical.
- Emission factors (26), GST rules (27) and privacy logic (18) are illustrative placeholders, not authoritative values or legal advice.

## Index
| # | Accelerator | Pillar | Streamlit app |
|---|---|---|---|
| 00 | Account setup, demo data, teardown | Setup | |
| 01 | Migration Assessment | Migrate & Modernize | Yes |
| 02 | Code Conversion Kit | Migrate & Modernize | |
| 03 | Data Validation Framework | Migrate & Modernize | Yes |
| 04 | Ingestion Framework (metadata-driven) | Data Platform | |
| 05 | Lakehouse Blueprint (Bronze/Silver/Gold, dbt, Iceberg) | Data Platform | |
| 06 | Platform in a Day (Terraform, CI/CD, DEV/TEST/PROD) | Data Platform | |
| 07 | Governance Kit (RBAC, tags, masking, row access, DQ) | Governance & FinOps | |
| 08 | FinOps Cost Optimizer | Governance & FinOps | Yes |
| 09 | AI Governance Controls | Governance & FinOps | |
| 10 | Talk to Your Data Agent (semantic view + Cortex Agent) | AI & Agents | Yes |
| 11 | Semantic KPI Library (finance, supply chain, HR, service) | AI & Agents | |
| 12 | Document Intelligence (invoices, contracts) | AI & Agents | |
| 13 | Enterprise Knowledge Assistant (RAG) | AI & Agents | Yes |
| 14 | Forecasting & ML Starter | AI & Agents | |
| 15 | Data Sharing & Lightweight Clean Room | Data Products | |
| 16 | Native App Template ("Data Health Checker") | Data Products | In app |
| 17 | Data Observability | Governance & FinOps | Yes |
| 18 | DPDP Privacy Kit | Industry solution | |
| 19 | BCDR: Replication & Failover | Data Platform | |
| 20 | SAP Finance Accelerator | Industry solution | |
| 21 | Journal Entry Analytics | Industry solution | Yes |
| 22 | Fraud & Anomaly Detection | Industry solution | Yes |
| 23 | Customer 360 & Entity Resolution | Industry solution | Yes |
| 24 | Voice of Customer | Industry solution | Yes |
| 25 | Supply Chain Control Tower | Industry solution | Yes |
| 26 | ESG & Sustainability Hub | Industry solution | Yes |
| 27 | GST Tax Data Hub | Industry solution | Yes |
| 28 | Security Health Check | Governance & FinOps | |
| 29 | AI SQL Playbook | AI & Agents | |

## Suggested first demos
- **Any company already on Snowflake:** 08 FinOps → 28 Security Health Check → 10 Talk to Your Data.
- **Company on a legacy warehouse:** 01 Migration Assessment → 03 Validation → 05 Lakehouse.
- **Business audience:** 10 Agent → 24 Voice of Customer → 25 Control Tower or 21 Journal Entry Analytics.
