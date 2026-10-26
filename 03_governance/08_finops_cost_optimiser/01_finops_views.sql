/* =============================================================================
   08 FINOPS COST OPTIMIZER | 01_finops_views.sql
   Price config + cost views over SNOWFLAKE.ACCOUNT_USAGE (latency 45 min - 3 h).
   Run as: ACCEL_ADMIN (IMPORTED PRIVILEGES on SNOWFLAKE granted by 00_setup).
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS FINOPS;
USE SCHEMA FINOPS;

-- ---------------------------------------------------------------------------
-- 0. Prices (contract values) - used to convert credits / TB to currency
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE FINOPS_CONFIG (
  PARAM_NAME  VARCHAR,
  PARAM_VALUE NUMBER(12,4),
  NOTE        VARCHAR
);
INSERT INTO FINOPS_CONFIG VALUES
  ('CREDIT_PRICE_USD',          3.00,  'EDIT ME: price per credit from your contract'),
  ('STORAGE_PRICE_USD_TB_MONTH', 23.00, 'EDIT ME: capacity storage price per TB per month'),
  ('LOOKBACK_DAYS',             30,    'Window used by recommendations');

CREATE OR REPLACE VIEW V_PRICE AS
SELECT MAX(IFF(PARAM_NAME = 'CREDIT_PRICE_USD', PARAM_VALUE, NULL))           AS CREDIT_PRICE_USD,
       MAX(IFF(PARAM_NAME = 'STORAGE_PRICE_USD_TB_MONTH', PARAM_VALUE, NULL)) AS STORAGE_PRICE_USD_TB_MONTH,
       MAX(IFF(PARAM_NAME = 'LOOKBACK_DAYS', PARAM_VALUE, NULL))::INT          AS LOOKBACK_DAYS
FROM FINOPS_CONFIG;

-- ---------------------------------------------------------------------------
-- 1. Spend by day and service type (all services, billed credits)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SPEND_DAILY_BY_SERVICE AS
SELECT m.USAGE_DATE,
       m.SERVICE_TYPE,
       SUM(m.CREDITS_USED)                         AS CREDITS_USED,
       SUM(m.CREDITS_BILLED)                       AS CREDITS_BILLED,
       SUM(m.CREDITS_BILLED) * MAX(p.CREDIT_PRICE_USD) AS COST_USD
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY m
CROSS JOIN V_PRICE p
WHERE m.USAGE_DATE >= DATEADD('day', -365, CURRENT_DATE())
GROUP BY 1, 2;

-- ---------------------------------------------------------------------------
-- 2. Spend by day and warehouse, incl. idle (compute not attributed to queries)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SPEND_DAILY_BY_WAREHOUSE AS
SELECT DATE_TRUNC('day', w.START_TIME)::DATE                         AS USAGE_DATE,
       w.WAREHOUSE_NAME,
       SUM(w.CREDITS_USED)                                           AS CREDITS_USED,
       SUM(w.CREDITS_USED_COMPUTE)                                   AS CREDITS_COMPUTE,
       SUM(w.CREDITS_USED_CLOUD_SERVICES)                            AS CREDITS_CLOUD_SERVICES,
       SUM(w.CREDITS_ATTRIBUTED_COMPUTE_QUERIES)                     AS CREDITS_ATTRIBUTED_QUERIES,
       GREATEST(SUM(w.CREDITS_USED_COMPUTE) - SUM(w.CREDITS_ATTRIBUTED_COMPUTE_QUERIES), 0) AS CREDITS_IDLE,
       SUM(w.CREDITS_USED) * MAX(p.CREDIT_PRICE_USD)                 AS COST_USD
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
CROSS JOIN V_PRICE p
WHERE w.START_TIME >= DATEADD('day', -365, CURRENT_DATE())
GROUP BY 1, 2;

-- ---------------------------------------------------------------------------
-- 3. Idle warehouses (last 30 days): share of compute credits with no query running
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_IDLE_WAREHOUSES AS
SELECT WAREHOUSE_NAME,
       SUM(CREDITS_COMPUTE)                                        AS CREDITS_COMPUTE_30D,
       SUM(CREDITS_IDLE)                                           AS CREDITS_IDLE_30D,
       ROUND(100 * SUM(CREDITS_IDLE) / NULLIF(SUM(CREDITS_COMPUTE), 0), 1) AS IDLE_PCT,
       SUM(CREDITS_IDLE) * MAX(p.CREDIT_PRICE_USD)                 AS IDLE_COST_USD_30D
FROM V_SPEND_DAILY_BY_WAREHOUSE
CROSS JOIN V_PRICE p
WHERE USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE())
  AND USAGE_DATE < CURRENT_DATE()
GROUP BY WAREHOUSE_NAME;

-- ---------------------------------------------------------------------------
-- 4. Most expensive queries (grouped by parameterized hash = same query shape)
--    and users, from QUERY_ATTRIBUTION_HISTORY (warehouse compute only, excl. idle)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_TOP_QUERIES AS
WITH qa AS (
  SELECT QUERY_PARAMETERIZED_HASH,
         COUNT(*)                                 AS EXECUTIONS,
         SUM(CREDITS_ATTRIBUTED_COMPUTE)          AS CREDITS,
         SUM(COALESCE(CREDITS_USED_QUERY_ACCELERATION, 0)) AS QAS_CREDITS,
         ANY_VALUE(WAREHOUSE_NAME)                AS SAMPLE_WAREHOUSE,
         ANY_VALUE(USER_NAME)                     AS SAMPLE_USER,
         MAX_BY(QUERY_ID, CREDITS_ATTRIBUTED_COMPUTE) AS MOST_EXPENSIVE_QUERY_ID,
         MAX(START_TIME)                          AS LAST_RUN
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY QUERY_PARAMETERIZED_HASH
)
SELECT qa.*,
       qa.CREDITS * p.CREDIT_PRICE_USD                       AS COST_USD,
       LEFT(qh.QUERY_TEXT, 500)                              AS SAMPLE_QUERY_TEXT,
       qh.WAREHOUSE_SIZE,
       qh.TOTAL_ELAPSED_TIME / 1000                          AS SAMPLE_ELAPSED_SEC
FROM qa
CROSS JOIN V_PRICE p
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
  ON qh.QUERY_ID = qa.MOST_EXPENSIVE_QUERY_ID
 AND qh.START_TIME >= DATEADD('day', -31, CURRENT_TIMESTAMP());

CREATE OR REPLACE VIEW V_TOP_USERS AS
SELECT USER_NAME,
       COUNT(*)                                    AS QUERIES,
       SUM(CREDITS_ATTRIBUTED_COMPUTE)             AS CREDITS,
       SUM(CREDITS_ATTRIBUTED_COMPUTE) * MAX(p.CREDIT_PRICE_USD) AS COST_USD,
       COUNT(DISTINCT WAREHOUSE_NAME)              AS WAREHOUSES_USED
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
CROSS JOIN V_PRICE p
WHERE START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY USER_NAME;

-- ---------------------------------------------------------------------------
-- 5. Queries spilling to local / remote storage (warehouse too small or bad query)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SPILLING_QUERIES AS
SELECT QUERY_ID, START_TIME, USER_NAME, ROLE_NAME, WAREHOUSE_NAME, WAREHOUSE_SIZE,
       TOTAL_ELAPSED_TIME / 1000                                 AS ELAPSED_SEC,
       ROUND(BYTES_SPILLED_TO_LOCAL_STORAGE  / POWER(1024, 3), 2) AS GB_SPILLED_LOCAL,
       ROUND(BYTES_SPILLED_TO_REMOTE_STORAGE / POWER(1024, 3), 2) AS GB_SPILLED_REMOTE,
       ROUND(BYTES_SCANNED / POWER(1024, 3), 2)                   AS GB_SCANNED,
       QUERY_PARAMETERIZED_HASH,
       LEFT(QUERY_TEXT, 500)                                      AS QUERY_TEXT
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  AND (BYTES_SPILLED_TO_LOCAL_STORAGE > 0 OR BYTES_SPILLED_TO_REMOTE_STORAGE > 0);

-- ---------------------------------------------------------------------------
-- 6. Storage: per database per day, and largest tables
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_STORAGE_DAILY AS
SELECT d.USAGE_DATE, d.DATABASE_NAME,
       d.AVERAGE_DATABASE_BYTES / POWER(1024, 4)                AS DATABASE_TB,
       d.AVERAGE_FAILSAFE_BYTES / POWER(1024, 4)                AS FAILSAFE_TB,
       (d.AVERAGE_DATABASE_BYTES + d.AVERAGE_FAILSAFE_BYTES) / POWER(1024, 4)
         * p.STORAGE_PRICE_USD_TB_MONTH                         AS EST_MONTHLY_COST_USD
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY d
CROSS JOIN V_PRICE p
WHERE d.USAGE_DATE >= DATEADD('day', -90, CURRENT_DATE());

CREATE OR REPLACE VIEW V_TABLE_STORAGE AS
SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, IS_TRANSIENT,
       ROUND(ACTIVE_BYTES / POWER(1024, 3), 3)            AS ACTIVE_GB,
       ROUND(TIME_TRAVEL_BYTES / POWER(1024, 3), 3)       AS TIME_TRAVEL_GB,
       ROUND(FAILSAFE_BYTES / POWER(1024, 3), 3)          AS FAILSAFE_GB,
       ROUND(RETAINED_FOR_CLONE_BYTES / POWER(1024, 3), 3) AS CLONE_RETAINED_GB,
       (ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES + RETAINED_FOR_CLONE_BYTES) / POWER(1024, 4)
         * p.STORAGE_PRICE_USD_TB_MONTH                   AS EST_MONTHLY_COST_USD
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
CROSS JOIN V_PRICE p
WHERE DELETED = FALSE;

-- ---------------------------------------------------------------------------
-- 7. Unused tables: no read in ACCESS_HISTORY for 90 days (Enterprise edition)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_UNUSED_TABLES AS
WITH reads AS (
  SELECT f.value:"objectId"::NUMBER AS TABLE_ID,
         MAX(ah.QUERY_START_TIME)   AS LAST_READ
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
       LATERAL FLATTEN(INPUT => ah.BASE_OBJECTS_ACCESSED) f
  WHERE ah.QUERY_START_TIME >= DATEADD('day', -90, CURRENT_TIMESTAMP())
    AND f.value:"objectDomain"::STRING = 'Table'
  GROUP BY 1
)
SELECT t.TABLE_CATALOG, t.TABLE_SCHEMA, t.TABLE_NAME, t.TABLE_OWNER, t.CREATED, t.LAST_ALTERED,
       t.ROW_COUNT,
       ROUND(t.BYTES / POWER(1024, 3), 3)                           AS SIZE_GB,
       t.BYTES / POWER(1024, 4) * p.STORAGE_PRICE_USD_TB_MONTH      AS EST_MONTHLY_COST_USD
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES t
CROSS JOIN V_PRICE p
LEFT JOIN reads r ON r.TABLE_ID = t.TABLE_ID
WHERE t.DELETED IS NULL
  AND t.TABLE_TYPE = 'BASE TABLE'
  AND t.TABLE_CATALOG <> 'SNOWFLAKE'
  AND t.CREATED < DATEADD('day', -90, CURRENT_TIMESTAMP())
  AND r.TABLE_ID IS NULL;

-- ---------------------------------------------------------------------------
-- 8. AI / Cortex spend
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_AI_SPEND_DAILY AS
SELECT USAGE_DATE, SERVICE_TYPE, CREDITS_BILLED, COST_USD
FROM V_SPEND_DAILY_BY_SERVICE
WHERE SERVICE_TYPE IN ('AI_SERVICES', 'CORTEX_CODE_CLI', 'CORTEX_CODE_SNOWSIGHT');

CREATE OR REPLACE VIEW V_AI_SPEND_BY_FUNCTION_MODEL AS
SELECT DATE_TRUNC('day', h.START_TIME)::DATE           AS USAGE_DATE,
       h.FUNCTION_NAME,
       NULLIF(h.MODEL_NAME, '')                        AS MODEL_NAME,
       u.NAME                                          AS USER_NAME,
       COUNT(DISTINCT h.QUERY_ID)                      AS QUERIES,
       SUM(h.CREDITS)                                  AS CREDITS,
       SUM(h.CREDITS) * MAX(p.CREDIT_PRICE_USD)        AS COST_USD
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
CROSS JOIN V_PRICE p
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON TO_VARCHAR(u.USER_ID) = h.USER_ID
WHERE h.START_TIME >= DATEADD('day', -90, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3, 4;

CREATE OR REPLACE VIEW V_AI_SPEND_OTHER_SERVICES AS
SELECT DATE_TRUNC('day', START_TIME)::DATE AS USAGE_DATE, 'CORTEX_ANALYST' AS SERVICE, USERNAME AS DETAIL, SUM(CREDITS) AS CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_ANALYST_USAGE_HISTORY
WHERE START_TIME >= DATEADD('day', -90, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3
UNION ALL
SELECT USAGE_DATE, 'CORTEX_SEARCH', DATABASE_NAME || '.' || SCHEMA_NAME || '.' || SERVICE_NAME || ' (' || CONSUMPTION_TYPE || ')', SUM(CREDITS)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY
WHERE USAGE_DATE >= DATEADD('day', -90, CURRENT_DATE())
GROUP BY 1, 2, 3
UNION ALL
SELECT DATE_TRUNC('day', START_TIME)::DATE, 'CORTEX_AGENTS', AGENT_DATABASE_NAME || '.' || AGENT_SCHEMA_NAME || '.' || AGENT_NAME, SUM(TOKEN_CREDITS)
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
WHERE START_TIME >= DATEADD('day', -90, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3;

GRANT USAGE ON SCHEMA ACCEL_DB.FINOPS TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS IN SCHEMA ACCEL_DB.FINOPS TO ROLE ACCEL_ANALYST;

-- Quick look
SELECT USAGE_DATE, SUM(CREDITS_BILLED) AS CREDITS, SUM(COST_USD) AS COST_USD
FROM V_SPEND_DAILY_BY_SERVICE
WHERE USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE())
GROUP BY 1 ORDER BY 1 DESC;
