/*=============================================================================
  ACCELERATOR 22 - Fraud & Anomaly Detection
  File 01 : Synthetic card transactions with injected fraud patterns
  Creates : schema ACCEL_DB.FRAUD
            - FRAUD_CONFIG        period, training cut-off, thresholds
            - CITY_COORDS         city -> country, latitude, longitude
            - MCC_CATEGORIES      merchant category codes, typical amounts, risk
            - MERCHANTS           25 merchants per category
            - CARD_TRANSACTIONS   ~200,000 transactions, 4 Apr - 30 Sep 2026,
                                  cardholders = ACCEL_DB.DEMO.CUSTOMERS
  Injected fraud (IS_FRAUD_INJECTED = TRUE, FRAUD_PATTERN says which):
     VELOCITY_BURST     8-12 e-commerce purchases within ~30 minutes at night
     IMPOSSIBLE_TRAVEL  card-present purchase abroad 45-150 min after a home purchase
     ODD_MERCHANT       crypto / gambling / money-transfer merchants never used before
     AMOUNT_SPIKE       one purchase 15-40x the cardholder's normal amount
  All injected fraud falls in the last 60 days (the detection window).
  Run as  : ACCEL_ADMIN.  Runtime ~30 s on XSMALL.
  Rerun   : safe (CREATE OR REPLACE; deterministic).
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS FRAUD COMMENT = 'Accelerator 22: fraud and anomaly detection';
USE SCHEMA FRAUD;

------------------------------------------------------------------------------
-- 0. Configuration
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE FRAUD_CONFIG (
    PERIOD_START        DATE,
    PERIOD_DAYS         NUMBER,
    DETECT_FROM         DATE,      -- ML: train before this date, detect from this date
    ML_MIN_TRAIN_TXNS   NUMBER,    -- ML: cardholders with at least this many training transactions
    CASE_MIN_SCORE      NUMBER     -- customer-days at or above this combined score become cases
);
INSERT INTO FRAUD_CONFIG VALUES ('2026-04-04', 180, '2026-08-02', 100, 40);   -- EDIT ME

------------------------------------------------------------------------------
-- 1. Reference data
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE CITY_COORDS (CITY VARCHAR, COUNTRY VARCHAR, LAT FLOAT, LON FLOAT, IS_HOME_MARKET BOOLEAN);
INSERT INTO CITY_COORDS VALUES
  ('Mumbai','India',19.0760,72.8777,TRUE), ('Delhi','India',28.7041,77.1025,TRUE),
  ('Bengaluru','India',12.9716,77.5946,TRUE), ('Chennai','India',13.0827,80.2707,TRUE),
  ('Hyderabad','India',17.3850,78.4867,TRUE), ('Pune','India',18.5204,73.8567,TRUE),
  ('Kolkata','India',22.5726,88.3639,TRUE), ('Ahmedabad','India',23.0225,72.5714,TRUE),
  ('New York','USA',40.7128,-74.0060,TRUE), ('Chicago','USA',41.8781,-87.6298,TRUE),
  ('Houston','USA',29.7604,-95.3698,TRUE), ('San Francisco','USA',37.7749,-122.4194,TRUE),
  ('Atlanta','USA',33.7490,-84.3880,TRUE), ('Seattle','USA',47.6062,-122.3321,TRUE),
  ('Boston','USA',42.3601,-71.0589,TRUE), ('Dallas','USA',32.7767,-96.7970,TRUE),
  ('London','UK',51.5074,-0.1278,TRUE), ('Manchester','UK',53.4808,-2.2426,TRUE),
  ('Birmingham','UK',52.4862,-1.8904,TRUE), ('Leeds','UK',53.8008,-1.5491,TRUE),
  ('Glasgow','UK',55.8642,-4.2518,TRUE), ('Bristol','UK',51.4545,-2.5879,TRUE),
  ('Berlin','Germany',52.5200,13.4050,TRUE), ('Munich','Germany',48.1351,11.5820,TRUE),
  ('Hamburg','Germany',53.5511,9.9937,TRUE), ('Frankfurt','Germany',50.1109,8.6821,TRUE),
  ('Stuttgart','Germany',48.7758,9.1829,TRUE), ('Cologne','Germany',50.9375,6.9603,TRUE),
  ('Tokyo','Japan',35.6762,139.6503,TRUE), ('Osaka','Japan',34.6937,135.5023,TRUE),
  ('Yokohama','Japan',35.4437,139.6380,TRUE), ('Nagoya','Japan',35.1815,136.9066,TRUE),
  ('Fukuoka','Japan',33.5904,130.4017,TRUE), ('Singapore','Singapore',1.3521,103.8198,TRUE),
  -- foreign locations used by injected card-present fraud
  ('Lagos','Nigeria',6.5244,3.3792,FALSE), ('Sao Paulo','Brazil',-23.5505,-46.6333,FALSE),
  ('Bucharest','Romania',44.4268,26.1025,FALSE), ('Dubai','UAE',25.2048,55.2708,FALSE),
  ('Bangkok','Thailand',13.7563,100.5018,FALSE), ('Mexico City','Mexico',19.4326,-99.1332,FALSE);

CREATE OR REPLACE TABLE MCC_CATEGORIES (
    MCC VARCHAR(4), CATEGORY VARCHAR, TYPICAL_AMOUNT_USD NUMBER(10,2), IS_HIGH_RISK BOOLEAN,
    WEIGHT_LO NUMBER, WEIGHT_HI NUMBER      -- share of normal transactions (1-100 range)
);
INSERT INTO MCC_CATEGORIES VALUES
  ('5411','Grocery stores',          45,  FALSE,  1, 24),
  ('5812','Restaurants',             35,  FALSE, 25, 41),
  ('5541','Fuel',                    50,  FALSE, 42, 51),
  ('5912','Pharmacies',              25,  FALSE, 52, 57),
  ('5999','Miscellaneous retail',    60,  FALSE, 58, 67),
  ('5311','Department stores',       80,  FALSE, 68, 74),
  ('4111','Local transport',         15,  FALSE, 75, 83),
  ('4900','Utilities',               90,  FALSE, 84, 88),
  ('5732','Electronics',            250,  FALSE, 89, 92),
  ('7011','Hotels',                 220,  FALSE, 93, 95),
  ('4511','Airlines',               400,  FALSE, 96, 97),
  ('5942','Book stores',             20,  FALSE, 98, 100),
  ('5944','Jewelry',                600,  FALSE, NULL, NULL),
  ('6051','Crypto / quasi-cash',    900,  TRUE,  NULL, NULL),
  ('7995','Gambling',               300,  TRUE,  NULL, NULL),
  ('4829','Money transfer',         700,  TRUE,  NULL, NULL);

CREATE OR REPLACE TABLE MERCHANTS AS
SELECT TO_NUMBER(m.MCC) * 1000 + k.K AS MERCHANT_ID,
       m.CATEGORY || ' #' || LPAD(TO_VARCHAR(k.K), 2, '0') AS MERCHANT_NAME,
       m.MCC, m.CATEGORY, m.IS_HIGH_RISK
FROM MCC_CATEGORIES m
CROSS JOIN (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS K FROM TABLE(GENERATOR(ROWCOUNT => 25))) k;

------------------------------------------------------------------------------
-- 2. Transactions
------------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE TMP_TXN (
    SRC_KEY VARCHAR, TXN_TS TIMESTAMP_NTZ, CUSTOMER_ID NUMBER, MERCHANT_ID NUMBER, MCC VARCHAR,
    CHANNEL VARCHAR, AMOUNT_USD NUMBER(12,2), TXN_CITY VARCHAR, DEVICE_ID VARCHAR,
    IS_FRAUD_INJECTED BOOLEAN, FRAUD_PATTERN VARCHAR
);

-- Cardholder profile: home city and personal spend factor
CREATE OR REPLACE TEMPORARY TABLE TMP_CARDHOLDERS AS
SELECT c.CUSTOMER_ID, c.CITY AS HOME_CITY, c.COUNTRY AS HOME_COUNTRY,
       0.6 + MOD(ABS(HASH(c.CUSTOMER_ID, 'spend')), 140) / 100 AS SPEND_FACTOR,      -- 0.6 - 2.0
       'DEV-' || TO_VARCHAR(MOD(ABS(HASH(c.CUSTOMER_ID, 'dev')), 9000000) + 1000000) AS HOME_DEVICE,
       MOD(ABS(HASH(c.CUSTOMER_ID, 'fraud')), 1000) AS FRAUD_BUCKET
FROM ACCEL_DB.DEMO.CUSTOMERS c;

-- 2a. Normal behaviour (~198,000). Half of the volume comes from 300
--     high-activity cardholders (IDs 1-300) so their daily spend is a usable
--     time series for ML; the rest is spread over all 5,000.
INSERT INTO TMP_TXN
WITH g AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4())   AS RN,
           UNIFORM(1, 100, RANDOM(2201))         AS R_WHO,
           UNIFORM(1, 300, RANDOM(2202))         AS HEAVY_ID,
           UNIFORM(1, 5000, RANDOM(2203))        AS ANY_ID,
           UNIFORM(0, 179, RANDOM(2204))         AS D_OFF,
           UNIFORM(1, 100, RANDOM(2205))         AS R_HOUR,
           UNIFORM(7, 21, RANDOM(2206))          AS DAY_HOUR,
           UNIFORM(0, 5, RANDOM(2207))           AS NIGHT_HOUR,
           UNIFORM(0, 3599, RANDOM(2208))        AS SECS,
           UNIFORM(1, 100, RANDOM(2209))         AS R_CAT,
           UNIFORM(1, 25, RANDOM(2210))          AS R_MERCH,
           UNIFORM(1, 100, RANDOM(2211))         AS R_CH,
           NORMAL(0, 0.6, RANDOM(2212))          AS Z_AMT
    FROM TABLE(GENERATOR(ROWCOUNT => 198000))
),
p AS (SELECT PERIOD_START FROM FRAUD_CONFIG)
SELECT 'N' || g.RN,
       DATEADD(SECOND, IFF(g.R_HOUR <= 3, g.NIGHT_HOUR, g.DAY_HOUR) * 3600 + g.SECS,
               DATEADD(DAY, g.D_OFF, p.PERIOD_START)::TIMESTAMP_NTZ),
       ch.CUSTOMER_ID,
       TO_NUMBER(m.MCC) * 1000 + g.R_MERCH,
       m.MCC,
       CASE WHEN m.MCC IN ('5541', '4111') THEN IFF(g.R_CH <= 50, 'Contactless', 'POS')
            WHEN g.R_CH <= 30 THEN 'E-commerce'
            WHEN g.R_CH <= 65 THEN 'Contactless'
            ELSE 'POS' END,
       GREATEST(1, ROUND(m.TYPICAL_AMOUNT_USD * ch.SPEND_FACTOR * EXP(g.Z_AMT), 2)),
       ch.HOME_CITY,
       ch.HOME_DEVICE,
       FALSE,
       NULL
FROM g
CROSS JOIN p
JOIN TMP_CARDHOLDERS ch ON ch.CUSTOMER_ID = IFF(g.R_WHO <= 50, g.HEAVY_ID, g.ANY_ID)
JOIN MCC_CATEGORIES m ON g.R_CAT BETWEEN m.WEIGHT_LO AND m.WEIGHT_HI;

-- 2b. VELOCITY_BURST: ~40 cardholders, 8-12 e-commerce purchases in ~30 minutes, 01:00-04:00
INSERT INTO TMP_TXN
WITH v AS (
    SELECT ch.*, 8 + MOD(ABS(HASH(ch.CUSTOMER_ID, 'vn')), 5) AS N_TXN,
           DATEADD(SECOND, 3600 + MOD(ABS(HASH(ch.CUSTOMER_ID, 'vt')), 10800),
                   DATEADD(DAY, 120 + MOD(ABS(HASH(ch.CUSTOMER_ID, 'vd')), 60), p.PERIOD_START)::TIMESTAMP_NTZ) AS T0
    FROM TMP_CARDHOLDERS ch CROSS JOIN FRAUD_CONFIG p
    WHERE ch.FRAUD_BUCKET < 8
),
k AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS K FROM TABLE(GENERATOR(ROWCOUNT => 12)))
SELECT 'V' || v.CUSTOMER_ID || '-' || k.K,
       DATEADD(SECOND, (k.K - 1) * (90 + MOD(ABS(HASH(v.CUSTOMER_ID, k.K)), 150)), v.T0),
       v.CUSTOMER_ID,
       IFF(MOD(k.K, 2) = 0, 5732000, 5999000) + 1 + MOD(ABS(HASH(v.CUSTOMER_ID, 'vm')), 25),
       IFF(MOD(k.K, 2) = 0, '5732', '5999'),
       'E-commerce',
       ROUND(80 + MOD(ABS(HASH(v.CUSTOMER_ID, k.K, 'va')), 32000) / 100, 2),
       v.HOME_CITY,
       'DEV-NEW-' || TO_VARCHAR(MOD(ABS(HASH(v.CUSTOMER_ID, 'nd')), 900000) + 100000),
       TRUE,
       'VELOCITY_BURST'
FROM v JOIN k ON k.K <= v.N_TXN;

-- 2c. IMPOSSIBLE_TRAVEL: ~40 cardholders; a genuine home purchase, then a
--     card-present purchase in a foreign city 45-150 minutes later
INSERT INTO TMP_TXN
WITH t AS (
    SELECT ch.*,
           DATEADD(SECOND, 36000 + MOD(ABS(HASH(ch.CUSTOMER_ID, 'tt')), 28800),
                   DATEADD(DAY, 120 + MOD(ABS(HASH(ch.CUSTOMER_ID, 'td')), 60), p.PERIOD_START)::TIMESTAMP_NTZ) AS T0,
           DECODE(MOD(ABS(HASH(ch.CUSTOMER_ID, 'tc')), 6), 0, 'Lagos', 1, 'Sao Paulo', 2, 'Bucharest',
                  3, 'Dubai', 4, 'Bangkok', 'Mexico City') AS FOREIGN_CITY
    FROM TMP_CARDHOLDERS ch CROSS JOIN FRAUD_CONFIG p
    WHERE ch.FRAUD_BUCKET BETWEEN 8 AND 15
)
SELECT 'TH' || CUSTOMER_ID, T0, CUSTOMER_ID, 5411000 + 1 + MOD(ABS(HASH(CUSTOMER_ID, 'g')), 25), '5411',
       'Contactless', ROUND(45 * SPEND_FACTOR, 2), HOME_CITY, HOME_DEVICE, FALSE, NULL
FROM t
UNION ALL
SELECT 'TF' || CUSTOMER_ID,
       DATEADD(MINUTE, 45 + MOD(ABS(HASH(CUSTOMER_ID, 'tm')), 105), T0),
       CUSTOMER_ID,
       IFF(MOD(CUSTOMER_ID, 2) = 0, 5944000, 5732000) + 1 + MOD(ABS(HASH(CUSTOMER_ID, 'fm')), 25),
       IFF(MOD(CUSTOMER_ID, 2) = 0, '5944', '5732'),
       'POS',
       ROUND(300 + MOD(ABS(HASH(CUSTOMER_ID, 'fa')), 120000) / 100, 2),
       FOREIGN_CITY,
       NULL,
       TRUE,
       'IMPOSSIBLE_TRAVEL'
FROM t;

-- 2d. ODD_MERCHANT: ~60 cardholders, two purchases at high-risk MCCs they never used
INSERT INTO TMP_TXN
WITH o AS (
    SELECT ch.*,
           DECODE(MOD(ABS(HASH(ch.CUSTOMER_ID, 'om')), 3), 0, '6051', 1, '7995', '4829') AS MCC,
           DATEADD(SECOND, MOD(ABS(HASH(ch.CUSTOMER_ID, 'ot')), 86400),
                   DATEADD(DAY, 120 + MOD(ABS(HASH(ch.CUSTOMER_ID, 'od')), 59), p.PERIOD_START)::TIMESTAMP_NTZ) AS T0
    FROM TMP_CARDHOLDERS ch CROSS JOIN FRAUD_CONFIG p
    WHERE ch.FRAUD_BUCKET BETWEEN 16 AND 27
),
k AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS K FROM TABLE(GENERATOR(ROWCOUNT => 2)))
SELECT 'O' || o.CUSTOMER_ID || '-' || k.K,
       DATEADD(MINUTE, (k.K - 1) * (20 + MOD(ABS(HASH(o.CUSTOMER_ID, 'og')), 600)), o.T0),
       o.CUSTOMER_ID,
       TO_NUMBER(o.MCC) * 1000 + 1 + MOD(ABS(HASH(o.CUSTOMER_ID, 'omm')), 25),
       o.MCC,
       'E-commerce',
       ROUND(500 + MOD(ABS(HASH(o.CUSTOMER_ID, k.K, 'oa')), 250000) / 100, 2),
       o.HOME_CITY,
       o.HOME_DEVICE,
       TRUE,
       'ODD_MERCHANT'
FROM o CROSS JOIN k;

-- 2e. AMOUNT_SPIKE: ~70 cardholders (about half of them high-activity), one
--     purchase at 15-40x their normal retail amount
INSERT INTO TMP_TXN
WITH s AS (
    SELECT ch.*,
           DATEADD(SECOND, 32400 + MOD(ABS(HASH(ch.CUSTOMER_ID, 'st')), 43200),
                   DATEADD(DAY, 120 + MOD(ABS(HASH(ch.CUSTOMER_ID, 'sd')), 60), p.PERIOD_START)::TIMESTAMP_NTZ) AS T0
    FROM TMP_CARDHOLDERS ch CROSS JOIN FRAUD_CONFIG p
    WHERE ch.FRAUD_BUCKET BETWEEN 28 AND 39
       OR (ch.CUSTOMER_ID <= 300 AND MOD(ABS(HASH(ch.CUSTOMER_ID, 'spk')), 10) = 0)
)
SELECT 'S' || CUSTOMER_ID, T0, CUSTOMER_ID,
       IFF(MOD(CUSTOMER_ID, 3) = 0, 5944000, 5732000) + 1 + MOD(ABS(HASH(CUSTOMER_ID, 'sm')), 25),
       IFF(MOD(CUSTOMER_ID, 3) = 0, '5944', '5732'),
       IFF(MOD(CUSTOMER_ID, 2) = 0, 'E-commerce', 'POS'),
       ROUND(60 * SPEND_FACTOR * (15 + MOD(ABS(HASH(CUSTOMER_ID, 'sx')), 26)), 2),
       HOME_CITY,
       IFF(MOD(CUSTOMER_ID, 2) = 0, HOME_DEVICE, NULL),
       TRUE,
       'AMOUNT_SPIKE'
FROM s;

-- 2f. Final table: sequential TXN_ID in time order, location from CITY_COORDS
CREATE OR REPLACE TABLE CARD_TRANSACTIONS (
    TXN_ID            NUMBER,
    TXN_TS            TIMESTAMP_NTZ,
    CUSTOMER_ID       NUMBER,
    CARD_ID           VARCHAR,
    MERCHANT_ID       NUMBER,
    MERCHANT_NAME     VARCHAR,
    MCC               VARCHAR(4),
    MERCHANT_CATEGORY VARCHAR,
    CHANNEL           VARCHAR,       -- POS | Contactless | E-commerce
    AMOUNT_USD        NUMBER(12,2),
    TXN_CITY          VARCHAR,
    TXN_COUNTRY       VARCHAR,
    LAT               FLOAT,
    LON               FLOAT,
    DEVICE_ID         VARCHAR,       -- e-commerce device fingerprint (NULL for card-present)
    IS_FRAUD_INJECTED BOOLEAN,       -- ground truth for evaluation only - never used by the detectors
    FRAUD_PATTERN     VARCHAR
) COMMENT = 'Synthetic card transactions with injected fraud (Accelerator 22)';

INSERT INTO CARD_TRANSACTIONS
SELECT ROW_NUMBER() OVER (ORDER BY t.TXN_TS, t.CUSTOMER_ID, t.SRC_KEY)   AS TXN_ID,
       t.TXN_TS,
       t.CUSTOMER_ID,
       'CARD-' || LPAD(TO_VARCHAR(t.CUSTOMER_ID), 6, '0'),
       t.MERCHANT_ID,
       m.MERCHANT_NAME,
       t.MCC,
       m.CATEGORY,
       t.CHANNEL,
       t.AMOUNT_USD,
       t.TXN_CITY,
       c.COUNTRY,
       ROUND(c.LAT + (MOD(ABS(HASH(t.SRC_KEY, 'la')), 200) - 100) / 2000, 5),   -- +/- 0.05 deg jitter
       ROUND(c.LON + (MOD(ABS(HASH(t.SRC_KEY, 'lo')), 200) - 100) / 2000, 5),
       IFF(t.CHANNEL = 'E-commerce', t.DEVICE_ID, NULL),
       t.IS_FRAUD_INJECTED,
       t.FRAUD_PATTERN
FROM TMP_TXN t
JOIN MERCHANTS m ON m.MERCHANT_ID = t.MERCHANT_ID
JOIN CITY_COORDS c ON c.CITY = t.TXN_CITY;

------------------------------------------------------------------------------
-- 3. Checks
------------------------------------------------------------------------------
SELECT COUNT(*) AS TXNS, COUNT(DISTINCT CUSTOMER_ID) AS CARDHOLDERS,
       MIN(TXN_TS) AS FIRST_TXN, MAX(TXN_TS) AS LAST_TXN,
       COUNT_IF(IS_FRAUD_INJECTED) AS FRAUD_TXNS
FROM CARD_TRANSACTIONS;

SELECT FRAUD_PATTERN, COUNT(*) AS TXNS, COUNT(DISTINCT CUSTOMER_ID) AS CARDHOLDERS, ROUND(SUM(AMOUNT_USD)) AS USD
FROM CARD_TRANSACTIONS WHERE IS_FRAUD_INJECTED GROUP BY 1 ORDER BY 1;
