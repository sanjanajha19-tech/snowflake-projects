/*=============================================================================
  ASSET 14 - Forecasting & ML Starter
  File 02   : Anomaly detection on daily order counts
              (SNOWFLAKE.ML.ANOMALY_DETECTION, unsupervised)
  Creates   : DAILY_ORDERS_V, DAILY_ORDERS_TRAIN_V, DAILY_ORDERS_TEST_V,
              ORDERS_ANOMALY_MODEL, ORDER_ANOMALIES (table)
  Run as    : ACCEL_ADMIN
  Rerun     : safe. Run top to bottom (RESULT_SCAN reads the CALL before it).
  Logic     : train on everything except the last 60 days, then score the
              last 60 days (test timestamps must be after training timestamps).
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_AI_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS ML_STARTER;
USE SCHEMA ML_STARTER;

------------------------------------------------------------------------------
-- 1. Daily orders (all channels, all statuses) - zero-filled calendar
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW DAILY_ORDERS_V
  COMMENT = 'Daily order count across the business'
AS
WITH bounds AS (
    SELECT MIN(ORDER_DATE) AS MIN_D, MAX(ORDER_DATE) AS MAX_D FROM ACCEL_DB.DEMO.ORDERS
),
calendar AS (
    SELECT g.D
    FROM (
        SELECT DATEADD('day', ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, b.MIN_D) AS D
        FROM TABLE(GENERATOR(ROWCOUNT => 2000)), bounds b
    ) g, bounds b2
    WHERE g.D <= b2.MAX_D
),
daily AS (
    SELECT ORDER_DATE, COUNT(*) AS ORDER_COUNT
    FROM ACCEL_DB.DEMO.ORDERS
    GROUP BY ORDER_DATE
)
SELECT cal.D::TIMESTAMP_NTZ               AS TS,
       COALESCE(d.ORDER_COUNT, 0)::FLOAT  AS ORDER_COUNT
FROM calendar cal
LEFT JOIN daily d ON d.ORDER_DATE = cal.D;

CREATE OR REPLACE VIEW DAILY_ORDERS_TRAIN_V AS
SELECT TS, ORDER_COUNT
FROM DAILY_ORDERS_V
WHERE TS < DATEADD('day', -60, (SELECT MAX(TS) FROM DAILY_ORDERS_V));   -- EDIT ME: test window

-- Test window = last 60 days. Two synthetic incidents are injected so the
-- demo always shows anomalies: a spike (x3, e.g. bot orders / duplicate
-- feed) and a dip (x0.2, e.g. checkout outage).
-- EDIT ME: set INJECT_DEMO_ANOMALIES to FALSE for real monitoring.
CREATE OR REPLACE VIEW DAILY_ORDERS_TEST_V AS
WITH p AS (
    SELECT MAX(TS) AS MAX_TS, TRUE AS INJECT_DEMO_ANOMALIES FROM DAILY_ORDERS_V
)
SELECT v.TS,
       CASE
         WHEN p.INJECT_DEMO_ANOMALIES AND v.TS = DATEADD('day', -40, p.MAX_TS) THEN v.ORDER_COUNT * 3
         WHEN p.INJECT_DEMO_ANOMALIES AND v.TS = DATEADD('day', -15, p.MAX_TS) THEN v.ORDER_COUNT * 0.2
         ELSE v.ORDER_COUNT
       END AS ORDER_COUNT
FROM DAILY_ORDERS_V v, p
WHERE v.TS >= DATEADD('day', -60, p.MAX_TS);

------------------------------------------------------------------------------
-- 2. Train (LABEL_COLNAME => '' means unsupervised)
------------------------------------------------------------------------------
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION ORDERS_ANOMALY_MODEL(
    INPUT_DATA        => TABLE(DAILY_ORDERS_TRAIN_V),
    TIMESTAMP_COLNAME => 'TS',
    TARGET_COLNAME    => 'ORDER_COUNT',
    LABEL_COLNAME     => ''
);

------------------------------------------------------------------------------
-- 3. Detect anomalies in the test window and store them
------------------------------------------------------------------------------
CALL ORDERS_ANOMALY_MODEL!DETECT_ANOMALIES(
    INPUT_DATA        => TABLE(DAILY_ORDERS_TEST_V),
    TIMESTAMP_COLNAME => 'TS',
    TARGET_COLNAME    => 'ORDER_COUNT',
    CONFIG_OBJECT     => {'prediction_interval': 0.99}      -- EDIT ME: sensitivity
);

CREATE OR REPLACE TABLE ORDER_ANOMALIES AS
SELECT TS, Y AS ACTUAL_ORDERS, FORECAST AS EXPECTED_ORDERS, LOWER_BOUND, UPPER_BOUND,
       IS_ANOMALY, PERCENTILE, DISTANCE, CURRENT_TIMESTAMP() AS SCORED_AT
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

GRANT SELECT ON ALL TABLES IN SCHEMA ACCEL_DB.ML_STARTER TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ACCEL_DB.ML_STARTER TO ROLE ACCEL_ANALYST;

-- Anomalous days
SELECT TS::DATE AS DAY, ACTUAL_ORDERS, ROUND(EXPECTED_ORDERS, 1) AS EXPECTED_ORDERS,
       ROUND(LOWER_BOUND, 1) AS LOWER_BOUND, ROUND(UPPER_BOUND, 1) AS UPPER_BOUND,
       ROUND(PERCENTILE, 4) AS PERCENTILE
FROM ORDER_ANOMALIES
WHERE IS_ANOMALY
ORDER BY TS;

-- Production pattern (optional): score yesterday every morning and alert.
-- CREATE OR REPLACE TASK ORDER_ANOMALY_TASK WAREHOUSE = ACCEL_AI_WH
--   SCHEDULE = 'USING CRON 0 7 * * * Asia/Kolkata'     -- EDIT ME
-- AS CALL ORDERS_ANOMALY_MODEL!DETECT_ANOMALIES(
--      INPUT_DATA => TABLE(DAILY_ORDERS_TEST_V), TIMESTAMP_COLNAME => 'TS', TARGET_COLNAME => 'ORDER_COUNT');
-- (Pair with a Snowflake ALERT or notification integration to email the owner.)
