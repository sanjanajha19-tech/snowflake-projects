/*=============================================================================
  ASSET 14 - Forecasting & ML Starter
  File 03   : Churn feature engineering (RFM + service signals)
  Creates   : CUSTOMER_FEATURES(AS_OF DATE) table function,
              CHURN_TRAINING_SET (features as of cutoff + label),
              CHURN_SCORING_SET  (features as of latest date, to score)
  Churn def : a customer who ordered in the 365 days before the cutoff and
              places NO Delivered/Shipped order in the 90 days after it.
  Run as    : ACCEL_ADMIN
  Rerun     : safe (CREATE OR REPLACE)
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS ML_STARTER;
USE SCHEMA ML_STARTER;

------------------------------------------------------------------------------
-- 1. Point-in-time feature function (no leakage: only data <= AS_OF)
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION CUSTOMER_FEATURES(AS_OF DATE)
RETURNS TABLE (
    CUSTOMER_ID          NUMBER,
    SEGMENT              VARCHAR,
    REGION               VARCHAR,
    COUNTRY              VARCHAR,
    TENURE_DAYS          FLOAT,
    RECENCY_DAYS         FLOAT,
    FREQUENCY_365D       FLOAT,
    MONETARY_365D        FLOAT,
    AVG_ORDER_VALUE_365D FLOAT,
    ORDERS_90D           FLOAT,
    ORDERS_PRIOR_90D     FLOAT,
    ORDER_TREND_RATIO    FLOAT,
    RETURN_RATE_365D     FLOAT,
    ECOMMERCE_SHARE_365D FLOAT,
    TICKETS_180D         FLOAT,
    ESCALATED_180D       FLOAT,
    CREDIT_LIMIT         FLOAT
)
AS
$$
    WITH o AS (
        SELECT CUSTOMER_ID, ORDER_DATE, STATUS, CHANNEL, ORDER_TOTAL
        FROM ACCEL_DB.DEMO.ORDERS
        WHERE ORDER_DATE <= AS_OF
    ),
    agg AS (
        SELECT CUSTOMER_ID,
               MAX(IFF(STATUS IN ('Delivered', 'Shipped'), ORDER_DATE, NULL))                         AS LAST_ORDER_DATE,
               COUNT_IF(ORDER_DATE > DATEADD('day', -365, AS_OF))                                     AS FREQ_365,
               SUM(IFF(ORDER_DATE > DATEADD('day', -365, AS_OF) AND STATUS IN ('Delivered', 'Shipped'), ORDER_TOTAL, 0)) AS MON_365,
               COUNT_IF(ORDER_DATE > DATEADD('day', -90, AS_OF))                                      AS ORD_90,
               COUNT_IF(ORDER_DATE >  DATEADD('day', -180, AS_OF) AND ORDER_DATE <= DATEADD('day', -90, AS_OF)) AS ORD_PRIOR_90,
               COUNT_IF(ORDER_DATE > DATEADD('day', -365, AS_OF) AND STATUS = 'Returned')             AS RET_365,
               COUNT_IF(ORDER_DATE > DATEADD('day', -365, AS_OF) AND CHANNEL = 'E-commerce')          AS ECOM_365
        FROM o
        GROUP BY CUSTOMER_ID
    ),
    t AS (
        SELECT CUSTOMER_ID,
               COUNT(*)                         AS TICKETS_180,
               COUNT_IF(STATUS = 'Escalated')   AS ESC_180
        FROM ACCEL_DB.DEMO.SUPPORT_TICKETS
        WHERE CREATED_AT::DATE <= AS_OF
          AND CREATED_AT::DATE >  DATEADD('day', -180, AS_OF)
        GROUP BY CUSTOMER_ID
    )
    SELECT c.CUSTOMER_ID,
           c.SEGMENT,
           c.REGION,
           c.COUNTRY,
           DATEDIFF('day', c.CREATED_DATE, AS_OF)::FLOAT,
           COALESCE(DATEDIFF('day', a.LAST_ORDER_DATE, AS_OF), 9999)::FLOAT,
           COALESCE(a.FREQ_365, 0)::FLOAT,
           COALESCE(a.MON_365, 0)::FLOAT,
           (COALESCE(a.MON_365, 0) / NULLIF(a.FREQ_365, 0))::FLOAT,
           COALESCE(a.ORD_90, 0)::FLOAT,
           COALESCE(a.ORD_PRIOR_90, 0)::FLOAT,
           ((COALESCE(a.ORD_90, 0) + 1) / (COALESCE(a.ORD_PRIOR_90, 0) + 1))::FLOAT,
           (COALESCE(a.RET_365, 0) / NULLIF(a.FREQ_365, 0))::FLOAT,
           (COALESCE(a.ECOM_365, 0) / NULLIF(a.FREQ_365, 0))::FLOAT,
           COALESCE(t.TICKETS_180, 0)::FLOAT,
           COALESCE(t.ESC_180, 0)::FLOAT,
           c.CREDIT_LIMIT::FLOAT
    FROM ACCEL_DB.DEMO.CUSTOMERS c
    LEFT JOIN agg a ON a.CUSTOMER_ID = c.CUSTOMER_ID
    LEFT JOIN t     ON t.CUSTOMER_ID = c.CUSTOMER_ID
    WHERE c.CREATED_DATE <= AS_OF
$$;

------------------------------------------------------------------------------
-- 2. Training set: features as of (latest order date - 90 days) + label
------------------------------------------------------------------------------
SET MAX_ORDER_DATE = (SELECT MAX(ORDER_DATE) FROM ACCEL_DB.DEMO.ORDERS);
SET CHURN_WINDOW_DAYS = 90;                                             -- EDIT ME
SET CUTOFF_DATE = (SELECT DATEADD('day', -$CHURN_WINDOW_DAYS, $MAX_ORDER_DATE));

CREATE OR REPLACE TABLE CHURN_TRAINING_SET
  COMMENT = 'Customers active in the 365 days before CUTOFF_DATE with churn label for the next 90 days'
AS
SELECT f.*,
       $CUTOFF_DATE::DATE AS AS_OF_DATE,
       IFF(fut.CUSTOMER_ID IS NULL, 1, 0) AS CHURNED
FROM TABLE(CUSTOMER_FEATURES($CUTOFF_DATE::DATE)) f
LEFT JOIN (
    SELECT DISTINCT CUSTOMER_ID
    FROM ACCEL_DB.DEMO.ORDERS
    WHERE ORDER_DATE >  $CUTOFF_DATE::DATE
      AND ORDER_DATE <= DATEADD('day', $CHURN_WINDOW_DAYS, $CUTOFF_DATE::DATE)
      AND STATUS IN ('Delivered', 'Shipped')
) fut ON fut.CUSTOMER_ID = f.CUSTOMER_ID
WHERE f.FREQUENCY_365D > 0;           -- only customers who were active

------------------------------------------------------------------------------
-- 3. Scoring set: same features as of the latest date (who will churn next?)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE CHURN_SCORING_SET
  COMMENT = 'Active customers with features as of the latest order date, to be scored'
AS
SELECT f.*, $MAX_ORDER_DATE::DATE AS AS_OF_DATE
FROM TABLE(CUSTOMER_FEATURES($MAX_ORDER_DATE::DATE)) f
WHERE f.FREQUENCY_365D > 0;

SELECT COUNT(*) AS CUSTOMERS, SUM(CHURNED) AS CHURNED, ROUND(AVG(CHURNED) * 100, 1) AS CHURN_RATE_PCT
FROM CHURN_TRAINING_SET;

SELECT COUNT(*) AS CUSTOMERS_TO_SCORE FROM CHURN_SCORING_SET;
