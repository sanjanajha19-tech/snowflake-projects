/* =============================================================================
   07 GOVERNANCE KIT | 02_tag_library.sql
   Central tag library with controlled vocabularies (ALLOWED_VALUES).
   Run as: ACCEL_ADMIN (has APPLY TAG ON ACCOUNT from file 01).
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS GOVERNANCE;
USE SCHEMA GOVERNANCE;

-- IF NOT EXISTS (not OR REPLACE): a tag with masking policies attached cannot be replaced.
CREATE TAG IF NOT EXISTS PII_TYPE
  ALLOWED_VALUES 'EMAIL', 'PHONE', 'PAN', 'NAME', 'SALARY', 'GSTIN', 'ADDRESS', 'FINANCIAL'
  COMMENT = 'Kind of personal/sensitive data in the column. Drives tag-based masking.';

CREATE TAG IF NOT EXISTS DATA_CLASSIFICATION
  ALLOWED_VALUES 'PUBLIC', 'INTERNAL', 'CONFIDENTIAL', 'RESTRICTED'
  COMMENT = 'Information security classification (object or column level).';

CREATE TAG IF NOT EXISTS DATA_OWNER
  ALLOWED_VALUES 'Sales', 'Finance', 'HR', 'Supply Chain', 'Customer Service', 'IT'
  COMMENT = 'Accountable business owner (data owner function).';

CREATE TAG IF NOT EXISTS DOMAIN
  ALLOWED_VALUES 'Customer', 'Product', 'Sales', 'Finance', 'HR', 'Supply Chain', 'Support'
  COMMENT = 'Data domain (data mesh / catalog grouping).';

-- Reference table so catalogs and the Streamlit/coverage views can show the vocabulary
CREATE OR REPLACE TABLE TAG_LIBRARY (
  TAG_NAME      VARCHAR,
  ALLOWED_VALUE VARCHAR,
  MEANING       VARCHAR,
  PROTECTION    VARCHAR
);
INSERT INTO TAG_LIBRARY VALUES
  ('PII_TYPE', 'EMAIL',     'E-mail address',                 'Masked: local part hidden'),
  ('PII_TYPE', 'PHONE',     'Phone number',                   'Masked: last 4 digits shown'),
  ('PII_TYPE', 'PAN',       'Indian Permanent Account Number','Masked: middle digits only'),
  ('PII_TYPE', 'NAME',      'Person / contact name',          'Masked: first letter only'),
  ('PII_TYPE', 'SALARY',    'Compensation amount',            'Masked: NULL'),
  ('PII_TYPE', 'GSTIN',     'GST identification number',      'Masked: fully hidden'),
  ('PII_TYPE', 'ADDRESS',   'Postal address',                 'Masked: fully hidden'),
  ('PII_TYPE', 'FINANCIAL', 'Customer financial attribute',   'Masked: NULL (numbers) / hidden (text)'),
  ('DATA_CLASSIFICATION', 'PUBLIC',       'Can be published',               'None'),
  ('DATA_CLASSIFICATION', 'INTERNAL',     'Employees only',                 'RBAC'),
  ('DATA_CLASSIFICATION', 'CONFIDENTIAL', 'Need-to-know business data',     'RBAC + row access'),
  ('DATA_CLASSIFICATION', 'RESTRICTED',   'Personal / regulated data',      'RBAC + masking + audit'),
  ('DATA_OWNER', 'Sales',            'Head of Sales',               NULL),
  ('DATA_OWNER', 'Finance',          'CFO office',                  NULL),
  ('DATA_OWNER', 'HR',               'CHRO office',                 NULL),
  ('DATA_OWNER', 'Supply Chain',     'Head of Supply Chain',        NULL),
  ('DATA_OWNER', 'Customer Service', 'Head of Customer Service',    NULL),
  ('DATA_OWNER', 'IT',               'CIO office',                  NULL),
  ('DOMAIN', 'Customer', NULL, NULL), ('DOMAIN', 'Product', NULL, NULL), ('DOMAIN', 'Sales', NULL, NULL),
  ('DOMAIN', 'Finance', NULL, NULL), ('DOMAIN', 'HR', NULL, NULL), ('DOMAIN', 'Supply Chain', NULL, NULL),
  ('DOMAIN', 'Support', NULL, NULL);

-- Stewards and developers may apply the tags (but not change them)
GRANT USAGE ON SCHEMA ACCEL_DB.GOVERNANCE TO ROLE ACCEL_DEVELOPER;
GRANT APPLY ON TAG PII_TYPE            TO ROLE ACCEL_DEVELOPER;
GRANT APPLY ON TAG DATA_CLASSIFICATION TO ROLE ACCEL_DEVELOPER;
GRANT APPLY ON TAG DATA_OWNER          TO ROLE ACCEL_DEVELOPER;
GRANT APPLY ON TAG DOMAIN              TO ROLE ACCEL_DEVELOPER;
GRANT APPLY ON TAG PII_TYPE            TO ROLE FR_DATA_STEWARD;
GRANT APPLY ON TAG DATA_CLASSIFICATION TO ROLE FR_DATA_STEWARD;
GRANT APPLY ON TAG DATA_OWNER          TO ROLE FR_DATA_STEWARD;
GRANT APPLY ON TAG DOMAIN              TO ROLE FR_DATA_STEWARD;
GRANT SELECT ON TABLE TAG_LIBRARY TO DATABASE ROLE ACCEL_DB.AR_GOVERNANCE_READ;

SHOW TAGS IN SCHEMA ACCEL_DB.GOVERNANCE;
