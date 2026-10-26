/* =============================================================================
   07 GOVERNANCE KIT | 06_masking_and_row_access.sql
   - Tag-based masking: two policies attached to the PII_TYPE tag (one per data
     type, the maximum Snowflake allows per tag). Each policy reads the column's
     tag value and masks EMAIL / PHONE / PAN / NAME / SALARY differently.
     Only sessions with ACCEL_ADMIN in their role hierarchy see clear values.
   - Row access policy on REGION driven by a role-to-region mapping table.
   Policies use IS_ROLE_IN_SESSION (role hierarchy aware; also supported on base
   tables of Dynamic Tables, so the lakehouse asset keeps refreshing).
   Rerunnable: CREATE ... IF NOT EXISTS + ALTER ... SET BODY, attachments via SAFE_EXEC.
   Run as: ACCEL_ADMIN (APPLY MASKING / ROW ACCESS POLICY granted in file 01).
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS GOVERNANCE;
USE SCHEMA GOVERNANCE;

-- ---------------------------------------------------------------------------
-- 1. Masking policies (STRING + NUMBER)
-- ---------------------------------------------------------------------------
CREATE MASKING POLICY IF NOT EXISTS MASK_PII_STRING AS (VAL STRING) RETURNS STRING -> VAL
  COMMENT = 'Tag-based PII masking for text columns (driven by GOVERNANCE.PII_TYPE)';

ALTER MASKING POLICY MASK_PII_STRING SET BODY ->
  CASE
    WHEN VAL IS NULL THEN NULL
    WHEN IS_ROLE_IN_SESSION('ACCEL_ADMIN') THEN VAL
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('ACCEL_DB.GOVERNANCE.PII_TYPE') = 'EMAIL'
      THEN REGEXP_REPLACE(VAL, '^[^@]+', '*****')                                   -- *****@domain.com
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('ACCEL_DB.GOVERNANCE.PII_TYPE') = 'PHONE'
      THEN REPEAT('*', GREATEST(LENGTH(VAL) - 4, 0)) || RIGHT(VAL, 4)              -- ********1001
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('ACCEL_DB.GOVERNANCE.PII_TYPE') = 'PAN'
      THEN 'XXXXX' || SUBSTR(VAL, 6, 4) || 'X'                                      -- XXXXX1001X
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('ACCEL_DB.GOVERNANCE.PII_TYPE') = 'NAME'
      THEN LEFT(VAL, 1) || '*****'                                                  -- A*****
    ELSE '***MASKED***'                                                             -- GSTIN, ADDRESS, ...
  END;

CREATE MASKING POLICY IF NOT EXISTS MASK_PII_NUMBER AS (VAL NUMBER(38,2)) RETURNS NUMBER(38,2) -> VAL
  COMMENT = 'Tag-based PII masking for numeric columns (SALARY, FINANCIAL)';

ALTER MASKING POLICY MASK_PII_NUMBER SET BODY ->
  CASE
    WHEN IS_ROLE_IN_SESSION('ACCEL_ADMIN') THEN VAL
    ELSE NULL
  END;

-- Attach both to the tag: every column tagged PII_TYPE is protected automatically,
-- including columns tagged in the future. (SAFE_EXEC: skip if already attached.)
CALL SAFE_EXEC('ALTER TAG ACCEL_DB.GOVERNANCE.PII_TYPE SET MASKING POLICY ACCEL_DB.GOVERNANCE.MASK_PII_STRING');
CALL SAFE_EXEC('ALTER TAG ACCEL_DB.GOVERNANCE.PII_TYPE SET MASKING POLICY ACCEL_DB.GOVERNANCE.MASK_PII_NUMBER');

-- ---------------------------------------------------------------------------
-- 2. Row access: role -> region mapping ('*' = all regions)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS REGION_ACCESS_MAP (
  ROLE_NAME  VARCHAR NOT NULL,
  REGION     VARCHAR NOT NULL,       -- 'North','South','East','West','Central' or '*'
  GRANTED_BY VARCHAR DEFAULT CURRENT_USER(),
  GRANTED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

MERGE INTO REGION_ACCESS_MAP t
USING (
  SELECT * FROM VALUES
    ('FR_SALES_ANALYST',   'North'),     -- EDIT ME: your entitlements
    ('FR_SALES_ANALYST',   'West'),
    ('FR_FINANCE_ANALYST', '*'),
    ('FR_DATA_STEWARD',    '*'),
    ('ACCEL_DEVELOPER',    '*'),         -- other accelerators keep full row visibility
    ('ACCEL_ANALYST',      '*'),
    ('ACCEL_VIEWER',       '*')
  AS s(ROLE_NAME, REGION)
) s
ON t.ROLE_NAME = s.ROLE_NAME AND t.REGION = s.REGION
WHEN NOT MATCHED THEN INSERT (ROLE_NAME, REGION) VALUES (s.ROLE_NAME, s.REGION);

CREATE ROW ACCESS POLICY IF NOT EXISTS RAP_REGION AS (P_REGION VARCHAR) RETURNS BOOLEAN -> TRUE
  COMMENT = 'Rows visible when a role in the session is mapped to the row region';

ALTER ROW ACCESS POLICY RAP_REGION SET BODY ->
  IS_ROLE_IN_SESSION('ACCEL_ADMIN')
  OR EXISTS (
    SELECT 1
    FROM ACCEL_DB.GOVERNANCE.REGION_ACCESS_MAP m
    WHERE (m.REGION = P_REGION OR m.REGION = '*')
      AND IS_ROLE_IN_SESSION(m.ROLE_NAME)
  );

CALL SAFE_EXEC('ALTER TABLE ACCEL_DB.DEMO.CUSTOMERS ADD ROW ACCESS POLICY ACCEL_DB.GOVERNANCE.RAP_REGION ON (REGION)');

-- ---------------------------------------------------------------------------
-- 3. Verify (real time)
-- ---------------------------------------------------------------------------
SELECT POLICY_NAME, POLICY_KIND, REF_ENTITY_NAME, REF_COLUMN_NAME, TAG_NAME, POLICY_STATUS
FROM TABLE(ACCEL_DB.INFORMATION_SCHEMA.POLICY_REFERENCES(
       REF_ENTITY_NAME => 'ACCEL_DB.DEMO.CUSTOMERS', REF_ENTITY_DOMAIN => 'table'))
UNION ALL
SELECT POLICY_NAME, POLICY_KIND, REF_ENTITY_NAME, REF_COLUMN_NAME, TAG_NAME, POLICY_STATUS
FROM TABLE(ACCEL_DB.INFORMATION_SCHEMA.POLICY_REFERENCES(
       REF_ENTITY_NAME => 'ACCEL_DB.DEMO.EMPLOYEES', REF_ENTITY_DOMAIN => 'table'));

-- As ACCEL_ADMIN you still see clear values; file 08 switches roles to show masking.
SELECT CUSTOMER_ID, REGION, EMAIL, PHONE, PAN_NUMBER FROM ACCEL_DB.DEMO.CUSTOMERS LIMIT 5;

-- Remove everything (if needed):
-- ALTER TABLE ACCEL_DB.DEMO.CUSTOMERS DROP ROW ACCESS POLICY ACCEL_DB.GOVERNANCE.RAP_REGION;
-- ALTER TAG ACCEL_DB.GOVERNANCE.PII_TYPE UNSET MASKING POLICY ACCEL_DB.GOVERNANCE.MASK_PII_STRING;
-- ALTER TAG ACCEL_DB.GOVERNANCE.PII_TYPE UNSET MASKING POLICY ACCEL_DB.GOVERNANCE.MASK_PII_NUMBER;
