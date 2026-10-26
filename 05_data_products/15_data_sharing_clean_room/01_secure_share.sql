/*=============================================================================
  ACCELERATOR 15 - Data Sharing & Clean Room
  File 01 : Secure data sharing of aggregated sales
  Creates : schema ACCEL_DB.SHARING
            - SALES_MONTHLY_AGG          (aggregated table, refreshed by SP)
            - CONSUMER_ENTITLEMENTS      (which consumer account sees which regions)
            - SHARE_CONFIG               (consumer accounts to add to the share)
            - V_SALES_BY_REGION_CATEGORY_MONTH  (secure view, all regions)
            - V_SALES_ENTITLED           (secure view, row-filtered per consumer)
            - SP_REFRESH_SALES_AGG       (procedure)
            - SHARE ACCEL_SALES_SHARE    (with grants)
  Run as  : ACCOUNTADMIN for one grant (CREATE SHARE), then ACCEL_ADMIN.
  Rerun   : safe.
=============================================================================*/

-- ACCOUNTADMIN: only an account admin can grant the account-level CREATE SHARE privilege
USE ROLE ACCOUNTADMIN;
GRANT CREATE SHARE ON ACCOUNT TO ROLE ACCEL_ADMIN;

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SHARING COMMENT = 'Accelerator 15: outbound data products';
USE SCHEMA SHARING;

------------------------------------------------------------------------------
-- 1. Aggregated data product (no customer-level rows ever leave the account)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE SALES_MONTHLY_AGG (
    SALES_MONTH        DATE,
    REGION             VARCHAR,
    COUNTRY            VARCHAR,
    CATEGORY           VARCHAR,
    CURRENCY           VARCHAR,
    ORDER_COUNT        NUMBER,
    CUSTOMER_COUNT     NUMBER,
    UNITS_SOLD         NUMBER,
    NET_SALES          NUMBER(18,2),
    AVG_DISCOUNT_PCT   NUMBER(6,2),
    REFRESHED_AT       TIMESTAMP_NTZ
) COMMENT = 'Monthly sales aggregated by region / country / category. Groups with < 5 customers suppressed.';

CREATE OR REPLACE PROCEDURE SP_REFRESH_SALES_AGG(MIN_CUSTOMERS NUMBER)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    TRUNCATE TABLE ACCEL_DB.SHARING.SALES_MONTHLY_AGG;
    INSERT INTO ACCEL_DB.SHARING.SALES_MONTHLY_AGG
    SELECT
        DATE_TRUNC('MONTH', o.ORDER_DATE)              AS SALES_MONTH,
        c.REGION,
        c.COUNTRY,
        p.CATEGORY,
        o.CURRENCY,
        COUNT(DISTINCT o.ORDER_ID)                     AS ORDER_COUNT,
        COUNT(DISTINCT o.CUSTOMER_ID)                  AS CUSTOMER_COUNT,
        SUM(ol.QUANTITY)                               AS UNITS_SOLD,
        SUM(ol.NET_AMOUNT)::NUMBER(18,2)               AS NET_SALES,
        AVG(ol.DISCOUNT_PCT)::NUMBER(6,2)              AS AVG_DISCOUNT_PCT,
        CURRENT_TIMESTAMP()::TIMESTAMP_NTZ             AS REFRESHED_AT
    FROM ACCEL_DB.DEMO.ORDERS o
    JOIN ACCEL_DB.DEMO.ORDER_LINES ol ON ol.ORDER_ID = o.ORDER_ID
    JOIN ACCEL_DB.DEMO.CUSTOMERS  c  ON c.CUSTOMER_ID = o.CUSTOMER_ID
    JOIN ACCEL_DB.DEMO.PRODUCTS   p  ON p.PRODUCT_ID = ol.PRODUCT_ID
    WHERE o.STATUS IN ('Delivered', 'Shipped')
    GROUP BY 1, 2, 3, 4, 5
    HAVING COUNT(DISTINCT o.CUSTOMER_ID) >= :MIN_CUSTOMERS;   -- small-cell suppression
    RETURN 'SALES_MONTHLY_AGG refreshed: ' || SQLROWCOUNT || ' rows';
END;
$$;

CALL SP_REFRESH_SALES_AGG(5);   -- EDIT ME: minimum distinct customers per published cell

------------------------------------------------------------------------------
-- 2. Entitlements: one share, many consumers, each sees only its regions.
--    CURRENT_ACCOUNT() inside a shared secure view returns the CONSUMER's
--    account locator, so a mapping table gives per-consumer row filtering.
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CONSUMER_ENTITLEMENTS (
    CONSUMER_ACCOUNT_LOCATOR VARCHAR,   -- e.g. 'AB12345' (run SELECT CURRENT_ACCOUNT() in the consumer account)
    REGION                   VARCHAR,
    GRANTED_AT               TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
);

MERGE INTO CONSUMER_ENTITLEMENTS t
USING (
    SELECT 'CONSUMER_LOCATOR_1' AS CONSUMER_ACCOUNT_LOCATOR, 'North' AS REGION   -- EDIT ME: real consumer locator
    UNION ALL SELECT 'CONSUMER_LOCATOR_1', 'West'                               -- EDIT ME
    UNION ALL SELECT 'CONSUMER_LOCATOR_2', 'South'                              -- EDIT ME
) s
ON t.CONSUMER_ACCOUNT_LOCATOR = s.CONSUMER_ACCOUNT_LOCATOR AND t.REGION = s.REGION
WHEN NOT MATCHED THEN INSERT (CONSUMER_ACCOUNT_LOCATOR, REGION) VALUES (s.CONSUMER_ACCOUNT_LOCATOR, s.REGION);

------------------------------------------------------------------------------
-- 3. Secure views (the only objects granted to the share)
------------------------------------------------------------------------------
CREATE OR REPLACE SECURE VIEW V_SALES_BY_REGION_CATEGORY_MONTH
  COMMENT = 'Shared data product: monthly sales by region / country / category (aggregated, suppressed < 5 customers)'
AS
SELECT SALES_MONTH, REGION, COUNTRY, CATEGORY, CURRENCY,
       ORDER_COUNT, CUSTOMER_COUNT, UNITS_SOLD, NET_SALES, AVG_DISCOUNT_PCT, REFRESHED_AT
FROM ACCEL_DB.SHARING.SALES_MONTHLY_AGG;

CREATE OR REPLACE SECURE VIEW V_SALES_ENTITLED
  COMMENT = 'Shared data product: same as V_SALES_BY_REGION_CATEGORY_MONTH, filtered to the regions the consumer account is entitled to'
AS
SELECT a.SALES_MONTH, a.REGION, a.COUNTRY, a.CATEGORY, a.CURRENCY,
       a.ORDER_COUNT, a.CUSTOMER_COUNT, a.UNITS_SOLD, a.NET_SALES, a.AVG_DISCOUNT_PCT, a.REFRESHED_AT
FROM ACCEL_DB.SHARING.SALES_MONTHLY_AGG a
JOIN ACCEL_DB.SHARING.CONSUMER_ENTITLEMENTS e
  ON e.REGION = a.REGION
 AND e.CONSUMER_ACCOUNT_LOCATOR = CURRENT_ACCOUNT();

------------------------------------------------------------------------------
-- 4. The share
------------------------------------------------------------------------------
CREATE SHARE IF NOT EXISTS ACCEL_SALES_SHARE
  COMMENT = 'Accelerator 15: aggregated sales data product';

GRANT USAGE  ON DATABASE ACCEL_DB                                      TO SHARE ACCEL_SALES_SHARE;
GRANT USAGE  ON SCHEMA   ACCEL_DB.SHARING                              TO SHARE ACCEL_SALES_SHARE;
GRANT SELECT ON VIEW     ACCEL_DB.SHARING.V_SALES_BY_REGION_CATEGORY_MONTH TO SHARE ACCEL_SALES_SHARE;
GRANT SELECT ON VIEW     ACCEL_DB.SHARING.V_SALES_ENTITLED             TO SHARE ACCEL_SALES_SHARE;

------------------------------------------------------------------------------
-- 5. Add consumer account(s). Format: ORGNAME.ACCOUNTNAME (preferred) or account locator.
--    Leave 'NONE' to skip (the share is still created and testable in-account).
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SHARE_CONFIG (CONSUMER_ACCOUNTS VARCHAR);
INSERT OVERWRITE INTO SHARE_CONFIG
SELECT 'NONE';   -- EDIT ME: e.g. 'MYORG.PARTNER_ACCT' or 'MYORG.ACCT1, MYORG.ACCT2'

EXECUTE IMMEDIATE $$
DECLARE
    accts VARCHAR;
BEGIN
    SELECT CONSUMER_ACCOUNTS INTO :accts FROM ACCEL_DB.SHARING.SHARE_CONFIG LIMIT 1;
    IF (accts IS NULL OR UPPER(TRIM(accts)) = 'NONE') THEN
        RETURN 'No consumer account configured - share created without consumers. Edit SHARE_CONFIG and rerun section 5.';
    END IF;
    EXECUTE IMMEDIATE 'ALTER SHARE ACCEL_SALES_SHARE ADD ACCOUNTS = ' || accts;
    RETURN 'Share ACCEL_SALES_SHARE granted to: ' || accts;
END;
$$;

------------------------------------------------------------------------------
-- 6. Verify (provider side)
------------------------------------------------------------------------------
SHOW SHARES LIKE 'ACCEL_SALES_SHARE';
SHOW GRANTS TO SHARE ACCEL_SALES_SHARE;

SELECT REGION, CATEGORY, SUM(NET_SALES) AS NET_SALES
FROM V_SALES_BY_REGION_CATEGORY_MONTH
WHERE SALES_MONTH >= '2026-01-01'
GROUP BY 1, 2
ORDER BY NET_SALES DESC
LIMIT 20;

-- Simulate what a consumer will see through the entitlement view:
-- SIMULATED_DATA_SHARING_CONSUMER makes CURRENT_ACCOUNT() return the given value
-- inside secure views, without needing a second account.
ALTER SESSION SET SIMULATED_DATA_SHARING_CONSUMER = 'CONSUMER_LOCATOR_1';   -- EDIT ME if you changed the entitlements
SELECT REGION, COUNT(*) AS ROWS_VISIBLE, SUM(NET_SALES) AS NET_SALES
FROM V_SALES_ENTITLED
GROUP BY REGION;
ALTER SESSION UNSET SIMULATED_DATA_SHARING_CONSUMER;

/*----------------------------------------------------------------------------
  CONSUMER SIDE (run in the consumer account, not here):

  USE ROLE ACCOUNTADMIN;
  CREATE DATABASE SALES_FROM_PROVIDER FROM SHARE <provider_org>.<provider_account>.ACCEL_SALES_SHARE;
  GRANT IMPORTED PRIVILEGES ON DATABASE SALES_FROM_PROVIDER TO ROLE SYSADMIN;
  SELECT * FROM SALES_FROM_PROVIDER.SHARING.V_SALES_ENTITLED LIMIT 100;
----------------------------------------------------------------------------*/
