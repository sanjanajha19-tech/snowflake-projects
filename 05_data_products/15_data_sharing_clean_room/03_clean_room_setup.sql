/*=============================================================================
  ACCELERATOR 15 - Data Sharing & Clean Room
  File 03 : Lightweight two-party clean room (single-account demo)
            Party A = BRAND    (e.g. a consumer-goods manufacturer)
            Party B = RETAILER (e.g. a supermarket chain)
            Both upload customer lists keyed on a salted SHA-256 of the
            normalised e-mail. Neither party can see row-level data of the other;
            only approved aggregate analyses are allowed.
  Creates : schema ACCEL_DB.CLEANROOM
            - BRAND_CUSTOMERS, RETAILER_CUSTOMERS      (hashed identifiers)
            - CR_AGG_POLICY       aggregation policy (MIN_GROUP_SIZE)
            - CR_HASH_PROJ_POLICY projection policy on HASHED_EMAIL
            - V_APPROVED_OVERLAP_SUMMARY, V_APPROVED_OVERLAP_BY_SEGMENT,
              V_APPROVED_OVERLAP_BY_CATEGORY_AFFINITY  (approved analyses)
            - APPROVED_OVERLAP_FOR_REGION(region)      (approved secure UDTF)
  Roles   : ACCEL_ADMIN = clean-room operator (unrestricted, sets up policies)
            ACCEL_ANALYST = the analyst of the collaborating party (restricted)
  Run as  : ACCOUNTADMIN for two policy grants, then ACCEL_ADMIN.
  Rerun   : safe (tables are recreated first, which detaches old policies).
=============================================================================*/

-- ACCOUNTADMIN: APPLY AGGREGATION / PROJECTION POLICY are account-level privileges
USE ROLE ACCOUNTADMIN;
GRANT APPLY AGGREGATION POLICY ON ACCOUNT TO ROLE ACCEL_ADMIN;
GRANT APPLY PROJECTION POLICY  ON ACCOUNT TO ROLE ACCEL_ADMIN;

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS CLEANROOM COMMENT = 'Accelerator 15: lightweight two-party clean room demo';
USE SCHEMA CLEANROOM;

------------------------------------------------------------------------------
-- 0. Shared salt agreed by both parties (exchanged out of band in real life)
------------------------------------------------------------------------------
SET CR_SALT = 'accel-cleanroom-2026';   -- EDIT ME: agree a secret salt with the other party

------------------------------------------------------------------------------
-- 1. Party A: BRAND customer list
--    ~70% of DEMO customers (CUSTOMER_ID mod 10 in 0..6) + 1,500 brand-only fans
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE BRAND_CUSTOMERS (
    HASHED_EMAIL     VARCHAR(64)  COMMENT 'SHA2-256 of salt || lower(trim(email))',
    AGE_BAND         VARCHAR,
    LOYALTY_TIER     VARCHAR      COMMENT 'Bronze / Silver / Gold / Platinum',
    CATEGORY_AFFINITY VARCHAR     COMMENT 'Product category the brand sees the customer engage with most',
    OPTED_IN_MARKETING BOOLEAN,
    LOADED_AT        TIMESTAMP_NTZ
) COMMENT = 'Clean room - BRAND party customer list (hashed identifiers only)';

INSERT INTO BRAND_CUSTOMERS
WITH cats AS (
    SELECT CATEGORY, ROW_NUMBER() OVER (ORDER BY CATEGORY) - 1 AS IDX, COUNT(*) OVER () AS N
    FROM (SELECT DISTINCT CATEGORY FROM ACCEL_DB.DEMO.PRODUCTS)
),
src AS (
    SELECT LOWER(TRIM(EMAIL)) AS EMAIL_NORM, CUSTOMER_ID AS K
    FROM ACCEL_DB.DEMO.CUSTOMERS
    WHERE MOD(CUSTOMER_ID, 10) BETWEEN 0 AND 6
    UNION ALL
    SELECT 'brandfan' || SEQ4() || '@example.com', 100000 + SEQ4()
    FROM TABLE(GENERATOR(ROWCOUNT => 1500))
)
SELECT
    SHA2($CR_SALT || s.EMAIL_NORM, 256),
    DECODE(MOD(ABS(HASH(s.K, 'age')), 5), 0, '18-24', 1, '25-34', 2, '35-44', 3, '45-54', '55+'),
    DECODE(MOD(ABS(HASH(s.K, 'tier')), 10), 0, 'Platinum', 1, 'Gold', 2, 'Gold', 3, 'Silver', 4, 'Silver', 5, 'Silver', 'Bronze'),
    c.CATEGORY,
    MOD(ABS(HASH(s.K, 'optin')), 10) < 8,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM src s
JOIN cats c ON c.IDX = MOD(ABS(HASH(s.K, 'cat')), c.N);

------------------------------------------------------------------------------
-- 2. Party B: RETAILER customer list with spend
--    ~70% of DEMO customers (CUSTOMER_ID mod 10 in 3..9) + 2,000 retail-only shoppers
--    -> true overlap = CUSTOMER_ID mod 10 in 3..6 (about 40% of DEMO customers)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE RETAILER_CUSTOMERS (
    HASHED_EMAIL     VARCHAR(64)  COMMENT 'SHA2-256 of salt || lower(trim(email))',
    STORE_REGION     VARCHAR,
    PREFERRED_CHANNEL VARCHAR,
    VISITS_12M       NUMBER,
    SPEND_12M        NUMBER(14,2),
    LOADED_AT        TIMESTAMP_NTZ
) COMMENT = 'Clean room - RETAILER party customer list (hashed identifiers only)';

INSERT INTO RETAILER_CUSTOMERS
WITH spend AS (
    SELECT CUSTOMER_ID, COUNT(*) AS N_ORDERS, SUM(ORDER_TOTAL) AS TOTAL
    FROM ACCEL_DB.DEMO.ORDERS
    WHERE ORDER_DATE >= DATEADD(MONTH, -12, '2026-09-30'::DATE)
      AND STATUS IN ('Delivered', 'Shipped')
    GROUP BY CUSTOMER_ID
),
src AS (
    SELECT LOWER(TRIM(c.EMAIL)) AS EMAIL_NORM, c.CUSTOMER_ID AS K, c.REGION,
           COALESCE(s.N_ORDERS, 0) AS N_ORDERS, COALESCE(s.TOTAL, 0) AS TOTAL
    FROM ACCEL_DB.DEMO.CUSTOMERS c
    LEFT JOIN spend s ON s.CUSTOMER_ID = c.CUSTOMER_ID
    WHERE MOD(c.CUSTOMER_ID, 10) BETWEEN 3 AND 9
    UNION ALL
    SELECT 'shopper' || SEQ4() || '@example.org', 200000 + SEQ4(),
           DECODE(MOD(SEQ4(), 5), 0, 'North', 1, 'South', 2, 'East', 3, 'West', 'Central'),
           UNIFORM(1, 30, RANDOM(15)), UNIFORM(50, 5000, RANDOM(16))
    FROM TABLE(GENERATOR(ROWCOUNT => 2000))
)
SELECT
    SHA2($CR_SALT || EMAIL_NORM, 256),
    REGION,
    DECODE(MOD(ABS(HASH(K, 'ch')), 3), 0, 'In-store', 1, 'Online', 'Click & Collect'),
    N_ORDERS + MOD(ABS(HASH(K, 'v')), 12),
    ROUND(TOTAL / 10 + MOD(ABS(HASH(K, 's')), 400), 2),   -- retailer basket spend on the brand's categories
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM src;

------------------------------------------------------------------------------
-- 3. Policies
--    Aggregation policy: non-operator roles must aggregate, min 25 rows per group.
--    Groups below the threshold are folded into a remainder group (NULL keys).
--    Projection policy: HASHED_EMAIL can be used to JOIN / filter, never SELECTed.
------------------------------------------------------------------------------
CREATE OR REPLACE AGGREGATION POLICY CR_AGG_POLICY
  AS () RETURNS AGGREGATION_CONSTRAINT ->
    CASE
      WHEN CURRENT_ROLE() IN ('ACCEL_ADMIN', 'ACCOUNTADMIN') THEN NO_AGGREGATION_CONSTRAINT()
      ELSE AGGREGATION_CONSTRAINT(MIN_GROUP_SIZE => 25)          -- EDIT ME: minimum group size
    END
  COMMENT = 'Clean room: collaborating analysts only see aggregates of >= 25 people';

CREATE OR REPLACE PROJECTION POLICY CR_HASH_PROJ_POLICY
  AS () RETURNS PROJECTION_CONSTRAINT ->
    CASE
      WHEN CURRENT_ROLE() IN ('ACCEL_ADMIN', 'ACCOUNTADMIN') THEN PROJECTION_CONSTRAINT(ALLOW => true)
      ELSE PROJECTION_CONSTRAINT(ALLOW => false)
    END
  COMMENT = 'Clean room: hashed identifiers may be joined on but never returned';

ALTER TABLE BRAND_CUSTOMERS    SET AGGREGATION POLICY CR_AGG_POLICY;
ALTER TABLE RETAILER_CUSTOMERS SET AGGREGATION POLICY CR_AGG_POLICY;
ALTER TABLE BRAND_CUSTOMERS    MODIFY COLUMN HASHED_EMAIL SET PROJECTION POLICY CR_HASH_PROJ_POLICY;
ALTER TABLE RETAILER_CUSTOMERS MODIFY COLUMN HASHED_EMAIL SET PROJECTION POLICY CR_HASH_PROJ_POLICY;

------------------------------------------------------------------------------
-- 4. Approved analyses (the "templates" both parties signed off)
--    Every one aggregates. For collaborating roles the aggregation policy
--    folds any group smaller than MIN_GROUP_SIZE into a remainder row
--    (NULL group keys), so small cells are never exposed.
------------------------------------------------------------------------------
-- Note: queries on aggregation-constrained tables may not use CAST / :: in the
-- SELECT list (only TRY_ functions), window functions, or set operators other
-- than UNION ALL - so the approved analyses return plain aggregates.
CREATE OR REPLACE SECURE VIEW V_APPROVED_OVERLAP_SUMMARY
  COMMENT = 'Approved analysis: audience sizes and overlap (one row per metric)'
AS
SELECT 1 AS SORT_ORDER, 'Brand audience' AS METRIC, COUNT(*) AS CUSTOMERS, NULL AS SPEND_12M
FROM ACCEL_DB.CLEANROOM.BRAND_CUSTOMERS
UNION ALL
SELECT 2, 'Retailer audience', COUNT(*), SUM(SPEND_12M)
FROM ACCEL_DB.CLEANROOM.RETAILER_CUSTOMERS
UNION ALL
SELECT 3, 'Overlap (in both lists)', COUNT(*), SUM(rc.SPEND_12M)
FROM ACCEL_DB.CLEANROOM.BRAND_CUSTOMERS bc
JOIN ACCEL_DB.CLEANROOM.RETAILER_CUSTOMERS rc ON rc.HASHED_EMAIL = bc.HASHED_EMAIL;

CREATE OR REPLACE SECURE VIEW V_APPROVED_OVERLAP_BY_SEGMENT
  COMMENT = 'Approved analysis: overlap by brand loyalty tier x retailer store region'
AS
SELECT bc.LOYALTY_TIER,
       rc.STORE_REGION,
       COUNT(*)                         AS OVERLAP_CUSTOMERS,
       SUM(rc.SPEND_12M)                AS TOTAL_SPEND_12M,
       AVG(rc.SPEND_12M)                AS AVG_SPEND_12M,
       AVG(rc.VISITS_12M)               AS AVG_VISITS_12M
FROM ACCEL_DB.CLEANROOM.BRAND_CUSTOMERS bc
JOIN ACCEL_DB.CLEANROOM.RETAILER_CUSTOMERS rc ON rc.HASHED_EMAIL = bc.HASHED_EMAIL
GROUP BY bc.LOYALTY_TIER, rc.STORE_REGION;

CREATE OR REPLACE SECURE VIEW V_APPROVED_OVERLAP_BY_CATEGORY_AFFINITY
  COMMENT = 'Approved analysis: overlap by brand category affinity x retailer channel, opted-in customers only'
AS
SELECT bc.CATEGORY_AFFINITY,
       rc.PREFERRED_CHANNEL,
       COUNT(*)                         AS OVERLAP_CUSTOMERS,
       AVG(rc.SPEND_12M)                AS AVG_SPEND_12M
FROM ACCEL_DB.CLEANROOM.BRAND_CUSTOMERS bc
JOIN ACCEL_DB.CLEANROOM.RETAILER_CUSTOMERS rc ON rc.HASHED_EMAIL = bc.HASHED_EMAIL
WHERE bc.OPTED_IN_MARKETING
GROUP BY bc.CATEGORY_AFFINITY, rc.PREFERRED_CHANNEL;

-- Parameterised approved analysis as a secure SQL table function
CREATE OR REPLACE SECURE FUNCTION APPROVED_OVERLAP_FOR_REGION(P_REGION VARCHAR)
RETURNS TABLE (LOYALTY_TIER VARCHAR, AGE_BAND VARCHAR, OVERLAP_CUSTOMERS NUMBER, AVG_SPEND_12M NUMBER(38,6))
COMMENT = 'Approved analysis: overlap by loyalty tier and age band for one retailer region'
AS
$$
    SELECT bc.LOYALTY_TIER,
           bc.AGE_BAND,
           COUNT(*)                        AS OVERLAP_CUSTOMERS,
           AVG(rc.SPEND_12M)               AS AVG_SPEND_12M
    FROM ACCEL_DB.CLEANROOM.BRAND_CUSTOMERS bc
    JOIN ACCEL_DB.CLEANROOM.RETAILER_CUSTOMERS rc ON rc.HASHED_EMAIL = bc.HASHED_EMAIL
    WHERE rc.STORE_REGION = P_REGION
    GROUP BY bc.LOYALTY_TIER, bc.AGE_BAND
$$;

------------------------------------------------------------------------------
-- 5. Access for the collaborating analyst role
--    (SELECT on the raw tables is granted on purpose: the policies, not the
--     grants, are what stop row-level access - this is what the demo shows.)
------------------------------------------------------------------------------
GRANT USAGE  ON SCHEMA ACCEL_DB.CLEANROOM TO ROLE ACCEL_ANALYST;
GRANT SELECT ON TABLE  ACCEL_DB.CLEANROOM.BRAND_CUSTOMERS    TO ROLE ACCEL_ANALYST;
GRANT SELECT ON TABLE  ACCEL_DB.CLEANROOM.RETAILER_CUSTOMERS TO ROLE ACCEL_ANALYST;
GRANT SELECT ON VIEW   ACCEL_DB.CLEANROOM.V_APPROVED_OVERLAP_SUMMARY              TO ROLE ACCEL_ANALYST;
GRANT SELECT ON VIEW   ACCEL_DB.CLEANROOM.V_APPROVED_OVERLAP_BY_SEGMENT           TO ROLE ACCEL_ANALYST;
GRANT SELECT ON VIEW   ACCEL_DB.CLEANROOM.V_APPROVED_OVERLAP_BY_CATEGORY_AFFINITY TO ROLE ACCEL_ANALYST;
GRANT USAGE  ON FUNCTION ACCEL_DB.CLEANROOM.APPROVED_OVERLAP_FOR_REGION(VARCHAR)  TO ROLE ACCEL_ANALYST;

-- Verify as operator
SELECT 'BRAND' AS PARTY, COUNT(*) AS ROWS_LOADED FROM BRAND_CUSTOMERS
UNION ALL
SELECT 'RETAILER', COUNT(*) FROM RETAILER_CUSTOMERS;

SELECT * FROM V_APPROVED_OVERLAP_SUMMARY ORDER BY SORT_ORDER;
