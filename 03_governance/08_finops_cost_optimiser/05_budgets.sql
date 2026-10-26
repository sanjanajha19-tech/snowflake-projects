/* =============================================================================
   08 FINOPS COST OPTIMIZER | 05_budgets.sql
   Snowflake Budgets (SNOWFLAKE.CORE.BUDGET):
   A) account budget  SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET (monthly limit for the whole account)
   B) custom budget   ACCEL_DB.FINOPS.ACCEL_BUDGET for objects tagged COST_CENTER = 'CC-DATA-PLATFORM'
                      plus the two accelerator warehouses
   Email notifications need a notification integration whose recipients are
   VERIFIED e-mail addresses of users in this account.
   ACCOUNTADMIN: only ACCOUNTADMIN (or a role with SNOWFLAKE.BUDGET_ADMIN) can
   activate the account budget; integrations are account-level objects.
============================================================================= */
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS FINOPS;
USE SCHEMA FINOPS;

-- ---------------------------------------------------------------------------
-- A) Account budget
-- ---------------------------------------------------------------------------
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!ACTIVATE();
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!SET_SPENDING_LIMIT(500);          -- EDIT ME: credits per month
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!GET_SPENDING_LIMIT();

-- ---------------------------------------------------------------------------
-- B) Custom budget for the accelerator footprint
-- ---------------------------------------------------------------------------
CREATE SNOWFLAKE.CORE.BUDGET IF NOT EXISTS ACCEL_DB.FINOPS.ACCEL_BUDGET()
  COMMENT = 'Accelerator warehouses + objects tagged COST_CENTER = CC-DATA-PLATFORM';
CALL ACCEL_DB.FINOPS.ACCEL_BUDGET!SET_SPENDING_LIMIT(100);                -- EDIT ME: credits per month

CALL ACCEL_DB.FINOPS.ACCEL_BUDGET!ADD_RESOURCE(
  SELECT SYSTEM$REFERENCE('WAREHOUSE', 'ACCEL_WH', 'SESSION', 'applybudget'));
CALL ACCEL_DB.FINOPS.ACCEL_BUDGET!ADD_RESOURCE(
  SELECT SYSTEM$REFERENCE('WAREHOUSE', 'ACCEL_AI_WH', 'SESSION', 'applybudget'));

-- Everything tagged with the cost center joins the budget automatically (file 03 creates the tag)
CALL ACCEL_DB.FINOPS.ACCEL_BUDGET!ADD_RESOURCE_TAG(
  SELECT SYSTEM$REFERENCE('TAG', 'ACCEL_DB.FINOPS.COST_CENTER', 'SESSION', 'applybudget'),
  'CC-DATA-PLATFORM');

CALL ACCEL_DB.FINOPS.ACCEL_BUDGET!GET_SPENDING_LIMIT();
CALL ACCEL_DB.FINOPS.ACCEL_BUDGET!GET_LINKED_RESOURCES();

-- Let ACCEL_ADMIN monitor / manage the custom budget
GRANT SNOWFLAKE.CORE.BUDGET ROLE ACCEL_DB.FINOPS.ACCEL_BUDGET!ADMIN TO ROLE ACCEL_ADMIN;

-- ---------------------------------------------------------------------------
-- C) E-mail notifications (TEMPLATE - uncomment after editing the addresses)
-- ---------------------------------------------------------------------------
-- CREATE NOTIFICATION INTEGRATION IF NOT EXISTS ACCEL_BUDGET_EMAIL_INT
--   TYPE = EMAIL
--   ENABLED = TRUE
--   ALLOWED_RECIPIENTS = ('finops@example.com', 'cto@example.com');            -- EDIT ME (verified user e-mails)
-- GRANT USAGE ON INTEGRATION ACCEL_BUDGET_EMAIL_INT TO APPLICATION SNOWFLAKE;
--
-- CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!SET_EMAIL_NOTIFICATIONS(
--   'ACCEL_BUDGET_EMAIL_INT', 'finops@example.com, cto@example.com');         -- EDIT ME
-- CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!SET_NOTIFICATION_THRESHOLD(80);   -- % of limit (projected)
--
-- CALL ACCEL_DB.FINOPS.ACCEL_BUDGET!SET_EMAIL_NOTIFICATIONS(
--   'ACCEL_BUDGET_EMAIL_INT', 'finops@example.com');                          -- EDIT ME
-- CALL ACCEL_DB.FINOPS.ACCEL_BUDGET!SET_NOTIFICATION_THRESHOLD(90);

USE ROLE ACCEL_ADMIN;
