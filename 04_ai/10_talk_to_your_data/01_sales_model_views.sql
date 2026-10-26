/*=============================================================================
  ASSET 10 - Talk to your Data Agent
  File 01   : GOLD-like sales model (views) in ACCEL_DB.SEMANTIC
  Creates   : SALES_ORDERS_V, SALES_ORDER_LINES_V, SALES_CUSTOMERS_V, SALES_PRODUCTS_V
  Run as    : ACCEL_ADMIN
  Rerun     : safe (CREATE OR REPLACE)
  Notes     : Amounts are treated as already in one reporting currency
              (the demo data is synthetic). For a client, convert ORDER/LINE
              amounts with an FX table before exposing them to Cortex Analyst.
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SEMANTIC COMMENT = 'Asset 10/11: business-friendly views + semantic views for Cortex Analyst';
USE SCHEMA SEMANTIC;

------------------------------------------------------------------------------
-- 1. Orders (one row per order)
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW SALES_ORDERS_V
  COMMENT = 'One row per sales order (GOLD-like). Source: DEMO.ORDERS'
AS
SELECT
    o.ORDER_ID,
    o.ORDER_DATE,
    o.CUSTOMER_ID,
    o.PLANT_ID,
    o.CHANNEL,
    o.STATUS                                              AS ORDER_STATUS,
    o.CURRENCY,
    o.ORDER_TOTAL,
    IFF(o.STATUS IN ('Cancelled', 'Returned'), FALSE, TRUE) AS IS_REVENUE_ORDER
FROM ACCEL_DB.DEMO.ORDERS o;

------------------------------------------------------------------------------
-- 2. Order lines (one row per order line) with revenue and cost
--    Revenue is recognised only for Delivered / Shipped orders.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW SALES_ORDER_LINES_V
  COMMENT = 'One row per order line with net revenue, COGS and margin. Source: DEMO.ORDER_LINES, ORDERS, PRODUCTS'
AS
SELECT
    l.ORDER_ID,
    l.LINE_NO,
    l.PRODUCT_ID,
    l.QUANTITY,
    l.UNIT_PRICE,
    l.DISCOUNT_PCT,
    l.NET_AMOUNT,
    IFF(o.STATUS IN ('Cancelled', 'Returned'), 0, l.NET_AMOUNT)                 AS LINE_REVENUE,
    IFF(o.STATUS IN ('Cancelled', 'Returned'), 0, l.QUANTITY * p.UNIT_COST)     AS LINE_COGS,
    IFF(o.STATUS IN ('Cancelled', 'Returned'), 0, l.QUANTITY)                   AS UNITS_SOLD,
    l.QUANTITY * l.UNIT_PRICE * (l.DISCOUNT_PCT / 100)                          AS DISCOUNT_AMOUNT
FROM ACCEL_DB.DEMO.ORDER_LINES l
JOIN ACCEL_DB.DEMO.ORDERS      o ON o.ORDER_ID   = l.ORDER_ID
JOIN ACCEL_DB.DEMO.PRODUCTS    p ON p.PRODUCT_ID = l.PRODUCT_ID;

------------------------------------------------------------------------------
-- 3. Customers (no PII columns exposed to the LLM layer: no email/phone/PAN)
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW SALES_CUSTOMERS_V
  COMMENT = 'Customer dimension without PII. Source: DEMO.CUSTOMERS'
AS
SELECT
    CUSTOMER_ID,
    CUSTOMER_NAME,
    SEGMENT,
    INDUSTRY,
    REGION,
    COUNTRY,
    CITY,
    CREATED_DATE,
    CREDIT_LIMIT
FROM ACCEL_DB.DEMO.CUSTOMERS;

------------------------------------------------------------------------------
-- 4. Products
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW SALES_PRODUCTS_V
  COMMENT = 'Product dimension. Source: DEMO.PRODUCTS'
AS
SELECT
    PRODUCT_ID,
    SKU,
    PRODUCT_NAME,
    CATEGORY,
    SUB_CATEGORY,
    BRAND,
    UNIT_COST,
    LIST_PRICE,
    LAUNCH_DATE
FROM ACCEL_DB.DEMO.PRODUCTS;

------------------------------------------------------------------------------
-- 5. Grants for analysts (they query through the semantic view / Analyst)
------------------------------------------------------------------------------
GRANT USAGE ON SCHEMA ACCEL_DB.SEMANTIC TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS IN SCHEMA ACCEL_DB.SEMANTIC TO ROLE ACCEL_ANALYST;

-- Quick check
SELECT COUNT(*) AS LINES, SUM(LINE_REVENUE) AS REVENUE, SUM(LINE_COGS) AS COGS
FROM SALES_ORDER_LINES_V;
