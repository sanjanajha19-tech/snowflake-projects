/*=============================================================================
  ASSET 10 - Talk to your Data Agent
  File 05   : Publish SALES_INSIGHTS_AGENT to Snowflake Intelligence / CoWork
              (ai.snowflake.com). OPTIONAL - only needed for business users.
  Run as    : ACCOUNTADMIN - the account-level Snowflake Intelligence object
              is created and managed by ACCOUNTADMIN.
  Rerun     : safe. If the object already exists (it is created automatically
              the first time someone opens AI & ML > Agents > Snowflake CoWork
              > Open settings), the CREATE is skipped by IF NOT EXISTS.
              Re-adding an agent that is already added may return an error
              saying it already exists - that is harmless.
  UI alternative: Snowsight > AI & ML > Agents > Snowflake CoWork tab >
              Open settings > add the agent.
=============================================================================*/
-- ACCOUNTADMIN: the Snowflake Intelligence object is account-level
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SEMANTIC;
USE SCHEMA SEMANTIC;

-- Only one Snowflake Intelligence object is allowed per account; this is the
-- default name Snowflake uses.
CREATE SNOWFLAKE INTELLIGENCE IF NOT EXISTS SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;

ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  ADD AGENT ACCEL_DB.SEMANTIC.SALES_INSIGHTS_AGENT;

-- Business users: role ACCEL_ANALYST (EDIT ME: or a client business role)
GRANT USAGE ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT TO ROLE ACCEL_ANALYST;
GRANT USAGE ON AGENT ACCEL_DB.SEMANTIC.SALES_INSIGHTS_AGENT TO ROLE ACCEL_ANALYST;

-- Users also need a default role + warehouse they can use, e.g.:
-- ALTER USER JANE_DOE SET DEFAULT_ROLE = ACCEL_ANALYST DEFAULT_WAREHOUSE = ACCEL_WH;   -- EDIT ME
-- GRANT ROLE ACCEL_ANALYST TO USER JANE_DOE;                                          -- EDIT ME
