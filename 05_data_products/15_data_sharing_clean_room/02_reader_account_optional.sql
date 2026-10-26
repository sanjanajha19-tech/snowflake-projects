/*=============================================================================
  ACCELERATOR 15 - Data Sharing & Clean Room
  File 02 : OPTIONAL reader account for a consumer that has no Snowflake account
  Creates : managed READER account ACCEL_SALES_READER and adds it to ACCEL_SALES_SHARE
  Run as  : ACCOUNTADMIN (only account admins can create managed accounts)
  Rerun   : safe - skips creation if the reader account already exists.
  Cost    : the provider pays for all compute used inside a reader account.
=============================================================================*/

-- ACCOUNTADMIN: CREATE MANAGED ACCOUNT requires it
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SHARING;
USE SCHEMA SHARING;

EXECUTE IMMEDIATE $$
DECLARE
    create_reader  BOOLEAN DEFAULT FALSE;                         -- EDIT ME: set TRUE to create the reader account
    reader_name    VARCHAR DEFAULT 'ACCEL_SALES_READER';
    admin_name     VARCHAR DEFAULT 'READER_ADMIN';                -- EDIT ME
    admin_password VARCHAR DEFAULT 'Replace-With-A-Str0ng-Passw0rd!';  -- EDIT ME: min 8 chars, upper, lower, digit
    existing_cnt   NUMBER DEFAULT 0;
    reader_locator VARCHAR;
BEGIN
    IF (NOT create_reader) THEN
        RETURN 'Skipped: set create_reader = TRUE in 02_reader_account_optional.sql to create a reader account.';
    END IF;

    SHOW MANAGED ACCOUNTS;
    SELECT COUNT(*) INTO :existing_cnt
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
    WHERE "name" = :reader_name;

    IF (existing_cnt = 0) THEN
        EXECUTE IMMEDIATE 'CREATE MANAGED ACCOUNT ' || reader_name ||
                          ' ADMIN_NAME = ''' || admin_name || '''' ||
                          ', ADMIN_PASSWORD = ''' || admin_password || '''' ||
                          ', TYPE = READER' ||
                          ', COMMENT = ''Accelerator 15 reader account for ACCEL_SALES_SHARE''';
    END IF;

    SHOW MANAGED ACCOUNTS;
    SELECT "locator" INTO :reader_locator
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
    WHERE "name" = :reader_name
    LIMIT 1;

    EXECUTE IMMEDIATE 'ALTER SHARE ACCEL_SALES_SHARE ADD ACCOUNTS = ' || reader_locator;
    RETURN 'Reader account ' || reader_name || ' (locator ' || reader_locator || ') added to ACCEL_SALES_SHARE. ' ||
           'Login URL: see SHOW MANAGED ACCOUNTS (column "url"). Provisioning can take a few minutes.';
END;
$$;

SHOW MANAGED ACCOUNTS;

/*----------------------------------------------------------------------------
  INSIDE THE READER ACCOUNT (log in with the URL from SHOW MANAGED ACCOUNTS
  as READER_ADMIN, open a worksheet and run):

  USE ROLE ACCOUNTADMIN;
  CREATE WAREHOUSE IF NOT EXISTS READER_WH WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE;
  CREATE RESOURCE MONITOR READER_RM WITH CREDIT_QUOTA = 5 TRIGGERS ON 100 PERCENT DO SUSPEND;
  ALTER WAREHOUSE READER_WH SET RESOURCE_MONITOR = READER_RM;
  -- <provider_locator> = SELECT CURRENT_ACCOUNT() in the provider account
  CREATE DATABASE SALES_FROM_PROVIDER FROM SHARE <provider_locator>.ACCEL_SALES_SHARE;
  SELECT * FROM SALES_FROM_PROVIDER.SHARING.V_SALES_BY_REGION_CATEGORY_MONTH LIMIT 100;

  To remove later (provider account, ACCOUNTADMIN):
  DROP MANAGED ACCOUNT ACCEL_SALES_READER;
----------------------------------------------------------------------------*/
