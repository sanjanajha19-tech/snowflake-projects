/*=============================================================================
  ACCELERATOR SETUP 99 - Teardown
  !!! DESTRUCTIVE: drops ACCEL_DB (all accelerator schemas, apps and data),
      both warehouses, the resource monitor and the four ACCEL roles.
  Run as : ACCOUNTADMIN (dropping roles and resource monitors needs it).
  Safety : nothing happens until you change CONFIRM to 'YES' below.
=============================================================================*/

-- ACCOUNTADMIN: required to drop resource monitors and roles
USE ROLE ACCOUNTADMIN;

EXECUTE IMMEDIATE $$
DECLARE
  confirm VARCHAR DEFAULT 'NO';   -- EDIT ME: set to 'YES' to really drop everything
BEGIN
  IF (confirm <> 'YES') THEN
    RETURN 'Teardown skipped. Set confirm to YES in 99_teardown.sql to proceed.';
  END IF;

  DROP DATABASE IF EXISTS ACCEL_DB;

  DROP WAREHOUSE IF EXISTS ACCEL_WH;
  DROP WAREHOUSE IF EXISTS ACCEL_AI_WH;

  DROP RESOURCE MONITOR IF EXISTS ACCEL_RM;

  DROP ROLE IF EXISTS ACCEL_VIEWER;
  DROP ROLE IF EXISTS ACCEL_ANALYST;
  DROP ROLE IF EXISTS ACCEL_DEVELOPER;
  DROP ROLE IF EXISTS ACCEL_ADMIN;

  RETURN 'Teardown complete: ACCEL_DB, ACCEL_WH, ACCEL_AI_WH, ACCEL_RM and ACCEL_* roles dropped.';
END;
$$;

-- Optional: revert cross-region inference if you enabled it in 01_account_setup.sql
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'DISABLED';
