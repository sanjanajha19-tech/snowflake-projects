/*=============================================================================
  ACCELERATOR SETUP 01 - Account setup
  Creates: roles ACCEL_ADMIN / ACCEL_DEVELOPER / ACCEL_ANALYST / ACCEL_VIEWER,
           warehouses ACCEL_WH / ACCEL_AI_WH, resource monitor ACCEL_RM,
           database ACCEL_DB (schemas DEMO, COMMON) and all grants.
  Run as : ACCOUNTADMIN (role creation, account privileges, resource monitors,
           SNOWFLAKE database roles and future grants all need it).
  Rerun  : safe - everything is IF NOT EXISTS / OR REPLACE / idempotent GRANT.
=============================================================================*/

-- ACCOUNTADMIN: needed for CREATE ROLE, account-level grants, resource monitors
USE ROLE ACCOUNTADMIN;

------------------------------------------------------------------------------
-- 1. Roles and hierarchy  VIEWER -> ANALYST -> DEVELOPER -> ADMIN -> SYSADMIN
------------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS ACCEL_ADMIN     COMMENT = 'Accelerators: owns ACCEL_DB and warehouses';
CREATE ROLE IF NOT EXISTS ACCEL_DEVELOPER COMMENT = 'Accelerators: builds objects in ACCEL_DB';
CREATE ROLE IF NOT EXISTS ACCEL_ANALYST   COMMENT = 'Accelerators: reads data, uses Cortex';
CREATE ROLE IF NOT EXISTS ACCEL_VIEWER    COMMENT = 'Accelerators: read-only on demo outputs';

GRANT ROLE ACCEL_VIEWER    TO ROLE ACCEL_ANALYST;
GRANT ROLE ACCEL_ANALYST   TO ROLE ACCEL_DEVELOPER;
GRANT ROLE ACCEL_DEVELOPER TO ROLE ACCEL_ADMIN;
GRANT ROLE ACCEL_ADMIN     TO ROLE SYSADMIN;

-- Grant ACCEL_ADMIN to the installing user (defaults to you).
EXECUTE IMMEDIATE $$
DECLARE
  install_user VARCHAR DEFAULT CURRENT_USER();   -- EDIT ME: or a literal user name, e.g. 'JANE_DOE'
  stmt VARCHAR;
BEGIN
  stmt := 'GRANT ROLE ACCEL_ADMIN TO USER "' || REPLACE(install_user, '"', '""') || '"';
  EXECUTE IMMEDIATE :stmt;
  RETURN 'Executed: ' || stmt;
END;
$$;
-- Optional: grant to other users as well
-- GRANT ROLE ACCEL_ADMIN   TO USER JANE_DOE;   -- EDIT ME
-- GRANT ROLE ACCEL_ANALYST TO USER JOHN_DOE;   -- EDIT ME

------------------------------------------------------------------------------
-- 2. Account-level privileges for ACCEL_ADMIN (ACCOUNTADMIN only)
------------------------------------------------------------------------------
GRANT CREATE DATABASE  ON ACCOUNT TO ROLE ACCEL_ADMIN;   -- ACCEL_DB + databases for shares / replication demos
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE ACCEL_ADMIN;   -- ACCEL_WH / ACCEL_AI_WH
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE ACCEL_ADMIN; -- notification (email/webhook) + API integrations
GRANT EXECUTE TASK         ON ACCOUNT TO ROLE ACCEL_ADMIN;   -- resume / run tasks
GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE ACCEL_ADMIN;   -- serverless tasks
GRANT EXECUTE ALERT        ON ACCOUNT TO ROLE ACCEL_ADMIN;   -- resume / run alerts (FinOps, data quality)
GRANT EXECUTE MANAGED ALERT ON ACCOUNT TO ROLE ACCEL_ADMIN;  -- serverless alerts
GRANT CREATE SHARE ON ACCOUNT TO ROLE ACCEL_ADMIN;           -- secure data sharing accelerators
GRANT CREATE APPLICATION PACKAGE ON ACCOUNT TO ROLE ACCEL_ADMIN;  -- Native App packaging
GRANT CREATE APPLICATION         ON ACCOUNT TO ROLE ACCEL_ADMIN;  -- install / test Native Apps
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE ACCEL_ADMIN;  -- data quality assets

------------------------------------------------------------------------------
-- 3. Warehouses and database (created as ACCEL_ADMIN so it owns them)
------------------------------------------------------------------------------
USE ROLE ACCEL_ADMIN;

CREATE WAREHOUSE IF NOT EXISTS ACCEL_WH
  WITH WAREHOUSE_SIZE = 'XSMALL'
       AUTO_SUSPEND = 60
       AUTO_RESUME = TRUE
       INITIALLY_SUSPENDED = TRUE
       COMMENT = 'Accelerators: general workloads';

CREATE WAREHOUSE IF NOT EXISTS ACCEL_AI_WH
  WITH WAREHOUSE_SIZE = 'SMALL'
       AUTO_SUSPEND = 60
       AUTO_RESUME = TRUE
       INITIALLY_SUSPENDED = TRUE
       COMMENT = 'Accelerators: Cortex Search, ML, Document AI';

CREATE DATABASE IF NOT EXISTS ACCEL_DB COMMENT = 'Snowflake accelerators';
CREATE SCHEMA IF NOT EXISTS ACCEL_DB.DEMO   COMMENT = 'Shared synthetic demo data';
CREATE SCHEMA IF NOT EXISTS ACCEL_DB.COMMON COMMENT = 'Shared utilities';

-- Warehouse access
GRANT USAGE, OPERATE ON WAREHOUSE ACCEL_WH    TO ROLE ACCEL_DEVELOPER;
GRANT USAGE, OPERATE ON WAREHOUSE ACCEL_AI_WH TO ROLE ACCEL_DEVELOPER;
GRANT USAGE ON WAREHOUSE ACCEL_WH    TO ROLE ACCEL_VIEWER;
GRANT USAGE ON WAREHOUSE ACCEL_AI_WH TO ROLE ACCEL_ANALYST;

-- Database / schema access (existing objects)
GRANT USAGE ON DATABASE ACCEL_DB TO ROLE ACCEL_VIEWER;
GRANT CREATE SCHEMA ON DATABASE ACCEL_DB TO ROLE ACCEL_DEVELOPER;
GRANT USAGE ON ALL SCHEMAS IN DATABASE ACCEL_DB TO ROLE ACCEL_VIEWER;
GRANT SELECT ON ALL TABLES IN DATABASE ACCEL_DB TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN DATABASE ACCEL_DB TO ROLE ACCEL_VIEWER;

-- Developers build shared utilities in COMMON
GRANT CREATE TABLE, CREATE VIEW, CREATE FUNCTION, CREATE PROCEDURE, CREATE STAGE,
      CREATE FILE FORMAT, CREATE SEQUENCE, CREATE TASK, CREATE STREAMLIT,
      CREATE DYNAMIC TABLE
  ON SCHEMA ACCEL_DB.COMMON TO ROLE ACCEL_DEVELOPER;

------------------------------------------------------------------------------
-- 4. Future grants - ACCOUNTADMIN (database-level future grants need MANAGE GRANTS)
------------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

GRANT USAGE  ON FUTURE SCHEMAS        IN DATABASE ACCEL_DB TO ROLE ACCEL_VIEWER;
GRANT SELECT ON FUTURE VIEWS          IN DATABASE ACCEL_DB TO ROLE ACCEL_VIEWER;
GRANT SELECT ON FUTURE TABLES         IN DATABASE ACCEL_DB TO ROLE ACCEL_ANALYST;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN DATABASE ACCEL_DB TO ROLE ACCEL_ANALYST;
GRANT USAGE  ON FUTURE FUNCTIONS      IN DATABASE ACCEL_DB TO ROLE ACCEL_ANALYST;
GRANT USAGE  ON FUTURE PROCEDURES     IN DATABASE ACCEL_DB TO ROLE ACCEL_DEVELOPER;

------------------------------------------------------------------------------
-- 5. Resource monitor - ACCOUNTADMIN (only account admins can create/assign)
------------------------------------------------------------------------------
CREATE OR REPLACE RESOURCE MONITOR ACCEL_RM
  WITH CREDIT_QUOTA = 100                     -- EDIT ME: monthly credits for both warehouses
       FREQUENCY = MONTHLY
       START_TIMESTAMP = IMMEDIATELY
       TRIGGERS ON 75 PERCENT DO NOTIFY
                ON 90 PERCENT DO NOTIFY
                ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE ACCEL_WH    SET RESOURCE_MONITOR = ACCEL_RM;
ALTER WAREHOUSE ACCEL_AI_WH SET RESOURCE_MONITOR = ACCEL_RM;

------------------------------------------------------------------------------
-- 6. Cortex AI + ACCOUNT_USAGE - ACCOUNTADMIN (SNOWFLAKE database grants)
------------------------------------------------------------------------------
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE ACCEL_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE ACCEL_DEVELOPER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE ACCEL_ANALYST;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE ACCEL_VIEWER;

GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE ACCEL_ADMIN;   -- ACCOUNT_USAGE views

-- Optional: cross-region inference.
-- Some AI models are not hosted in every region. Enabling this lets Cortex
-- route requests to another region when the model is not available locally.
-- Data is processed outside your account region - confirm with the client's
-- data-residency policy first. Values: 'DISABLED' (default), 'ANY_REGION',
-- 'AWS_US', 'AWS_EU', 'AWS_APJ', ...
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- Note: account-level Budgets are configured in the FinOps accelerator.

------------------------------------------------------------------------------
-- 7. Verify
------------------------------------------------------------------------------
SHOW GRANTS TO ROLE ACCEL_ADMIN;
SHOW WAREHOUSES LIKE 'ACCEL%';
SHOW SCHEMAS IN DATABASE ACCEL_DB;

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
USE SCHEMA DEMO;
SELECT CURRENT_ROLE() AS ROLE_NOW, CURRENT_WAREHOUSE() AS WH_NOW, 'Setup complete - run 02_demo_data.sql next' AS NEXT_STEP;
