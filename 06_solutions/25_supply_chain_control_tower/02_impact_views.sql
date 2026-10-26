/* =============================================================================
   Asset 25 - Supply Chain Control Tower
   File  02_impact_views.sql
   Purpose
     SCT.LATE_PURCHASE_ORDERS     - open POs past their promised date
     SCT.OPEN_CUSTOMER_ORDERS     - customer order lines still open
                                    (assumption: STATUS = 'Shipped' within the last
                                    OPEN_ORDER_DAYS days; DEMO has no 'Open' status)
     SCT.LATE_PO_IMPACT           - each late PO with the customer orders and
                                    revenue exposed at the same plant-product
     SCT.REVENUE_AT_RISK_BY_PLANT - stockout revenue at risk rolled up per plant
   Run as  ACCEL_ADMIN after 01. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SCT;
USE SCHEMA SCT;

CREATE OR REPLACE VIEW SCT.LATE_PURCHASE_ORDERS AS
SELECT p.PO_ID, p.PO_DATE, p.SUPPLIER_ID, s.SUPPLIER_NAME, p.PLANT_ID, p.PRODUCT_ID,
       p.QUANTITY, p.UNIT_COST, ROUND(p.QUANTITY * p.UNIT_COST, 2) AS PO_VALUE,
       p.PROMISED_DATE, p.STATUS,
       DATEDIFF('day', p.PROMISED_DATE, cfg.AS_OF_DATE) AS DAYS_LATE,
       cfg.AS_OF_DATE
FROM ACCEL_DB.DEMO.PURCHASE_ORDERS p
CROSS JOIN SCT.CONFIG_V cfg
LEFT JOIN ACCEL_DB.DEMO.SUPPLIERS s ON s.SUPPLIER_ID = p.SUPPLIER_ID
WHERE p.RECEIVED_DATE IS NULL
  AND p.STATUS <> 'Cancelled'
  AND p.PROMISED_DATE < cfg.AS_OF_DATE;

CREATE OR REPLACE VIEW SCT.OPEN_CUSTOMER_ORDERS AS
SELECT o.ORDER_ID, o.ORDER_DATE, o.CUSTOMER_ID, o.PLANT_ID, o.CHANNEL, o.STATUS, o.CURRENCY,
       l.LINE_NO, l.PRODUCT_ID, l.QUANTITY, l.NET_AMOUNT
FROM ACCEL_DB.DEMO.ORDERS o
JOIN ACCEL_DB.DEMO.ORDER_LINES l ON l.ORDER_ID = o.ORDER_ID
CROSS JOIN SCT.CONFIG_V cfg
WHERE o.STATUS = 'Shipped'                                                  -- EDIT ME: your open statuses
  AND o.ORDER_DATE > DATEADD('day', -cfg.OPEN_ORDER_DAYS, cfg.AS_OF_DATE);

CREATE OR REPLACE VIEW SCT.LATE_PO_IMPACT AS
WITH exposure AS (
    SELECT PLANT_ID, PRODUCT_ID,
           COUNT(DISTINCT ORDER_ID)    AS OPEN_CUSTOMER_ORDERS,
           COUNT(DISTINCT CUSTOMER_ID) AS CUSTOMERS_EXPOSED,
           SUM(QUANTITY)               AS OPEN_ORDER_QTY,
           SUM(NET_AMOUNT)             AS OPEN_ORDER_VALUE
    FROM SCT.OPEN_CUSTOMER_ORDERS
    GROUP BY PLANT_ID, PRODUCT_ID
)
SELECT lp.PO_ID, lp.SUPPLIER_ID, lp.SUPPLIER_NAME, lp.PLANT_ID, sr.PLANT_NAME, lp.PRODUCT_ID,
       sr.SKU, sr.PRODUCT_NAME, lp.QUANTITY AS LATE_QTY, lp.PO_VALUE, lp.PROMISED_DATE, lp.DAYS_LATE,
       sr.ON_HAND_QTY, sr.DAYS_OF_SUPPLY, sr.PROJECTED_ON_HAND, sr.RISK_LEVEL AS STOCKOUT_RISK_LEVEL,
       COALESCE(e.OPEN_CUSTOMER_ORDERS, 0) AS OPEN_CUSTOMER_ORDERS,
       COALESCE(e.CUSTOMERS_EXPOSED, 0)    AS CUSTOMERS_EXPOSED,
       COALESCE(e.OPEN_ORDER_QTY, 0)       AS OPEN_ORDER_QTY,
       ROUND(COALESCE(e.OPEN_ORDER_VALUE, 0), 2) AS OPEN_ORDER_VALUE,
       -- revenue at risk attributable to this PO: the part of the stockout shortfall
       -- this late quantity would have covered, valued at the unit selling price
       ROUND(LEAST(lp.QUANTITY, COALESCE(sr.SHORTFALL_QTY, 0)) * COALESCE(sr.UNIT_PRICE, 0), 2) AS REVENUE_AT_RISK,
       CASE WHEN sr.RISK_LEVEL = 'CRITICAL' AND COALESCE(e.OPEN_CUSTOMER_ORDERS, 0) > 0 THEN 'Expedite now'
            WHEN sr.RISK_LEVEL IN ('CRITICAL', 'HIGH')                                  THEN 'Expedite'
            WHEN lp.DAYS_LATE > 30                                                      THEN 'Chase supplier / re-source'
            ELSE 'Monitor' END AS RECOMMENDED_ACTION
FROM SCT.LATE_PURCHASE_ORDERS lp
LEFT JOIN SCT.STOCKOUT_RISK sr ON sr.PLANT_ID = lp.PLANT_ID AND sr.PRODUCT_ID = lp.PRODUCT_ID
LEFT JOIN exposure e           ON e.PLANT_ID  = lp.PLANT_ID AND e.PRODUCT_ID  = lp.PRODUCT_ID;

CREATE OR REPLACE VIEW SCT.REVENUE_AT_RISK_BY_PLANT AS
SELECT sr.PLANT_ID, sr.PLANT_NAME,
       COUNT_IF(sr.RISK_LEVEL = 'CRITICAL')                 AS CRITICAL_SKUS,
       COUNT_IF(sr.RISK_LEVEL = 'HIGH')                     AS HIGH_SKUS,
       COUNT_IF(sr.RISK_LEVEL = 'MEDIUM')                   AS MEDIUM_SKUS,
       ROUND(SUM(sr.REVENUE_AT_RISK), 2)                    AS REVENUE_AT_RISK,
       ROUND(SUM(sr.INVENTORY_VALUE_AT_COST), 2)            AS INVENTORY_VALUE_AT_COST,
       ROUND(MEDIAN(sr.DAYS_OF_SUPPLY), 1)                  AS MEDIAN_DAYS_OF_SUPPLY,
       SUM(sr.LATE_OPEN_POS)                                AS LATE_OPEN_POS
FROM SCT.STOCKOUT_RISK sr
GROUP BY sr.PLANT_ID, sr.PLANT_NAME;

GRANT SELECT ON ALL VIEWS IN SCHEMA ACCEL_DB.SCT TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS IN SCHEMA ACCEL_DB.SCT TO ROLE ACCEL_VIEWER;

SELECT * FROM SCT.REVENUE_AT_RISK_BY_PLANT ORDER BY REVENUE_AT_RISK DESC;

SELECT PO_ID, SUPPLIER_NAME, PLANT_NAME, PRODUCT_NAME, DAYS_LATE, STOCKOUT_RISK_LEVEL,
       OPEN_CUSTOMER_ORDERS, REVENUE_AT_RISK, RECOMMENDED_ACTION
FROM SCT.LATE_PO_IMPACT
ORDER BY REVENUE_AT_RISK DESC, DAYS_LATE DESC
LIMIT 25;
