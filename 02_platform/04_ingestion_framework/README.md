# 04 · Ingestion Framework (metadata-driven)

One config table, one generic procedure, one audit log. New feeds are onboarded by inserting a row, not by writing code.

## What it does
- **Config table** `ACCEL_DB.INGEST.INGESTION_CONFIG`: source name, type (`FILE` / `API` / `TABLE`), stage path, file pattern, file format, source object, target table, load mode (`APPEND` / `MERGE` / `TRUNCATE_INSERT`), merge keys, dedupe order, `ON_ERROR`, schedule label, active flag, owner.
- **File formats** `FF_CSV` (header parsed), `FF_JSON`, `FF_PARQUET`. **Internal stage** `LANDING`, plus commented S3 / Azure / GCS storage-integration, external-stage and auto-ingest Snowpipe templates.
- **Generic procedure** `RUN_INGESTION(source_name, schedule)` (Python, caller's rights). It loops over the active configs and:
  - **FILE/API**: lists the stage path. If the target table doesn't exist, it creates it from the files with `INFER_SCHEMA` + `CREATE TABLE … USING TEMPLATE`. Then it runs `COPY INTO … MATCH_BY_COLUMN_NAME`. `APPEND` loads straight into the target. `MERGE` and `TRUNCATE_INSERT` load into a temporary staging table first, then run a deduplicated `MERGE` or an atomic `INSERT OVERWRITE`.
  - **TABLE**: creates the target with `CREATE TABLE … LIKE` when it is missing, then runs `INSERT`, `MERGE` or `INSERT OVERWRITE`.
  - Writes one audit row per feed with status, files, rows parsed/loaded/inserted/updated, errors, first error, duration and query ID. It reads these from the COPY/MERGE result sets.
- **Snowpipe** `PIPE_ORDERS_JSON`, with lineage columns (`METADATA$FILENAME`, row number, scan time). The `AUTO_INGEST` variants for external stages are in the templates file.
- **Task** `TASK_DAILY_INGESTION` (CRON 02:00 UTC, created **suspended**).
- **Demo without uploads**: `04_demo_seed_and_run.sql` unloads `ACCEL_DB.DEMO` tables to the stage as CSV, JSON and Parquet, so every load path runs on a fresh account. `sample_data/` holds a customer delta CSV (5 updates + 5 inserts) and a JSON order feed that has an extra column (auto table creation).

## Prerequisites
- `00_setup` has been run (ACCEL_ADMIN, ACCEL_WH, ACCEL_DB, DEMO data).
- `05_snowpipe_and_task.sql` uses ACCOUNTADMIN once to `GRANT EXECUTE TASK ON ACCOUNT TO ROLE ACCEL_ADMIN`. This is needed to resume tasks.
- External stages need ACCOUNTADMIN, or a role with `CREATE INTEGRATION`, to create storage/notification integrations.

## Run order
| # | File | Role |
|---|---|---|
| 1 | `01_ingestion_setup.sql` – schema, formats, stage, config + audit tables | ACCEL_ADMIN |
| 2 | `02_ingestion_config.sql` – seeds 8 feeds | ACCEL_ADMIN |
| 3 | `03_ingestion_procedure.sql` – `RUN_INGESTION` | ACCEL_ADMIN |
| 4 | `04_demo_seed_and_run.sql` – generates files, runs everything, shows audit | ACCEL_ADMIN |
| 5 | `05_snowpipe_and_task.sql` – pipe + suspended task | ACCOUNTADMIN (1 grant), ACCEL_ADMIN |
| 6 | `06_external_stage_templates.sql` – commented cloud templates | ACCOUNTADMIN for integrations |

Upload instructions for `sample_data/` (Snowsight UI, `snow stage copy`, or `PUT`) are at the bottom of file 04.

## 5-step demo script
1. Show `INGESTION_CONFIG`: "every feed is a row: type, path, format, target, load mode, keys, schedule."
2. Run `04_demo_seed_and_run.sql`. `RAW_CUSTOMERS`, `RAW_ORDERS` and `RAW_PRODUCTS` did not exist; they were **created from the files** (CSV/JSON/Parquet) by INFER_SCHEMA.
3. Query `INGESTION_AUDIT_LOG`: rows parsed/loaded, inserts vs updates, errors, duration, query ID.
4. Rerun `CALL RUN_INGESTION()`. APPEND feeds return `NO_FILES` because COPY load metadata prevents double loading. MERGE feeds update in place.
5. Upload `sample_data/customers_delta.csv` and run `CALL RUN_INGESTION('UPLOAD_CUSTOMERS_DELTA_CSV')`: 5 updated + 5 inserted. Then insert a new config row live to onboard a feed without code.

## Client value
"Onboard a new source in minutes with a config row instead of a pipeline build." One audited loader replaces dozens of hand-written COPY scripts. Every load is traceable (rows, errors, duration, query ID), and teams typically cut ingestion build effort by 60–80% for file and table feeds.

## Notes and limits
- `MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE` means file headers/keys must match target column names. Extra file columns are ignored, and missing ones load as NULL.
- INFER_SCHEMA sizes NUMBER/VARCHAR columns from the sample files. Widen columns (`ALTER TABLE … ALTER COLUMN … SET DATA TYPE`) if later files carry larger values.
- `TRUNCATE_INSERT` and `MERGE` reload every file in the path each run (`FORCE = TRUE` into staging). Archive processed files, or use date-partitioned paths, for large feeds.
- `API` feeds are loaded exactly like `FILE` feeds from the stage path where the extractor lands JSON. The extractor can be Openflow, a Snowpark function with External Access, or a partner tool.

## Alternatives: Openflow and zero-copy connectors
- **Snowflake Openflow** is a managed integration service based on Apache NiFi. It runs either in your cloud (BYOC) or on Snowpark Container Services. It ships prebuilt connectors (databases with CDC, SaaS apps, Kafka, SharePoint/Google Drive for unstructured files) and a visual flow designer. Use it for CDC from operational databases, SaaS APIs, and unstructured documents feeding Cortex. It can land into the same `RAW_*` tables or stages this framework reads. Set it up from Snowsight (Data » Ingestion » Openflow) following the current Snowflake docs.
- **Zero-copy / bidirectional connectors for SAP, Salesforce and Workday** share data without copying it through pipelines:
  - **SAP**: SAP Business Data Cloud Connect for Snowflake shares SAP data products zero-copy.
  - **Salesforce**: Data Cloud and Snowflake sharing works in both directions.
  - **Workday**: Workday data is shared into Snowflake through Snowflake's data sharing.

  Availability, editions and setup steps vary by vendor contract and region. Configure them from the vendor side and Snowflake listings/shares, as documented by each vendor. No custom SQL is needed in this framework. Once shared, register the shared database in `INGESTION_CONFIG` as `TABLE` feeds to materialize curated copies, or reference it directly from the lakehouse.
- **Snowpipe Streaming** is for row-level, low-latency events (Kafka connector or SDK) where files are the wrong unit.
