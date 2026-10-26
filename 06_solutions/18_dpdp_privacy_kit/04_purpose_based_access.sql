/*=============================================================================
  ACCELERATOR 18 - DPDP Privacy Kit
  File 04 : Purpose limitation - a role may only see a data principal's rows
            if (a) its purpose is a legitimate use, or (b) the principal has an
            ACTIVE consent for that purpose. Identifiers are masked for roles
            that do not need them (data minimisation).
  Creates : ROLE_PURPOSE_MAP, V_CUSTOMER_PERSONAL_DATA (governed view),
            RAP_PURPOSE_CONSENT (row access policy),
            MP_DPDP_IDENTIFIER (masking policy)
  Run as  : ACCOUNTADMIN for two policy grants, then ACCEL_ADMIN
  Rerun   : safe (view is recreated first, which detaches the old policies).
=============================================================================*/

-- ACCOUNTADMIN: APPLY ROW ACCESS POLICY / APPLY MASKING POLICY are account-level privileges
USE ROLE ACCOUNTADMIN;
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE ACCEL_ADMIN;
GRANT APPLY MASKING POLICY    ON ACCOUNT TO ROLE ACCEL_ADMIN;

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS DPDP;
USE SCHEMA DPDP;

------------------------------------------------------------------------------
-- 1. Which role works for which purpose
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE ROLE_PURPOSE_MAP (
    ROLE_NAME          VARCHAR,
    PURPOSE_CODE       VARCHAR,
    SEES_IDENTIFIERS   BOOLEAN    -- may this role see e-mail / phone / PAN in clear?
);
INSERT INTO ROLE_PURPOSE_MAP VALUES
    ('ACCEL_DEVELOPER', 'CUSTOMER_SUPPORT', TRUE),    -- EDIT ME: support team role
    ('ACCEL_ANALYST',   'ANALYTICS',        FALSE),   -- EDIT ME: analytics role
    ('ACCEL_VIEWER',    'MARKETING',        TRUE);    -- EDIT ME: marketing role

------------------------------------------------------------------------------
-- 2. Governed view over the system of record
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_CUSTOMER_PERSONAL_DATA
  COMMENT = 'DPDP kit: purpose-bound access to customer personal data'
AS
SELECT CUSTOMER_ID, CUSTOMER_NAME, SEGMENT, INDUSTRY, REGION, COUNTRY, CITY,
       EMAIL, PHONE, PAN_NUMBER, CREATED_DATE, CREDIT_LIMIT
FROM ACCEL_DB.DPDP.CUSTOMERS;

------------------------------------------------------------------------------
-- 3. Row access policy: legitimate use OR active consent for the role's purpose
------------------------------------------------------------------------------
CREATE OR REPLACE ROW ACCESS POLICY RAP_PURPOSE_CONSENT
  AS (P_CUSTOMER_ID NUMBER) RETURNS BOOLEAN ->
    CURRENT_ROLE() IN ('ACCEL_ADMIN', 'ACCOUNTADMIN')          -- privacy office / DPO
    OR EXISTS (
        SELECT 1
        FROM ACCEL_DB.DPDP.ROLE_PURPOSE_MAP m
        JOIN ACCEL_DB.DPDP.PROCESSING_PURPOSES p ON p.PURPOSE_CODE = m.PURPOSE_CODE
        WHERE m.ROLE_NAME = CURRENT_ROLE()
          AND p.LAWFUL_BASIS = 'LEGITIMATE_USE'
    )
    OR EXISTS (
        SELECT 1
        FROM ACCEL_DB.DPDP.ROLE_PURPOSE_MAP m
        JOIN ACCEL_DB.DPDP.CONSENT_REGISTER c ON c.PURPOSE_CODE = m.PURPOSE_CODE
        WHERE m.ROLE_NAME = CURRENT_ROLE()
          AND c.DATA_PRINCIPAL_ID = P_CUSTOMER_ID
          AND c.IS_CURRENT
          AND c.CONSENT_STATUS = 'GRANTED'
          AND (c.EXPIRES_AT IS NULL OR c.EXPIRES_AT > CURRENT_TIMESTAMP())
    )
  COMMENT = 'DPDP purpose limitation: rows visible only for legitimate use or active consent';

------------------------------------------------------------------------------
-- 4. Masking policy: identifiers only in clear for roles that need them
------------------------------------------------------------------------------
CREATE OR REPLACE MASKING POLICY MP_DPDP_IDENTIFIER
  AS (VAL VARCHAR) RETURNS VARCHAR ->
    CASE
      WHEN VAL IS NULL THEN NULL
      WHEN CURRENT_ROLE() IN ('ACCEL_ADMIN', 'ACCOUNTADMIN') THEN VAL
      WHEN EXISTS (SELECT 1 FROM ACCEL_DB.DPDP.ROLE_PURPOSE_MAP m
                   WHERE m.ROLE_NAME = CURRENT_ROLE() AND m.SEES_IDENTIFIERS) THEN VAL
      ELSE '***' || RIGHT(VAL, 2)
    END
  COMMENT = 'DPDP data minimisation: mask direct identifiers for roles that do not need them';

ALTER VIEW V_CUSTOMER_PERSONAL_DATA ADD ROW ACCESS POLICY RAP_PURPOSE_CONSENT ON (CUSTOMER_ID);
ALTER VIEW V_CUSTOMER_PERSONAL_DATA MODIFY COLUMN EMAIL      SET MASKING POLICY MP_DPDP_IDENTIFIER;
ALTER VIEW V_CUSTOMER_PERSONAL_DATA MODIFY COLUMN PHONE      SET MASKING POLICY MP_DPDP_IDENTIFIER;
ALTER VIEW V_CUSTOMER_PERSONAL_DATA MODIFY COLUMN PAN_NUMBER SET MASKING POLICY MP_DPDP_IDENTIFIER;

GRANT USAGE  ON SCHEMA ACCEL_DB.DPDP TO ROLE ACCEL_VIEWER;
GRANT SELECT ON VIEW ACCEL_DB.DPDP.V_CUSTOMER_PERSONAL_DATA TO ROLE ACCEL_VIEWER;   -- inherited by ANALYST / DEVELOPER

------------------------------------------------------------------------------
-- 5. Demo: same view, different purpose -> different rows and masking
------------------------------------------------------------------------------
USE ROLE ACCEL_ADMIN;
SELECT 'ACCEL_ADMIN (privacy office)' AS ROLE_PURPOSE, COUNT(*) AS VISIBLE_CUSTOMERS FROM V_CUSTOMER_PERSONAL_DATA;

USE ROLE ACCEL_DEVELOPER;
SELECT 'ACCEL_DEVELOPER (support = legitimate use)' AS ROLE_PURPOSE, COUNT(*) AS VISIBLE_CUSTOMERS FROM ACCEL_DB.DPDP.V_CUSTOMER_PERSONAL_DATA;

USE ROLE ACCEL_ANALYST;
SELECT 'ACCEL_ANALYST (analytics consent)' AS ROLE_PURPOSE, COUNT(*) AS VISIBLE_CUSTOMERS FROM ACCEL_DB.DPDP.V_CUSTOMER_PERSONAL_DATA;
SELECT CUSTOMER_ID, CUSTOMER_NAME, EMAIL, PHONE, PAN_NUMBER        -- identifiers masked for analytics
FROM ACCEL_DB.DPDP.V_CUSTOMER_PERSONAL_DATA LIMIT 5;

USE ROLE ACCEL_VIEWER;
SELECT 'ACCEL_VIEWER (marketing consent)' AS ROLE_PURPOSE, COUNT(*) AS VISIBLE_CUSTOMERS FROM ACCEL_DB.DPDP.V_CUSTOMER_PERSONAL_DATA;
-- Customer 42 withdrew marketing consent in file 03 -> returns no row:
SELECT * FROM ACCEL_DB.DPDP.V_CUSTOMER_PERSONAL_DATA WHERE CUSTOMER_ID = 42;

USE ROLE ACCEL_ADMIN;
