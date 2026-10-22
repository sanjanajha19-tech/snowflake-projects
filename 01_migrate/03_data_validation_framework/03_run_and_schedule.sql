/*=============================================================================
  DATA VALIDATION FRAMEWORK 03 - Run, inspect, schedule
  Runs all active pairs, shows the summary, exceptions and row diffs, and
  creates a nightly TASK (created SUSPENDED - resume it when ready).
  Run as : ACCEL_ADMIN (EXECUTE TASK granted in 00_setup). Rerun: safe.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS VALIDATION;
USE SCHEMA VALIDATION;

------------------------------------------------------------------------------
-- 1. Run (all active pairs; failed pairs get an automatic row diff)
------------------------------------------------------------------------------
CALL SP_RUN_VALIDATION();
-- One pair without row diff:   CALL SP_RUN_VALIDATION(2, FALSE);
-- Row diff on demand:          CALL SP_ROW_DIFF('<run_id>', 1, 50);

------------------------------------------------------------------------------
-- 2. Inspect
------------------------------------------------------------------------------
-- Pair status (latest run per pair)
SELECT PAIR_ID, PAIR_NAME, STATUS, SOURCE_ROWS, TARGET_ROWS, ROW_VARIANCE,
       CHECKS_RUN, CHECKS_FAILED, CHECKS_WARNED, SIGNOFF_DECISION
FROM V_LATEST_PAIR_STATUS ORDER BY PAIR_ID;

-- What failed, and by how much
SELECT PAIR_NAME, CHECK_TYPE, COLUMN_NAME, SOURCE_VALUE, TARGET_VALUE, VARIANCE, ROUND(VARIANCE_PCT, 6) AS VARIANCE_PCT, STATUS
FROM V_LATEST_EXCEPTIONS
ORDER BY PAIR_ID, CHECK_TYPE, COLUMN_NAME;

-- Example rows behind the failures
SELECT d.PAIR_ID, d.DIFF_TYPE, d.KEY_VALUES, d.DIFF_COLUMNS, d.SOURCE_ROW, d.TARGET_ROW
FROM VALIDATION_ROW_DIFFS d
JOIN V_LATEST_PAIR_STATUS l ON l.PAIR_ID = d.PAIR_ID AND l.RUN_ID = d.RUN_ID
ORDER BY d.PAIR_ID, d.DIFF_TYPE;

-- Run history
SELECT * FROM V_VALIDATION_SUMMARY ORDER BY RUN_TS DESC LIMIT 10;

------------------------------------------------------------------------------
-- 3. Sign-off (normally done from the Streamlit app)
------------------------------------------------------------------------------
-- INSERT INTO VALIDATION_SIGNOFF (PAIR_ID, RUN_ID, DECISION, SIGNED_BY, COMMENTS)
-- SELECT PAIR_ID, RUN_ID, 'APPROVED', CURRENT_USER(), 'Counts and checksums match'
-- FROM V_LATEST_PAIR_STATUS WHERE PAIR_ID = 3;

------------------------------------------------------------------------------
-- 4. Nightly schedule - created SUSPENDED
------------------------------------------------------------------------------
CREATE OR REPLACE TASK TSK_NIGHTLY_VALIDATION
  WAREHOUSE = ACCEL_WH
  SCHEDULE = 'USING CRON 0 2 * * * UTC'          -- EDIT ME: 02:00 UTC daily
  COMMENT = 'Nightly source-vs-target validation of all active pairs'
AS
  CALL ACCEL_DB.VALIDATION.SP_RUN_VALIDATION(NULL, TRUE);

-- ALTER TASK TSK_NIGHTLY_VALIDATION RESUME;    -- start the schedule
-- EXECUTE TASK TSK_NIGHTLY_VALIDATION;         -- one-off run now
-- ALTER TASK TSK_NIGHTLY_VALIDATION SUSPEND;
SHOW TASKS LIKE 'TSK_NIGHTLY_VALIDATION' IN SCHEMA VALIDATION;
