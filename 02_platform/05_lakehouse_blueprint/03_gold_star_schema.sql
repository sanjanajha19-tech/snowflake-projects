/* =============================================================================
   05 LAKEHOUSE BLUEPRINT | 03_gold_star_schema.sql
   GOLD = star schema for BI / semantic views / Cortex Analyst.
   Dimensions: DIM_DATE (static table), DIM_CUSTOMER, DIM_PRODUCT, DIM_PLANT
   Facts:      FACT_SALES (order line), FACT_INVENTORY (weekly snapshot), FACT_GL (journal line)
   Amounts are in transaction currency (CURRENCY column); add an FX table to convert.
   Run as: ACCEL_ADMIN.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS GOLD;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------------
-- DIM_DATE: static calendar 2023-01-01 .. 2027-12-31 (Indian fiscal year Apr-Mar)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE DIM_DATE AS
WITH d AS (
  SELECT DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2023-01-01'::DATE) AS CAL_DATE
  FROM TABLE(GENERATOR(ROWCOUNT => 1826))
)
SELECT
  (YEAR(CAL_DATE) * 10000 + MONTH(CAL_DATE) * 100 + DAY(CAL_DATE))::NUMBER(8,0) AS DATE_KEY,
  CAL_DATE,
  YEAR(CAL_DATE)                         AS CAL_YEAR,
  QUARTER(CAL_DATE)                      AS CAL_QUARTER,
  MONTH(CAL_DATE)                        AS CAL_MONTH,
  MONTHNAME(CAL_DATE)                    AS MONTH_NAME,
  TO_CHAR(CAL_DATE, 'YYYY-MM')           AS YEAR_MONTH,
  DATE_TRUNC('MONTH', CAL_DATE)          AS MONTH_START,
  WEEKOFYEAR(CAL_DATE)                   AS WEEK_OF_YEAR,
  DAYOFWEEKISO(CAL_DATE)                 AS DAY_OF_WEEK_ISO,
  DAYNAME(CAL_DATE)                      AS DAY_NAME,
  DAYOFWEEKISO(CAL_DATE) IN (6, 7)       AS IS_WEEKEND,
  IFF(MONTH(CAL_DATE) >= 4, YEAR(CAL_DATE) + 1, YEAR(CAL_DATE)) AS FISCAL_YEAR,      -- EDIT ME: fiscal calendar
  CEIL(IFF(MONTH(CAL_DATE) >= 4, MONTH(CAL_DATE) - 3, MONTH(CAL_DATE) + 9) / 3)  AS FISCAL_QUARTER
FROM d;

ALTER TABLE DIM_DATE ADD PRIMARY KEY (DATE_KEY);

-- ---------------------------------------------------------------------------
-- Dimensions (Type 1)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE DIM_CUSTOMER
  TARGET_LAG = '1 hour'          -- EDIT ME: freshness SLA
  WAREHOUSE = ACCEL_WH
AS
SELECT CUSTOMER_SK, CUSTOMER_ID, CUSTOMER_NAME, SEGMENT, INDUSTRY, REGION, COUNTRY, COUNTRY_CODE,
       CITY, EMAIL, PHONE, CREATED_DATE, CREDIT_LIMIT,
       CASE WHEN CREDIT_LIMIT >= 500000 THEN 'High'
            WHEN CREDIT_LIMIT >= 100000 THEN 'Medium' ELSE 'Low' END AS CREDIT_BAND
FROM ACCEL_DB.SILVER.SLV_CUSTOMERS;

CREATE OR REPLACE DYNAMIC TABLE DIM_PRODUCT
  TARGET_LAG = '1 hour'
  WAREHOUSE = ACCEL_WH
AS
SELECT PRODUCT_SK, PRODUCT_ID, SKU, PRODUCT_NAME, CATEGORY, SUB_CATEGORY, BRAND,
       UNIT_COST, LIST_PRICE, STD_MARGIN,
       ROUND(STD_MARGIN / NULLIF(LIST_PRICE, 0) * 100, 2) AS STD_MARGIN_PCT,
       LAUNCH_DATE
FROM ACCEL_DB.SILVER.SLV_PRODUCTS;

CREATE OR REPLACE DYNAMIC TABLE DIM_PLANT
  TARGET_LAG = '1 hour'
  WAREHOUSE = ACCEL_WH
AS
SELECT PLANT_SK, PLANT_ID, PLANT_NAME, CITY, COUNTRY, CAPACITY_UNITS_PER_DAY
FROM ACCEL_DB.SILVER.SLV_PLANTS;

-- ---------------------------------------------------------------------------
-- FACT_SALES: grain = order line
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE FACT_SALES
  TARGET_LAG = '1 hour'
  WAREHOUSE = ACCEL_WH
AS
SELECT
  l.ORDER_LINE_SK,
  l.ORDER_ID,
  l.LINE_NO,
  (YEAR(o.ORDER_DATE) * 10000 + MONTH(o.ORDER_DATE) * 100 + DAY(o.ORDER_DATE))::NUMBER(8,0) AS DATE_KEY,
  o.ORDER_DATE,
  MD5(TO_VARCHAR(o.CUSTOMER_ID))            AS CUSTOMER_SK,
  MD5(TO_VARCHAR(l.PRODUCT_ID))             AS PRODUCT_SK,
  MD5(TO_VARCHAR(o.PLANT_ID))               AS PLANT_SK,
  o.CHANNEL,
  o.ORDER_STATUS,
  o.IS_REVENUE_RECOGNISED,
  o.CURRENCY,
  l.QUANTITY,
  l.UNIT_PRICE,
  l.DISCOUNT_PCT,
  (l.QUANTITY * l.UNIT_PRICE)::NUMBER(14,2) AS GROSS_AMOUNT,
  l.NET_AMOUNT,
  (l.QUANTITY * p.UNIT_COST)::NUMBER(14,2)  AS COST_AMOUNT,
  (l.NET_AMOUNT - l.QUANTITY * p.UNIT_COST)::NUMBER(14,2) AS MARGIN_AMOUNT
FROM ACCEL_DB.SILVER.SLV_ORDER_LINES l
JOIN ACCEL_DB.SILVER.SLV_ORDERS o   ON o.ORDER_ID = l.ORDER_ID
LEFT JOIN ACCEL_DB.SILVER.SLV_PRODUCTS p ON p.PRODUCT_ID = l.PRODUCT_ID;

-- ---------------------------------------------------------------------------
-- FACT_INVENTORY: grain = snapshot date x plant x product
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE FACT_INVENTORY
  TARGET_LAG = '1 hour'
  WAREHOUSE = ACCEL_WH
AS
SELECT
  (YEAR(i.SNAPSHOT_DATE) * 10000 + MONTH(i.SNAPSHOT_DATE) * 100 + DAY(i.SNAPSHOT_DATE))::NUMBER(8,0) AS DATE_KEY,
  i.SNAPSHOT_DATE,
  MD5(TO_VARCHAR(i.PLANT_ID))               AS PLANT_SK,
  MD5(TO_VARCHAR(i.PRODUCT_ID))             AS PRODUCT_SK,
  i.ON_HAND_QTY,
  i.REORDER_POINT,
  i.SAFETY_STOCK,
  (i.ON_HAND_QTY * p.UNIT_COST)::NUMBER(16,2) AS INVENTORY_VALUE,
  i.ON_HAND_QTY < i.REORDER_POINT           AS IS_BELOW_REORDER_POINT,
  i.ON_HAND_QTY < i.SAFETY_STOCK            AS IS_BELOW_SAFETY_STOCK
FROM ACCEL_DB.SILVER.SLV_INVENTORY_SNAPSHOTS i
LEFT JOIN ACCEL_DB.SILVER.SLV_PRODUCTS p ON p.PRODUCT_ID = i.PRODUCT_ID;

-- ---------------------------------------------------------------------------
-- FACT_GL: grain = journal line (debit +, credit -)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE FACT_GL
  TARGET_LAG = '1 hour'
  WAREHOUSE = ACCEL_WH
AS
SELECT
  JOURNAL_ID,
  LINE_NO,
  (YEAR(POSTING_DATE) * 10000 + MONTH(POSTING_DATE) * 100 + DAY(POSTING_DATE))::NUMBER(8,0) AS DATE_KEY,
  POSTING_DATE,
  ENTITY,
  ACCOUNT_CODE,
  ACCOUNT_NAME,
  ACCOUNT_TYPE,
  COST_CENTER,
  CURRENCY,
  SOURCE,
  AMOUNT,
  DEBIT_AMOUNT,
  CREDIT_AMOUNT,
  -- P&L sign convention: revenue positive, costs positive
  CASE WHEN ACCOUNT_TYPE = 'Revenue' THEN -AMOUNT
       WHEN ACCOUNT_TYPE IN ('COGS', 'Opex') THEN AMOUNT
       ELSE 0 END::NUMBER(16,2) AS PNL_AMOUNT
FROM ACCEL_DB.SILVER.SLV_GL_JOURNAL;

SHOW DYNAMIC TABLES IN SCHEMA ACCEL_DB.GOLD;
