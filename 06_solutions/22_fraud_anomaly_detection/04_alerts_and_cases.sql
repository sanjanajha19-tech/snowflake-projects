/*=============================================================================
  ACCELERATOR 22 - Fraud & Anomaly Detection
  File 04 : Fraud cases, case workflow, case queue and ALERT
  Creates : CASE_CONFIG              high-risk threshold (EDIT ME)
            CASE_STATUSES            Open / Investigating / Confirmed fraud / False positive
            V_CASE_CANDIDATES        one row per cardholder-day in the detection window:
                                     rule flags + ML anomaly -> RISK_SCORE (0-100) + REASONS
            FRAUD_CASES              persisted cases (score >= FRAUD_CONFIG.CASE_MIN_SCORE)
                                     with workflow columns (status, assignee, notes)
            FRAUD_CASE_HISTORY       audit trail of status changes
            CASE_QUEUE, V_CASE_QUEUE high-risk cases pushed for investigation
            REFRESH_FRAUD_CASES()    MERGE candidates into FRAUD_CASES (keeps workflow)
            SET_CASE_STATUS(...)     status update + audit (used by streamlit_app.py)
            ENQUEUE_HIGH_RISK_CASES()refresh, then queue new high-risk open cases
            FRAUD_HIGH_RISK_ALERT    ALERT (created SUSPENDED) that calls the above hourly
  Prereq  : files 01-03 (AD_RESULTS must exist). ACCEL_ADMIN has EXECUTE ALERT (00_setup).
  Run as  : ACCEL_ADMIN
  Rerun   : safe. FRAUD_CASES, history and queue are kept (IF NOT EXISTS); the
            alert is recreated, which leaves it suspended again.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS FRAUD;
USE SCHEMA FRAUD;

------------------------------------------------------------------------------
-- 1. Configuration and status list
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CASE_CONFIG (
    HIGH_RISK_MIN_SCORE NUMBER          -- cases at or above this score are "High" and get queued
);
INSERT INTO CASE_CONFIG (HIGH_RISK_MIN_SCORE)
SELECT 70                                                            -- EDIT ME
WHERE NOT EXISTS (SELECT 1 FROM CASE_CONFIG);

CREATE OR REPLACE TABLE CASE_STATUSES (STATUS VARCHAR, SORT_ORDER NUMBER, IS_CLOSED BOOLEAN);
INSERT INTO CASE_STATUSES VALUES
  ('Open', 1, FALSE), ('Investigating', 2, FALSE),
  ('Confirmed fraud', 3, TRUE), ('False positive', 4, TRUE);

------------------------------------------------------------------------------
-- 2. Candidates: rules + ML combined per cardholder-day
--    RISK_SCORE = rule points (best transaction score, +10 per extra rule type,
--                 +10 if 3+ flagged transactions) + ML points (40-60 when the
--                 day's spend is above the model's upper bound), capped at 100.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_CASE_CANDIDATES
  COMMENT = 'Rule flags and ML anomalies combined per cardholder-day, with risk score and reasons'
AS
WITH cfg AS (
    SELECT f.DETECT_FROM, f.CASE_MIN_SCORE, k.HIGH_RISK_MIN_SCORE
    FROM ACCEL_DB.FRAUD.FRAUD_CONFIG f
    CROSS JOIN ACCEL_DB.FRAUD.CASE_CONFIG k
),
r AS (
    SELECT s.CUSTOMER_ID,
           s.TXN_TS::DATE                                                         AS CASE_DATE,
           ANY_VALUE(s.CARD_ID)                                                   AS CARD_ID,
           COUNT(*)                                                               AS DAY_TXNS,
           SUM(s.AMOUNT_USD)                                                      AS DAY_SPEND_USD,
           MAX(s.RULE_SCORE)                                                      AS MAX_TXN_RULE_SCORE,
           COUNT_IF(s.RULE_SCORE > 0)                                             AS FLAGGED_TXNS,
           SUM(IFF(s.RULE_SCORE > 0, s.AMOUNT_USD, 0))                            AS FLAGGED_AMOUNT_USD,
           COUNT_IF(s.F_VELOCITY)                                                 AS N_VELOCITY,
           COUNT_IF(s.F_TRAVEL)                                                   AS N_TRAVEL,
           COUNT_IF(s.F_HIGH_RISK_MCC)                                            AS N_HIGH_RISK_MCC,
           COUNT_IF(s.F_AMOUNT_SPIKE)                                             AS N_AMOUNT_SPIKE,
           COUNT_IF(s.F_NEW_DEVICE_NIGHT)                                         AS N_NEW_DEVICE_NIGHT,
           COUNT_IF(s.F_FOREIGN_CP)                                               AS N_FOREIGN_CP,
           MAX(IFF(s.F_VELOCITY, s.TXN_COUNT_1H, NULL))                           AS MAX_TXNS_1H,
           MAX(IFF(s.F_TRAVEL, s.PREV_CITY || ' to ' || s.TXN_CITY || ' in '
                               || s.MINUTES_SINCE_PREV || ' min', NULL))          AS TRAVEL_DETAIL,
           LISTAGG(DISTINCT IFF(s.F_HIGH_RISK_MCC, s.MERCHANT_CATEGORY, NULL), ', ') AS HIGH_RISK_MCCS,
           MAX(IFF(s.F_AMOUNT_SPIKE, s.AMOUNT_RATIO, NULL))                       AS MAX_AMOUNT_RATIO,
           LISTAGG(DISTINCT IFF(s.F_FOREIGN_CP, s.TXN_COUNTRY, NULL), ', ')       AS FOREIGN_COUNTRIES,
           BOOLOR_AGG(s.IS_FRAUD_INJECTED)                                        AS IS_FRAUD_INJECTED
    FROM ACCEL_DB.FRAUD.V_TXN_RULE_SCORES s
    WHERE s.TXN_TS >= (SELECT DETECT_FROM FROM cfg)
    GROUP BY s.CUSTOMER_ID, s.TXN_TS::DATE
),
ml AS (
    SELECT CUSTOMER_ID, SPEND_DATE, DAILY_SPEND, FORECAST, UPPER_BOUND, DISTANCE
    FROM ACCEL_DB.FRAUD.AD_RESULTS
    WHERE IS_ANOMALY AND DAILY_SPEND > UPPER_BOUND AND DAILY_SPEND > 0
),
j AS (
    SELECT r.*,
           (ml.CUSTOMER_ID IS NOT NULL)                                           AS ML_ANOMALY,
           ml.FORECAST                                                            AS ML_EXPECTED_SPEND,
           ml.UPPER_BOUND                                                         AS ML_UPPER_BOUND,
           ml.DISTANCE                                                            AS ML_DISTANCE,
           IFF(r.N_VELOCITY > 0, 1, 0) + IFF(r.N_TRAVEL > 0, 1, 0) + IFF(r.N_HIGH_RISK_MCC > 0, 1, 0)
         + IFF(r.N_AMOUNT_SPIKE > 0, 1, 0) + IFF(r.N_NEW_DEVICE_NIGHT > 0, 1, 0) + IFF(r.N_FOREIGN_CP > 0, 1, 0)
                                                                                  AS RULE_TYPES_HIT
    FROM r
    LEFT JOIN ml ON ml.CUSTOMER_ID = r.CUSTOMER_ID AND ml.SPEND_DATE = r.CASE_DATE
),
sc AS (
    SELECT j.*,
           IFF(j.MAX_TXN_RULE_SCORE > 0,
               LEAST(100, j.MAX_TXN_RULE_SCORE + 10 * GREATEST(j.RULE_TYPES_HIT - 1, 0)
                          + IFF(j.FLAGGED_TXNS >= 3, 10, 0)), 0)                  AS RULE_POINTS,
           IFF(j.ML_ANOMALY, 40 + LEAST(20, GREATEST(0, FLOOR(COALESCE(j.ML_DISTANCE, 0)))), 0) AS ML_POINTS
    FROM j
)
SELECT 'FC-' || sc.CUSTOMER_ID || '-' || TO_CHAR(sc.CASE_DATE, 'YYYYMMDD')          AS CASE_ID,
       sc.CUSTOMER_ID,
       c.CUSTOMER_NAME,
       c.SEGMENT,
       c.CITY                                                                     AS HOME_CITY,
       c.COUNTRY                                                                  AS HOME_COUNTRY,
       sc.CARD_ID,
       sc.CASE_DATE,
       sc.DAY_TXNS,
       sc.DAY_SPEND_USD,
       sc.FLAGGED_TXNS,
       sc.FLAGGED_AMOUNT_USD,
       sc.RULE_POINTS                                                              AS RULE_SCORE,
       sc.ML_ANOMALY,
       ROUND(sc.ML_EXPECTED_SPEND, 2)                                              AS ML_EXPECTED_SPEND,
       ROUND(sc.ML_UPPER_BOUND, 2)                                                 AS ML_UPPER_BOUND,
       ROUND(sc.ML_DISTANCE, 2)                                                    AS ML_DISTANCE,
       LEAST(100, sc.RULE_POINTS + sc.ML_POINTS)                                    AS RISK_SCORE,
       CASE WHEN LEAST(100, sc.RULE_POINTS + sc.ML_POINTS) >= cfg.HIGH_RISK_MIN_SCORE THEN 'High'
            WHEN LEAST(100, sc.RULE_POINTS + sc.ML_POINTS) >= cfg.CASE_MIN_SCORE      THEN 'Medium'
            ELSE 'Low' END                                                        AS RISK_BAND,
       CASE WHEN sc.RULE_POINTS > 0 AND sc.ML_ANOMALY THEN 'Rules + ML'
            WHEN sc.ML_ANOMALY THEN 'ML' ELSE 'Rules' END                          AS DETECTED_BY,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
           IFF(sc.N_VELOCITY > 0, 'Velocity: ' || sc.MAX_TXNS_1H || ' transactions within 1 hour', NULL),
           IFF(sc.N_TRAVEL > 0, 'Impossible travel: ' || sc.TRAVEL_DETAIL, NULL),
           IFF(sc.N_HIGH_RISK_MCC > 0, 'First-ever high-risk merchant: ' || sc.HIGH_RISK_MCCS, NULL),
           IFF(sc.N_AMOUNT_SPIKE > 0, 'Amount spike: ' || sc.MAX_AMOUNT_RATIO || 'x usual amount', NULL),
           IFF(sc.N_NEW_DEVICE_NIGHT > 0, 'New device used at night', NULL),
           IFF(sc.N_FOREIGN_CP > 0, 'Card present abroad: ' || sc.FOREIGN_COUNTRIES, NULL),
           IFF(sc.ML_ANOMALY, 'ML: day spend USD ' || ROUND(sc.DAY_SPEND_USD) || ' vs expected USD '
                             || ROUND(sc.ML_EXPECTED_SPEND) || ' (upper bound ' || ROUND(sc.ML_UPPER_BOUND) || ')', NULL)
       ), '; ')                                                                   AS REASONS,
       sc.IS_FRAUD_INJECTED
FROM sc
CROSS JOIN cfg
JOIN ACCEL_DB.DEMO.CUSTOMERS c ON c.CUSTOMER_ID = sc.CUSTOMER_ID
WHERE sc.RULE_POINTS > 0 OR sc.ML_ANOMALY;

------------------------------------------------------------------------------
-- 3. Case tables (kept on rerun)
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS FRAUD_CASES (
    CASE_ID             VARCHAR,
    CUSTOMER_ID         NUMBER,
    CUSTOMER_NAME       VARCHAR,
    SEGMENT             VARCHAR,
    HOME_CITY           VARCHAR,
    HOME_COUNTRY        VARCHAR,
    CARD_ID             VARCHAR,
    CASE_DATE           DATE,
    DAY_TXNS            NUMBER,
    DAY_SPEND_USD       NUMBER(14,2),
    FLAGGED_TXNS        NUMBER,
    FLAGGED_AMOUNT_USD  NUMBER(14,2),
    RULE_SCORE          NUMBER,
    ML_ANOMALY          BOOLEAN,
    ML_EXPECTED_SPEND   NUMBER(14,2),
    ML_UPPER_BOUND      NUMBER(14,2),
    ML_DISTANCE         FLOAT,
    RISK_SCORE          NUMBER,
    RISK_BAND           VARCHAR,          -- High | Medium
    DETECTED_BY         VARCHAR,          -- Rules | ML | Rules + ML
    REASONS             VARCHAR,
    IS_FRAUD_INJECTED   BOOLEAN,          -- ground truth, for demo evaluation only
    -- workflow
    STATUS              VARCHAR DEFAULT 'Open',   -- Open | Investigating | Confirmed fraud | False positive
    ASSIGNED_TO         VARCHAR,
    ANALYST_NOTES       VARCHAR,
    STATUS_UPDATED_AT   TIMESTAMP_NTZ,
    STATUS_UPDATED_BY   VARCHAR,
    CLOSED_AT           TIMESTAMP_NTZ,
    FIRST_DETECTED_AT   TIMESTAMP_NTZ,
    LAST_REFRESHED_AT   TIMESTAMP_NTZ
) COMMENT = 'Fraud cases: rule flags + ML anomalies per cardholder-day, with review workflow';

CREATE TABLE IF NOT EXISTS FRAUD_CASE_HISTORY (
    CASE_ID     VARCHAR,
    CHANGED_AT  TIMESTAMP_NTZ,
    CHANGED_BY  VARCHAR,
    OLD_STATUS  VARCHAR,
    NEW_STATUS  VARCHAR,
    NOTE        VARCHAR
);

CREATE TABLE IF NOT EXISTS CASE_QUEUE (
    CASE_ID      VARCHAR,
    CUSTOMER_ID  NUMBER,
    CASE_DATE    DATE,
    RISK_SCORE   NUMBER,
    REASONS      VARCHAR,
    QUEUED_AT    TIMESTAMP_NTZ,
    QUEUED_BY    VARCHAR            -- ALERT | MANUAL
) COMMENT = 'High-risk cases pushed for investigation by FRAUD_HIGH_RISK_ALERT';

CREATE OR REPLACE VIEW V_CASE_QUEUE AS
SELECT q.CASE_ID, q.QUEUED_AT, q.QUEUED_BY, q.RISK_SCORE AS RISK_SCORE_WHEN_QUEUED,
       c.RISK_SCORE, c.CUSTOMER_ID, c.CUSTOMER_NAME, c.CASE_DATE, c.FLAGGED_AMOUNT_USD,
       c.STATUS, c.ASSIGNED_TO, c.REASONS,
       DATEDIFF(HOUR, q.QUEUED_AT, COALESCE(c.CLOSED_AT, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)) AS AGE_HOURS
FROM ACCEL_DB.FRAUD.CASE_QUEUE q
JOIN ACCEL_DB.FRAUD.FRAUD_CASES c ON c.CASE_ID = q.CASE_ID;

------------------------------------------------------------------------------
-- 4. Procedures
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE REFRESH_FRAUD_CASES()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    before_n INTEGER DEFAULT 0;
    after_n  INTEGER DEFAULT 0;
    merged_n INTEGER DEFAULT 0;
BEGIN
    SELECT COUNT(*) INTO :before_n FROM ACCEL_DB.FRAUD.FRAUD_CASES;

    MERGE INTO ACCEL_DB.FRAUD.FRAUD_CASES t
    USING (
        SELECT v.*
        FROM ACCEL_DB.FRAUD.V_CASE_CANDIDATES v
        WHERE v.RISK_SCORE >= (SELECT CASE_MIN_SCORE FROM ACCEL_DB.FRAUD.FRAUD_CONFIG)
    ) s
    ON t.CASE_ID = s.CASE_ID
    WHEN MATCHED THEN UPDATE SET
        DAY_TXNS = s.DAY_TXNS, DAY_SPEND_USD = s.DAY_SPEND_USD,
        FLAGGED_TXNS = s.FLAGGED_TXNS, FLAGGED_AMOUNT_USD = s.FLAGGED_AMOUNT_USD,
        RULE_SCORE = s.RULE_SCORE, ML_ANOMALY = s.ML_ANOMALY,
        ML_EXPECTED_SPEND = s.ML_EXPECTED_SPEND, ML_UPPER_BOUND = s.ML_UPPER_BOUND, ML_DISTANCE = s.ML_DISTANCE,
        RISK_SCORE = s.RISK_SCORE, RISK_BAND = s.RISK_BAND, DETECTED_BY = s.DETECTED_BY,
        REASONS = s.REASONS, IS_FRAUD_INJECTED = s.IS_FRAUD_INJECTED,
        LAST_REFRESHED_AT = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    WHEN NOT MATCHED THEN INSERT (
        CASE_ID, CUSTOMER_ID, CUSTOMER_NAME, SEGMENT, HOME_CITY, HOME_COUNTRY, CARD_ID, CASE_DATE,
        DAY_TXNS, DAY_SPEND_USD, FLAGGED_TXNS, FLAGGED_AMOUNT_USD, RULE_SCORE, ML_ANOMALY,
        ML_EXPECTED_SPEND, ML_UPPER_BOUND, ML_DISTANCE, RISK_SCORE, RISK_BAND, DETECTED_BY, REASONS,
        IS_FRAUD_INJECTED, STATUS, FIRST_DETECTED_AT, LAST_REFRESHED_AT)
    VALUES (
        s.CASE_ID, s.CUSTOMER_ID, s.CUSTOMER_NAME, s.SEGMENT, s.HOME_CITY, s.HOME_COUNTRY, s.CARD_ID, s.CASE_DATE,
        s.DAY_TXNS, s.DAY_SPEND_USD, s.FLAGGED_TXNS, s.FLAGGED_AMOUNT_USD, s.RULE_SCORE, s.ML_ANOMALY,
        s.ML_EXPECTED_SPEND, s.ML_UPPER_BOUND, s.ML_DISTANCE, s.RISK_SCORE, s.RISK_BAND, s.DETECTED_BY, s.REASONS,
        s.IS_FRAUD_INJECTED, 'Open', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);
    merged_n := SQLROWCOUNT;

    SELECT COUNT(*) INTO :after_n FROM ACCEL_DB.FRAUD.FRAUD_CASES;
    RETURN 'Cases refreshed: ' || merged_n || ' candidate rows merged, ' || (after_n - before_n)
           || ' new cases, ' || after_n || ' cases in total.';
END;
$$;

CREATE OR REPLACE PROCEDURE SET_CASE_STATUS(P_CASE_ID VARCHAR, P_STATUS VARCHAR, P_NOTE VARCHAR, P_USER VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    valid_n    INTEGER DEFAULT 0;
    old_status VARCHAR;
    who        VARCHAR;
    note_line  VARCHAR;
BEGIN
    SELECT COUNT(*) INTO :valid_n FROM ACCEL_DB.FRAUD.CASE_STATUSES WHERE STATUS = :P_STATUS;
    IF (valid_n = 0) THEN
        RETURN 'Invalid status: ' || COALESCE(P_STATUS, 'NULL')
               || '. Use Open, Investigating, Confirmed fraud or False positive.';
    END IF;

    SELECT MAX(STATUS) INTO :old_status FROM ACCEL_DB.FRAUD.FRAUD_CASES WHERE CASE_ID = :P_CASE_ID;
    IF (old_status IS NULL) THEN
        RETURN 'Case not found: ' || COALESCE(P_CASE_ID, 'NULL');
    END IF;

    who := COALESCE(NULLIF(P_USER, ''), CURRENT_USER());
    note_line := IFF(P_NOTE IS NULL OR TRIM(P_NOTE) = '', NULL,
                     TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY-MM-DD HH24:MI') || ' ' || who || ': ' || P_NOTE);

    UPDATE ACCEL_DB.FRAUD.FRAUD_CASES
    SET STATUS            = :P_STATUS,
        ASSIGNED_TO       = IFF(:P_STATUS = 'Investigating', COALESCE(ASSIGNED_TO, :who), ASSIGNED_TO),
        ANALYST_NOTES     = IFF(:note_line IS NULL, ANALYST_NOTES,
                                IFF(ANALYST_NOTES IS NULL, :note_line, ANALYST_NOTES || CHR(10) || :note_line)),
        STATUS_UPDATED_AT = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
        STATUS_UPDATED_BY = :who,
        CLOSED_AT         = IFF(:P_STATUS IN ('Confirmed fraud', 'False positive'), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, NULL)
    WHERE CASE_ID = :P_CASE_ID;

    INSERT INTO ACCEL_DB.FRAUD.FRAUD_CASE_HISTORY (CASE_ID, CHANGED_AT, CHANGED_BY, OLD_STATUS, NEW_STATUS, NOTE)
    VALUES (:P_CASE_ID, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, :who, :old_status, :P_STATUS, :P_NOTE);

    RETURN P_CASE_ID || ': ' || old_status || ' -> ' || P_STATUS;
END;
$$;

CREATE OR REPLACE PROCEDURE ENQUEUE_HIGH_RISK_CASES(P_SOURCE VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    refresh_msg VARCHAR;
    queued_n    INTEGER DEFAULT 0;
BEGIN
    CALL ACCEL_DB.FRAUD.REFRESH_FRAUD_CASES();
    SELECT 'Cases: ' || COUNT(*) || ' (' || COUNT_IF(STATUS IN ('Open', 'Investigating')) || ' open).'
      INTO :refresh_msg
    FROM ACCEL_DB.FRAUD.FRAUD_CASES;

    INSERT INTO ACCEL_DB.FRAUD.CASE_QUEUE (CASE_ID, CUSTOMER_ID, CASE_DATE, RISK_SCORE, REASONS, QUEUED_AT, QUEUED_BY)
    SELECT c.CASE_ID, c.CUSTOMER_ID, c.CASE_DATE, c.RISK_SCORE, c.REASONS,
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, COALESCE(:P_SOURCE, 'MANUAL')
    FROM ACCEL_DB.FRAUD.FRAUD_CASES c
    CROSS JOIN ACCEL_DB.FRAUD.CASE_CONFIG k
    LEFT JOIN ACCEL_DB.FRAUD.CASE_QUEUE q ON q.CASE_ID = c.CASE_ID
    WHERE c.RISK_SCORE >= k.HIGH_RISK_MIN_SCORE
      AND c.STATUS IN ('Open', 'Investigating')
      AND q.CASE_ID IS NULL;
    queued_n := SQLROWCOUNT;

    RETURN refresh_msg || ' Queued ' || queued_n || ' new high-risk cases.';
END;
$$;

------------------------------------------------------------------------------
-- 5. Alert: hourly check for new high-risk cases. Created SUSPENDED.
--    Turn on:   ALTER ALERT ACCEL_DB.FRAUD.FRAUD_HIGH_RISK_ALERT RESUME;
--    Turn off:  ALTER ALERT ACCEL_DB.FRAUD.FRAUD_HIGH_RISK_ALERT SUSPEND;
--    History:   SELECT * FROM TABLE(ACCEL_DB.INFORMATION_SCHEMA.ALERT_HISTORY())
--               WHERE NAME = 'FRAUD_HIGH_RISK_ALERT' ORDER BY SCHEDULED_TIME DESC;
--    Optional email: add SYSTEM$SEND_EMAIL in ENQUEUE_HIGH_RISK_CASES once a
--    notification integration exists.
------------------------------------------------------------------------------
CREATE OR REPLACE ALERT FRAUD_HIGH_RISK_ALERT
  WAREHOUSE = ACCEL_WH
  SCHEDULE  = '60 MINUTE'                                            -- EDIT ME
  COMMENT   = 'Accelerator 22: queue new high-risk fraud cases'
  IF (EXISTS (
      SELECT 1
      FROM ACCEL_DB.FRAUD.V_CASE_CANDIDATES v
      CROSS JOIN ACCEL_DB.FRAUD.CASE_CONFIG k
      LEFT JOIN ACCEL_DB.FRAUD.CASE_QUEUE q ON q.CASE_ID = v.CASE_ID
      LEFT JOIN ACCEL_DB.FRAUD.FRAUD_CASES c ON c.CASE_ID = v.CASE_ID
      WHERE v.RISK_SCORE >= k.HIGH_RISK_MIN_SCORE
        AND q.CASE_ID IS NULL
        AND COALESCE(c.STATUS, 'Open') IN ('Open', 'Investigating')
  ))
  THEN
    CALL ACCEL_DB.FRAUD.ENQUEUE_HIGH_RISK_CASES('ALERT');

-- ALTER ALERT FRAUD_HIGH_RISK_ALERT RESUME;     -- uncomment to start the hourly schedule

------------------------------------------------------------------------------
-- 6. First run: build the cases and simulate one alert firing
------------------------------------------------------------------------------
CALL REFRESH_FRAUD_CASES();
CALL ENQUEUE_HIGH_RISK_CASES('MANUAL');

-- Cases by band and detector
SELECT RISK_BAND, DETECTED_BY, COUNT(*) AS CASES, ROUND(SUM(FLAGGED_AMOUNT_USD)) AS FLAGGED_USD
FROM FRAUD_CASES GROUP BY 1, 2 ORDER BY 1, 2;

-- How good are the cases? (injected ground truth)
SELECT RISK_BAND,
       COUNT(*)                                                    AS CASES,
       COUNT_IF(IS_FRAUD_INJECTED)                                 AS TRUE_FRAUD_CASES,
       ROUND(100 * COUNT_IF(IS_FRAUD_INJECTED) / COUNT(*), 1)      AS PRECISION_PCT
FROM FRAUD_CASES GROUP BY 1 ORDER BY 1;

WITH truth AS (
    SELECT DISTINCT CUSTOMER_ID, TXN_TS::DATE AS D FROM CARD_TRANSACTIONS WHERE IS_FRAUD_INJECTED
)
SELECT COUNT(*) AS FRAUD_CARDHOLDER_DAYS,
       COUNT(c.CASE_ID) AS CAUGHT_AS_CASES,
       ROUND(100 * COUNT(c.CASE_ID) / COUNT(*), 1) AS RECALL_PCT
FROM truth t
LEFT JOIN FRAUD_CASES c ON c.CUSTOMER_ID = t.CUSTOMER_ID AND c.CASE_DATE = t.D;

SELECT * FROM V_CASE_QUEUE ORDER BY RISK_SCORE DESC LIMIT 25;

SHOW ALERTS LIKE 'FRAUD_HIGH_RISK_ALERT' IN SCHEMA ACCEL_DB.FRAUD;   -- state = suspended
