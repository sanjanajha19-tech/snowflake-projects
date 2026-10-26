/* =============================================================================
   Asset 23 - Customer 360 & Entity Resolution
   File  06_customer_360_view.sql
   Purpose
     C360.CUSTOMER_360 - one row per golden customer with orders, lifetime
     value (INR), last order, open tickets and e-commerce activity.
     Sentiment is added by 07_optional_voc_sentiment.sql once asset 24 has run.
   Run as  ACCEL_ADMIN after 05. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS C360;
USE SCHEMA C360;

-- Illustrative FX rates to INR for lifetime value roll-up.            -- EDIT ME
-- Replace with your treasury / ERP period-average rates. Unknown currencies default to 1.
CREATE OR REPLACE TABLE C360.FX_TO_INR (CURRENCY VARCHAR, INR_PER_UNIT NUMBER(12,4));
INSERT INTO C360.FX_TO_INR VALUES
  ('INR', 1), ('USD', 83.0), ('GBP', 105.0), ('EUR', 90.0), ('JPY', 0.56), ('SGD', 62.0);   -- EDIT ME

CREATE OR REPLACE VIEW C360.CUSTOMER_ORDERS_BY_GOLDEN AS
SELECT x.GOLDEN_ID, o.*,
       o.ORDER_TOTAL * COALESCE(fx.INR_PER_UNIT, 1) AS ORDER_TOTAL_INR
FROM C360.CUSTOMER_XREF x
JOIN ACCEL_DB.DEMO.ORDERS o ON o.CUSTOMER_ID = x.ERP_CUSTOMER_ID
LEFT JOIN C360.FX_TO_INR fx ON fx.CURRENCY = o.CURRENCY
WHERE x.SOURCE_SYSTEM = 'ERP';

CREATE OR REPLACE VIEW C360.CUSTOMER_TICKETS_BY_GOLDEN AS
SELECT x.GOLDEN_ID, t.*
FROM C360.CUSTOMER_XREF x
JOIN ACCEL_DB.DEMO.SUPPORT_TICKETS t ON t.CUSTOMER_ID = x.ERP_CUSTOMER_ID
WHERE x.SOURCE_SYSTEM = 'ERP';

CREATE OR REPLACE VIEW C360.CUSTOMER_360 AS
WITH asof AS (SELECT MAX(ORDER_DATE) AS AS_OF_DATE FROM ACCEL_DB.DEMO.ORDERS),
ord AS (
    SELECT o.GOLDEN_ID,
           COUNT(*)                                                          AS ORDER_COUNT,
           COUNT_IF(o.STATUS IN ('Delivered', 'Shipped'))                    AS FULFILLED_ORDERS,
           COUNT_IF(o.STATUS = 'Returned')                                   AS RETURNED_ORDERS,
           COUNT_IF(o.STATUS = 'Cancelled')                                  AS CANCELLED_ORDERS,
           SUM(IFF(o.STATUS IN ('Delivered', 'Shipped'), o.ORDER_TOTAL_INR, 0)) AS LIFETIME_VALUE_INR,
           SUM(IFF(o.STATUS IN ('Delivered', 'Shipped') AND o.ORDER_DATE > DATEADD('day', -365, a.AS_OF_DATE),
                   o.ORDER_TOTAL_INR, 0))                                    AS REVENUE_LAST_365D_INR,
           MIN(o.ORDER_DATE)                                                 AS FIRST_ORDER_DATE,
           MAX(o.ORDER_DATE)                                                 AS LAST_ORDER_DATE,
           MODE(o.CHANNEL)                                                   AS PREFERRED_CHANNEL
    FROM C360.CUSTOMER_ORDERS_BY_GOLDEN o CROSS JOIN asof a
    GROUP BY o.GOLDEN_ID
),
tix AS (
    SELECT GOLDEN_ID,
           COUNT(*)                                                    AS TICKET_COUNT,
           COUNT_IF(STATUS IN ('Open', 'Escalated'))                   AS OPEN_TICKETS,
           COUNT_IF(STATUS = 'Escalated')                              AS ESCALATED_TICKETS,
           COUNT_IF(STATUS IN ('Open', 'Escalated') AND PRIORITY IN ('High', 'Critical')) AS OPEN_HIGH_PRIORITY_TICKETS,
           MAX(CREATED_AT)                                             AS LAST_TICKET_AT,
           ROUND(AVG(IFF(RESOLVED_AT IS NOT NULL, DATEDIFF('hour', CREATED_AT, RESOLVED_AT), NULL)), 1) AS AVG_RESOLUTION_HOURS
    FROM C360.CUSTOMER_TICKETS_BY_GOLDEN
    GROUP BY GOLDEN_ID
)
SELECT g.GOLDEN_ID, g.CUSTOMER_NAME, g.SEGMENT, g.INDUSTRY, g.REGION, g.CITY, g.COUNTRY,
       g.EMAIL, g.PHONE, g.PAN_NUMBER, g.CREDIT_LIMIT,
       g.PRIMARY_ERP_CUSTOMER_ID, g.ERP_CUSTOMER_IDS, g.SOURCE_SYSTEMS, g.SOURCE_COUNT, g.RECORD_COUNT,
       g.CRM_ACCOUNT_OWNER,
       COALESCE(o.ORDER_COUNT, 0)                      AS ORDER_COUNT,
       COALESCE(o.FULFILLED_ORDERS, 0)                 AS FULFILLED_ORDERS,
       COALESCE(o.RETURNED_ORDERS, 0)                  AS RETURNED_ORDERS,
       COALESCE(o.CANCELLED_ORDERS, 0)                 AS CANCELLED_ORDERS,
       ROUND(COALESCE(o.LIFETIME_VALUE_INR, 0), 2)     AS LIFETIME_VALUE_INR,
       ROUND(COALESCE(o.REVENUE_LAST_365D_INR, 0), 2)  AS REVENUE_LAST_365D_INR,
       ROUND(o.LIFETIME_VALUE_INR / NULLIF(o.FULFILLED_ORDERS, 0), 2) AS AVG_ORDER_VALUE_INR,
       o.FIRST_ORDER_DATE, o.LAST_ORDER_DATE,
       DATEDIFF('day', o.LAST_ORDER_DATE, a.AS_OF_DATE) AS DAYS_SINCE_LAST_ORDER,
       o.PREFERRED_CHANNEL,
       COALESCE(g.ECOM_LIFETIME_ORDERS, 0)             AS ECOM_LIFETIME_ORDERS,
       COALESCE(g.ECOM_LIFETIME_SPEND_INR, 0)          AS ECOM_LIFETIME_SPEND_INR,
       g.ECOM_LAST_ORDER_DATE,
       ROUND(COALESCE(o.LIFETIME_VALUE_INR, 0) + COALESCE(g.ECOM_LIFETIME_SPEND_INR, 0), 2) AS TOTAL_VALUE_ALL_CHANNELS_INR,
       COALESCE(t.TICKET_COUNT, 0)                     AS TICKET_COUNT,
       COALESCE(t.OPEN_TICKETS, 0)                     AS OPEN_TICKETS,
       COALESCE(t.ESCALATED_TICKETS, 0)                AS ESCALATED_TICKETS,
       COALESCE(t.OPEN_HIGH_PRIORITY_TICKETS, 0)       AS OPEN_HIGH_PRIORITY_TICKETS,
       t.LAST_TICKET_AT, t.AVG_RESOLUTION_HOURS,
       CASE WHEN o.LAST_ORDER_DATE IS NULL                                  THEN 'No ERP orders'
            WHEN DATEDIFF('day', o.LAST_ORDER_DATE, a.AS_OF_DATE) > 365     THEN 'Lapsed'
            WHEN DATEDIFF('day', o.LAST_ORDER_DATE, a.AS_OF_DATE) > 180     THEN 'At risk'
            ELSE 'Active' END                                                AS LIFECYCLE_STAGE,
       a.AS_OF_DATE
FROM C360.GOLDEN_CUSTOMER g
CROSS JOIN asof a
LEFT JOIN ord o ON o.GOLDEN_ID = g.GOLDEN_ID
LEFT JOIN tix t ON t.GOLDEN_ID = g.GOLDEN_ID;

-- Read access for analysts / viewers
GRANT USAGE ON SCHEMA ACCEL_DB.C360 TO ROLE ACCEL_ANALYST;
GRANT USAGE ON SCHEMA ACCEL_DB.C360 TO ROLE ACCEL_VIEWER;
GRANT SELECT ON ALL TABLES IN SCHEMA ACCEL_DB.C360 TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ACCEL_DB.C360 TO ROLE ACCEL_ANALYST;
GRANT SELECT ON VIEW ACCEL_DB.C360.CUSTOMER_360 TO ROLE ACCEL_VIEWER;

-- Top customers by lifetime value, with service health
SELECT GOLDEN_ID, CUSTOMER_NAME, SEGMENT, SOURCE_COUNT, ORDER_COUNT, LIFETIME_VALUE_INR,
       LAST_ORDER_DATE, OPEN_TICKETS, LIFECYCLE_STAGE
FROM C360.CUSTOMER_360
ORDER BY LIFETIME_VALUE_INR DESC
LIMIT 20;
