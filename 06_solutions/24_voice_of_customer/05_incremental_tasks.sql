/* =============================================================================
   Asset 24 - Voice of Customer (VoC) analytics
   File  05_incremental_tasks.sql
   Purpose
     Incremental processing of NEW tickets with a Stream + Tasks:
       VOC.NEW_TICKETS_STREAM      append-only stream on DEMO.SUPPORT_TICKETS
       VOC.PROCESS_NEW_TICKETS(n)  consumes the stream into VOC.TICKET_INTAKE
                                   (audit of arrivals), then enriches up to n
                                   unprocessed tickets via VOC.ENRICH_TICKETS
       VOC.ENRICH_NEW_TICKETS_TASK hourly, runs ONLY when the stream has data
                                   (no warehouse start, no cost otherwise)
       VOC.WEEKLY_THEMES_TASK      Mondays -> weekly summaries + top issues
     ENRICH_TICKETS anti-joins against TICKET_ENRICHED, so each ticket is sent
     to the AI functions exactly once, even if a run is repeated.
     Why not a dynamic table: a full refresh could recompute rows and re-run
     AI functions on unchanged tickets, which costs money.
     NOTE: rerunning 00_setup recreates DEMO.SUPPORT_TICKETS, which makes the
     stream stale - just rerun this file afterwards.
   Prerequisite: ACCEL_ADMIN has EXECUTE TASK (granted by 00_setup).
   Run as  ACCEL_ADMIN after 02-04. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS VOC;
USE SCHEMA VOC;

-- Suspend existing tasks first so CREATE OR REPLACE on a rerun is clean.
ALTER TASK IF EXISTS VOC.ENRICH_NEW_TICKETS_TASK SUSPEND;
ALTER TASK IF EXISTS VOC.WEEKLY_THEMES_TASK SUSPEND;

-- 1. Stream: captures tickets inserted after this point. Existing tickets are
--    the backlog, handled by ENRICH_TICKETS' anti-join (see 02). Replacing the
--    stream on rerun is safe for the same reason.
CREATE OR REPLACE STREAM VOC.NEW_TICKETS_STREAM
  ON TABLE ACCEL_DB.DEMO.SUPPORT_TICKETS
  APPEND_ONLY = TRUE
  COMMENT = 'New support tickets awaiting AI enrichment';

CREATE TABLE IF NOT EXISTS VOC.TICKET_INTAKE (
    TICKET_ID   NUMBER,
    CREATED_AT  TIMESTAMP_NTZ,
    ARRIVED_AT  TIMESTAMP_NTZ
);

-- 2. Procedure the task calls
CREATE OR REPLACE PROCEDURE VOC.PROCESS_NEW_TICKETS(MAX_PER_RUN INTEGER)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    arrived INTEGER DEFAULT 0;
    res_msg VARCHAR;
BEGIN
    -- Reading the stream inside DML advances its offset (consumes it).
    INSERT INTO ACCEL_DB.VOC.TICKET_INTAKE (TICKET_ID, CREATED_AT, ARRIVED_AT)
    SELECT TICKET_ID, CREATED_AT, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    FROM ACCEL_DB.VOC.NEW_TICKETS_STREAM
    WHERE METADATA$ACTION = 'INSERT';
    arrived := SQLROWCOUNT;

    CALL ACCEL_DB.VOC.ENRICH_TICKETS(:MAX_PER_RUN) INTO :res_msg;
    RETURN arrived || ' new tickets arrived; ' || res_msg;
END;
$$;

-- 3. Hourly enrichment task, skipped when nothing new has arrived
CREATE OR REPLACE TASK VOC.ENRICH_NEW_TICKETS_TASK
  WAREHOUSE = ACCEL_WH
  SCHEDULE = 'USING CRON 7 * * * * UTC'                          -- EDIT ME: hourly at :07
  COMMENT = 'Enrich up to 200 new support tickets per run with Cortex AI functions'
  WHEN SYSTEM$STREAM_HAS_DATA('ACCEL_DB.VOC.NEW_TICKETS_STREAM')
AS
  CALL ACCEL_DB.VOC.PROCESS_NEW_TICKETS(200);                    -- EDIT ME: cap on AI spend per run

-- 4. Weekly insights task
CREATE OR REPLACE PROCEDURE VOC.REFRESH_WEEKLY_INSIGHTS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    r1 VARCHAR;
    r2 VARCHAR;
BEGIN
    CALL ACCEL_DB.VOC.BUILD_WEEKLY_THEMES(2) INTO :r1;
    CALL ACCEL_DB.VOC.BUILD_TOPIC_ISSUES(90) INTO :r2;
    RETURN r1 || ' | ' || r2;
END;
$$;

CREATE OR REPLACE TASK VOC.WEEKLY_THEMES_TASK
  WAREHOUSE = ACCEL_WH
  SCHEDULE = 'USING CRON 30 6 * * 1 Asia/Kolkata'                -- EDIT ME: Mondays 06:30 IST
  COMMENT = 'Rebuild the last 2 weeks of AI theme summaries and the 90-day top issues'
AS
  CALL ACCEL_DB.VOC.REFRESH_WEEKLY_INSIGHTS();

ALTER TASK VOC.ENRICH_NEW_TICKETS_TASK RESUME;
ALTER TASK VOC.WEEKLY_THEMES_TASK RESUME;

-- 5. Demo: simulate a new ticket arriving, then run the task now.
--    (Uncomment both statements.)
-- INSERT INTO ACCEL_DB.DEMO.SUPPORT_TICKETS
--   (TICKET_ID, CREATED_AT, CUSTOMER_ID, PRODUCT_ID, CHANNEL, SUBJECT, BODY, PRIORITY, STATUS, RESOLVED_AT)
-- SELECT MAX(TICKET_ID) + 1, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 42, 7, 'Email',
--        'Third late delivery this month',
--        'Our order was promised for Monday and has still not arrived. Tracking has not updated in four days. '
--        || 'This is the third time this month and our production line is waiting. Please escalate.',
--        'High', 'Open', NULL
-- FROM ACCEL_DB.DEMO.SUPPORT_TICKETS;
-- EXECUTE TASK VOC.ENRICH_NEW_TICKETS_TASK;

-- To drain the initial backlog without waiting for new tickets:
-- CALL VOC.ENRICH_TICKETS(1000);

-- Monitor
SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, RETURN_VALUE, ERROR_MESSAGE
FROM TABLE(ACCEL_DB.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP())))
WHERE DATABASE_NAME = 'ACCEL_DB' AND SCHEMA_NAME = 'VOC'
ORDER BY SCHEDULED_TIME DESC
LIMIT 20;

SELECT * FROM VOC.PROCESSING_LOG ORDER BY RUN_AT DESC LIMIT 20;

-- To stop the scheduled processing (e.g. after the demo):
-- ALTER TASK VOC.ENRICH_NEW_TICKETS_TASK SUSPEND;
-- ALTER TASK VOC.WEEKLY_THEMES_TASK SUSPEND;
