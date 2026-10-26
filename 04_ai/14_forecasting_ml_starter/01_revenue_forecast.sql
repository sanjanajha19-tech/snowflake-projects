/*=============================================================================
  ASSET 14 - Forecasting & ML Starter
  File 01   : 90-day daily revenue forecast by region (SNOWFLAKE.ML.FORECAST)
  Creates   : ACCEL_DB.ML_STARTER.DAILY_REVENUE_BY_REGION_V,
              REVENUE_FORECAST_MODEL, REVENUE_FORECAST (table),
              REVENUE_FORECAST_EVAL, REVENUE_FORECAST_FEATURE_IMPORTANCE,
              REVENUE_ACTUAL_VS_FORECAST_V
  Run as    : ACCEL_ADMIN (owns the schema, so it can create ML models)
  Rerun     : safe (CREATE OR REPLACE). Run the whole file top to bottom:
              RESULT_SCAN(LAST_QUERY_ID()) reads the CALL right before it.
  Cost      : training 5 series x ~1,000 days takes ~1-2 min on ACCEL_AI_WH.
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_AI_WH;                 -- ML training runs on the AI warehouse
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS ML_STARTER COMMENT = 'Asset 14: forecasting, anomaly detection, churn model';
USE SCHEMA ML_STARTER;

------------------------------------------------------------------------------
-- 1. Daily revenue by region - dense (every region x every day, 0 if no sales)
--    Revenue = ORDER_TOTAL of Delivered / Shipped orders.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW DAILY_REVENUE_BY_REGION_V
  COMMENT = 'Daily revenue per customer region, zero-filled (forecast input)'
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
regions AS (
    SELECT DISTINCT REGION FROM ACCEL_DB.DEMO.CUSTOMERS
),
actuals AS (
    SELECT o.ORDER_DATE, c.REGION, SUM(o.ORDER_TOTAL) AS REVENUE, COUNT(*) AS ORDERS
    FROM ACCEL_DB.DEMO.ORDERS o
    JOIN ACCEL_DB.DEMO.CUSTOMERS c ON c.CUSTOMER_ID = o.CUSTOMER_ID
    WHERE o.STATUS IN ('Delivered', 'Shipped')
    GROUP BY 1, 2
)
SELECT
    cal.D::TIMESTAMP_NTZ          AS TS,
    r.REGION,
    COALESCE(a.REVENUE, 0)::FLOAT AS REVENUE,
    COALESCE(a.ORDERS, 0)         AS ORDERS
FROM calendar cal
CROSS JOIN regions r
LEFT JOIN actuals a ON a.ORDER_DATE = cal.D AND a.REGION = r.REGION;

-- Training input: only the 3 columns the model needs (no extra features)
CREATE OR REPLACE VIEW REVENUE_FORECAST_TRAIN_V AS
SELECT TS, REGION, REVENUE FROM DAILY_REVENUE_BY_REGION_V;

SELECT REGION, COUNT(*) AS DAYS, MIN(TS) AS FIRST_DAY, MAX(TS) AS LAST_DAY, SUM(REVENUE) AS REVENUE
FROM REVENUE_FORECAST_TRAIN_V GROUP BY REGION ORDER BY REGION;

------------------------------------------------------------------------------
-- 2. Train one multi-series model (one series per region)
------------------------------------------------------------------------------
CREATE OR REPLACE SNOWFLAKE.ML.FORECAST REVENUE_FORECAST_MODEL(
    INPUT_DATA        => TABLE(REVENUE_FORECAST_TRAIN_V),
    SERIES_COLNAME    => 'REGION',
    TIMESTAMP_COLNAME => 'TS',
    TARGET_COLNAME    => 'REVENUE',
    CONFIG_OBJECT     => {'ON_ERROR': 'SKIP'}
);

------------------------------------------------------------------------------
-- 3. Forecast the next 90 days and store the result
------------------------------------------------------------------------------
CALL REVENUE_FORECAST_MODEL!FORECAST(
    FORECASTING_PERIODS => 90,                              -- EDIT ME: horizon (days)
    CONFIG_OBJECT       => {'prediction_interval': 0.9}     -- EDIT ME: interval width
);

CREATE OR REPLACE TABLE REVENUE_FORECAST AS
SELECT SERIES::VARCHAR AS REGION,
       TS,
       GREATEST(FORECAST, 0)    AS FORECAST,
       GREATEST(LOWER_BOUND, 0) AS LOWER_BOUND,
       UPPER_BOUND,
       CURRENT_TIMESTAMP()      AS FORECAST_CREATED_AT
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

------------------------------------------------------------------------------
-- 4. Evaluation metrics (cross-validation run during training) + drivers
------------------------------------------------------------------------------
CALL REVENUE_FORECAST_MODEL!SHOW_EVALUATION_METRICS();

CREATE OR REPLACE TABLE REVENUE_FORECAST_EVAL AS
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

CALL REVENUE_FORECAST_MODEL!EXPLAIN_FEATURE_IMPORTANCE();

CREATE OR REPLACE TABLE REVENUE_FORECAST_FEATURE_IMPORTANCE AS
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- MAPE / MAE per region (pivoted for readability)
SELECT SERIES::VARCHAR AS REGION, ERROR_METRIC, ROUND(METRIC_VALUE, 4) AS METRIC_VALUE
FROM REVENUE_FORECAST_EVAL
WHERE ERROR_METRIC IN ('MAPE', 'MAE', 'SMAPE', 'MSE')
ORDER BY REGION, ERROR_METRIC;

------------------------------------------------------------------------------
-- 5. Actual + forecast in one view (chart in Snowsight: line, X = TS,
--    Y = VALUE, series = REGION + KIND)
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW REVENUE_ACTUAL_VS_FORECAST_V AS
SELECT REGION, TS, 'ACTUAL' AS KIND, REVENUE AS VALUE, NULL AS LOWER_BOUND, NULL AS UPPER_BOUND
FROM DAILY_REVENUE_BY_REGION_V
WHERE TS >= DATEADD('day', -180, (SELECT MAX(TS) FROM DAILY_REVENUE_BY_REGION_V))
UNION ALL
SELECT REGION, TS, 'FORECAST', FORECAST, LOWER_BOUND, UPPER_BOUND
FROM REVENUE_FORECAST;

GRANT USAGE ON SCHEMA ACCEL_DB.ML_STARTER TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA ACCEL_DB.ML_STARTER TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ACCEL_DB.ML_STARTER TO ROLE ACCEL_ANALYST;

-- Forecast summary: next 90 days by region
SELECT REGION,
       ROUND(SUM(FORECAST), 0)    AS FORECAST_90D,
       ROUND(SUM(LOWER_BOUND), 0) AS LOW_90D,
       ROUND(SUM(UPPER_BOUND), 0) AS HIGH_90D
FROM REVENUE_FORECAST
GROUP BY REGION
ORDER BY FORECAST_90D DESC;
