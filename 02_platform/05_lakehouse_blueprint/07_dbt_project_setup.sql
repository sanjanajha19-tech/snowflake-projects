/* =============================================================================
   05 LAKEHOUSE BLUEPRINT | 07_dbt_project_setup.sql
   OPTIONAL - target schema + run commands for the dbt/ project
   (dbt Projects on Snowflake). The dbt models write to ACCEL_DB.DBT_LAKEHOUSE
   so they never collide with the Dynamic Table pipeline.
   Run as: ACCEL_ADMIN.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS DBT_LAKEHOUSE;
USE SCHEMA DBT_LAKEHOUSE;

GRANT USAGE ON SCHEMA ACCEL_DB.DBT_LAKEHOUSE TO ROLE ACCEL_DEVELOPER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA ACCEL_DB.DBT_LAKEHOUSE TO ROLE ACCEL_DEVELOPER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA ACCEL_DB.DBT_LAKEHOUSE TO ROLE ACCEL_DEVELOPER;

/* Deploy the project (pick one):

   A) Snowsight Workspaces: Projects > Workspaces > Create > From Git repository (or upload
      the dbt/ folder) > select profile target 'dev' > Run 'build'. Then "Deploy" to create
      the DBT PROJECT object in ACCEL_DB.DBT_LAKEHOUSE.

   B) Snowflake CLI from the repo root:
        snow dbt deploy ACCEL_LAKEHOUSE --source 02_platform/05_lakehouse_blueprint/dbt \
             --database ACCEL_DB --schema DBT_LAKEHOUSE -c <connection>

   Then run it from SQL (uncomment): */
-- EXECUTE DBT PROJECT ACCEL_DB.DBT_LAKEHOUSE.ACCEL_LAKEHOUSE ARGS = 'build --target dev';

-- Schedule it (created suspended; EXECUTE TASK privilege needed to resume):
-- CREATE OR REPLACE TASK ACCEL_DB.DBT_LAKEHOUSE.TASK_DBT_BUILD
--   WAREHOUSE = ACCEL_WH
--   SCHEDULE = 'USING CRON 30 2 * * * UTC'
-- AS
--   EXECUTE DBT PROJECT ACCEL_DB.DBT_LAKEHOUSE.ACCEL_LAKEHOUSE ARGS = 'build --target dev';

-- After a run, compare dbt vs Dynamic Table outputs (should match):
-- SELECT (SELECT SUM(NET_AMOUNT) FROM ACCEL_DB.DBT_LAKEHOUSE.FACT_SALES) AS DBT_NET,
--        (SELECT SUM(NET_AMOUNT) FROM ACCEL_DB.GOLD.FACT_SALES)          AS DT_NET;

SHOW SCHEMAS LIKE 'DBT_LAKEHOUSE' IN DATABASE ACCEL_DB;
