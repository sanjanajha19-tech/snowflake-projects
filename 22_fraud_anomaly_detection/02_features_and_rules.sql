/*=============================================================================
  ACCELERATOR 22 - Fraud & Anomaly Detection
  File 02 : Behavioural features (window functions) and rule flags
  Creates : FRAUD_RULES          configurable thresholds and weights
            V_TXN_FEATURES       per-transaction features vs the cardholder's own history
            V_TXN_RULE_SCORES    rule flags, score and reasons per transaction
            V_RULE_EVALUATION    precision / recall of each rule vs injected ground truth
  Run as  : ACCEL_ADMIN
  Rerun   : safe. Threshold changes in FRAUD_RULES are kept (MERGE inserts
            missing rules only) and take effect immediately (views).
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS FRAUD;
USE SCHEMA FRAUD;

------------------------------------------------------------------------------
-- 1. Rule configuration
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS FRAUD_RULES (
    RULE_CODE    VARCHAR,
    DESCRIPTION  VARCHAR,
    THRESHOLD_1  FLOAT,
    THRESHOLD_2  FLOAT,
    WEIGHT       NUMBER,
    IS_ACTIVE    BOOLEAN
);

MERGE INTO FRAUD_RULES t
USING (
    SELECT $1 AS RULE_CODE, $2 AS DESCRIPTION, $3 AS THRESHOLD_1, $4 AS THRESHOLD_2, $5 AS WEIGHT
    FROM VALUES
    ('VELOCITY',          'At least THRESHOLD_1 transactions by the cardholder in the last hour',                          5,    NULL, 45),
    ('IMPOSSIBLE_TRAVEL', 'Implied speed since previous transaction above THRESHOLD_1 km/h over more than THRESHOLD_2 km', 900,  500,  45),
    ('NEW_HIGH_RISK_MCC', 'First-ever transaction of the cardholder at a high-risk MCC (crypto, gambling, money transfer)', NULL, NULL, 30),
    ('AMOUNT_SPIKE',      'Amount at least THRESHOLD_1 x the cardholder''s average, with at least THRESHOLD_2 prior txns', 10,   5,    40),
    ('NEW_DEVICE_NIGHT',  'E-commerce at night (00:00-05:59) from a device never seen for this cardholder (THRESHOLD_1 prior txns)', 5, NULL, 15),
    ('FOREIGN_CARD_PRESENT','Card-present transaction outside the cardholder''s home country',                            NULL, NULL, 20)
) s
ON t.RULE_CODE = s.RULE_CODE
WHEN NOT MATCHED THEN INSERT (RULE_CODE, DESCRIPTION, THRESHOLD_1, THRESHOLD_2, WEIGHT, IS_ACTIVE)
VALUES (s.RULE_CODE, s.DESCRIPTION, s.THRESHOLD_1, s.THRESHOLD_2, s.WEIGHT, TRUE);

------------------------------------------------------------------------------
-- 2. Features: everything is relative to the cardholder's own past behaviour
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_TXN_FEATURES
  COMMENT = 'Per-transaction behavioural features computed with window functions'
AS
WITH base AS (
    SELECT t.*,
           c.COUNTRY AS HOME_COUNTRY,
           m.IS_HIGH_RISK AS IS_HIGH_RISK_MCC
    FROM ACCEL_DB.FRAUD.CARD_TRANSACTIONS t
    JOIN ACCEL_DB.DEMO.CUSTOMERS c ON c.CUSTOMER_ID = t.CUSTOMER_ID
    JOIN ACCEL_DB.FRAUD.MCC_CATEGORIES m ON m.MCC = t.MCC
),
w AS (
    SELECT b.*,
           -- velocity
           COUNT(*) OVER (PARTITION BY CUSTOMER_ID ORDER BY TXN_TS
                          RANGE BETWEEN INTERVAL '1 HOUR' PRECEDING AND CURRENT ROW)     AS TXN_COUNT_1H,
           SUM(AMOUNT_USD) OVER (PARTITION BY CUSTOMER_ID ORDER BY TXN_TS
                          RANGE BETWEEN INTERVAL '1 HOUR' PRECEDING AND CURRENT ROW)     AS AMOUNT_1H,
           COUNT(*) OVER (PARTITION BY CUSTOMER_ID ORDER BY TXN_TS
                          RANGE BETWEEN INTERVAL '24 HOURS' PRECEDING AND CURRENT ROW)   AS TXN_COUNT_24H,
           -- previous transaction (travel)
           LAG(TXN_TS)   OVER (PARTITION BY CUSTOMER_ID ORDER BY TXN_TS, TXN_ID)           AS PREV_TS,
           LAG(LAT)      OVER (PARTITION BY CUSTOMER_ID ORDER BY TXN_TS, TXN_ID)           AS PREV_LAT,
           LAG(LON)      OVER (PARTITION BY CUSTOMER_ID ORDER BY TXN_TS, TXN_ID)           AS PREV_LON,
           LAG(TXN_CITY) OVER (PARTITION BY CUSTOMER_ID ORDER BY TXN_TS, TXN_ID)           AS PREV_CITY,
           -- amount baseline from PRIOR transactions only
           COUNT(*) OVER (PARTITION BY CUSTOMER_ID ORDER BY TXN_TS, TXN_ID
                          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)               AS PRIOR_TXNS,
           AVG(AMOUNT_USD) OVER (PARTITION BY CUSTOMER_ID ORDER BY TXN_TS, TXN_ID
                          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)               AS PRIOR_AVG_AMOUNT,
           STDDEV(AMOUNT_USD) OVER (PARTITION BY CUSTOMER_ID ORDER BY TXN_TS, TXN_ID
                          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)               AS PRIOR_STD_AMOUNT,
           -- familiarity with merchant category and device
           COUNT(*) OVER (PARTITION BY CUSTOMER_ID, MCC ORDER BY TXN_TS, TXN_ID
                          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)               AS PRIOR_TXNS_AT_MCC,
           ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID, COALESCE(DEVICE_ID, '-') ORDER BY TXN_TS, TXN_ID) AS DEVICE_SEQ
    FROM base b
)
SELECT w.TXN_ID, w.TXN_TS, w.CUSTOMER_ID, w.CARD_ID, w.MERCHANT_ID, w.MERCHANT_NAME, w.MCC, w.MERCHANT_CATEGORY,
       w.CHANNEL, w.AMOUNT_USD, w.TXN_CITY, w.TXN_COUNTRY, w.LAT, w.LON, w.DEVICE_ID,
       w.HOME_COUNTRY, w.IS_HIGH_RISK_MCC,
       w.TXN_COUNT_1H, w.AMOUNT_1H, w.TXN_COUNT_24H,
       w.PREV_CITY,
       DATEDIFF(MINUTE, w.PREV_TS, w.TXN_TS)                                          AS MINUTES_SINCE_PREV,
       ROUND(HAVERSINE(w.PREV_LAT, w.PREV_LON, w.LAT, w.LON), 1)                      AS KM_FROM_PREV,
       ROUND(HAVERSINE(w.PREV_LAT, w.PREV_LON, w.LAT, w.LON)
             / GREATEST(DATEDIFF(MINUTE, w.PREV_TS, w.TXN_TS), 1) * 60, 0)            AS IMPLIED_KMH,
       w.PRIOR_TXNS,
       ROUND(w.PRIOR_AVG_AMOUNT, 2)                                                   AS PRIOR_AVG_AMOUNT,
       ROUND(w.AMOUNT_USD / NULLIF(w.PRIOR_AVG_AMOUNT, 0), 2)                         AS AMOUNT_RATIO,
       ROUND((w.AMOUNT_USD - w.PRIOR_AVG_AMOUNT) / NULLIF(w.PRIOR_STD_AMOUNT, 0), 2)  AS AMOUNT_ZSCORE,
       w.PRIOR_TXNS_AT_MCC,
       (w.CHANNEL = 'E-commerce' AND w.DEVICE_SEQ = 1)                                AS IS_NEW_DEVICE,
       (HOUR(w.TXN_TS) < 6)                                                           AS IS_NIGHT,
       w.IS_FRAUD_INJECTED,
       w.FRAUD_PATTERN
FROM w;

------------------------------------------------------------------------------
-- 3. Rule flags and transaction score
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_TXN_RULE_SCORES
  COMMENT = 'Rule flags, rule score (0-100) and reasons per transaction'
AS
WITH r AS (
    SELECT
        MAX(IFF(RULE_CODE = 'VELOCITY', THRESHOLD_1, NULL))             AS VEL_N,
        MAX(IFF(RULE_CODE = 'VELOCITY', WEIGHT, NULL))                  AS VEL_W,
        BOOLOR_AGG(RULE_CODE = 'VELOCITY' AND IS_ACTIVE)                AS VEL_ON,
        MAX(IFF(RULE_CODE = 'IMPOSSIBLE_TRAVEL', THRESHOLD_1, NULL))    AS TRV_KMH,
        MAX(IFF(RULE_CODE = 'IMPOSSIBLE_TRAVEL', THRESHOLD_2, NULL))    AS TRV_KM,
        MAX(IFF(RULE_CODE = 'IMPOSSIBLE_TRAVEL', WEIGHT, NULL))         AS TRV_W,
        BOOLOR_AGG(RULE_CODE = 'IMPOSSIBLE_TRAVEL' AND IS_ACTIVE)       AS TRV_ON,
        MAX(IFF(RULE_CODE = 'NEW_HIGH_RISK_MCC', WEIGHT, NULL))         AS MCC_W,
        BOOLOR_AGG(RULE_CODE = 'NEW_HIGH_RISK_MCC' AND IS_ACTIVE)       AS MCC_ON,
        MAX(IFF(RULE_CODE = 'AMOUNT_SPIKE', THRESHOLD_1, NULL))         AS SPK_X,
        MAX(IFF(RULE_CODE = 'AMOUNT_SPIKE', THRESHOLD_2, NULL))         AS SPK_MIN,
        MAX(IFF(RULE_CODE = 'AMOUNT_SPIKE', WEIGHT, NULL))              AS SPK_W,
        BOOLOR_AGG(RULE_CODE = 'AMOUNT_SPIKE' AND IS_ACTIVE)            AS SPK_ON,
        MAX(IFF(RULE_CODE = 'NEW_DEVICE_NIGHT', THRESHOLD_1, NULL))     AS DEV_MIN,
        MAX(IFF(RULE_CODE = 'NEW_DEVICE_NIGHT', WEIGHT, NULL))          AS DEV_W,
        BOOLOR_AGG(RULE_CODE = 'NEW_DEVICE_NIGHT' AND IS_ACTIVE)        AS DEV_ON,
        MAX(IFF(RULE_CODE = 'FOREIGN_CARD_PRESENT', WEIGHT, NULL))      AS FCP_W,
        BOOLOR_AGG(RULE_CODE = 'FOREIGN_CARD_PRESENT' AND IS_ACTIVE)    AS FCP_ON
    FROM ACCEL_DB.FRAUD.FRAUD_RULES
),
f AS (
    SELECT x.*,
           (r.VEL_ON AND x.TXN_COUNT_1H >= r.VEL_N)                                         AS F_VELOCITY,
           (r.TRV_ON AND x.IMPLIED_KMH > r.TRV_KMH AND x.KM_FROM_PREV > r.TRV_KM)          AS F_TRAVEL,
           (r.MCC_ON AND x.IS_HIGH_RISK_MCC AND x.PRIOR_TXNS_AT_MCC = 0)                    AS F_HIGH_RISK_MCC,
           (r.SPK_ON AND x.PRIOR_TXNS >= r.SPK_MIN AND x.AMOUNT_RATIO >= r.SPK_X)           AS F_AMOUNT_SPIKE,
           (r.DEV_ON AND x.IS_NEW_DEVICE AND x.IS_NIGHT AND x.PRIOR_TXNS >= r.DEV_MIN)      AS F_NEW_DEVICE_NIGHT,
           (r.FCP_ON AND x.CHANNEL <> 'E-commerce' AND x.TXN_COUNTRY <> x.HOME_COUNTRY)     AS F_FOREIGN_CP,
           r.VEL_W, r.TRV_W, r.MCC_W, r.SPK_W, r.DEV_W, r.FCP_W
    FROM ACCEL_DB.FRAUD.V_TXN_FEATURES x
    CROSS JOIN r
)
SELECT f.TXN_ID, f.TXN_TS, f.CUSTOMER_ID, f.CARD_ID, f.MERCHANT_NAME, f.MCC, f.MERCHANT_CATEGORY, f.CHANNEL,
       f.AMOUNT_USD, f.TXN_CITY, f.TXN_COUNTRY, f.HOME_COUNTRY, f.LAT, f.LON, f.DEVICE_ID,
       f.TXN_COUNT_1H, f.KM_FROM_PREV, f.MINUTES_SINCE_PREV, f.IMPLIED_KMH, f.PREV_CITY,
       f.PRIOR_TXNS, f.PRIOR_AVG_AMOUNT, f.AMOUNT_RATIO, f.AMOUNT_ZSCORE, f.PRIOR_TXNS_AT_MCC,
       f.F_VELOCITY, f.F_TRAVEL, f.F_HIGH_RISK_MCC, f.F_AMOUNT_SPIKE, f.F_NEW_DEVICE_NIGHT, f.F_FOREIGN_CP,
       LEAST(100,
             IFF(f.F_VELOCITY,         f.VEL_W, 0) + IFF(f.F_TRAVEL,           f.TRV_W, 0)
           + IFF(f.F_HIGH_RISK_MCC,    f.MCC_W, 0) + IFF(f.F_AMOUNT_SPIKE,     f.SPK_W, 0)
           + IFF(f.F_NEW_DEVICE_NIGHT, f.DEV_W, 0) + IFF(f.F_FOREIGN_CP,       f.FCP_W, 0)) AS RULE_SCORE,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
           IFF(f.F_VELOCITY, f.TXN_COUNT_1H || ' txns in 1 hour', NULL),
           IFF(f.F_TRAVEL, ROUND(f.KM_FROM_PREV) || ' km from ' || f.PREV_CITY || ' in '
                           || f.MINUTES_SINCE_PREV || ' min (' || f.IMPLIED_KMH || ' km/h)', NULL),
           IFF(f.F_HIGH_RISK_MCC, 'first ever ' || f.MERCHANT_CATEGORY || ' transaction', NULL),
           IFF(f.F_AMOUNT_SPIKE, 'amount ' || f.AMOUNT_RATIO || 'x usual (avg USD ' || f.PRIOR_AVG_AMOUNT || ')', NULL),
           IFF(f.F_NEW_DEVICE_NIGHT, 'new device at night', NULL),
           IFF(f.F_FOREIGN_CP, 'card present in ' || f.TXN_COUNTRY || ' (home ' || f.HOME_COUNTRY || ')', NULL)
       ), '; ') AS RULE_REASONS,
       f.IS_FRAUD_INJECTED, f.FRAUD_PATTERN
FROM f;

------------------------------------------------------------------------------
-- 4. How good are the rules? (uses the injected ground truth)
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_RULE_EVALUATION AS
WITH s AS (      -- scanned once, reused below
    SELECT F_VELOCITY, F_TRAVEL, F_HIGH_RISK_MCC, F_AMOUNT_SPIKE, F_NEW_DEVICE_NIGHT, F_FOREIGN_CP,
           RULE_SCORE, IS_FRAUD_INJECTED
    FROM ACCEL_DB.FRAUD.V_TXN_RULE_SCORES
),
x AS (
    SELECT 'VELOCITY' AS RULE_CODE, F_VELOCITY AS FLAG, IS_FRAUD_INJECTED FROM s
    UNION ALL SELECT 'IMPOSSIBLE_TRAVEL',       F_TRAVEL,           IS_FRAUD_INJECTED FROM s
    UNION ALL SELECT 'NEW_HIGH_RISK_MCC',       F_HIGH_RISK_MCC,    IS_FRAUD_INJECTED FROM s
    UNION ALL SELECT 'AMOUNT_SPIKE',            F_AMOUNT_SPIKE,     IS_FRAUD_INJECTED FROM s
    UNION ALL SELECT 'NEW_DEVICE_NIGHT',        F_NEW_DEVICE_NIGHT, IS_FRAUD_INJECTED FROM s
    UNION ALL SELECT 'FOREIGN_CARD_PRESENT',    F_FOREIGN_CP,       IS_FRAUD_INJECTED FROM s
    UNION ALL SELECT 'ANY RULE (score >= 30)',  RULE_SCORE >= 30,   IS_FRAUD_INJECTED FROM s
)
SELECT RULE_CODE,
       COUNT_IF(FLAG)                                                       AS FLAGGED,
       COUNT_IF(FLAG AND IS_FRAUD_INJECTED)                                 AS TRUE_POSITIVES,
       ROUND(100 * COUNT_IF(FLAG AND IS_FRAUD_INJECTED) / NULLIF(COUNT_IF(FLAG), 0), 1)          AS PRECISION_PCT,
       ROUND(100 * COUNT_IF(FLAG AND IS_FRAUD_INJECTED) / NULLIF(COUNT_IF(IS_FRAUD_INJECTED), 0), 1) AS RECALL_PCT
FROM x
GROUP BY RULE_CODE;

------------------------------------------------------------------------------
-- 5. Results
------------------------------------------------------------------------------
SELECT * FROM V_RULE_EVALUATION ORDER BY RULE_CODE;

SELECT TXN_ID, TXN_TS, CUSTOMER_ID, MERCHANT_CATEGORY, CHANNEL, AMOUNT_USD, TXN_CITY, RULE_SCORE, RULE_REASONS
FROM V_TXN_RULE_SCORES
WHERE RULE_SCORE > 0
ORDER BY RULE_SCORE DESC, TXN_TS DESC
LIMIT 25;
