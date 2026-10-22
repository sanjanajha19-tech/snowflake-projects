/* =============================================================================
   04 INGESTION FRAMEWORK | 05_snowpipe_and_task.sql
   - Snowpipe template on the internal stage (refreshed manually / via REST).
     AUTO_INGEST needs an external stage + cloud event notifications:
     see 06_external_stage_templates.sql.
   - Scheduled TASK that calls the framework (created SUSPENDED).
============================================================================= */

-- ACCOUNTADMIN only for this grant: resuming tasks needs the account-level EXECUTE TASK privilege.
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE ACCEL_ADMIN;

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS INGEST;
USE SCHEMA INGEST;

-- ---------------------------------------------------------------------------
-- 1. Snowpipe: continuous JSON loading with file lineage columns
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS RAW_ORDERS_PIPE (
  ORDER_ID      NUMBER,
  ORDER_DATE    DATE,
  CUSTOMER_ID   NUMBER,
  PLANT_ID      NUMBER,
  CHANNEL       VARCHAR,
  STATUS        VARCHAR,
  CURRENCY      VARCHAR,
  ORDER_TOTAL   NUMBER(14,2),
  _FILE_NAME    VARCHAR,
  _FILE_ROW     NUMBER,
  _LOADED_AT    TIMESTAMP_LTZ
);

CREATE OR REPLACE PIPE PIPE_ORDERS_JSON
  COMMENT = 'Loads JSON order files dropped in @LANDING/pipe/orders/'
AS
COPY INTO RAW_ORDERS_PIPE (ORDER_ID, ORDER_DATE, CUSTOMER_ID, PLANT_ID, CHANNEL, STATUS, CURRENCY,
                           ORDER_TOTAL, _FILE_NAME, _FILE_ROW, _LOADED_AT)
FROM (
  SELECT $1:ORDER_ID::NUMBER, $1:ORDER_DATE::DATE, $1:CUSTOMER_ID::NUMBER, $1:PLANT_ID::NUMBER,
         $1:CHANNEL::VARCHAR, $1:STATUS::VARCHAR, $1:CURRENCY::VARCHAR, $1:ORDER_TOTAL::NUMBER(14,2),
         METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME
  FROM @ACCEL_DB.INGEST.LANDING/pipe/orders/
)
FILE_FORMAT = (FORMAT_NAME = 'ACCEL_DB.INGEST.FF_JSON');

-- Demo: drop a file into the pipe folder, then ask the pipe to pick it up.
-- (Internal stages have no event notifications, so REFRESH queues files staged in the last 7 days.)
COPY INTO @LANDING/pipe/orders/batch_
  FROM (SELECT OBJECT_CONSTRUCT(*) FROM ACCEL_DB.DEMO.ORDERS WHERE ORDER_ID BETWEEN 5001 AND 6000)
  FILE_FORMAT = (TYPE = JSON COMPRESSION = GZIP)
  OVERWRITE = TRUE;

ALTER PIPE PIPE_ORDERS_JSON REFRESH;
SELECT SYSTEM$PIPE_STATUS('ACCEL_DB.INGEST.PIPE_ORDERS_JSON') AS PIPE_STATUS;

-- Wait ~1 minute, then:
-- SELECT COUNT(*), MIN(_LOADED_AT), MAX(_LOADED_AT) FROM ACCEL_DB.INGEST.RAW_ORDERS_PIPE;
-- SELECT * FROM TABLE(ACCEL_DB.INFORMATION_SCHEMA.COPY_HISTORY(
--   TABLE_NAME => 'ACCEL_DB.INGEST.RAW_ORDERS_PIPE', START_TIME => DATEADD('hour', -1, CURRENT_TIMESTAMP())));

-- Pause the pipe when the demo is over (no cost while paused):
-- ALTER PIPE ACCEL_DB.INGEST.PIPE_ORDERS_JSON SET PIPE_EXECUTION_PAUSED = TRUE;

-- ---------------------------------------------------------------------------
-- 2. Scheduled task: runs DAILY-labelled feeds at 02:00 UTC. Created SUSPENDED.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TASK TASK_DAILY_INGESTION
  WAREHOUSE = ACCEL_WH
  SCHEDULE = 'USING CRON 0 2 * * * UTC'     -- EDIT ME: schedule
  COMMENT = 'Runs ACCEL_DB.INGEST.RUN_INGESTION for SCHEDULE = DAILY feeds'
AS
  CALL ACCEL_DB.INGEST.RUN_INGESTION(NULL, 'DAILY');

-- Tasks are created suspended. To turn the schedule on:
-- ALTER TASK ACCEL_DB.INGEST.TASK_DAILY_INGESTION RESUME;
-- Run once now without resuming:
-- EXECUTE TASK ACCEL_DB.INGEST.TASK_DAILY_INGESTION;
-- History:
-- SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE
-- FROM TABLE(ACCEL_DB.INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'TASK_DAILY_INGESTION')) ORDER BY SCHEDULED_TIME DESC;

SHOW TASKS LIKE 'TASK_DAILY_INGESTION' IN SCHEMA ACCEL_DB.INGEST;
