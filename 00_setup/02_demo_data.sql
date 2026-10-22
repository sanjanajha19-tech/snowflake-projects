/*=============================================================================
  ACCELERATOR SETUP 02 - Shared synthetic demo data (ACCEL_DB.DEMO)
  Builds  : CUSTOMERS, PRODUCTS, SUPPLIERS, PLANTS, ORDERS, ORDER_LINES,
            PURCHASE_ORDERS, INVENTORY_SNAPSHOTS, GL_JOURNAL, EMPLOYEES,
            SUPPORT_TICKETS  (Jan 2024 - Sep 2026)
  Run as  : ACCEL_ADMIN (after 01_account_setup.sql). Runtime ~1-3 min on XSMALL.
  Rerun   : safe - every table is CREATE OR REPLACE.
  Determinism: generator tables use RANDOM(<fixed seed>); tables derived from
            joins use HASH(<keys>, <salt>) as the random source, so values do
            not depend on join order.
  Built-in demo patterns:
    * ORDERS: ~30% YoY growth, Q4 peak / Feb trough, quieter weekends,
              E-commerce share growing, South region dips in 2026-Q2.
    * SUPPLIERS: 6 High-risk suppliers deliver late far more often (worse in 2026).
    * INVENTORY: plant 3 runs out of a handful of SKUs from Aug 2026.
    * GL_JOURNAL: balanced journals; Manual anomalies - weekend/late-night
              postings, round amounts, CREATED_BY = APPROVED_BY (~0.5%),
              a few very large adjustments, month-end clustering.
    * SUPPORT_TICKETS: realistic text across 8 topics for AI demos.
  All orders are invoiced in USD; GL is in each entity's local currency.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS DEMO;
USE SCHEMA DEMO;

------------------------------------------------------------------------------
-- 1. CUSTOMERS (5,000)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE CUSTOMERS (
  CUSTOMER_ID    NUMBER,
  CUSTOMER_NAME  VARCHAR,
  SEGMENT        VARCHAR,
  INDUSTRY       VARCHAR,
  REGION         VARCHAR,
  COUNTRY        VARCHAR,
  CITY           VARCHAR,
  EMAIL          VARCHAR,
  PHONE          VARCHAR,
  PAN_NUMBER     VARCHAR,
  CREATED_DATE   DATE,
  CREDIT_LIMIT   NUMBER(12,2)
) COMMENT = 'Synthetic customers (PII-like columns are fake)';

INSERT INTO CUSTOMERS
WITH lk AS (
  SELECT
    ARRAY_CONSTRUCT('Aarav','Vivaan','Aditya','Priya','Ananya','Diya','Rohan','Kavya','Arjun','Isha',
                    'James','Olivia','Liam','Emma','Noah','Sophia','Hiroshi','Yuki','Haruto','Sakura',
                    'Lukas','Mia','Felix','Hannah','Wei','Mei','Jun','Siti','Oliver','Amelia',
                    'Rahul','Sneha','Vikram','Neha','Karan','Pooja','Ethan','Ava','Ben','Chloe') AS FN,
    ARRAY_CONSTRUCT('Sharma','Patel','Iyer','Reddy','Gupta','Nair','Mehta','Singh','Kapoor','Rao',
                    'Smith','Johnson','Brown','Taylor','Wilson','Davies','Evans','Tanaka','Suzuki','Sato',
                    'Watanabe','Muller','Schmidt','Schneider','Fischer','Weber','Tan','Lim','Ng','Wong',
                    'Chen','Banerjee','Joshi','Kulkarni','Desai','Clarke','Walker','Hughes','Becker','Koch') AS LN,
    ARRAY_CONSTRUCT('Apex','Zenith','Nova','Summit','Crescent','Orion','Vertex','Pioneer','Silverline',
                    'Evergreen','Bluewater','Redstone') AS CO_PRE,
    ARRAY_CONSTRUCT('Tech','Steel','Agro','Pharma','Auto','Power','Foods','Textiles','Chem','Infra') AS CO_MID,
    ARRAY_CONSTRUCT('Industries','Technologies','Solutions','Enterprises','Systems','Global',
                    'Manufacturing','Labs','Holdings','Partners','Retail','Logistics') AS CO_SFX,
    ARRAY_CONSTRUCT('Pvt Ltd','Inc','Ltd','GmbH','KK','Pte Ltd') AS LEGAL,
    ARRAY_CONSTRUCT('Manufacturing','Retail','Healthcare','Financial Services','Technology',
                    'Automotive','Pharmaceuticals','Logistics','Energy','Consumer Goods') AS IND,
    ARRAY_CONSTRUCT('North','South','East','West','Central') AS REG,
    ARRAY_CONSTRUCT('India','USA','UK','Germany','Japan','Singapore') AS CTRY,
    ARRAY_CONSTRUCT('+91','+1','+44','+49','+81','+65') AS DIAL,
    ARRAY_CONSTRUCT(
      ARRAY_CONSTRUCT('Mumbai','Delhi','Bengaluru','Chennai','Hyderabad','Pune','Kolkata','Ahmedabad'),
      ARRAY_CONSTRUCT('New York','Chicago','Houston','San Francisco','Atlanta','Seattle','Boston','Dallas'),
      ARRAY_CONSTRUCT('London','Manchester','Birmingham','Leeds','Glasgow','Bristol'),
      ARRAY_CONSTRUCT('Berlin','Munich','Hamburg','Frankfurt','Stuttgart','Cologne'),
      ARRAY_CONSTRUCT('Tokyo','Osaka','Yokohama','Nagoya','Fukuoka'),
      ARRAY_CONSTRUCT('Singapore')) AS CITIES,
    ARRAY_CONSTRUCT('example.com','example.org','example.net') AS MAIL_DOM
),
g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS ID,
         UNIFORM(1, 100,     RANDOM(101)) AS R_SEG,
         UNIFORM(0, 999999,  RANDOM(102)) AS R_FN,
         UNIFORM(0, 999999,  RANDOM(103)) AS R_LN,
         UNIFORM(0, 999999,  RANDOM(104)) AS R_PRE,
         UNIFORM(0, 999999,  RANDOM(105)) AS R_MID,
         UNIFORM(0, 999999,  RANDOM(106)) AS R_SFX,
         UNIFORM(0, 999999,  RANDOM(107)) AS R_IND,
         UNIFORM(0, 999999,  RANDOM(108)) AS R_REG,
         UNIFORM(1, 100,     RANDOM(109)) AS R_CTRY,
         UNIFORM(0, 999999,  RANDOM(110)) AS R_CITY,
         UNIFORM(10000, 99999, RANDOM(111)) AS PH1,
         UNIFORM(10000, 99999, RANDOM(112)) AS PH2,
         UNIFORM(0, 25,      RANDOM(113)) AS P1,
         UNIFORM(0, 25,      RANDOM(114)) AS P2,
         UNIFORM(0, 25,      RANDOM(115)) AS P3,
         UNIFORM(0, 9999,    RANDOM(116)) AS P_NUM,
         UNIFORM(0, 25,      RANDOM(117)) AS P_CHK,
         UNIFORM(0, 2190,    RANDOM(118)) AS R_DAYS,
         UNIFORM(0, 999999,  RANDOM(119)) AS R_CREDIT,
         UNIFORM(0, 999999,  RANDOM(120)) AS R_MAIL
  FROM TABLE(GENERATOR(ROWCOUNT => 5000))
),
b AS (
  SELECT g.*,
    CASE WHEN R_SEG <= 10 THEN 'Enterprise' WHEN R_SEG <= 35 THEN 'Mid-Market'
         WHEN R_SEG <= 75 THEN 'SMB' ELSE 'Consumer' END                         AS SEGMENT,
    CASE WHEN R_CTRY <= 35 THEN 0 WHEN R_CTRY <= 55 THEN 1 WHEN R_CTRY <= 67 THEN 2
         WHEN R_CTRY <= 79 THEN 3 WHEN R_CTRY <= 89 THEN 4 ELSE 5 END             AS CI,
    GET(lk.FN, MOD(R_FN, ARRAY_SIZE(lk.FN)))::STRING                              AS FIRST_NAME,
    GET(lk.LN, MOD(R_LN, ARRAY_SIZE(lk.LN)))::STRING                              AS LAST_NAME
  FROM g CROSS JOIN lk
),
c AS (
  SELECT b.*,
    CASE WHEN SEGMENT = 'Consumer' THEN FIRST_NAME || ' ' || LAST_NAME
         WHEN MOD(R_PRE, 2) = 0 THEN LAST_NAME || ' ' || GET(lk.CO_SFX, MOD(R_SFX, ARRAY_SIZE(lk.CO_SFX)))::STRING
         ELSE GET(lk.CO_PRE, MOD(R_PRE, ARRAY_SIZE(lk.CO_PRE)))::STRING || ' '
              || GET(lk.CO_MID, MOD(R_MID, ARRAY_SIZE(lk.CO_MID)))::STRING || ' '
              || GET(lk.CO_SFX, MOD(R_SFX, ARRAY_SIZE(lk.CO_SFX)))::STRING
    END AS NAME_CORE
  FROM b CROSS JOIN lk
)
SELECT
  c.ID                                                                        AS CUSTOMER_ID,
  IFF(c.SEGMENT = 'Consumer', c.NAME_CORE, c.NAME_CORE || ' ' || GET(lk.LEGAL, c.CI)::STRING) AS CUSTOMER_NAME,
  c.SEGMENT,
  IFF(c.SEGMENT = 'Consumer', 'Consumer', GET(lk.IND, MOD(c.R_IND, ARRAY_SIZE(lk.IND)))::STRING) AS INDUSTRY,
  GET(lk.REG, MOD(c.R_REG, 5))::STRING                                        AS REGION,
  GET(lk.CTRY, c.CI)::STRING                                                  AS COUNTRY,
  GET(GET(lk.CITIES, c.CI), MOD(c.R_CITY, ARRAY_SIZE(GET(lk.CITIES, c.CI))))::STRING AS CITY,
  IFF(c.SEGMENT = 'Consumer',
      LOWER(c.FIRST_NAME || '.' || c.LAST_NAME || MOD(c.ID, 97)) || '@' || GET(lk.MAIL_DOM, MOD(c.R_MAIL, 3))::STRING,
      LOWER(c.FIRST_NAME || '.' || c.LAST_NAME) || '@' || LOWER(REGEXP_REPLACE(c.NAME_CORE, '[^A-Za-z]', '')) || '.example.com')
                                                                              AS EMAIL,
  GET(lk.DIAL, c.CI)::STRING || ' ' || c.PH1 || ' ' || c.PH2                  AS PHONE,
  CHR(65 + c.P1) || CHR(65 + c.P2) || CHR(65 + c.P3)
    || IFF(c.SEGMENT = 'Consumer', 'P', 'C')
    || LEFT(UPPER(IFF(c.SEGMENT = 'Consumer', c.LAST_NAME, c.NAME_CORE)), 1)
    || LPAD(c.P_NUM::STRING, 4, '0') || CHR(65 + c.P_CHK)                    AS PAN_NUMBER,
  DATEADD(DAY, c.R_DAYS, '2018-01-01'::DATE)                                  AS CREATED_DATE,
  (CASE c.SEGMENT
     WHEN 'Enterprise' THEN 500000 + MOD(c.R_CREDIT, 1500) * 1000
     WHEN 'Mid-Market' THEN 100000 + MOD(c.R_CREDIT, 400) * 1000
     WHEN 'SMB'        THEN  10000 + MOD(c.R_CREDIT, 90) * 1000
     ELSE                     1000 + MOD(c.R_CREDIT, 90) * 100 END)::NUMBER(12,2) AS CREDIT_LIMIT
FROM c CROSS JOIN lk;

------------------------------------------------------------------------------
-- 2. PRODUCTS (200) - category = MOD(PRODUCT_ID-1, 5); low IDs sell most
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE PRODUCTS (
  PRODUCT_ID    NUMBER,
  SKU           VARCHAR,
  PRODUCT_NAME  VARCHAR,
  CATEGORY      VARCHAR,
  SUB_CATEGORY  VARCHAR,
  BRAND         VARCHAR,
  UNIT_COST     NUMBER(10,2),
  LIST_PRICE    NUMBER(10,2),
  LAUNCH_DATE   DATE
) COMMENT = 'Synthetic product catalogue';

INSERT INTO PRODUCTS
WITH lk AS (
  SELECT
    ARRAY_CONSTRUCT('Electronics','Industrial Tools','Home Appliances','Office Supplies','Safety Equipment') AS CAT,
    ARRAY_CONSTRUCT('ELE','TOL','HAP','OFF','SAF') AS CAT_CODE,
    ARRAY_CONSTRUCT(
      ARRAY_CONSTRUCT('Sensors','Controllers','Power Supplies','Cables & Connectors'),
      ARRAY_CONSTRUCT('Power Tools','Hand Tools','Measuring Instruments','Welding'),
      ARRAY_CONSTRUCT('Kitchen','Cooling','Cleaning','Water Purifiers'),
      ARRAY_CONSTRUCT('Paper Products','Furniture','Printing','Stationery'),
      ARRAY_CONSTRUCT('Head Protection','Gloves','Footwear','Respiratory')) AS SUB,
    ARRAY_CONSTRUCT(
      ARRAY_CONSTRUCT('Smart Sensor','Logic Controller','Power Supply Unit','Connector Kit'),
      ARRAY_CONSTRUCT('Cordless Drill','Wrench Set','Digital Caliper','Welding Torch'),
      ARRAY_CONSTRUCT('Mixer Grinder','Air Cooler','Vacuum Cleaner','Water Purifier'),
      ARRAY_CONSTRUCT('Copier Paper Pack','Ergonomic Chair','Toner Cartridge','Notebook Pack'),
      ARRAY_CONSTRUCT('Safety Helmet','Cut-Resistant Gloves','Safety Boots','Respirator Mask')) AS NOUN,
    ARRAY_CONSTRUCT(ARRAY_CONSTRUCT('Voltix','Nexa'), ARRAY_CONSTRUCT('Kraftline','Toolmaster'),
                    ARRAY_CONSTRUCT('HomeEase','Coolbreeze'), ARRAY_CONSTRUCT('OfficeMate','Papyra'),
                    ARRAY_CONSTRUCT('SafeGuard','ShieldPro')) AS BRANDS,
    ARRAY_CONSTRUCT(15, 20, 40, 2, 3)      AS COST_LO,
    ARRAY_CONSTRUCT(400, 600, 500, 250, 120) AS COST_HI,
    ARRAY_CONSTRUCT('Pro','Max','Lite','Plus','Ultra','Eco','Prime','Edge') AS ADJ
),
g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS ID,
         UNIFORM(0, 3,      RANDOM(201)) AS SI,
         UNIFORM(0, 1,      RANDOM(202)) AS BI,
         UNIFORM(0, 7,      RANDOM(203)) AS AI,
         UNIFORM(0, 25,     RANDOM(204)) AS M1,
         UNIFORM(100, 999,  RANDOM(205)) AS M2,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(206)) AS U_COST,
         UNIFORM(125, 190,  RANDOM(207)) AS MARKUP,
         UNIFORM(0, 2900,   RANDOM(208)) AS R_DAYS
  FROM TABLE(GENERATOR(ROWCOUNT => 200))
),
b AS (
  SELECT g.*, MOD(g.ID - 1, 5) AS CI FROM g
)
SELECT
  b.ID,
  GET(lk.CAT_CODE, b.CI)::STRING || '-' || LPAD(b.ID::STRING, 5, '0'),
  GET(GET(lk.BRANDS, b.CI), b.BI)::STRING || ' ' || GET(lk.ADJ, b.AI)::STRING || ' '
    || GET(GET(lk.NOUN, b.CI), b.SI)::STRING || ' ' || CHR(65 + b.M1) || b.M2,
  GET(lk.CAT, b.CI)::STRING,
  GET(GET(lk.SUB, b.CI), b.SI)::STRING,
  GET(GET(lk.BRANDS, b.CI), b.BI)::STRING,
  ROUND(GET(lk.COST_LO, b.CI)::NUMBER + b.U_COST * (GET(lk.COST_HI, b.CI)::NUMBER - GET(lk.COST_LO, b.CI)::NUMBER), 2),
  ROUND((GET(lk.COST_LO, b.CI)::NUMBER + b.U_COST * (GET(lk.COST_HI, b.CI)::NUMBER - GET(lk.COST_LO, b.CI)::NUMBER)) * b.MARKUP / 100, 2),
  DATEADD(DAY, b.R_DAYS, '2016-01-01'::DATE)
FROM b CROSS JOIN lk;

------------------------------------------------------------------------------
-- 3. SUPPLIERS (50) - category = MOD(SUPPLIER_ID-1, 5) (matches PRODUCTS)
--    6 High-risk suppliers; ON_TIME_DELIVERY_PCT is recalculated from POs below.
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE SUPPLIERS (
  SUPPLIER_ID           NUMBER,
  SUPPLIER_NAME         VARCHAR,
  COUNTRY               VARCHAR,
  CATEGORY              VARCHAR,
  RISK_RATING           VARCHAR,
  ON_TIME_DELIVERY_PCT  NUMBER(5,2),
  GSTIN                 VARCHAR
) COMMENT = 'Synthetic suppliers; GSTIN only for Indian suppliers';

INSERT INTO SUPPLIERS
WITH lk AS (
  SELECT
    ARRAY_CONSTRUCT('Apex','Zenith','Orion','Sunrise','Vertex','Pinnacle','Allied','Global',
                    'Precision','United','Eastern','Delta') AS PRE,
    ARRAY_CONSTRUCT('Components','Metals','Electronics','Plastics','Packaging','Polymers',
                    'Castings','Fasteners','Textiles','Chemicals') AS MID,
    ARRAY_CONSTRUCT('India','China','Germany','USA','Japan','Vietnam','Taiwan') AS CTRY,
    ARRAY_CONSTRUCT('Pvt Ltd','Co Ltd','GmbH','Inc','KK','JSC','Corp') AS LEGAL,
    ARRAY_CONSTRUCT('Electronics','Industrial Tools','Home Appliances','Office Supplies','Safety Equipment') AS CAT,
    ARRAY_CONSTRUCT('27','29','33','24','07','36') AS GST_STATE
),
g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS ID,
         UNIFORM(0, 11, RANDOM(301)) AS R_PRE,
         UNIFORM(0, 9,  RANDOM(302)) AS R_MID,
         UNIFORM(1, 100, RANDOM(303)) AS R_CTRY,
         UNIFORM(0, 5,  RANDOM(304)) AS R_ST,
         UNIFORM(0, 25, RANDOM(305)) AS G1,
         UNIFORM(0, 25, RANDOM(306)) AS G2,
         UNIFORM(0, 25, RANDOM(307)) AS G3,
         UNIFORM(0, 25, RANDOM(308)) AS G4,
         UNIFORM(0, 9999, RANDOM(309)) AS G_NUM,
         UNIFORM(0, 25, RANDOM(310)) AS G5,
         UNIFORM(0, 35, RANDOM(311)) AS G_CHK
  FROM TABLE(GENERATOR(ROWCOUNT => 50))
),
b AS (
  SELECT g.*,
    CASE WHEN R_CTRY <= 40 THEN 0 WHEN R_CTRY <= 60 THEN 1 WHEN R_CTRY <= 70 THEN 2 WHEN R_CTRY <= 80 THEN 3
         WHEN R_CTRY <= 88 THEN 4 WHEN R_CTRY <= 94 THEN 5 ELSE 6 END AS CI,
    CASE WHEN ID IN (7, 14, 23, 31, 42, 48) THEN 'High'
         WHEN MOD(ID, 4) = 0 THEN 'Medium' ELSE 'Low' END AS RISK
  FROM g
)
SELECT
  b.ID,
  GET(lk.PRE, b.R_PRE)::STRING || ' ' || GET(lk.MID, b.R_MID)::STRING || ' ' || GET(lk.LEGAL, b.CI)::STRING,
  GET(lk.CTRY, b.CI)::STRING,
  GET(lk.CAT, MOD(b.ID - 1, 5))::STRING,
  b.RISK,
  NULL,
  IFF(b.CI = 0,
      GET(lk.GST_STATE, b.R_ST)::STRING || CHR(65 + b.G1) || CHR(65 + b.G2) || CHR(65 + b.G3) || 'C'
        || CHR(65 + b.G4) || LPAD(b.G_NUM::STRING, 4, '0') || CHR(65 + b.G5) || '1Z'
        || IFF(b.G_CHK < 10, b.G_CHK::STRING, CHR(55 + b.G_CHK)),
      NULL)
FROM b CROSS JOIN lk;

------------------------------------------------------------------------------
-- 4. PLANTS (8)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE PLANTS (
  PLANT_ID                NUMBER,
  PLANT_NAME              VARCHAR,
  CITY                    VARCHAR,
  COUNTRY                 VARCHAR,
  CAPACITY_UNITS_PER_DAY  NUMBER
) COMMENT = 'Manufacturing / distribution plants';

INSERT INTO PLANTS VALUES
  (1, 'Pune Assembly Plant',            'Pune',       'India',     1800),
  (2, 'Chennai Components Plant',       'Chennai',    'India',     1500),
  (3, 'Houston Assembly & Distribution','Houston',    'USA',       1600),
  (4, 'Columbus Manufacturing',         'Columbus',   'USA',       1200),
  (5, 'Manchester Works',               'Manchester', 'UK',         900),
  (6, 'Stuttgart Precision Plant',      'Stuttgart',  'Germany',   1100),
  (7, 'Osaka Electronics Plant',        'Osaka',      'Japan',     1000),
  (8, 'Singapore Regional Hub',         'Singapore',  'Singapore',  700);

------------------------------------------------------------------------------
-- 5. ORDERS (100,000) + ORDER_LINES (~250,000)
--    Step a: daily order counts with growth x seasonality x weekday weights.
------------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE TMP_DAY_COUNTS AS
WITH d AS (
  SELECT DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2024-01-01'::DATE) AS D
  FROM TABLE(GENERATOR(ROWCOUNT => 1004))                       -- 2024-01-01 .. 2026-09-30
),
w AS (
  SELECT D,
         (1 + 0.30 * DATEDIFF(DAY, '2024-01-01'::DATE, D) / 365.0)                       -- ~30% YoY growth
       * DECODE(MONTH(D), 1,0.85, 2,0.82, 3,1.05, 4,0.92, 5,0.94, 6,0.96,
                          7,0.95, 8,0.98, 9,1.03, 10,1.12, 11,1.22, 12,1.28)             -- seasonality
       * DECODE(DAYOFWEEKISO(D), 6,0.65, 7,0.50, 1.0) AS W                               -- weekends quieter
  FROM d
),
c AS (
  SELECT D, SUM(W) OVER (ORDER BY D) / SUM(W) OVER () AS CUM FROM w
)
SELECT D AS ORDER_DATE,
       ROUND(CUM * 100000) - ROUND(COALESCE(LAG(CUM) OVER (ORDER BY D), 0) * 100000) AS N
FROM c;

-- Step b: customers numbered within region (Enterprise first => they order more)
CREATE OR REPLACE TEMPORARY TABLE TMP_CUST_REGION AS
SELECT CUSTOMER_ID, REGION, SEGMENT, COUNTRY,
       ROW_NUMBER() OVER (PARTITION BY REGION
                          ORDER BY DECODE(SEGMENT,'Enterprise',1,'Mid-Market',2,'SMB',3,4), CUSTOMER_ID) AS REGION_SEQ,
       COUNT(*) OVER (PARTITION BY REGION) AS REGION_CNT
FROM CUSTOMERS;

-- Step c: order headers (without total)
CREATE OR REPLACE TEMPORARY TABLE TMP_ORDERS AS
WITH k AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS K FROM TABLE(GENERATOR(ROWCOUNT => 1000))
),
o AS (
  SELECT 1000000 + ROW_NUMBER() OVER (ORDER BY dc.ORDER_DATE, k.K) AS ORDER_ID, dc.ORDER_DATE
  FROM TMP_DAY_COUNTS dc JOIN k ON k.K <= dc.N
),
r AS (
  SELECT o.*,
    CASE WHEN UNIFORM(1, 100, HASH(ORDER_ID, 1)) <= 22 THEN 'North'
         WHEN UNIFORM(1, 100, HASH(ORDER_ID, 1)) <= 44 THEN 'South'
         WHEN UNIFORM(1, 100, HASH(ORDER_ID, 1)) <= 64 THEN 'East'
         WHEN UNIFORM(1, 100, HASH(ORDER_ID, 1)) <= 84 THEN 'West'
         ELSE 'Central' END AS REGION0
  FROM o
),
r2 AS (
  SELECT r.*,
    -- South dip in 2026-Q2: ~45% of South orders disappear to other regions
    IFF(REGION0 = 'South' AND ORDER_DATE BETWEEN '2026-04-01' AND '2026-06-30'
        AND UNIFORM(1, 100, HASH(ORDER_ID, 2)) <= 45,
        GET(ARRAY_CONSTRUCT('North','East','West','Central'), UNIFORM(0, 3, HASH(ORDER_ID, 3)))::STRING,
        REGION0) AS REGION,
    UNIFORM(0::FLOAT, 1::FLOAT, HASH(ORDER_ID, 4)) AS U_CUST
  FROM r
),
rc AS (
  SELECT REGION, COUNT(*) AS REGION_CNT FROM TMP_CUST_REGION GROUP BY REGION
),
r3 AS (
  SELECT r2.ORDER_ID, r2.ORDER_DATE, r2.REGION,
         LEAST(rc.REGION_CNT, 1 + FLOOR(rc.REGION_CNT * POW(r2.U_CUST, 1.5))) AS PICK_SEQ
  FROM r2 JOIN rc ON rc.REGION = r2.REGION
),
oc AS (
  SELECT r3.ORDER_ID, r3.ORDER_DATE, c.CUSTOMER_ID, c.SEGMENT, c.COUNTRY
  FROM r3
  JOIN TMP_CUST_REGION c
    ON c.REGION = r3.REGION
   AND c.REGION_SEQ = r3.PICK_SEQ
)
SELECT
  ORDER_ID, ORDER_DATE, CUSTOMER_ID, SEGMENT,
  CASE WHEN UNIFORM(1, 100, HASH(ORDER_ID, 5)) <= 10 THEN UNIFORM(1, 8, HASH(ORDER_ID, 6))
       ELSE DECODE(COUNTRY, 'India', 1 + MOD(ORDER_ID, 2), 'USA', 3 + MOD(ORDER_ID, 2),
                            'UK', 5, 'Germany', 6, 'Japan', 7, 8) END AS PLANT_ID,
  CASE SEGMENT
    WHEN 'Consumer'   THEN IFF(UNIFORM(1, 100, HASH(ORDER_ID, 7)) <= 50 + 8 * (YEAR(ORDER_DATE) - 2024), 'E-commerce', 'Retail')
    WHEN 'Enterprise' THEN CASE WHEN UNIFORM(1, 100, HASH(ORDER_ID, 7)) <= 70 THEN 'Direct'
                                WHEN UNIFORM(1, 100, HASH(ORDER_ID, 7)) <= 92 THEN 'Distributor' ELSE 'E-commerce' END
    ELSE CASE WHEN UNIFORM(1, 100, HASH(ORDER_ID, 7)) <= 25 THEN 'Direct'
              WHEN UNIFORM(1, 100, HASH(ORDER_ID, 7)) > 82 - 6 * (YEAR(ORDER_DATE) - 2024) THEN 'E-commerce'
              WHEN UNIFORM(1, 100, HASH(ORDER_ID, 7)) > 72 - 6 * (YEAR(ORDER_DATE) - 2024) THEN 'Retail'
              ELSE 'Distributor' END
  END AS CHANNEL,
  CASE WHEN UNIFORM(1, 1000, HASH(ORDER_ID, 8)) <= 30 THEN 'Cancelled'
       WHEN DATEDIFF(DAY, ORDER_DATE, '2026-09-30'::DATE) <= 6 THEN 'Shipped'
       WHEN DATEDIFF(DAY, ORDER_DATE, '2026-09-30'::DATE) <= 12 AND UNIFORM(1, 1000, HASH(ORDER_ID, 8)) <= 500 THEN 'Shipped'
       WHEN UNIFORM(1, 1000, HASH(ORDER_ID, 8)) <= 70 AND DATEDIFF(DAY, ORDER_DATE, '2026-09-30'::DATE) > 14 THEN 'Returned'
       ELSE 'Delivered' END AS STATUS,
  'USD' AS CURRENCY,
  CASE WHEN UNIFORM(1, 100, HASH(ORDER_ID, 9)) <= 20 THEN 1
       WHEN UNIFORM(1, 100, HASH(ORDER_ID, 9)) <= 50 THEN 2
       WHEN UNIFORM(1, 100, HASH(ORDER_ID, 9)) <= 80 THEN 3 ELSE 4 END AS N_LINES
FROM oc;

-- Step d: ORDER_LINES (built first so ORDER_TOTAL = SUM(NET_AMOUNT) exactly)
CREATE OR REPLACE TABLE ORDER_LINES (
  ORDER_ID      NUMBER,
  LINE_NO       NUMBER,
  PRODUCT_ID    NUMBER,
  QUANTITY      NUMBER,
  UNIT_PRICE    NUMBER(10,2),
  DISCOUNT_PCT  NUMBER(5,2),
  NET_AMOUNT    NUMBER(14,2)
) COMMENT = 'Order lines; NET_AMOUNT = QUANTITY * UNIT_PRICE * (1 - DISCOUNT_PCT/100)';

INSERT INTO ORDER_LINES
WITH ln AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS LINE_NO FROM TABLE(GENERATOR(ROWCOUNT => 4))
),
x AS (
  SELECT o.ORDER_ID, ln.LINE_NO, o.ORDER_DATE, o.SEGMENT, o.CHANNEL,
         -- skewed popularity: low PRODUCT_IDs sell most
         LEAST(200, 1 + FLOOR(200 * POW(UNIFORM(0::FLOAT, 1::FLOAT, HASH(o.ORDER_ID, ln.LINE_NO, 21)), 1.7)))::NUMBER AS PRODUCT_ID,
         CASE o.SEGMENT
           WHEN 'Enterprise' THEN UNIFORM(10, 200, HASH(o.ORDER_ID, ln.LINE_NO, 22))
           WHEN 'Mid-Market' THEN UNIFORM(5, 50,   HASH(o.ORDER_ID, ln.LINE_NO, 22))
           WHEN 'SMB'        THEN UNIFORM(1, 20,   HASH(o.ORDER_ID, ln.LINE_NO, 22))
           ELSE                   UNIFORM(1, 3,    HASH(o.ORDER_ID, ln.LINE_NO, 22)) END AS QUANTITY,
         (CASE o.SEGMENT
            WHEN 'Enterprise' THEN UNIFORM(800, 2000, HASH(o.ORDER_ID, ln.LINE_NO, 23))
            WHEN 'Mid-Market' THEN UNIFORM(500, 1200, HASH(o.ORDER_ID, ln.LINE_NO, 23))
            WHEN 'SMB'        THEN UNIFORM(0, 800,    HASH(o.ORDER_ID, ln.LINE_NO, 23))
            ELSE                   UNIFORM(0, 500,    HASH(o.ORDER_ID, ln.LINE_NO, 23)) END
          + IFF(o.CHANNEL = 'Distributor', 300, 0)) / 100 AS DISCOUNT_PCT
  FROM TMP_ORDERS o JOIN ln ON ln.LINE_NO <= o.N_LINES
)
SELECT x.ORDER_ID, x.LINE_NO, x.PRODUCT_ID, x.QUANTITY,
       ROUND(p.LIST_PRICE * (1 + 0.03 * (YEAR(x.ORDER_DATE) - 2024)), 2)::NUMBER(10,2) AS UNIT_PRICE,   -- 3% price rise per year
       x.DISCOUNT_PCT::NUMBER(5,2),
       ROUND(x.QUANTITY * ROUND(p.LIST_PRICE * (1 + 0.03 * (YEAR(x.ORDER_DATE) - 2024)), 2)
             * (1 - x.DISCOUNT_PCT / 100), 2)::NUMBER(14,2) AS NET_AMOUNT
FROM x JOIN PRODUCTS p ON p.PRODUCT_ID = x.PRODUCT_ID;

-- Step e: ORDERS with ORDER_TOTAL = sum of line NET_AMOUNT
CREATE OR REPLACE TABLE ORDERS (
  ORDER_ID     NUMBER,
  ORDER_DATE   DATE,
  CUSTOMER_ID  NUMBER,
  PLANT_ID     NUMBER,
  CHANNEL      VARCHAR,
  STATUS       VARCHAR,
  CURRENCY     VARCHAR,
  ORDER_TOTAL  NUMBER(14,2)
) COMMENT = 'Order headers; ORDER_TOTAL = SUM(ORDER_LINES.NET_AMOUNT)';

INSERT INTO ORDERS
SELECT o.ORDER_ID, o.ORDER_DATE, o.CUSTOMER_ID, o.PLANT_ID, o.CHANNEL, o.STATUS, o.CURRENCY,
       COALESCE(l.TOTAL, 0)::NUMBER(14,2)
FROM TMP_ORDERS o
LEFT JOIN (SELECT ORDER_ID, SUM(NET_AMOUNT) AS TOTAL FROM ORDER_LINES GROUP BY ORDER_ID) l
  ON l.ORDER_ID = o.ORDER_ID
ORDER BY o.ORDER_ID;

------------------------------------------------------------------------------
-- 6. PURCHASE_ORDERS (20,000) - product always in the supplier's category
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE PURCHASE_ORDERS (
  PO_ID          NUMBER,
  PO_DATE        DATE,
  SUPPLIER_ID    NUMBER,
  PLANT_ID       NUMBER,
  PRODUCT_ID     NUMBER,
  QUANTITY       NUMBER,
  UNIT_COST      NUMBER(10,2),
  PROMISED_DATE  DATE,
  RECEIVED_DATE  DATE,
  STATUS         VARCHAR
) COMMENT = 'Purchase orders; RECEIVED_DATE NULL while open or cancelled';

INSERT INTO PURCHASE_ORDERS
WITH g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS RN,
         UNIFORM(0, 1003, RANDOM(501)) AS D_OFF,
         UNIFORM(1, 50,   RANDOM(502)) AS SUPPLIER_ID,
         UNIFORM(1, 8,    RANDOM(503)) AS PLANT_ID,
         UNIFORM(0, 39,   RANDOM(504)) AS P_K,
         UNIFORM(5, 200,  RANDOM(505)) AS Q10,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(506)) AS U_COST,
         UNIFORM(7, 30,   RANDOM(507)) AS LEAD_DAYS,
         UNIFORM(1, 100,  RANDOM(508)) AS R_LATE,
         UNIFORM(5, 25,   RANDOM(509)) AS DLY_H,
         UNIFORM(2, 10,   RANDOM(510)) AS DLY_M,
         UNIFORM(1, 5,    RANDOM(511)) AS DLY_L,
         UNIFORM(-3, 0,   RANDOM(512)) AS EARLY,
         UNIFORM(1, 100,  RANDOM(513)) AS R_CANCEL
  FROM TABLE(GENERATOR(ROWCOUNT => 20000))
),
b AS (
  SELECT g.RN,
         DATEADD(DAY, g.D_OFF, '2024-01-01'::DATE)                    AS PO_DATE,
         g.SUPPLIER_ID, g.PLANT_ID,
         MOD(g.SUPPLIER_ID - 1, 5) + 1 + 5 * g.P_K                     AS PRODUCT_ID,
         g.Q10 * 10                                                    AS QUANTITY,
         ROUND(p.UNIT_COST * (0.92 + 0.10 * g.U_COST), 2)              AS UNIT_COST,
         DATEADD(DAY, g.LEAD_DAYS + g.D_OFF, '2024-01-01'::DATE)       AS PROMISED_DATE,
         CASE s.RISK_RATING
           WHEN 'High'   THEN IFF(g.R_LATE <= 40 + IFF(g.D_OFF >= 731, 15, 0), g.DLY_H, g.EARLY)  -- worse in 2026
           WHEN 'Medium' THEN IFF(g.R_LATE <= 12, g.DLY_M, g.EARLY)
           ELSE               IFF(g.R_LATE <= 4,  g.DLY_L, g.EARLY) END AS DELAY_DAYS,
         g.R_CANCEL
  FROM g
  JOIN SUPPLIERS s ON s.SUPPLIER_ID = g.SUPPLIER_ID
  JOIN PRODUCTS  p ON p.PRODUCT_ID  = MOD(g.SUPPLIER_ID - 1, 5) + 1 + 5 * g.P_K
)
SELECT 4500000 + RN, PO_DATE, SUPPLIER_ID, PLANT_ID, PRODUCT_ID, QUANTITY, UNIT_COST::NUMBER(10,2), PROMISED_DATE,
       CASE WHEN R_CANCEL <= 2 THEN NULL
            WHEN DATEADD(DAY, DELAY_DAYS, PROMISED_DATE) > '2026-09-30'::DATE THEN NULL
            ELSE DATEADD(DAY, DELAY_DAYS, PROMISED_DATE) END,
       CASE WHEN R_CANCEL <= 2 THEN 'Cancelled'
            WHEN DATEADD(DAY, DELAY_DAYS, PROMISED_DATE) > '2026-09-30'::DATE THEN 'Open'
            WHEN DELAY_DAYS > 0 THEN 'Late'
            ELSE 'Received' END
FROM b;

-- Supplier on-time % derived from actual receipts (keeps the story consistent)
UPDATE SUPPLIERS s
   SET ON_TIME_DELIVERY_PCT = t.PCT
  FROM (SELECT SUPPLIER_ID,
               ROUND(100 * COUNT_IF(STATUS = 'Received') / NULLIF(COUNT_IF(STATUS IN ('Received','Late')), 0), 2) AS PCT
        FROM PURCHASE_ORDERS GROUP BY SUPPLIER_ID) t
 WHERE s.SUPPLIER_ID = t.SUPPLIER_ID;

------------------------------------------------------------------------------
-- 7. INVENTORY_SNAPSHOTS (weekly, Mondays, 8 plants x 200 products x 144 weeks)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE INVENTORY_SNAPSHOTS (
  SNAPSHOT_DATE  DATE,
  PLANT_ID       NUMBER,
  PRODUCT_ID     NUMBER,
  ON_HAND_QTY    NUMBER,
  REORDER_POINT  NUMBER,
  SAFETY_STOCK   NUMBER
) COMMENT = 'Weekly stock snapshots';

INSERT INTO INVENTORY_SNAPSHOTS
WITH w AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS WK FROM TABLE(GENERATOR(ROWCOUNT => 144))
),
pp AS (
  SELECT pl.PLANT_ID, p.PRODUCT_ID,
         ROUND(UNIFORM(50, 500, HASH(pl.PLANT_ID, p.PRODUCT_ID, 71)), -1) AS RP,
         UNIFORM(0::FLOAT, 6.28::FLOAT, HASH(pl.PLANT_ID, p.PRODUCT_ID, 72)) AS PHASE
  FROM PLANTS pl CROSS JOIN PRODUCTS p
)
SELECT DATEADD(WEEK, w.WK, '2024-01-01'::DATE) AS SNAPSHOT_DATE,
       pp.PLANT_ID, pp.PRODUCT_ID,
       CASE WHEN pp.PLANT_ID = 3 AND MOD(pp.PRODUCT_ID, 37) = 0
                 AND DATEADD(WEEK, w.WK, '2024-01-01'::DATE) >= '2026-08-01'::DATE
            THEN UNIFORM(0, 5, HASH(pp.PLANT_ID, pp.PRODUCT_ID, w.WK, 73))       -- Houston stock-out story
            ELSE GREATEST(0, ROUND(pp.RP * (1.5 + 0.9 * SIN(w.WK / 3.0 + pp.PHASE)
                                   + UNIFORM(-25, 25, HASH(pp.PLANT_ID, pp.PRODUCT_ID, w.WK, 74)) / 100.0)))
       END::NUMBER AS ON_HAND_QTY,
       pp.RP::NUMBER AS REORDER_POINT,
       ROUND(pp.RP * 0.5)::NUMBER AS SAFETY_STOCK
FROM pp CROSS JOIN w;

------------------------------------------------------------------------------
-- 8. GL_JOURNAL (~200,000 lines, every journal balances to zero)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE GL_JOURNAL (
  JOURNAL_ID       NUMBER,
  LINE_NO          NUMBER,
  POSTING_DATE     DATE,
  ENTRY_TIMESTAMP  TIMESTAMP_NTZ,
  ENTITY           VARCHAR,
  ACCOUNT_CODE     VARCHAR,
  ACCOUNT_NAME     VARCHAR,
  ACCOUNT_TYPE     VARCHAR,
  COST_CENTER      VARCHAR,
  AMOUNT           NUMBER(16,2),
  CURRENCY         VARCHAR,
  DESCRIPTION      VARCHAR,
  CREATED_BY       VARCHAR,
  APPROVED_BY      VARCHAR,
  SOURCE           VARCHAR
) COMMENT = 'General ledger lines; debit +, credit -; local currency per entity';

INSERT INTO GL_JOURNAL
WITH coa AS (
  SELECT $1 AS ACCOUNT_CODE, $2 AS ACCOUNT_NAME, $3 AS ACCOUNT_TYPE FROM VALUES
    ('1000','Cash at Bank','Asset'), ('1100','Accounts Receivable','Asset'), ('1200','Inventory','Asset'),
    ('1300','Prepaid Expenses','Asset'), ('1500','Fixed Assets - Plant & Machinery','Asset'),
    ('1510','Fixed Assets - IT Equipment','Asset'),
    ('2000','Accounts Payable','Liability'), ('2100','Accrued Liabilities','Liability'),
    ('2200','Payroll Payable','Liability'), ('2300','GST/VAT Payable','Liability'),
    ('3000','Share Capital','Equity'), ('3100','Retained Earnings','Equity'),
    ('4000','Product Revenue','Revenue'), ('4100','Service Revenue','Revenue'), ('4200','Freight Income','Revenue'),
    ('5000','Cost of Goods Sold','COGS'), ('5100','Freight Inward','COGS'), ('5200','Direct Labour','COGS'),
    ('6000','Salaries & Wages','Opex'), ('6100','Rent','Opex'), ('6200','Utilities','Opex'),
    ('6300','Marketing','Opex'), ('6400','Travel','Opex'), ('6500','IT & Software','Opex'),
    ('6600','Professional Fees','Opex'), ('6700','Depreciation','Opex'), ('6800','Repairs & Maintenance','Opex')
),
lk AS (
  SELECT
    ARRAY_CONSTRUCT('5000','5000','5100','6100','6200','6300','6400','6500','6600','6800','1200','1200') AS AP_ACC,
    ARRAY_CONSTRUCT('4000','4000','4000','4100','4200') AS AR_ACC,
    ARRAY_CONSTRUCT('6000','6000','5200') AS PAY_ACC,
    ARRAY_CONSTRUCT('1500','1510') AS FA_ACC,
    ARRAY_CONSTRUCT('6600','6300','6000','6700','6400','5000','6500','1300') AS MAN_ACC,
    ARRAY_CONSTRUCT('CC100-SALES','CC200-MARKETING','CC300-OPERATIONS','CC400-FINANCE',
                    'CC500-HR','CC600-IT','CC700-R&D','CC800-PLANT') AS CC,
    ARRAY_CONSTRUCT('priya.sharma','rahul.mehta','anita.iyer','john.carter','emma.wilson',
                    'lukas.weber','kenji.sato','mei.tan') AS MAN_USERS,
    ARRAY_CONSTRUCT('Month-end accrual - audit fees','Reclass of marketing spend to correct cost center',
                    'Bonus accrual','Correction of prior period posting','Depreciation true-up',
                    'Prepaid insurance amortisation','Accrual - consulting services','Freight cost reclass',
                    'Intercompany recharge','Reversal of duplicate accrual') AS MAN_DESC
),
h0 AS (
  SELECT 700000 + ROW_NUMBER() OVER (ORDER BY SEQ4()) AS JOURNAL_ID,
         UNIFORM(1, 100,       RANDOM(601)) AS R_SRC,
         UNIFORM(1, 100,       RANDOM(602)) AS R_ENT,
         UNIFORM(0, 1003,      RANDOM(603)) AS D_OFF,
         UNIFORM(1, 10000,     RANDOM(604)) AS R_ANOM,
         UNIFORM(1, 100,       RANDOM(605)) AS R_ME,
         UNIFORM(0, 2,         RANDOM(606)) AS ME_BACK,
         UNIFORM(0, 999999,    RANDOM(607)) AS R_N,
         UNIFORM(28800, 68400, RANDOM(608)) AS SEC_DAY,     -- 08:00-19:00
         UNIFORM(72000, 86000, RANDOM(609)) AS SEC_NIGHT,   -- 20:00-23:53
         UNIFORM(0, 999999,    RANDOM(610)) AS R_USER,
         UNIFORM(0, 999999,    RANDOM(611)) AS R_APPR,
         UNIFORM(0, 999999,    RANDOM(612)) AS R_DESC,
         UNIFORM(1, 50,        RANDOM(613)) AS SUPPLIER_ID,
         UNIFORM(1, 5000,      RANDOM(614)) AS CUSTOMER_ID,
         UNIFORM(100000, 999999, RANDOM(615)) AS DOC_NO,
         UNIFORM(0, 7,         RANDOM(616)) AS CC_IDX,
         UNIFORM(0, 1,         RANDOM(617)) AS SUN,
         UNIFORM(1, 100,       RANDOM(618)) AS R_REV
  FROM TABLE(GENERATOR(ROWCOUNT => 62500))
),
h1 AS (
  SELECT h0.*,
    CASE WHEN R_SRC <= 35 THEN 'AP' WHEN R_SRC <= 65 THEN 'AR' WHEN R_SRC <= 73 THEN 'Payroll'
         WHEN R_SRC <= 78 THEN 'FA' ELSE 'Manual' END AS SOURCE,
    CASE WHEN R_ENT <= 35 THEN 'IN01' WHEN R_ENT <= 65 THEN 'US01' WHEN R_ENT <= 80 THEN 'UK01' ELSE 'DE01' END AS ENTITY,
    DATEADD(DAY, D_OFF, '2024-01-01'::DATE) AS RAW_DATE
  FROM h0
),
h2 AS (
  SELECT h1.*,
    (SOURCE = 'Manual' AND R_ANOM <= 50)                 AS IS_SOD,      -- creator approves own entry
    (SOURCE = 'Manual' AND R_ANOM BETWEEN 51 AND 70)     AS IS_LARGE,    -- very large adjustment
    (SOURCE = 'Manual' AND R_ANOM BETWEEN 71 AND 270)    AS IS_WEEKEND,  -- weekend, late-night posting
    (SOURCE = 'Manual' AND R_ANOM BETWEEN 271 AND 670)   AS IS_ROUND,    -- suspiciously round amount
    CASE SOURCE WHEN 'AP' THEN 2 + MOD(R_N, 4) WHEN 'AR' THEN 2 + MOD(R_N, 3)
                WHEN 'Payroll' THEN 3 + MOD(R_N, 4) WHEN 'FA' THEN 2 ELSE 2 + MOD(R_N, 3) END AS N_LINES,
    CASE WHEN SOURCE = 'Payroll' THEN LAST_DAY(RAW_DATE)
         WHEN SOURCE = 'Manual' AND R_ME <= 40 THEN DATEADD(DAY, -ME_BACK, LAST_DAY(RAW_DATE))  -- month-end clustering
         ELSE RAW_DATE END AS D1
  FROM h1
),
h3 AS (
  SELECT h2.*,
    CASE
      WHEN IS_WEEKEND THEN
        IFF(DATEADD(DAY, 5 + SUN - (DAYOFWEEKISO(D1) - 1), D1) > '2026-09-30'::DATE,
            DATEADD(DAY, -2 + SUN - (DAYOFWEEKISO(D1) - 1), D1),     -- previous weekend
            DATEADD(DAY,  5 + SUN - (DAYOFWEEKISO(D1) - 1), D1))     -- Saturday/Sunday of same week
      WHEN DAYOFWEEKISO(D1) = 6 THEN DATEADD(DAY, -1, D1)            -- normal postings move to Friday
      WHEN DAYOFWEEKISO(D1) = 7 THEN DATEADD(DAY, -2, D1)
      ELSE D1 END AS POSTING_DATE,
    CASE SOURCE WHEN 'AP' THEN 'svc_ap_interface' WHEN 'AR' THEN 'svc_ar_interface'
                WHEN 'Payroll' THEN 'svc_payroll' WHEN 'FA' THEN 'svc_fixed_assets'
                ELSE GET(lk.MAN_USERS, MOD(R_USER, ARRAY_SIZE(lk.MAN_USERS)))::STRING END AS CREATED_BY,
    DECODE(ENTITY, 'IN01', 83, 'US01', 1, 'UK01', 0.79, 0.92) AS FX,
    DECODE(ENTITY, 'IN01', 'INR', 'US01', 'USD', 'UK01', 'GBP', 'EUR') AS CURRENCY,
    GET(lk.CC, CC_IDX)::STRING AS CC_PL
  FROM h2 CROSS JOIN lk
),
h4 AS (
  SELECT h3.*,
    CASE WHEN IS_SOD THEN CREATED_BY
         WHEN SOURCE = 'AP' THEN 'ap.supervisor'
         WHEN SOURCE = 'AR' THEN 'ar.supervisor'
         WHEN SOURCE = 'Payroll' THEN 'payroll.manager'
         WHEN SOURCE = 'FA' THEN 'fa.controller'
         WHEN MOD(R_APPR, 3) = 0 THEN 'finance.manager.' || LOWER(LEFT(ENTITY, 2))
         ELSE 'controller.' || LOWER(LEFT(ENTITY, 2)) END AS APPROVED_BY,
    CASE SOURCE
      WHEN 'AP' THEN 'Vendor invoice VINV-' || DOC_NO || ' - ' || s.SUPPLIER_NAME
      WHEN 'AR' THEN 'Sales invoice SI-' || DOC_NO || ' - ' || c.CUSTOMER_NAME
      WHEN 'Payroll' THEN 'Payroll run ' || TO_CHAR(POSTING_DATE, 'MON YYYY')
      WHEN 'FA' THEN 'Capitalisation of asset FA-' || DOC_NO
      ELSE CASE WHEN IS_LARGE THEN 'Adjustment per management instruction'
                WHEN IS_ROUND THEN 'Provision top-up'
                ELSE GET(lk.MAN_DESC, MOD(R_DESC, ARRAY_SIZE(lk.MAN_DESC)))::STRING END
    END AS DESCRIPTION,
    IFF(IS_WEEKEND, SEC_NIGHT, SEC_DAY) AS ENTRY_SEC
  FROM h3
  CROSS JOIN lk
  JOIN SUPPLIERS s ON s.SUPPLIER_ID = h3.SUPPLIER_ID
  JOIN CUSTOMERS c ON c.CUSTOMER_ID = h3.CUSTOMER_ID
),
ln AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS LINE_NO FROM TABLE(GENERATOR(ROWCOUNT => 6))
),
l1 AS (
  SELECT h.*, ln.LINE_NO, (ln.LINE_NO = h.N_LINES) AS IS_BAL,
         UNIFORM(0, 999999, HASH(h.JOURNAL_ID, ln.LINE_NO, 81)) AS R_ACC,
         UNIFORM(0::FLOAT, 1::FLOAT, HASH(h.JOURNAL_ID, ln.LINE_NO, 82)) AS U_AMT,
         UNIFORM(0, 99, HASH(h.JOURNAL_ID, ln.LINE_NO, 83)) AS CENTS,
         UNIFORM(60, 120, HASH(h.JOURNAL_ID, 84)) AS LARGE_MULT
  FROM h4 h JOIN ln ON ln.LINE_NO <= h.N_LINES
),
l2 AS (
  SELECT l1.*,
    CASE WHEN IS_BAL THEN DECODE(SOURCE, 'AP','2000', 'AR','1100', 'Payroll','2200', 'FA','1000', '2100')
         WHEN SOURCE = 'AP'      THEN GET(lk.AP_ACC,  MOD(R_ACC, ARRAY_SIZE(lk.AP_ACC)))::STRING
         WHEN SOURCE = 'AR'      THEN GET(lk.AR_ACC,  MOD(R_ACC, ARRAY_SIZE(lk.AR_ACC)))::STRING
         WHEN SOURCE = 'Payroll' THEN GET(lk.PAY_ACC, MOD(R_ACC, ARRAY_SIZE(lk.PAY_ACC)))::STRING
         WHEN SOURCE = 'FA'      THEN GET(lk.FA_ACC,  MOD(R_ACC, ARRAY_SIZE(lk.FA_ACC)))::STRING
         ELSE                         GET(lk.MAN_ACC, MOD(R_ACC, ARRAY_SIZE(lk.MAN_ACC)))::STRING END AS ACCOUNT_CODE,
    CASE SOURCE WHEN 'AP'      THEN 200   + U_AMT * 29800
                WHEN 'AR'      THEN 500   + U_AMT * 49500
                WHEN 'Payroll' THEN 20000 + U_AMT * 130000
                WHEN 'FA'      THEN 5000  + U_AMT * 245000
                ELSE                100   + U_AMT * 19900 END AS BASE_USD
  FROM l1 CROSS JOIN lk
),
l3 AS (
  SELECT l2.*,
    IFF(IS_BAL, 0,
        CASE WHEN IS_LARGE THEN ROUND(BASE_USD * FX * LARGE_MULT, -3)
             WHEN IS_ROUND THEN GREATEST(10000, ROUND(BASE_USD * FX, -4))
             ELSE ROUND(BASE_USD * FX, 0) + CENTS / 100 END
        * CASE WHEN SOURCE = 'AR' THEN -1                         -- revenue lines are credits
               WHEN SOURCE = 'Manual' AND R_REV <= 15 THEN -1     -- some manual reversals
               ELSE 1 END) AS DETAIL_AMT
  FROM l2
)
SELECT
  l3.JOURNAL_ID, l3.LINE_NO, l3.POSTING_DATE,
  DATEADD(SECOND, l3.ENTRY_SEC, l3.POSTING_DATE::TIMESTAMP_NTZ) AS ENTRY_TIMESTAMP,
  l3.ENTITY, l3.ACCOUNT_CODE, coa.ACCOUNT_NAME, coa.ACCOUNT_TYPE,
  IFF(coa.ACCOUNT_TYPE IN ('Revenue','COGS','Opex'), l3.CC_PL, 'CC000-CORPORATE') AS COST_CENTER,
  IFF(l3.IS_BAL, -SUM(l3.DETAIL_AMT) OVER (PARTITION BY l3.JOURNAL_ID), l3.DETAIL_AMT)::NUMBER(16,2) AS AMOUNT,
  l3.CURRENCY, l3.DESCRIPTION, l3.CREATED_BY, l3.APPROVED_BY, l3.SOURCE
FROM l3 JOIN coa ON coa.ACCOUNT_CODE = l3.ACCOUNT_CODE;

------------------------------------------------------------------------------
-- 9. EMPLOYEES (500): 1 CEO, 8 department heads, 48 managers, staff
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE EMPLOYEES (
  EMPLOYEE_ID  NUMBER,
  FULL_NAME    VARCHAR,
  EMAIL        VARCHAR,
  DEPARTMENT   VARCHAR,
  JOB_TITLE    VARCHAR,
  LOCATION     VARCHAR,
  HIRE_DATE    DATE,
  SALARY       NUMBER(12,2),
  MANAGER_ID   NUMBER,
  STATUS       VARCHAR
) COMMENT = 'Synthetic employees; SALARY in USD';

INSERT INTO EMPLOYEES
WITH lk AS (
  SELECT
    ARRAY_CONSTRUCT('Aarav','Vivaan','Aditya','Priya','Ananya','Diya','Rohan','Kavya','Arjun','Isha',
                    'James','Olivia','Liam','Emma','Noah','Sophia','Hiroshi','Yuki','Haruto','Sakura',
                    'Lukas','Mia','Felix','Hannah','Wei','Mei','Jun','Siti','Oliver','Amelia') AS FN,
    ARRAY_CONSTRUCT('Sharma','Patel','Iyer','Reddy','Gupta','Nair','Mehta','Singh','Kapoor','Rao',
                    'Smith','Johnson','Brown','Taylor','Wilson','Davies','Tanaka','Suzuki','Sato',
                    'Muller','Schmidt','Weber','Tan','Lim','Ng','Chen','Joshi','Desai','Clarke','Becker') AS LN,
    ARRAY_CONSTRUCT('Sales','Marketing','Operations','Finance','Human Resources','IT','R&D','Supply Chain') AS DEPT,
    ARRAY_CONSTRUCT(
      ARRAY_CONSTRUCT('Account Executive','Sales Representative','Key Account Manager'),
      ARRAY_CONSTRUCT('Marketing Specialist','Content Strategist','Digital Marketing Analyst'),
      ARRAY_CONSTRUCT('Production Supervisor','Process Engineer','Maintenance Technician'),
      ARRAY_CONSTRUCT('Financial Analyst','Accountant','AP Specialist'),
      ARRAY_CONSTRUCT('HR Business Partner','Recruiter','Payroll Specialist'),
      ARRAY_CONSTRUCT('Data Engineer','Systems Administrator','Software Engineer'),
      ARRAY_CONSTRUCT('Research Scientist','Design Engineer','Lab Technician'),
      ARRAY_CONSTRUCT('Buyer','Logistics Coordinator','Demand Planner')) AS TITLES,
    ARRAY_CONSTRUCT('Mumbai','Bengaluru','Pune','Chennai','New York','Houston','London','Munich','Osaka','Singapore') AS LOC
),
g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS ID,
         UNIFORM(0, 999999, RANDOM(901)) AS R_FN,
         UNIFORM(0, 999999, RANDOM(902)) AS R_LN,
         UNIFORM(0, 2,      RANDOM(903)) AS R_T,
         UNIFORM(0, 9,      RANDOM(904)) AS R_LOC,
         UNIFORM(0, 5900,   RANDOM(905)) AS R_HIRE,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(906)) AS U_SAL,
         UNIFORM(1, 100,    RANDOM(907)) AS R_EXIT
  FROM TABLE(GENERATOR(ROWCOUNT => 500))
),
b AS (
  SELECT g.*, MOD(g.ID, 8) AS D,
         CASE WHEN g.ID = 1 THEN 'CEO' WHEN g.ID <= 9 THEN 'HEAD' WHEN g.ID <= 65 THEN 'MANAGER' ELSE 'STAFF' END AS LVL,
         GET(lk.FN, MOD(g.R_FN, ARRAY_SIZE(lk.FN)))::STRING AS FIRST_NAME,
         GET(lk.LN, MOD(g.R_LN, ARRAY_SIZE(lk.LN)))::STRING AS LAST_NAME
  FROM g CROSS JOIN lk
)
SELECT
  b.ID,
  b.FIRST_NAME || ' ' || b.LAST_NAME,
  LOWER(b.FIRST_NAME || '.' || b.LAST_NAME || b.ID) || '@accel-demo.example.com',
  IFF(b.LVL = 'CEO', 'Executive', GET(lk.DEPT, b.D)::STRING),
  CASE b.LVL WHEN 'CEO' THEN 'Chief Executive Officer'
             WHEN 'HEAD' THEN 'Head of ' || GET(lk.DEPT, b.D)::STRING
             WHEN 'MANAGER' THEN GET(lk.DEPT, b.D)::STRING || ' Manager'
             ELSE GET(GET(lk.TITLES, b.D), b.R_T)::STRING END,
  GET(lk.LOC, b.R_LOC)::STRING,
  IFF(b.LVL = 'CEO', '2010-01-04'::DATE, DATEADD(DAY, b.R_HIRE, '2010-06-01'::DATE)),
  ROUND(CASE b.LVL WHEN 'CEO' THEN 450000
                   WHEN 'HEAD' THEN 180000 + b.U_SAL * 80000
                   WHEN 'MANAGER' THEN 95000 + b.U_SAL * 55000
                   ELSE 35000 + b.U_SAL * 75000 END, -2)::NUMBER(12,2),
  CASE b.LVL WHEN 'CEO' THEN NULL
             WHEN 'HEAD' THEN 1
             WHEN 'MANAGER' THEN IFF(b.D < 2, b.D + 8, b.D)                       -- head of same department
             ELSE 16 + b.D + 8 * MOD(FLOOR(b.ID / 8), 6) END,                       -- a manager in same department
  IFF(b.LVL = 'STAFF' AND b.R_EXIT <= 8, 'Exited', 'Active')
FROM b CROSS JOIN lk;

------------------------------------------------------------------------------
-- 10. SUPPORT_TICKETS (2,000) - sentence templates per topic
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE SUPPORT_TICKETS (
  TICKET_ID    NUMBER,
  CREATED_AT   TIMESTAMP_NTZ,
  CUSTOMER_ID  NUMBER,
  PRODUCT_ID   NUMBER,
  CHANNEL      VARCHAR,
  SUBJECT      VARCHAR,
  BODY         VARCHAR,
  PRIORITY     VARCHAR,
  STATUS       VARCHAR,
  RESOLVED_AT  TIMESTAMP_NTZ
) COMMENT = 'Customer support tickets with free text for AI demos';

INSERT INTO SUPPORT_TICKETS
WITH lk AS (
  SELECT
    -- topics: 0 delivery delay, 1 billing error, 2 product defect, 3 praise,
    --         4 installation help, 5 return/refund, 6 account access, 7 warranty
    ARRAY_CONSTRUCT(
      ARRAY_CONSTRUCT('Order {order} still not delivered','Delivery delayed again','Where is my shipment?'),
      ARRAY_CONSTRUCT('Incorrect amount on invoice for {order}','Charged twice for the same order','Tax details wrong on invoice'),
      ARRAY_CONSTRUCT('{product} stopped working','Defective units received','Quality issue with {product}'),
      ARRAY_CONSTRUCT('Great service from your team','Thank you for the quick delivery','Very happy with {product}'),
      ARRAY_CONSTRUCT('Need help installing {product}','Setup instructions unclear','Configuration question for {product}'),
      ARRAY_CONSTRUCT('Return request for {order}','Refund not received yet','Wrong item shipped'),
      ARRAY_CONSTRUCT('Cannot log in to the customer portal','Password reset not working','Need portal access for a new team member'),
      ARRAY_CONSTRUCT('Warranty claim for {product}','Is my {product} still under warranty?','Warranty repair status')) AS SUBJ,
    ARRAY_CONSTRUCT(
      ARRAY_CONSTRUCT('I placed order {order} for the {product} and it has still not arrived.',
                      'Our shipment of {product} was promised last week but is now {days} days late.',
                      'The tracking for order {order} has not updated in {days} days.'),
      ARRAY_CONSTRUCT('The invoice for order {order} shows {amount} but our agreed price was lower.',
                      'We have been charged twice for order {order}.',
                      'The tax details on our latest invoice for order {order} are incorrect.'),
      ARRAY_CONSTRUCT('The {product} we received stopped working after only {days} days of use.',
                      'Several units of {product} in order {order} arrived damaged.',
                      'The {product} overheats and shuts down during normal operation.'),
      ARRAY_CONSTRUCT('I wanted to say thank you for delivering order {order} ahead of schedule.',
                      'The {product} has exceeded our expectations.',
                      'Your support engineer resolved our issue in under an hour.'),
      ARRAY_CONSTRUCT('We are trying to install the {product} but the manual is not clear.',
                      'Our technician cannot complete the setup of the {product}.',
                      'I need guidance on configuring the {product} for our site.'),
      ARRAY_CONSTRUCT('We would like to return the {product} from order {order}.',
                      'We returned the goods from order {order} {days} days ago but have not received the refund.',
                      'We received a different item instead of the {product} we ordered.'),
      ARRAY_CONSTRUCT('I am unable to log in to the customer portal since yesterday.',
                      'The password reset email never arrives.',
                      'We need portal access for a new buyer in our procurement team.'),
      ARRAY_CONSTRUCT('Our {product} failed within the warranty period.',
                      'I would like to check the warranty status of the {product} purchased under order {order}.',
                      'We sent the {product} for warranty repair {days} days ago.')) AS S1,
    ARRAY_CONSTRUCT(
      ARRAY_CONSTRUCT('Your logistics partner keeps rescheduling the delivery without any explanation.',
                      'Our production line is waiting on these parts and the delay is costing us money.',
                      'The courier marked it as an attempted delivery but nobody came to our site.'),
      ARRAY_CONSTRUCT('The discount agreed in our contract has not been applied.',
                      'Our finance team cannot release the payment until the invoice is corrected.',
                      'This is the second billing mistake this quarter.'),
      ARRAY_CONSTRUCT('We have attached photos of the damaged packaging and the serial numbers.',
                      'This is affecting shop floor safety and we have stopped using the batch.',
                      'Three out of ten units in the batch show the same fault.'),
      ARRAY_CONSTRUCT('The build quality is excellent and our team loves it.',
                      'Communication throughout the process was clear and proactive.',
                      'It has already improved productivity on our line.'),
      ARRAY_CONSTRUCT('The wiring diagram does not match the unit we received.',
                      'The firmware update fails at 80 percent every time.',
                      'We could not find the calibration steps in the documentation.'),
      ARRAY_CONSTRUCT('The items are unused and still in the original packaging.',
                      'Your portal shows the return as received but the refund status is still pending.',
                      'We need the correct item urgently for an ongoing project.'),
      ARRAY_CONSTRUCT('We cannot download invoices or track orders without access.',
                      'I have checked the spam folder and tried two different browsers.',
                      'Our previous portal admin has left the company.'),
      ARRAY_CONSTRUCT('The invoice and serial number are attached for reference.',
                      'We have not received any update from the service centre.',
                      'The unit has been used strictly as per the manual.')) AS S2,
    ARRAY_CONSTRUCT(
      ARRAY_CONSTRUCT('Please share a firm delivery date today.',
                      'If this is not resolved this week we will have to cancel the order.',
                      'Kindly escalate this to your dispatch team.'),
      ARRAY_CONSTRUCT('Please issue a credit note for the difference.',
                      'Please send a corrected invoice at the earliest.',
                      'Please refund the duplicate charge to our account.'),
      ARRAY_CONSTRUCT('Please arrange a replacement as soon as possible.',
                      'We need a root cause analysis from your quality team.',
                      'Kindly advise whether the whole batch should be recalled.'),
      ARRAY_CONSTRUCT('We will definitely order again.',
                      'Please pass on our thanks to the team.',
                      'Keep up the good work.'),
      ARRAY_CONSTRUCT('Could someone schedule a call with our team?',
                      'Please send an updated installation guide.',
                      'An on-site visit would be appreciated.'),
      ARRAY_CONSTRUCT('Please share the return authorisation number.',
                      'Kindly process the refund of {amount} immediately.',
                      'Please arrange a pickup and a replacement.'),
      ARRAY_CONSTRUCT('Please reset our account access.',
                      'Please let me know what details you need from us.',
                      'Kindly treat this as urgent.'),
      ARRAY_CONSTRUCT('Please confirm the next steps for the claim.',
                      'Kindly expedite the repair.',
                      'Let us know if a replacement can be provided instead.')) AS S3,
    ARRAY_CONSTRUCT('Our account manager is copied on this message.',
                    'This is our third follow-up on this issue.',
                    'Please refer to our earlier ticket for context.',
                    'Thanks in advance for your help.') AS S4,
    ARRAY_CONSTRUCT('Email','Phone','Chat','Web') AS CH
),
g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS ID,
         UNIFORM(1, 100000, RANDOM(951)) AS ORD_IDX,
         UNIFORM(1, 100,    RANDOM(952)) AS R_TOPIC,
         UNIFORM(0, 2,      RANDOM(953)) AS I_SUBJ,
         UNIFORM(0, 2,      RANDOM(954)) AS I1,
         UNIFORM(0, 2,      RANDOM(955)) AS I2,
         UNIFORM(0, 2,      RANDOM(956)) AS I3,
         UNIFORM(0, 3,      RANDOM(957)) AS I4,
         UNIFORM(1, 100,    RANDOM(958)) AS R_S4,
         UNIFORM(3, 21,     RANDOM(959)) AS DAYS,
         UNIFORM(1, 100,    RANDOM(960)) AS R_CH,
         UNIFORM(1, 100,    RANDOM(961)) AS R_PRI,
         UNIFORM(1, 100,    RANDOM(962)) AS R_STAT,
         UNIFORM(1440, 28800, RANDOM(963)) AS MIN_AFTER_ORDER,   -- 1-20 days after order
         UNIFORM(60, 7200,  RANDOM(964)) AS MIN_TO_RESOLVE       -- 1 hour - 5 days
  FROM TABLE(GENERATOR(ROWCOUNT => 2000))
),
b AS (
  SELECT g.*,
         CASE WHEN R_TOPIC <= 22 THEN 0 WHEN R_TOPIC <= 37 THEN 1 WHEN R_TOPIC <= 57 THEN 2
              WHEN R_TOPIC <= 67 THEN 3 WHEN R_TOPIC <= 75 THEN 4 WHEN R_TOPIC <= 85 THEN 5
              WHEN R_TOPIC <= 92 THEN 6 ELSE 7 END AS T,
         o.ORDER_ID, o.CUSTOMER_ID, o.ORDER_DATE, o.ORDER_TOTAL, ol.PRODUCT_ID, p.PRODUCT_NAME,
         LEAST(DATEADD(MINUTE, g.MIN_AFTER_ORDER, o.ORDER_DATE::TIMESTAMP_NTZ),
               DATEADD(MINUTE, -g.MIN_TO_RESOLVE, '2026-09-30 23:59:00'::TIMESTAMP_NTZ)) AS CREATED_AT
  FROM g
  JOIN ORDERS o       ON o.ORDER_ID = 1000000 + g.ORD_IDX
  JOIN ORDER_LINES ol ON ol.ORDER_ID = o.ORDER_ID AND ol.LINE_NO = 1
  JOIN PRODUCTS p     ON p.PRODUCT_ID = ol.PRODUCT_ID
),
t AS (
  SELECT b.*,
    GET(GET(lk.SUBJ, T), I_SUBJ)::STRING AS SUBJ_T,
    GET(GET(lk.S1, T), I1)::STRING || ' ' || GET(GET(lk.S2, T), I2)::STRING || ' ' || GET(GET(lk.S3, T), I3)::STRING
      || IFF(T <> 3 AND R_S4 <= 50, ' ' || GET(lk.S4, I4)::STRING, '') AS BODY_T,
    CASE WHEN R_CH <= 40 THEN 'Email' WHEN R_CH <= 65 THEN 'Phone' WHEN R_CH <= 85 THEN 'Chat' ELSE 'Web' END AS CHANNEL,
    CASE WHEN T = 3 THEN 'Low'
         WHEN T IN (0, 1, 2) THEN CASE WHEN R_PRI <= 10 THEN 'Critical' WHEN R_PRI <= 40 THEN 'High'
                                       WHEN R_PRI <= 80 THEN 'Medium' ELSE 'Low' END
         ELSE CASE WHEN R_PRI <= 3 THEN 'Critical' WHEN R_PRI <= 20 THEN 'High'
                   WHEN R_PRI <= 65 THEN 'Medium' ELSE 'Low' END END AS PRIORITY
  FROM b CROSS JOIN lk
)
SELECT
  ID AS TICKET_ID,
  CREATED_AT,
  CUSTOMER_ID,
  PRODUCT_ID,
  CHANNEL,
  REPLACE(REPLACE(SUBJ_T, '{product}', PRODUCT_NAME), '{order}', 'ORD-' || ORDER_ID) AS SUBJECT,
  REPLACE(REPLACE(REPLACE(REPLACE(BODY_T,
      '{product}', PRODUCT_NAME),
      '{order}',   'ORD-' || ORDER_ID),
      '{days}',    DAYS::STRING),
      '{amount}',  'USD ' || TRIM(TO_CHAR(ORDER_TOTAL, '999,999,990.00'))) AS BODY,
  PRIORITY,
  CASE WHEN CREATED_AT >= '2026-09-23'::TIMESTAMP_NTZ AND R_STAT <= 70 THEN 'Open'
       WHEN R_STAT <= IFF(PRIORITY IN ('Critical','High'), 15, 5) THEN 'Escalated'
       ELSE 'Resolved' END AS STATUS,
  CASE WHEN CREATED_AT >= '2026-09-23'::TIMESTAMP_NTZ AND R_STAT <= 70 THEN NULL
       WHEN R_STAT <= IFF(PRIORITY IN ('Critical','High'), 15, 5) THEN NULL
       ELSE DATEADD(MINUTE, MIN_TO_RESOLVE, CREATED_AT) END AS RESOLVED_AT
FROM t;

------------------------------------------------------------------------------
-- 11. Clean up helpers, grant read access, verify
------------------------------------------------------------------------------
DROP TABLE IF EXISTS TMP_DAY_COUNTS;
DROP TABLE IF EXISTS TMP_CUST_REGION;
DROP TABLE IF EXISTS TMP_ORDERS;

GRANT SELECT ON ALL TABLES IN SCHEMA ACCEL_DB.DEMO TO ROLE ACCEL_VIEWER;

-- Row-count check (expected: 5000 / 200 / 50 / 8 / 100000 / ~250000 / 20000 / 230400 / ~200000 / 500 / 2000)
SELECT 'CUSTOMERS' AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM CUSTOMERS
UNION ALL SELECT 'PRODUCTS',            COUNT(*) FROM PRODUCTS
UNION ALL SELECT 'SUPPLIERS',           COUNT(*) FROM SUPPLIERS
UNION ALL SELECT 'PLANTS',              COUNT(*) FROM PLANTS
UNION ALL SELECT 'ORDERS',              COUNT(*) FROM ORDERS
UNION ALL SELECT 'ORDER_LINES',         COUNT(*) FROM ORDER_LINES
UNION ALL SELECT 'PURCHASE_ORDERS',     COUNT(*) FROM PURCHASE_ORDERS
UNION ALL SELECT 'INVENTORY_SNAPSHOTS', COUNT(*) FROM INVENTORY_SNAPSHOTS
UNION ALL SELECT 'GL_JOURNAL',          COUNT(*) FROM GL_JOURNAL
UNION ALL SELECT 'EMPLOYEES',           COUNT(*) FROM EMPLOYEES
UNION ALL SELECT 'SUPPORT_TICKETS',     COUNT(*) FROM SUPPORT_TICKETS
ORDER BY TABLE_NAME;

-- Integrity checks (all three should return 0)
SELECT
  (SELECT COUNT(*) FROM ORDERS o
     JOIN (SELECT ORDER_ID, SUM(NET_AMOUNT) S FROM ORDER_LINES GROUP BY 1) l USING (ORDER_ID)
    WHERE o.ORDER_TOTAL <> l.S)                                               AS ORDER_TOTAL_MISMATCHES,
  (SELECT COUNT(*) FROM (SELECT JOURNAL_ID FROM GL_JOURNAL GROUP BY 1 HAVING SUM(AMOUNT) <> 0)) AS UNBALANCED_JOURNALS,
  (SELECT COUNT(*) FROM ORDERS o LEFT JOIN CUSTOMERS c USING (CUSTOMER_ID) WHERE c.CUSTOMER_ID IS NULL) AS ORPHAN_ORDERS;

-- Pattern preview: South region quarterly revenue (note the 2026-Q2 dip)
SELECT TO_CHAR(DATE_TRUNC('QUARTER', o.ORDER_DATE), 'YYYY-MM') AS QUARTER_START,
       c.REGION, ROUND(SUM(o.ORDER_TOTAL)) AS REVENUE_USD
FROM ORDERS o JOIN CUSTOMERS c USING (CUSTOMER_ID)
WHERE o.ORDER_DATE >= '2025-07-01' AND c.REGION = 'South'
GROUP BY 1, 2 ORDER BY 1;
