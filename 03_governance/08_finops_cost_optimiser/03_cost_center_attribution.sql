/* =============================================================================
   08 FINOPS COST OPTIMIZER | 03_cost_center_attribution.sql
   Showback / chargeback with a COST_CENTER tag:
   - warehouses tagged -> warehouse credits per cost center (incl. idle)
   - users tagged      -> query credits per cost center (shared warehouses)
   - QUERY_TAG fallback: sessions can set QUERY_TAG = 'cost_center=CC-...'
   Run as: ACCEL_ADMIN (owns the tag and the ACCEL warehouses).
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS FINOPS;
USE SCHEMA FINOPS;

CREATE TAG IF NOT EXISTS COST_CENTER
  ALLOWED_VALUES 'CC-DATA-PLATFORM', 'CC-SALES', 'CC-FINANCE', 'CC-SUPPLY-CHAIN', 'CC-HR', 'CC-AI-LAB'   -- EDIT ME
  COMMENT = 'Cost center for showback / chargeback';

-- Tag the accelerator warehouses (owner + tag owner can apply)
ALTER WAREHOUSE ACCEL_WH    SET TAG ACCEL_DB.FINOPS.COST_CENTER = 'CC-DATA-PLATFORM';
ALTER WAREHOUSE ACCEL_AI_WH SET TAG ACCEL_DB.FINOPS.COST_CENTER = 'CC-AI-LAB';

-- Tag users (ACCOUNTADMIN / user owner, because users are owned by USERADMIN): EDIT ME
-- USE ROLE ACCOUNTADMIN;
-- GRANT APPLY ON TAG ACCEL_DB.FINOPS.COST_CENTER TO ROLE USERADMIN;
-- USE ROLE USERADMIN;
-- ALTER USER JANE_DOE SET TAG ACCEL_DB.FINOPS.COST_CENTER = 'CC-FINANCE';
-- USE ROLE ACCEL_ADMIN;

-- Query-tag convention for shared service accounts / tools:
-- ALTER SESSION SET QUERY_TAG = 'cost_center=CC-SALES';

-- ---------------------------------------------------------------------------
-- 1. Warehouse credits by cost center (ACCOUNT_USAGE.TAG_REFERENCES ~2 h latency)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_COST_BY_CENTER_WAREHOUSE AS
WITH wh_tag AS (
  SELECT OBJECT_NAME AS WAREHOUSE_NAME, TAG_VALUE AS COST_CENTER
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE DOMAIN = 'WAREHOUSE' AND TAG_NAME = 'COST_CENTER'
    AND TAG_DATABASE = 'ACCEL_DB' AND TAG_SCHEMA = 'FINOPS' AND OBJECT_DELETED IS NULL
)
SELECT DATE_TRUNC('month', s.USAGE_DATE)::DATE   AS MONTH,
       COALESCE(t.COST_CENTER, 'UNTAGGED')        AS COST_CENTER,
       s.WAREHOUSE_NAME,
       SUM(s.CREDITS_USED)                        AS CREDITS,
       SUM(s.CREDITS_IDLE)                        AS CREDITS_IDLE,
       SUM(s.COST_USD)                            AS COST_USD
FROM V_SPEND_DAILY_BY_WAREHOUSE s
LEFT JOIN wh_tag t ON t.WAREHOUSE_NAME = s.WAREHOUSE_NAME
GROUP BY 1, 2, 3;

-- ---------------------------------------------------------------------------
-- 2. Query credits by cost center: user tag first, then QUERY_TAG, then warehouse tag
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_COST_BY_CENTER_QUERY AS
WITH user_tag AS (
  SELECT OBJECT_NAME AS USER_NAME, TAG_VALUE AS COST_CENTER
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE DOMAIN = 'USER' AND TAG_NAME = 'COST_CENTER'
    AND TAG_DATABASE = 'ACCEL_DB' AND TAG_SCHEMA = 'FINOPS' AND OBJECT_DELETED IS NULL
),
wh_tag AS (
  SELECT OBJECT_NAME AS WAREHOUSE_NAME, TAG_VALUE AS COST_CENTER
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE DOMAIN = 'WAREHOUSE' AND TAG_NAME = 'COST_CENTER'
    AND TAG_DATABASE = 'ACCEL_DB' AND TAG_SCHEMA = 'FINOPS' AND OBJECT_DELETED IS NULL
)
SELECT DATE_TRUNC('month', q.START_TIME)::DATE AS MONTH,
       COALESCE(u.COST_CENTER,
                REGEXP_SUBSTR(q.QUERY_TAG, 'cost_center=([A-Za-z0-9-]+)', 1, 1, 'e', 1),
                w.COST_CENTER,
                'UNTAGGED')                     AS COST_CENTER,
       CASE WHEN u.COST_CENTER IS NOT NULL THEN 'USER_TAG'
            WHEN REGEXP_SUBSTR(q.QUERY_TAG, 'cost_center=([A-Za-z0-9-]+)', 1, 1, 'e', 1) IS NOT NULL THEN 'QUERY_TAG'
            WHEN w.COST_CENTER IS NOT NULL THEN 'WAREHOUSE_TAG'
            ELSE 'NONE' END                     AS ATTRIBUTION_SOURCE,
       COUNT(*)                                 AS QUERIES,
       SUM(q.CREDITS_ATTRIBUTED_COMPUTE)        AS CREDITS,
       SUM(q.CREDITS_ATTRIBUTED_COMPUTE) * MAX(p.CREDIT_PRICE_USD) AS COST_USD
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY q
CROSS JOIN V_PRICE p
LEFT JOIN user_tag u ON u.USER_NAME = q.USER_NAME
LEFT JOIN wh_tag   w ON w.WAREHOUSE_NAME = q.WAREHOUSE_NAME
WHERE q.START_TIME >= DATEADD('day', -365, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3;

GRANT SELECT ON VIEW V_COST_BY_CENTER_WAREHOUSE TO ROLE ACCEL_ANALYST;
GRANT SELECT ON VIEW V_COST_BY_CENTER_QUERY     TO ROLE ACCEL_ANALYST;

-- Real-time check of the warehouse tags
SELECT SYSTEM$GET_TAG('ACCEL_DB.FINOPS.COST_CENTER', 'ACCEL_WH', 'WAREHOUSE')    AS ACCEL_WH_CC,
       SYSTEM$GET_TAG('ACCEL_DB.FINOPS.COST_CENTER', 'ACCEL_AI_WH', 'WAREHOUSE') AS ACCEL_AI_WH_CC;

SELECT * FROM V_COST_BY_CENTER_WAREHOUSE ORDER BY MONTH DESC, COST_USD DESC LIMIT 50;
