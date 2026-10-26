/* =============================================================================
   17 DATA OBSERVABILITY | 01_monitor_config.sql
   MONITOR_CONFIG : which ACCEL_DB tables are watched, with thresholds for
                    freshness (minutes since last change), volume (minimum rows,
                    max % row-count change between snapshots) and schema change.
   OBS_SETTINGS   : notification settings (e-mail recipients, integration name).
   Seeds every base table in ACCEL_DB.DEMO. Rerunning keeps your edits (MERGE
   only inserts tables that are not configured yet).
   Run as: ACCEL_ADMIN.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS OBSERVABILITY;
USE SCHEMA OBSERVABILITY;

CREATE TABLE IF NOT EXISTS MONITOR_CONFIG (
  SCHEMA_NAME            VARCHAR,        -- schema in ACCEL_DB (upper case)
  TABLE_NAME             VARCHAR,        -- table name (upper case)
  FRESHNESS_SLA_MINUTES  NUMBER,         -- incident if not modified for longer than this; NULL = no freshness check
  MIN_ROWS               NUMBER,         -- incident if ROW_COUNT below this; NULL = no check
  MAX_ROW_CHANGE_PCT     NUMBER(10,2),   -- incident if row count moves more than this % between two snapshots; NULL = no check
  CHECK_SCHEMA           BOOLEAN,        -- incident when columns / data types change
  SEVERITY               VARCHAR,        -- CRITICAL | HIGH | MEDIUM | LOW (used for freshness / volume)
  OWNER                  VARCHAR,
  ENABLED                BOOLEAN,
  UPDATED_AT             TIMESTAMP_LTZ
);

-- Seed: every base table in ACCEL_DB.DEMO.
-- The demo data is static, so freshness is set to 7 days here.   -- EDIT ME per table
MERGE INTO MONITOR_CONFIG t
USING (
  SELECT TABLE_SCHEMA AS SCHEMA_NAME, TABLE_NAME, ROW_COUNT
  FROM ACCEL_DB.INFORMATION_SCHEMA.TABLES
  WHERE TABLE_SCHEMA = 'DEMO' AND TABLE_TYPE = 'BASE TABLE'
) s
ON t.SCHEMA_NAME = s.SCHEMA_NAME AND t.TABLE_NAME = s.TABLE_NAME
WHEN NOT MATCHED THEN INSERT
  (SCHEMA_NAME, TABLE_NAME, FRESHNESS_SLA_MINUTES, MIN_ROWS, MAX_ROW_CHANGE_PCT, CHECK_SCHEMA, SEVERITY, OWNER, ENABLED, UPDATED_AT)
VALUES
  (s.SCHEMA_NAME, s.TABLE_NAME, 10080,
   GREATEST(1, FLOOR(COALESCE(s.ROW_COUNT, 0) * 0.5)),   -- alert if the table loses half its rows
   25, TRUE,
   IFF(s.TABLE_NAME IN ('ORDERS', 'ORDER_LINES', 'GL_JOURNAL'), 'HIGH', 'MEDIUM'),
   'data-platform-team', TRUE, CURRENT_TIMESTAMP());

-- Tighter SLAs for the business-critical tables                   -- EDIT ME
UPDATE MONITOR_CONFIG
   SET MAX_ROW_CHANGE_PCT = 10, UPDATED_AT = CURRENT_TIMESTAMP()
 WHERE SCHEMA_NAME = 'DEMO' AND TABLE_NAME IN ('ORDERS', 'GL_JOURNAL') AND MAX_ROW_CHANGE_PCT = 25;

-- To monitor another table in ACCEL_DB:
-- INSERT INTO MONITOR_CONFIG VALUES ('GOLD', 'FCT_SALES', 60*26, 1000, 20, TRUE, 'HIGH', 'sales-data-team', TRUE, CURRENT_TIMESTAMP());

CREATE TABLE IF NOT EXISTS OBS_SETTINGS (
  SETTING_NAME  VARCHAR,
  SETTING_VALUE VARCHAR,
  NOTE          VARCHAR
);
MERGE INTO OBS_SETTINGS t
USING (
  SELECT * FROM VALUES
  ('EMAIL_RECIPIENTS',         'data-team@example.com', 'Comma-separated. Must be verified e-mail addresses of users in this account.'),  -- EDIT ME
  ('NOTIFICATION_INTEGRATION', 'ACCEL_OBS_EMAIL_INT',   'Created in 03_notifications_and_alert.sql'),
  ('EMAIL_SUBJECT_PREFIX',     '[ACCEL Data Observability]', 'Prefix for alert e-mails')
  AS s(SETTING_NAME, SETTING_VALUE, NOTE)
) s
ON t.SETTING_NAME = s.SETTING_NAME
WHEN NOT MATCHED THEN INSERT VALUES (s.SETTING_NAME, s.SETTING_VALUE, s.NOTE);

-- After the first run, change recipients with:                    -- EDIT ME
-- UPDATE OBS_SETTINGS SET SETTING_VALUE = 'you@yourcompany.com' WHERE SETTING_NAME = 'EMAIL_RECIPIENTS';

GRANT USAGE ON SCHEMA ACCEL_DB.OBSERVABILITY TO ROLE ACCEL_ANALYST;
GRANT SELECT ON TABLE MONITOR_CONFIG TO ROLE ACCEL_ANALYST;

SELECT * FROM MONITOR_CONFIG ORDER BY SCHEMA_NAME, TABLE_NAME;
SELECT * FROM OBS_SETTINGS;
