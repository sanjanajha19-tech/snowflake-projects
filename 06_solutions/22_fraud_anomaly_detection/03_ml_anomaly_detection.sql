/*=============================================================================
  ACCELERATOR 22 - Fraud & Anomaly Detection
  File 03 : SNOWFLAKE.ML.ANOMALY_DETECTION on per-cardholder daily spend
            Multi-series model: one series per high-activity cardholder
            (>= FRAUD_CONFIG.ML_MIN_TRAIN_TXNS transactions before DETECT_FROM).
            Train on days before DETECT_FROM, detect on days from DETECT_FROM.
            Complements the rules: it catches "this cardholder spent far more
            today than their own pattern predicts", without hand-set thresholds.
  Creates : V_AD_DAILY, V_AD_TRAIN, V_AD_DETECT, model FRAUD_SPEND_AD,
            AD_RESULTS (one row per cardholder-day in the detection window)
  Run as  : ACCEL_ADMIN on ACCEL_AI_WH. Training takes a few minutes.
  Rerun   : safe (model and results are replaced).
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_AI_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS FRAUD;
USE SCHEMA FRAUD;

-- ACCEL_ADMIN owns the schema; the explicit grant documents the privilege a non-owner role would need
GRANT CREATE SNOWFLAKE.ML.ANOMALY_DETECTION ON SCHEMA ACCEL_DB.FRAUD TO ROLE ACCEL_ADMIN;

------------------------------------------------------------------------------
-- 1. Daily spend per cardholder, zero-filled (no spend = 0, not missing)
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_AD_DAILY
  COMMENT = 'Daily spend per high-activity cardholder, zero-filled'
AS
WITH cfg AS (
    SELECT PERIOD_START, PERIOD_DAYS, DETECT_FROM, ML_MIN_TRAIN_TXNS FROM ACCEL_DB.FRAUD.FRAUD_CONFIG
),
cust AS (
    SELECT t.CUSTOMER_ID
    FROM ACCEL_DB.FRAUD.CARD_TRANSACTIONS t
    CROSS JOIN cfg
    WHERE t.TXN_TS < cfg.DETECT_FROM
    GROUP BY t.CUSTOMER_ID, cfg.ML_MIN_TRAIN_TXNS
    HAVING COUNT(*) >= cfg.ML_MIN_TRAIN_TXNS
),
days AS (
    SELECT DATEADD(DAY, g.N, cfg.PERIOD_START) AS D
    FROM cfg
    CROSS JOIN (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS N FROM TABLE(GENERATOR(ROWCOUNT => 366))) g
    WHERE g.N < cfg.PERIOD_DAYS
),
spend AS (
    SELECT CUSTOMER_ID, TXN_TS::DATE AS D, SUM(AMOUNT_USD) AS AMT, COUNT(*) AS N_TXN
    FROM ACCEL_DB.FRAUD.CARD_TRANSACTIONS
    GROUP BY 1, 2
)
SELECT c.CUSTOMER_ID,
       TO_VARIANT(c.CUSTOMER_ID)                AS SERIES_KEY,     -- multi-series column must be VARIANT
       d.D::TIMESTAMP_NTZ                       AS DAY_TS,
       COALESCE(s.AMT, 0)::FLOAT                AS DAILY_SPEND,
       COALESCE(s.N_TXN, 0)                     AS DAILY_TXNS
FROM cust c
CROSS JOIN days d
LEFT JOIN spend s ON s.CUSTOMER_ID = c.CUSTOMER_ID AND s.D = d.D;

CREATE OR REPLACE VIEW V_AD_TRAIN AS
SELECT SERIES_KEY, DAY_TS, DAILY_SPEND
FROM ACCEL_DB.FRAUD.V_AD_DAILY
WHERE DAY_TS < (SELECT DETECT_FROM FROM ACCEL_DB.FRAUD.FRAUD_CONFIG);

CREATE OR REPLACE VIEW V_AD_DETECT AS
SELECT SERIES_KEY, DAY_TS, DAILY_SPEND
FROM ACCEL_DB.FRAUD.V_AD_DAILY
WHERE DAY_TS >= (SELECT DETECT_FROM FROM ACCEL_DB.FRAUD.FRAUD_CONFIG);

SELECT COUNT(DISTINCT SERIES_KEY) AS SERIES, MIN(DAY_TS) AS TRAIN_FROM, MAX(DAY_TS) AS TRAIN_TO, COUNT(*) AS TRAIN_ROWS
FROM V_AD_TRAIN;

------------------------------------------------------------------------------
-- 2. Train (unsupervised: LABEL_COLNAME => '')
------------------------------------------------------------------------------
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION FRAUD_SPEND_AD(
    INPUT_DATA        => TABLE(ACCEL_DB.FRAUD.V_AD_TRAIN),
    SERIES_COLNAME    => 'SERIES_KEY',
    TIMESTAMP_COLNAME => 'DAY_TS',
    TARGET_COLNAME    => 'DAILY_SPEND',
    LABEL_COLNAME     => ''
);

------------------------------------------------------------------------------
-- 3. Detect on the detection window and keep the results
------------------------------------------------------------------------------
CALL FRAUD_SPEND_AD!DETECT_ANOMALIES(
    INPUT_DATA        => TABLE(ACCEL_DB.FRAUD.V_AD_DETECT),
    SERIES_COLNAME    => 'SERIES_KEY',
    TIMESTAMP_COLNAME => 'DAY_TS',
    TARGET_COLNAME    => 'DAILY_SPEND',
    CONFIG_OBJECT     => {'prediction_interval': 0.99}     -- EDIT ME: higher = fewer, stronger anomalies
);

CREATE OR REPLACE TABLE AD_RESULTS AS
SELECT SERIES::NUMBER       AS CUSTOMER_ID,
       TS::DATE             AS SPEND_DATE,
       Y                    AS DAILY_SPEND,
       FORECAST,
       LOWER_BOUND,
       UPPER_BOUND,
       IS_ANOMALY,
       PERCENTILE,
       DISTANCE,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS DETECTED_AT
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

------------------------------------------------------------------------------
-- 4. Results and evaluation vs injected fraud
------------------------------------------------------------------------------
SELECT COUNT(*) AS CARDHOLDER_DAYS, COUNT_IF(IS_ANOMALY) AS ANOMALIES,
       COUNT(DISTINCT IFF(IS_ANOMALY, CUSTOMER_ID, NULL)) AS CARDHOLDERS_WITH_ANOMALY
FROM AD_RESULTS;

-- Anomalous days (only spend ABOVE the expected band matters for fraud)
WITH inj AS (
    SELECT CUSTOMER_ID, TXN_TS::DATE AS D, LISTAGG(DISTINCT FRAUD_PATTERN, ', ') AS INJECTED_PATTERN
    FROM CARD_TRANSACTIONS
    WHERE IS_FRAUD_INJECTED
    GROUP BY 1, 2
)
SELECT a.CUSTOMER_ID, a.SPEND_DATE, ROUND(a.DAILY_SPEND, 2) AS DAILY_SPEND,
       ROUND(a.FORECAST, 2) AS FORECAST, ROUND(a.UPPER_BOUND, 2) AS UPPER_BOUND, ROUND(a.DISTANCE, 2) AS DISTANCE,
       i.INJECTED_PATTERN
FROM AD_RESULTS a
LEFT JOIN inj i ON i.CUSTOMER_ID = a.CUSTOMER_ID AND i.D = a.SPEND_DATE
WHERE a.IS_ANOMALY AND a.DAILY_SPEND > a.UPPER_BOUND
ORDER BY a.DISTANCE DESC
LIMIT 25;

-- Inspect the model
CALL FRAUD_SPEND_AD!SHOW_TRAINING_LOGS();
