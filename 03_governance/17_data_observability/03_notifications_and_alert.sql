/* =============================================================================
   17 DATA OBSERVABILITY | 03_notifications_and_alert.sql
   ACCEL_OBS_EMAIL_INT    : e-mail notification integration
   NOTIFICATION_LOG       : every e-mail attempt (sent / failed)
   NOTIFY_NEW_INCIDENTS() : e-mails all OPEN incidents not yet notified
                            (SYSTEM$SEND_EMAIL) and stamps NOTIFIED_AT
   OBS_NEW_INCIDENT_ALERT : ALERT that fires when un-notified incidents exist.
                            Created SUSPENDED (Snowflake default); resume it after
                            setting recipients.
   E-mail rules: recipients must be users of THIS account who have verified their
   e-mail address (Snowsight > profile > verify). ALLOWED_RECIPIENTS is optional;
   without it any verified address in the account can receive mail.
   Run as: ACCEL_ADMIN (has CREATE INTEGRATION and EXECUTE ALERT from 00_setup).
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS OBSERVABILITY;
USE SCHEMA OBSERVABILITY;

-- 1. Recipients: verified e-mail address(es) of users in this account, comma-separated
UPDATE OBS_SETTINGS SET SETTING_VALUE = 'data-team@example.com'      -- EDIT ME
 WHERE SETTING_NAME = 'EMAIL_RECIPIENTS';

-- 2. Notification integration
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS ACCEL_OBS_EMAIL_INT
  TYPE = EMAIL
  ENABLED = TRUE
  -- Optional hard restriction of who can receive mail through this integration:
  -- ALLOWED_RECIPIENTS = ('data-team@yourcompany.com', 'oncall@yourcompany.com')   -- EDIT ME
  COMMENT = 'ACCEL data observability incident e-mails';

-- 3. Notification log + sender
CREATE TABLE IF NOT EXISTS NOTIFICATION_LOG (
  SENT_AT      TIMESTAMP_LTZ,
  RECIPIENTS   VARCHAR,
  SUBJECT      VARCHAR,
  INCIDENTS    NUMBER,
  STATUS       VARCHAR,     -- SENT | FAILED
  ERROR        VARCHAR
);

CREATE OR REPLACE PROCEDURE NOTIFY_NEW_INCIDENTS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  ts          TIMESTAMP_LTZ;
  n           INTEGER DEFAULT 0;
  n_crit      INTEGER DEFAULT 0;
  recipients  VARCHAR;
  integ       VARCHAR;
  prefix      VARCHAR;
  subj        VARCHAR;
  body        VARCHAR;
BEGIN
  ts := CURRENT_TIMESTAMP();
  SELECT MAX(IFF(SETTING_NAME = 'EMAIL_RECIPIENTS', SETTING_VALUE, NULL)),
         MAX(IFF(SETTING_NAME = 'NOTIFICATION_INTEGRATION', SETTING_VALUE, NULL)),
         MAX(IFF(SETTING_NAME = 'EMAIL_SUBJECT_PREFIX', SETTING_VALUE, NULL))
    INTO :recipients, :integ, :prefix
  FROM ACCEL_DB.OBSERVABILITY.OBS_SETTINGS;

  SELECT COUNT(*), COUNT_IF(SEVERITY = 'CRITICAL') INTO :n, :n_crit
  FROM ACCEL_DB.OBSERVABILITY.INCIDENTS
  WHERE STATUS = 'OPEN' AND NOTIFIED_AT IS NULL AND DETECTED_AT <= :ts;

  IF (n = 0) THEN
    RETURN 'No new incidents';
  END IF;

  SELECT 'New data incidents in ACCEL_DB: ' || :n || ' (' || :n_crit || ' critical)\n\n'
         || LISTAGG('#' || INCIDENT_ID || ' [' || SEVERITY || '] ' || MONITOR_TYPE || ' on '
                    || SCHEMA_NAME || '.' || TABLE_NAME || ': ' || MESSAGE, '\n')
              WITHIN GROUP (ORDER BY CASE SEVERITY WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 ELSE 4 END, INCIDENT_ID)
         || '\n\nDashboard: Snowsight > Projects > Streamlit > Data Observability.'
         || '\nAcknowledge: CALL ACCEL_DB.OBSERVABILITY.SET_INCIDENT_STATUS(<id>, ''ACKNOWLEDGED'', ''note'');'
    INTO :body
  FROM (SELECT * FROM ACCEL_DB.OBSERVABILITY.INCIDENTS
        WHERE STATUS = 'OPEN' AND NOTIFIED_AT IS NULL AND DETECTED_AT <= :ts
        ORDER BY INCIDENT_ID LIMIT 50);

  subj := COALESCE(prefix, '[Data Observability]') || ' ' || n || ' new incident(s)';

  BEGIN
    CALL SYSTEM$SEND_EMAIL(:integ, :recipients, :subj, :body);
    UPDATE ACCEL_DB.OBSERVABILITY.INCIDENTS SET NOTIFIED_AT = :ts
     WHERE STATUS = 'OPEN' AND NOTIFIED_AT IS NULL AND DETECTED_AT <= :ts;
    INSERT INTO ACCEL_DB.OBSERVABILITY.NOTIFICATION_LOG SELECT :ts, :recipients, :subj, :n, 'SENT', NULL;
    RETURN 'E-mail sent for ' || n || ' incident(s)';
  EXCEPTION
    WHEN OTHER THEN
      LET err VARCHAR := SQLERRM;
      INSERT INTO ACCEL_DB.OBSERVABILITY.NOTIFICATION_LOG SELECT :ts, :recipients, :subj, :n, 'FAILED', :err;
      RETURN 'E-mail failed: ' || err;
  END;
END;
$$;

-- 4. Alert: checks hourly for un-notified incidents, then e-mails them.
--    Pair it with TASK_OBS_EVALUATE (file 02), which creates the incidents.
CREATE OR REPLACE ALERT OBS_NEW_INCIDENT_ALERT
  WAREHOUSE = ACCEL_WH
  SCHEDULE = '60 MINUTE'                                              -- EDIT ME
  IF (EXISTS (
        SELECT 1 FROM ACCEL_DB.OBSERVABILITY.INCIDENTS
        WHERE STATUS = 'OPEN' AND NOTIFIED_AT IS NULL))
  THEN
    CALL ACCEL_DB.OBSERVABILITY.NOTIFY_NEW_INCIDENTS();

-- New alerts are suspended. To go live (after setting verified recipients):
-- ALTER TASK  ACCEL_DB.OBSERVABILITY.TASK_OBS_EVALUATE RESUME;
-- ALTER ALERT ACCEL_DB.OBSERVABILITY.OBS_NEW_INCIDENT_ALERT RESUME;
SHOW ALERTS LIKE 'OBS_NEW_INCIDENT_ALERT' IN SCHEMA ACCEL_DB.OBSERVABILITY;

GRANT SELECT ON TABLE NOTIFICATION_LOG TO ROLE ACCEL_ANALYST;

-- Optional manual test (sends mail for current open incidents, or reports the e-mail error in NOTIFICATION_LOG):
-- CALL NOTIFY_NEW_INCIDENTS();
-- SELECT * FROM NOTIFICATION_LOG ORDER BY SENT_AT DESC;

-- Alert run history:
-- SELECT * FROM TABLE(ACCEL_DB.INFORMATION_SCHEMA.ALERT_HISTORY(
--     SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP()))) ORDER BY SCHEDULED_TIME DESC;
