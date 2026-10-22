# 05 · Lakehouse Blueprint (Bronze / Silver / Gold)

A medallion architecture on Snowflake built from Dynamic Tables. You declare the SQL and a freshness target; Snowflake orchestrates the refreshes, incrementally where it can. A matching dbt project is included for teams that standardise on dbt.

## What it does
| Layer | Schema | Objects | Purpose |
|---|---|---|---|
| Bronze | `ACCEL_DB.BRONZE` | `BRZ_*` (7 DTs, `TARGET_LAG = DOWNSTREAM`) | As-landed copy plus `_SOURCE_TABLE` lineage |
| Silver | `ACCEL_DB.SILVER` | `SLV_*` (7 DTs, `DOWNSTREAM`) | Dedupe on business keys (`QUALIFY ROW_NUMBER()`), trim and standardise values, explicit types, country codes, deterministic surrogate keys (`MD5(business key)`), DQ flags |
| Gold | `ACCEL_DB.GOLD` | `DIM_DATE` (table), `DIM_CUSTOMER`, `DIM_PRODUCT`, `DIM_PLANT`, `FACT_SALES`, `FACT_INVENTORY`, `FACT_GL` (DTs, `1 hour`) | Star schema |
| Gold aggregates | `ACCEL_DB.GOLD` | `AGG_MONTHLY_REVENUE_REGION_CATEGORY`, `AGG_MONTHLY_MARGIN`, `AGG_MONTHLY_PNL` | Dashboard-ready marts |
| Open format | `ACCEL_DB.GOLD` | `FACT_SALES_ICEBERG` (commented) | Snowflake-managed Apache Iceberg table on your external volume |
| dbt | `ACCEL_DB.DBT_LAKEHOUSE` | `dbt/` project: 4 models, sources, generic + singular tests | Same logic for dbt Projects on Snowflake |

Bronze reads `ACCEL_DB.DEMO`. To chain this blueprint after the ingestion framework (asset 04), point the bronze `FROM` clauses at `ACCEL_DB.INGEST.RAW_*`.

## Prerequisites
- `00_setup` (ACCEL_ADMIN, ACCEL_WH, ACCEL_DB.DEMO). ACCEL_ADMIN must own the DEMO tables, or have change tracking enabled on them, so that Dynamic Tables can track changes.
- Iceberg (optional): a cloud bucket, an IAM role/app registration, and ACCOUNTADMIN to create the external volume.
- dbt (optional): Snowflake Workspaces or Snowflake CLI with `snow dbt` commands.

## Run order
1. `01_bronze.sql`
2. `02_silver.sql`
3. `03_gold_star_schema.sql`
4. `04_gold_aggregates.sql` (also grants GOLD read to ACCEL_ANALYST / ACCEL_VIEWER)
5. `05_iceberg_example.sql` (optional, commented; fill the `-- EDIT ME` values)
6. `06_validate_and_operate.sql`: reconciliation, orphan checks, refresh history, suspend commands
7. `07_dbt_project_setup.sql` + `dbt/` (optional)

All files run as ACCEL_ADMIN on ACCEL_WH. Each DT does its initial refresh at creation, so files 1–4 take a few minutes on XSMALL.

## 5-step demo script
1. Open the Snowsight DT graph (Monitoring » Dynamic Tables, or any gold DT » Graph). Bronze → silver → gold lineage is generated from SQL alone, with no orchestration code.
2. Run `06_validate_and_operate.sql`: row counts reconcile layer by layer, `NET_AMOUNT` ties out, and there are zero orphan facts.
3. Show `SLV_CUSTOMERS`: standardised values, `COUNTRY_CODE`, `DQ_EMAIL_VALID`, stable `CUSTOMER_SK`.
4. Query `AGG_MONTHLY_REVENUE_REGION_CATEGORY` and `AGG_MONTHLY_PNL` as the BI-ready layer. Change a value in a demo table, run `ALTER DYNAMIC TABLE … REFRESH` on the aggregate, and watch it flow through.
5. Show the `dbt/` project: the same logic as models + tests, deployable with `snow dbt deploy` and runnable with `EXECUTE DBT PROJECT`. Close with Iceberg: the gold data can live in open format readable by Spark/Trino.

## Client value
"A governed lakehouse in a day, not a quarter." Declarative pipelines replace hand-built ELT orchestration (often 30–50% less pipeline code and ops effort). Freshness SLAs are a single `TARGET_LAG` setting. Iceberg keeps gold data open to other engines, which avoids lock-in.

## Notes
- `TARGET_LAG = DOWNSTREAM` on bronze/silver means they only refresh when a gold table needs them. Change the gold lag (`'1 hour'`) to match your SLA.
- DTs use `REFRESH_MODE = AUTO`. Snowflake picks incremental refresh where the query supports it and full refresh otherwise. Check `refresh_mode` in `SHOW DYNAMIC TABLES`.
- Amounts are in transaction currency. Add an FX rate table and convert in silver for group reporting.
- If the governance kit (asset 07) masks DEMO columns, DTs refresh as their owner (ACCEL_ADMIN, which sees clear values). Re-apply tags/masking to gold columns, or use tag propagation, so gold consumers stay protected.
- Suspend the DTs after a demo (commands in file 06) to avoid hourly refresh checks.
