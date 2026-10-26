/* =============================================================================
   07 GOVERNANCE KIT | 03_auto_classification.sql
   Sensitive data classification with a classification profile:
   - SYSTEM$CLASSIFY on DEMO tables (auto_tag applies the system tags
     SNOWFLAKE.CORE.SEMANTIC_CATEGORY / PRIVACY_CATEGORY)
   - optional: attach the profile to the schema for automatic, scheduled
     (serverless) classification of new and changed tables
   Run BEFORE masking (file 06) so the classifier reads clear values.
   Run as: ACCEL_ADMIN (CLASSIFICATION_ADMIN + EXECUTE AUTO CLASSIFICATION from file 01 / below).
============================================================================= */
-- ACCOUNTADMIN: classification-profile creation + auto classification on a schema are granted privileges
USE ROLE ACCOUNTADMIN;
GRANT CREATE SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE ON SCHEMA ACCEL_DB.GOVERNANCE TO ROLE ACCEL_ADMIN;
GRANT EXECUTE AUTO CLASSIFICATION ON SCHEMA ACCEL_DB.DEMO TO ROLE ACCEL_ADMIN;

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS GOVERNANCE;
USE SCHEMA GOVERNANCE;

CREATE OR REPLACE SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE ACCEL_CLASSIFICATION_PROFILE(
  {
    'minimum_object_age_for_classification_days': 0,
    'maximum_classification_validity_days': 30,
    'auto_tag': true
  });

-- Optional: also map detected categories onto the custom DATA_CLASSIFICATION tag
-- CALL ACCEL_CLASSIFICATION_PROFILE!SET_TAG_MAP(
--   {'column_tag_map': [
--     {'tag_name': 'ACCEL_DB.GOVERNANCE.DATA_CLASSIFICATION', 'tag_value': 'RESTRICTED',
--      'semantic_categories': ['NAME', 'EMAIL', 'PHONE_NUMBER', 'DATE_OF_BIRTH']}
--   ]});

-- Classify the most sensitive demo tables now (returns a JSON result per table)
CALL SYSTEM$CLASSIFY('ACCEL_DB.DEMO.CUSTOMERS', 'ACCEL_DB.GOVERNANCE.ACCEL_CLASSIFICATION_PROFILE');
CALL SYSTEM$CLASSIFY('ACCEL_DB.DEMO.EMPLOYEES', 'ACCEL_DB.GOVERNANCE.ACCEL_CLASSIFICATION_PROFILE');
CALL SYSTEM$CLASSIFY('ACCEL_DB.DEMO.SUPPLIERS', 'ACCEL_DB.GOVERNANCE.ACCEL_CLASSIFICATION_PROFILE');

-- System tags written by auto_tag (real time)
SELECT 'CUSTOMERS' AS TABLE_NAME, COLUMN_NAME, TAG_DATABASE, TAG_SCHEMA, TAG_NAME, TAG_VALUE, APPLY_METHOD
FROM TABLE(ACCEL_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('ACCEL_DB.DEMO.CUSTOMERS', 'table'))
UNION ALL
SELECT 'EMPLOYEES', COLUMN_NAME, TAG_DATABASE, TAG_SCHEMA, TAG_NAME, TAG_VALUE, APPLY_METHOD
FROM TABLE(ACCEL_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('ACCEL_DB.DEMO.EMPLOYEES', 'table'))
ORDER BY 1, 2;

-- Latest classification results (ACCOUNT_USAGE, can lag up to a few hours)
-- SELECT DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, f.key AS COLUMN_NAME,
--        f.value:recommendation:semantic_category::STRING AS SEMANTIC_CATEGORY,
--        f.value:recommendation:privacy_category::STRING  AS PRIVACY_CATEGORY,
--        f.value:recommendation:confidence::STRING        AS CONFIDENCE
-- FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_CLASSIFICATION_LATEST, LATERAL FLATTEN(INPUT => RESULT) f
-- WHERE DATABASE_NAME = 'ACCEL_DB' AND f.value:recommendation IS NOT NULL
-- ORDER BY TABLE_NAME, COLUMN_NAME;

-- Turn on automatic classification for every table in DEMO (serverless, re-checks every 30 days):
-- ALTER SCHEMA ACCEL_DB.DEMO SET CLASSIFICATION_PROFILE = 'ACCEL_DB.GOVERNANCE.ACCEL_CLASSIFICATION_PROFILE';
-- Turn it off:
-- ALTER SCHEMA ACCEL_DB.DEMO UNSET CLASSIFICATION_PROFILE;
