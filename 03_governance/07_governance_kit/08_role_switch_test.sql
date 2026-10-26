/* =============================================================================
   07 GOVERNANCE KIT | 08_role_switch_test.sql
   Proves the controls by querying the same data under different roles.
   IMPORTANT: secondary roles are switched OFF for the test. Snowsight sessions
   often run with DEFAULT_SECONDARY_ROLES = ('ALL'); IS_ROLE_IN_SESSION would
   then see ACCEL_ADMIN as a secondary role and show clear values.
   Expected results are in the EXPECTED column of each query.
============================================================================= */

-- SECURITYADMIN: grant the functional roles to the user running this test
USE ROLE SECURITYADMIN;
EXECUTE IMMEDIATE $$
BEGIN
  EXECUTE IMMEDIATE 'GRANT ROLE FR_SALES_ANALYST TO USER "' || REPLACE(CURRENT_USER(), '"', '""') || '"';
  EXECUTE IMMEDIATE 'GRANT ROLE FR_HR_ANALYST TO USER "' || REPLACE(CURRENT_USER(), '"', '""') || '"';
  EXECUTE IMMEDIATE 'GRANT ROLE FR_FINANCE_ANALYST TO USER "' || REPLACE(CURRENT_USER(), '"', '""') || '"';
  RETURN 'Functional roles granted to ' || CURRENT_USER();
END;
$$;

USE SECONDARY ROLES NONE;

-- ---------------------------------------------------------------------------
-- TEST 1: ACCEL_ADMIN sees everything in clear
-- ---------------------------------------------------------------------------
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
SELECT 'ACCEL_ADMIN' AS TESTED_ROLE, 'all 5 regions, clear PII' AS EXPECTED,
       COUNT(DISTINCT REGION) AS REGIONS_VISIBLE, COUNT(*) AS ROWS_VISIBLE,
       MAX(EMAIL) AS SAMPLE_EMAIL, MAX(PHONE) AS SAMPLE_PHONE, MAX(PAN_NUMBER) AS SAMPLE_PAN
FROM ACCEL_DB.DEMO.CUSTOMERS;

-- ---------------------------------------------------------------------------
-- TEST 2: FR_SALES_ANALYST -> only North + West rows, masked email/phone/PAN
-- ---------------------------------------------------------------------------
USE ROLE FR_SALES_ANALYST;
USE WAREHOUSE ACCEL_WH;
SELECT 'FR_SALES_ANALYST' AS TESTED_ROLE, 'regions North, West only; masked PII' AS EXPECTED,
       LISTAGG(DISTINCT REGION, ', ') WITHIN GROUP (ORDER BY REGION) AS REGIONS_VISIBLE, COUNT(*) AS ROWS_VISIBLE,
       MAX(EMAIL) AS SAMPLE_EMAIL, MAX(PHONE) AS SAMPLE_PHONE, MAX(PAN_NUMBER) AS SAMPLE_PAN
FROM ACCEL_DB.DEMO.CUSTOMERS;

SELECT CUSTOMER_ID, CUSTOMER_NAME, REGION, EMAIL, PHONE, PAN_NUMBER
FROM ACCEL_DB.DEMO.CUSTOMERS
ORDER BY CUSTOMER_ID
LIMIT 10;
-- Not granted (AR_HR_READ missing) - uncomment to see the access error:
-- SELECT * FROM ACCEL_DB.DEMO.EMPLOYEES LIMIT 5;

-- ---------------------------------------------------------------------------
-- TEST 3: FR_FINANCE_ANALYST -> all regions (mapping '*'), still masked PII
-- ---------------------------------------------------------------------------
USE ROLE FR_FINANCE_ANALYST;
USE WAREHOUSE ACCEL_WH;
SELECT 'FR_FINANCE_ANALYST' AS TESTED_ROLE, 'all 5 regions; masked PII' AS EXPECTED,
       COUNT(DISTINCT REGION) AS REGIONS_VISIBLE, COUNT(*) AS ROWS_VISIBLE,
       MAX(EMAIL) AS SAMPLE_EMAIL, MAX(PAN_NUMBER) AS SAMPLE_PAN
FROM ACCEL_DB.DEMO.CUSTOMERS;

SELECT 'FR_FINANCE_ANALYST' AS TESTED_ROLE, 'GL readable' AS EXPECTED, COUNT(*) AS GL_ROWS
FROM ACCEL_DB.DEMO.GL_JOURNAL;

-- ---------------------------------------------------------------------------
-- TEST 4: FR_HR_ANALYST -> employees readable, names / e-mails masked, salary NULL
-- ---------------------------------------------------------------------------
USE ROLE FR_HR_ANALYST;
USE WAREHOUSE ACCEL_WH;
SELECT 'FR_HR_ANALYST' AS TESTED_ROLE, 'FULL_NAME A*****, EMAIL *****@..., SALARY NULL' AS EXPECTED,
       EMPLOYEE_ID, FULL_NAME, EMAIL, DEPARTMENT, SALARY
FROM ACCEL_DB.DEMO.EMPLOYEES
ORDER BY EMPLOYEE_ID
LIMIT 10;

-- ---------------------------------------------------------------------------
-- TEST 5: ACCEL_ANALYST (existing accelerator role) -> all rows, masked PII
-- ---------------------------------------------------------------------------
USE ROLE ACCEL_ANALYST;
USE WAREHOUSE ACCEL_WH;
SELECT 'ACCEL_ANALYST' AS TESTED_ROLE, 'all 5 regions; masked PII' AS EXPECTED,
       COUNT(DISTINCT REGION) AS REGIONS_VISIBLE, MAX(EMAIL) AS SAMPLE_EMAIL
FROM ACCEL_DB.DEMO.CUSTOMERS;

-- ---------------------------------------------------------------------------
-- Back to normal
-- ---------------------------------------------------------------------------
USE ROLE ACCEL_ADMIN;
USE SECONDARY ROLES ALL;

-- Live change demo: give the sales analyst the South region and rerun TEST 2
-- INSERT INTO ACCEL_DB.GOVERNANCE.REGION_ACCESS_MAP (ROLE_NAME, REGION) VALUES ('FR_SALES_ANALYST', 'South');
-- Revoke again:
-- DELETE FROM ACCEL_DB.GOVERNANCE.REGION_ACCESS_MAP WHERE ROLE_NAME = 'FR_SALES_ANALYST' AND REGION = 'South';
