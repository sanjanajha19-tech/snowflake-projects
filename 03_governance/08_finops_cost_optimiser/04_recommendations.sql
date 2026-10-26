/* =============================================================================
   08 FINOPS COST OPTIMIZER | 04_recommendations.sql
   GENERATE_RECOMMENDATIONS(): rule-based findings with estimated monthly savings
   (credits and USD, using FINOPS_CONFIG prices). Each run appends a new RUN_ID.
   Estimates are deliberately conservative heuristics - validate before acting.
   Run as: ACCEL_ADMIN. Run 01 and 02 first.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS FINOPS;
USE SCHEMA FINOPS;

-- EDIT ME: price per credit lives in FINOPS_CONFIG (file 01). Change it with:
-- UPDATE ACCEL_DB.FINOPS.FINOPS_CONFIG SET PARAM_VALUE = 2.50 WHERE PARAM_NAME = 'CREDIT_PRICE_USD';

CREATE TABLE IF NOT EXISTS FINOPS_RECOMMENDATIONS (
  RUN_ID                     VARCHAR,
  RUN_TS                     TIMESTAMP_LTZ,
  CATEGORY                   VARCHAR,   -- WAREHOUSE | QUERY | STORAGE | AI | GOVERNANCE
  SEVERITY                   VARCHAR,   -- HIGH | MEDIUM | LOW
  OBJECT_NAME                VARCHAR,
  FINDING                    VARCHAR,
  RECOMMENDATION             VARCHAR,
  EST_MONTHLY_CREDITS_SAVED  NUMBER(18,2),
  EST_MONTHLY_USD_SAVED      NUMBER(18,2),
  FIX_SQL                    VARCHAR
);

CREATE OR REPLACE PROCEDURE GENERATE_RECOMMENDATIONS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  run_id VARCHAR DEFAULT UUID_STRING();
  n INTEGER DEFAULT 0;
BEGIN
  -- 1. Idle compute: warehouses with > 20% idle credits -> shorter AUTO_SUSPEND (save ~half the idle)
  INSERT INTO ACCEL_DB.FINOPS.FINOPS_RECOMMENDATIONS
  SELECT :run_id, CURRENT_TIMESTAMP(), 'WAREHOUSE',
         IFF(i.CREDITS_IDLE_30D > 50, 'HIGH', IFF(i.CREDITS_IDLE_30D > 10, 'MEDIUM', 'LOW')),
         i.WAREHOUSE_NAME,
         'Idle ' || i.IDLE_PCT || '% of compute (' || ROUND(i.CREDITS_IDLE_30D, 1) || ' credits in 30 days)',
         'Lower AUTO_SUSPEND to 60 s and consolidate low-concurrency workloads onto fewer warehouses',
         ROUND(i.CREDITS_IDLE_30D * 0.5, 2),
         ROUND(i.CREDITS_IDLE_30D * 0.5 * p.CREDIT_PRICE_USD, 2),
         'ALTER WAREHOUSE ' || i.WAREHOUSE_NAME || ' SET AUTO_SUSPEND = 60;'
  FROM ACCEL_DB.FINOPS.V_IDLE_WAREHOUSES i
  CROSS JOIN ACCEL_DB.FINOPS.V_PRICE p
  WHERE i.IDLE_PCT > 20 AND i.CREDITS_IDLE_30D > 1;

  -- 2. AUTO_SUSPEND > 300 s or disabled (idle tail per suspend scales with the setting)
  INSERT INTO ACCEL_DB.FINOPS.FINOPS_RECOMMENDATIONS
  SELECT :run_id, CURRENT_TIMESTAMP(), 'WAREHOUSE',
         IFF(g.FLAG_AUTO_SUSPEND_DISABLED, 'HIGH', 'MEDIUM'),
         g.WAREHOUSE_NAME,
         IFF(g.FLAG_AUTO_SUSPEND_DISABLED, 'AUTO_SUSPEND is disabled',
             'AUTO_SUSPEND = ' || g.AUTO_SUSPEND || ' s (> 300 s)'),
         'Set AUTO_SUSPEND to 60 s (BI/interactive) or 300 s max (cache-sensitive)',
         ROUND(COALESCE(g.CREDITS_IDLE_30D, 0) * IFF(g.FLAG_AUTO_SUSPEND_DISABLED, 0.8, 1 - 60 / NULLIF(g.AUTO_SUSPEND, 0)), 2),
         ROUND(COALESCE(g.CREDITS_IDLE_30D, 0) * IFF(g.FLAG_AUTO_SUSPEND_DISABLED, 0.8, 1 - 60 / NULLIF(g.AUTO_SUSPEND, 0)) * p.CREDIT_PRICE_USD, 2),
         'ALTER WAREHOUSE ' || g.WAREHOUSE_NAME || ' SET AUTO_SUSPEND = 60;'
  FROM ACCEL_DB.FINOPS.V_WAREHOUSE_GUARDRAILS g
  CROSS JOIN ACCEL_DB.FINOPS.V_PRICE p
  WHERE g.FLAG_AUTO_SUSPEND_DISABLED OR g.FLAG_AUTO_SUSPEND_GT_300;

  -- 3. No resource monitor (risk control, no direct saving)
  INSERT INTO ACCEL_DB.FINOPS.FINOPS_RECOMMENDATIONS
  SELECT :run_id, CURRENT_TIMESTAMP(), 'GOVERNANCE', 'MEDIUM', g.WAREHOUSE_NAME,
         'Warehouse has no resource monitor',
         'Attach a resource monitor with notify / suspend triggers (ACCOUNTADMIN)',
         0, 0,
         'ALTER WAREHOUSE ' || g.WAREHOUSE_NAME || ' SET RESOURCE_MONITOR = <monitor_name>;'
  FROM ACCEL_DB.FINOPS.V_WAREHOUSE_GUARDRAILS g
  WHERE g.FLAG_NO_RESOURCE_MONITOR;

  -- 4. Expensive repeated query shapes (top 10 > 1 credit / 30 days): tune for ~25 %
  INSERT INTO ACCEL_DB.FINOPS.FINOPS_RECOMMENDATIONS
  SELECT :run_id, CURRENT_TIMESTAMP(), 'QUERY',
         IFF(t.CREDITS > 20, 'HIGH', 'MEDIUM'),
         t.QUERY_PARAMETERIZED_HASH,
         t.EXECUTIONS || ' runs, ' || ROUND(t.CREDITS, 2) || ' credits in 30 days on ' || COALESCE(t.SAMPLE_WAREHOUSE, '?')
           || ' (e.g. query ' || t.MOST_EXPENSIVE_QUERY_ID || ')',
         'Review the query profile: pruning (clustering / search optimization), avoid SELECT *, '
           || 'materialize repeated logic (Dynamic Table), check result-cache hits',
         ROUND(t.CREDITS * 0.25, 2),
         ROUND(t.CREDITS * 0.25 * p.CREDIT_PRICE_USD, 2),
         NULL
  FROM (SELECT * FROM ACCEL_DB.FINOPS.V_TOP_QUERIES WHERE CREDITS > 1 ORDER BY CREDITS DESC LIMIT 10) t
  CROSS JOIN ACCEL_DB.FINOPS.V_PRICE p;

  -- 5. Remote spilling: under-sized warehouse or memory-heavy query
  INSERT INTO ACCEL_DB.FINOPS.FINOPS_RECOMMENDATIONS
  SELECT :run_id, CURRENT_TIMESTAMP(), 'QUERY', 'MEDIUM', s.WAREHOUSE_NAME,
         COUNT(*) || ' queries spilled ' || ROUND(SUM(s.GB_SPILLED_REMOTE), 1) || ' GB to remote storage in 30 days',
         'Size up for these queries only (separate warehouse) or reduce data per join/sort; '
           || 'consider a Snowpark-optimized warehouse for memory-heavy jobs',
         0, 0, NULL
  FROM ACCEL_DB.FINOPS.V_SPILLING_QUERIES s
  WHERE s.GB_SPILLED_REMOTE > 0
  GROUP BY s.WAREHOUSE_NAME;

  -- 6. Unused tables (no reads for 90 days) larger than 1 GB
  INSERT INTO ACCEL_DB.FINOPS.FINOPS_RECOMMENDATIONS
  SELECT :run_id, CURRENT_TIMESTAMP(), 'STORAGE',
         IFF(u.SIZE_GB > 100, 'HIGH', 'LOW'),
         u.TABLE_CATALOG || '.' || u.TABLE_SCHEMA || '.' || u.TABLE_NAME,
         'Not read for 90 days, ' || u.SIZE_GB || ' GB',
         'Confirm with the owner (' || COALESCE(u.TABLE_OWNER, '?') || '), then drop or archive; '
           || 'set DATA_RETENTION_TIME_IN_DAYS = 0/1 on transient staging tables',
         0,
         ROUND(u.EST_MONTHLY_COST_USD, 2),
         'DROP TABLE ' || u.TABLE_CATALOG || '.' || u.TABLE_SCHEMA || '.' || u.TABLE_NAME || ';'
  FROM ACCEL_DB.FINOPS.V_UNUSED_TABLES u
  WHERE u.SIZE_GB > 1;

  -- 7. Time Travel / Fail-safe heavier than active data
  INSERT INTO ACCEL_DB.FINOPS.FINOPS_RECOMMENDATIONS
  SELECT :run_id, CURRENT_TIMESTAMP(), 'STORAGE', 'LOW',
         s.TABLE_CATALOG || '.' || s.TABLE_SCHEMA || '.' || s.TABLE_NAME,
         'Time Travel + Fail-safe ' || ROUND(s.TIME_TRAVEL_GB + s.FAILSAFE_GB, 1) || ' GB vs active ' || s.ACTIVE_GB || ' GB',
         'High churn table: lower DATA_RETENTION_TIME_IN_DAYS, or make it TRANSIENT if it can be rebuilt',
         0,
         ROUND((s.TIME_TRAVEL_GB + s.FAILSAFE_GB) / 1024 * 0.7 * p.STORAGE_PRICE_USD_TB_MONTH, 2),
         'ALTER TABLE ' || s.TABLE_CATALOG || '.' || s.TABLE_SCHEMA || '.' || s.TABLE_NAME || ' SET DATA_RETENTION_TIME_IN_DAYS = 1;'
  FROM ACCEL_DB.FINOPS.V_TABLE_STORAGE s
  CROSS JOIN ACCEL_DB.FINOPS.V_PRICE p
  WHERE (s.TIME_TRAVEL_GB + s.FAILSAFE_GB) > GREATEST(s.ACTIVE_GB, 1);

  -- 8. AI spend concentrated on one function/model: right-size the model (~30 %)
  INSERT INTO ACCEL_DB.FINOPS.FINOPS_RECOMMENDATIONS
  SELECT :run_id, CURRENT_TIMESTAMP(), 'AI',
         IFF(SUM(a.CREDITS) > 50, 'HIGH', 'MEDIUM'),
         a.FUNCTION_NAME || COALESCE(' / ' || a.MODEL_NAME, ''),
         ROUND(SUM(a.CREDITS), 2) || ' credits in 30 days',
         'Test a smaller model on a sample, cap input size (truncate / summarize), cache results in a table, '
           || 'and restrict models with CORTEX_MODELS_ALLOWLIST',
         ROUND(SUM(a.CREDITS) * 0.3, 2),
         ROUND(SUM(a.CREDITS) * 0.3 * MAX(p.CREDIT_PRICE_USD), 2),
         NULL
  FROM ACCEL_DB.FINOPS.V_AI_SPEND_BY_FUNCTION_MODEL a
  CROSS JOIN ACCEL_DB.FINOPS.V_PRICE p
  WHERE a.USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE())
  GROUP BY a.FUNCTION_NAME, a.MODEL_NAME
  HAVING SUM(a.CREDITS) > 5;

  -- 9. Cloud services billed (above the 10 % daily adjustment)
  INSERT INTO ACCEL_DB.FINOPS.FINOPS_RECOMMENDATIONS
  SELECT :run_id, CURRENT_TIMESTAMP(), 'QUERY', 'LOW', 'CLOUD_SERVICES',
         ROUND(SUM(m.CREDITS_USED_CLOUD_SERVICES + m.CREDITS_ADJUSTMENT_CLOUD_SERVICES), 2)
           || ' cloud services credits billed in 30 days',
         'Look for very frequent tiny queries, heavy SHOW/metadata calls, or complex compilation; batch them',
         ROUND(SUM(m.CREDITS_USED_CLOUD_SERVICES + m.CREDITS_ADJUSTMENT_CLOUD_SERVICES) * 0.5, 2),
         ROUND(SUM(m.CREDITS_USED_CLOUD_SERVICES + m.CREDITS_ADJUSTMENT_CLOUD_SERVICES) * 0.5 * MAX(p.CREDIT_PRICE_USD), 2),
         NULL
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY m
  CROSS JOIN ACCEL_DB.FINOPS.V_PRICE p
  WHERE m.USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE())
  HAVING SUM(m.CREDITS_USED_CLOUD_SERVICES + m.CREDITS_ADJUSTMENT_CLOUD_SERVICES) > 1;

  SELECT COUNT(*) INTO :n FROM ACCEL_DB.FINOPS.FINOPS_RECOMMENDATIONS WHERE RUN_ID = :run_id;
  RETURN n || ' recommendations, run ' || run_id;
END;
$$;

CREATE OR REPLACE VIEW V_RECOMMENDATIONS_LATEST AS
SELECT *
FROM FINOPS_RECOMMENDATIONS
WHERE RUN_ID = (SELECT MAX_BY(RUN_ID, RUN_TS) FROM FINOPS_RECOMMENDATIONS);

GRANT SELECT ON VIEW V_RECOMMENDATIONS_LATEST TO ROLE ACCEL_ANALYST;

CALL GENERATE_RECOMMENDATIONS();

SELECT CATEGORY, SEVERITY, OBJECT_NAME, FINDING, RECOMMENDATION,
       EST_MONTHLY_CREDITS_SAVED, EST_MONTHLY_USD_SAVED, FIX_SQL
FROM V_RECOMMENDATIONS_LATEST
ORDER BY EST_MONTHLY_USD_SAVED DESC, SEVERITY;

SELECT SUM(EST_MONTHLY_USD_SAVED) AS TOTAL_EST_MONTHLY_USD_SAVED FROM V_RECOMMENDATIONS_LATEST;

-- Weekly refresh (created suspended)
CREATE OR REPLACE TASK TASK_FINOPS_WEEKLY
  WAREHOUSE = ACCEL_WH
  SCHEDULE = 'USING CRON 0 7 * * 1 UTC'     -- EDIT ME
AS
EXECUTE IMMEDIATE $$
BEGIN
  CALL ACCEL_DB.FINOPS.SNAPSHOT_WAREHOUSES();
  CALL ACCEL_DB.FINOPS.GENERATE_RECOMMENDATIONS();
END;
$$;
-- ALTER TASK ACCEL_DB.FINOPS.TASK_FINOPS_WEEKLY RESUME;
