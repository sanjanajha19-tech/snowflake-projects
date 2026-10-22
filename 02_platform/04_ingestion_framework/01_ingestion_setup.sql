/* =============================================================================
   04 INGESTION FRAMEWORK | 01_ingestion_setup.sql
   Creates the INGEST schema, file formats, internal landing stage,
   the metadata config table and the audit log table.
   Run as: ACCEL_ADMIN. Idempotent.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS INGEST;
USE SCHEMA INGEST;

-- ---------------------------------------------------------------------------
-- 1. File formats
--    CSV uses PARSE_HEADER so INFER_SCHEMA can read column names and COPY can
--    load with MATCH_BY_COLUMN_NAME (same load path for CSV, JSON and PARQUET).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT FF_CSV
  TYPE = CSV
  PARSE_HEADER = TRUE
  FIELD_DELIMITER = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE
  EMPTY_FIELD_AS_NULL = TRUE
  NULL_IF = ('', 'NULL', '\\N')
  COMPRESSION = AUTO
  COMMENT = 'Accelerator CSV format (header row parsed for column names)';

CREATE OR REPLACE FILE FORMAT FF_JSON
  TYPE = JSON
  STRIP_OUTER_ARRAY = TRUE
  COMPRESSION = AUTO
  COMMENT = 'Accelerator JSON format (array or newline-delimited)';

CREATE OR REPLACE FILE FORMAT FF_PARQUET
  TYPE = PARQUET
  COMPRESSION = AUTO
  COMMENT = 'Accelerator Parquet format';

-- ---------------------------------------------------------------------------
-- 2. Internal landing stage (folders: demo/, upload/, pipe/, api/)
--    External stage templates for S3 / Azure / GCS: see 06_external_stage_templates.sql
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS LANDING
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Internal landing zone for the ingestion framework';

-- ---------------------------------------------------------------------------
-- 3. Config table: one row per source feed
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS INGESTION_CONFIG (
  CONFIG_ID         NUMBER AUTOINCREMENT START 1 INCREMENT 1,
  SOURCE_NAME       VARCHAR NOT NULL,          -- unique business name of the feed
  SOURCE_TYPE       VARCHAR NOT NULL,          -- FILE | API | TABLE
  STAGE_PATH        VARCHAR,                   -- FILE/API: '@DB.SCHEMA.STAGE/folder/'
  FILE_PATTERN      VARCHAR,                   -- optional regex, e.g. '.*[.]csv'
  FILE_FORMAT       VARCHAR,                   -- FILE/API: fully qualified named file format
  SOURCE_OBJECT     VARCHAR,                   -- TABLE: fully qualified source table/view
  TARGET_TABLE      VARCHAR NOT NULL,          -- fully qualified DB.SCHEMA.TABLE
  LOAD_MODE         VARCHAR NOT NULL,          -- APPEND | MERGE | TRUNCATE_INSERT
  MERGE_KEYS        VARCHAR,                   -- comma-separated key columns for MERGE
  DEDUPE_ORDER_BY   VARCHAR,                   -- optional, e.g. 'UPDATED_AT DESC' (latest row wins)
  ON_ERROR          VARCHAR DEFAULT 'CONTINUE',-- CONTINUE | SKIP_FILE | ABORT_STATEMENT
  SCHEDULE          VARCHAR DEFAULT 'DAILY',   -- free label used by tasks: DAILY | HOURLY | ADHOC
  ACTIVE_FLAG       BOOLEAN DEFAULT TRUE,
  OWNER_EMAIL       VARCHAR,
  DESCRIPTION       VARCHAR,
  CREATED_AT        TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  UPDATED_AT        TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT PK_INGESTION_CONFIG PRIMARY KEY (SOURCE_NAME)
);

-- ---------------------------------------------------------------------------
-- 4. Audit log: one row per config per run, populated from COPY / MERGE results
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS INGESTION_AUDIT_LOG (
  RUN_ID            VARCHAR,
  CONFIG_ID         NUMBER,
  SOURCE_NAME       VARCHAR,
  SOURCE_TYPE       VARCHAR,
  LOAD_MODE         VARCHAR,
  TARGET_TABLE      VARCHAR,
  STATUS            VARCHAR,       -- SUCCESS | PARTIAL | NO_FILES | FAILED | SKIPPED
  TABLE_CREATED     BOOLEAN,       -- TRUE when the target was auto-created via INFER_SCHEMA / LIKE
  FILES_PROCESSED   NUMBER,
  ROWS_PARSED       NUMBER,
  ROWS_LOADED       NUMBER,        -- rows COPY-ed (or selected from the source table)
  ROWS_INSERTED     NUMBER,
  ROWS_UPDATED      NUMBER,
  ERRORS_SEEN       NUMBER,
  FIRST_ERROR       VARCHAR,
  START_TS          TIMESTAMP_LTZ,
  END_TS            TIMESTAMP_LTZ,
  DURATION_SEC      NUMBER(10,2),
  QUERY_ID          VARCHAR,
  RUN_BY            VARCHAR DEFAULT CURRENT_USER()
);

-- Convenience view: latest run per source
CREATE OR REPLACE VIEW V_INGESTION_LATEST AS
SELECT *
FROM INGESTION_AUDIT_LOG
QUALIFY ROW_NUMBER() OVER (PARTITION BY SOURCE_NAME ORDER BY START_TS DESC) = 1;

GRANT USAGE ON SCHEMA ACCEL_DB.INGEST TO ROLE ACCEL_DEVELOPER;
GRANT SELECT ON ALL TABLES IN SCHEMA ACCEL_DB.INGEST TO ROLE ACCEL_DEVELOPER;
GRANT SELECT ON ALL VIEWS IN SCHEMA ACCEL_DB.INGEST TO ROLE ACCEL_DEVELOPER;

SHOW FILE FORMATS IN SCHEMA ACCEL_DB.INGEST;
