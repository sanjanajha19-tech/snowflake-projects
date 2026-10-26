/* =============================================================================
   Asset 23 - Customer 360 & Entity Resolution
   File  01_source_systems.sql
   Purpose
     Builds two additional, deliberately messy customer sources so that entity
     resolution has something realistic to resolve:
       * ACCEL_DB.C360_CRM.CRM_ACCOUNTS     - sales CRM (typos, Pvt Ltd/Private
                                               Limited, phone formats, missing
                                               emails, in-source duplicates)
       * ACCEL_DB.C360_ECOM.ECOM_CUSTOMERS  - e-commerce platform (lower-case
                                               names, +country-code phones, few
                                               PANs, guest shoppers not in ERP)
     The ERP source is ACCEL_DB.DEMO.CUSTOMERS (built by 00_setup).
   Run as  ACCEL_ADMIN. Rerunnable (CREATE OR REPLACE). Deterministic (HASH based).
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS C360;
CREATE SCHEMA IF NOT EXISTS C360_CRM;
CREATE SCHEMA IF NOT EXISTS C360_ECOM;
USE SCHEMA C360;

-- Dial calling codes used to re-format phone numbers in the synthetic sources.
CREATE OR REPLACE TABLE C360.COUNTRY_DIAL_CODES (COUNTRY VARCHAR, DIAL_CODE VARCHAR);
INSERT INTO C360.COUNTRY_DIAL_CODES VALUES
  ('India','91'), ('USA','1'), ('UK','44'), ('Germany','49'), ('Japan','81'), ('Singapore','65');

-- -----------------------------------------------------------------------------
-- 1. CRM source: ~85% of ERP customers + ~3% in-CRM duplicates
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE C360_CRM.CRM_ACCOUNTS AS
WITH base AS (
    SELECT c.*,
           COALESCE(d.DIAL_CODE, '91')                                   AS DIAL_CODE,
           REGEXP_REPLACE(COALESCE(c.PHONE, ''), '[^0-9]', '')           AS PHONE_DIGITS,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'crm_in')),   100)                AS H_IN,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'crm_name')),  10)                AS H_NAME,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'crm_phone')), 10)                AS H_PHONE,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'crm_email')), 10)                AS H_EMAIL,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'crm_pan')),   10)                AS H_PAN,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'crm_city')),  10)                AS H_CITY,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'crm_dup')),  100)                AS H_DUP,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'crm_pos')),  GREATEST(LENGTH(c.CUSTOMER_NAME) - 3, 1)) + 2 AS TYPO_POS
    FROM ACCEL_DB.DEMO.CUSTOMERS c
    LEFT JOIN C360.COUNTRY_DIAL_CODES d ON d.COUNTRY = c.COUNTRY
),
variants AS (
    -- copy 0 = primary CRM record, copy 1 = duplicate CRM record (sales rep re-keyed it)
    SELECT b.*, 0 AS COPY_NO FROM base b WHERE b.H_IN < 85
    UNION ALL
    SELECT b.*, 1 AS COPY_NO FROM base b WHERE b.H_IN < 85 AND b.H_DUP < 3
)
SELECT
    'CRM-' || TO_VARCHAR(CUSTOMER_ID) || IFF(COPY_NO = 1, '-D', '')            AS CRM_ACCOUNT_ID,
    CASE WHEN COPY_NO = 1 THEN   -- duplicates always carry a transposition typo
              SUBSTR(CUSTOMER_NAME, 1, TYPO_POS - 1) || SUBSTR(CUSTOMER_NAME, TYPO_POS + 1, 1)
              || SUBSTR(CUSTOMER_NAME, TYPO_POS, 1) || SUBSTR(CUSTOMER_NAME, TYPO_POS + 2)
         WHEN H_NAME = 0 THEN UPPER(CUSTOMER_NAME)
         WHEN H_NAME = 1 THEN   -- swap legal-form spellings both ways
              REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(CUSTOMER_NAME,
                  'Private Limited', '#PL#'), 'Pvt. Ltd.', '#PV#'), 'Pvt Ltd', 'Private Limited'),
                  '#PL#', 'Pvt. Ltd.'), '#PV#', 'Private Limited')
         WHEN H_NAME = 2 THEN   -- adjacent-character transposition
              SUBSTR(CUSTOMER_NAME, 1, TYPO_POS - 1) || SUBSTR(CUSTOMER_NAME, TYPO_POS + 1, 1)
              || SUBSTR(CUSTOMER_NAME, TYPO_POS, 1) || SUBSTR(CUSTOMER_NAME, TYPO_POS + 2)
         WHEN H_NAME = 3 THEN IFF(CUSTOMER_NAME ILIKE '%ltd%' OR CUSTOMER_NAME ILIKE '%limited%'
                                  OR CUSTOMER_NAME ILIKE '%inc%' OR CUSTOMER_NAME ILIKE '%llp%',
                                  REPLACE(CUSTOMER_NAME, 'Limited', 'Ltd'),
                                  CUSTOMER_NAME || ' Pvt Ltd')
         WHEN H_NAME = 4 THEN REPLACE(REPLACE(CUSTOMER_NAME, ' and ', ' & '), ' And ', ' & ')
         WHEN H_NAME = 5 THEN CUSTOMER_NAME || '.'
         WHEN H_NAME = 6 THEN LOWER(CUSTOMER_NAME)
         WHEN H_NAME = 7 THEN  -- dropped character
              SUBSTR(CUSTOMER_NAME, 1, TYPO_POS - 1) || SUBSTR(CUSTOMER_NAME, TYPO_POS + 1)
         ELSE CUSTOMER_NAME
    END                                                                         AS ACCOUNT_NAME,
    CASE WHEN COPY_NO = 1 THEN NULL
         WHEN H_EMAIL < 2 THEN NULL                                             -- 20% missing
         WHEN H_EMAIL = 2 THEN UPPER(EMAIL)
         WHEN H_EMAIL = 3 THEN REGEXP_REPLACE(EMAIL, '@', '+crm@', 1, 1)       -- plus-tag
         ELSE EMAIL
    END                                                                         AS EMAIL_ADDRESS,
    CASE WHEN PHONE_DIGITS = '' THEN NULL
         WHEN H_PHONE = 0 THEN NULL                                             -- 10% missing
         WHEN H_PHONE IN (1, 2) THEN '+' || DIAL_CODE || ' ' || RIGHT(PHONE_DIGITS, 10)
         WHEN H_PHONE = 3 THEN '0' || RIGHT(PHONE_DIGITS, 10)
         WHEN H_PHONE = 4 THEN SUBSTR(RIGHT(PHONE_DIGITS, 10), 1, 3) || '-' ||
                               SUBSTR(RIGHT(PHONE_DIGITS, 10), 4, 3) || '-' ||
                               SUBSTR(RIGHT(PHONE_DIGITS, 10), 7)
         WHEN H_PHONE = 5 THEN '(' || SUBSTR(RIGHT(PHONE_DIGITS, 10), 1, 3) || ') ' ||
                               SUBSTR(RIGHT(PHONE_DIGITS, 10), 4)
         ELSE PHONE
    END                                                                         AS PHONE_NUMBER,
    CASE WHEN H_PAN < 3 THEN NULL                                               -- 30% missing
         WHEN H_PAN = 3 THEN LOWER(SUBSTR(PAN_NUMBER, 1, 5) || ' ' || SUBSTR(PAN_NUMBER, 6))
         ELSE PAN_NUMBER
    END                                                                         AS PAN,
    IFF(H_CITY = 0, UPPER(CITY), CITY)                                          AS CITY,
    COUNTRY,
    SEGMENT                                                                     AS CRM_SEGMENT,
    'Rep ' || TO_VARCHAR(MOD(ABS(HASH(CUSTOMER_ID, 'rep')), 40) + 1)            AS ACCOUNT_OWNER,
    DATEADD('day', 30 + MOD(ABS(HASH(CUSTOMER_ID, COPY_NO, 'upd')), 700), CREATED_DATE)::TIMESTAMP_NTZ
                                                                                AS LAST_MODIFIED_AT
FROM variants;

-- -----------------------------------------------------------------------------
-- 2. E-commerce source: ~55% of ERP customers + 400 guest shoppers not in ERP
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE C360_ECOM.ECOM_CUSTOMERS AS
WITH base AS (
    SELECT c.*,
           COALESCE(d.DIAL_CODE, '91')                                   AS DIAL_CODE,
           REGEXP_REPLACE(COALESCE(c.PHONE, ''), '[^0-9]', '')           AS PHONE_DIGITS,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'ec_in')),   100)                 AS H_IN,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'ec_name')),  10)                 AS H_NAME,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'ec_email')), 10)                 AS H_EMAIL,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'ec_phone')), 10)                 AS H_PHONE,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'ec_pan')),   10)                 AS H_PAN
    FROM ACCEL_DB.DEMO.CUSTOMERS c
    LEFT JOIN C360.COUNTRY_DIAL_CODES d ON d.COUNTRY = c.COUNTRY
),
known AS (
    SELECT
        'EC-' || TO_VARCHAR(CUSTOMER_ID)                                        AS ECOM_USER_ID,
        CASE WHEN H_NAME < 4 THEN LOWER(CUSTOMER_NAME)
             WHEN H_NAME = 4 THEN REPLACE(REPLACE(CUSTOMER_NAME, 'Private Limited', 'Pvt Ltd'), 'Limited', 'Ltd')
             WHEN H_NAME = 5 THEN INITCAP(CUSTOMER_NAME)
             ELSE CUSTOMER_NAME
        END                                                                     AS DISPLAY_NAME,
        CASE WHEN H_EMAIL = 0 THEN 'buyer' || TO_VARCHAR(CUSTOMER_ID) || '@shopmail.example'  -- different login email
             ELSE LOWER(EMAIL)
        END                                                                     AS LOGIN_EMAIL,
        CASE WHEN PHONE_DIGITS = '' OR H_PHONE < 2 THEN NULL
             ELSE '+' || DIAL_CODE || RIGHT(PHONE_DIGITS, 10)
        END                                                                     AS MOBILE,
        IFF(H_PAN < 2, PAN_NUMBER, NULL)                                        AS PAN_FOR_INVOICE,
        CITY                                                                    AS SHIPPING_CITY,
        COUNTRY                                                                 AS SHIPPING_COUNTRY,
        1 + MOD(ABS(HASH(CUSTOMER_ID, 'ec_orders')), 40)                        AS LIFETIME_ORDERS,
        ROUND(500 + MOD(ABS(HASH(CUSTOMER_ID, 'ec_spend')), 250000), 2)         AS LIFETIME_SPEND_INR,
        DATEADD('day', MOD(ABS(HASH(CUSTOMER_ID, 'ec_last')), 900), '2024-01-01'::DATE)
                                                                                AS LAST_ORDER_DATE,
        DATEADD('day', 60 + MOD(ABS(HASH(CUSTOMER_ID, 'ec_upd')), 800), CREATED_DATE)::TIMESTAMP_NTZ
                                                                                AS UPDATED_AT
    FROM base
    WHERE H_IN < 55
),
guests AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS N
    FROM TABLE(GENERATOR(ROWCOUNT => 400))
)
SELECT * FROM known
UNION ALL
SELECT
    'EC-G' || TO_VARCHAR(N),
    'guest shopper ' || TO_VARCHAR(N),
    'shopper' || TO_VARCHAR(N) || '@shopmail.example',
    '+91' || TO_VARCHAR(7000000000 + N * 7919),
    NULL,
    DECODE(MOD(N, 5), 0, 'Mumbai', 1, 'Bengaluru', 2, 'Delhi', 3, 'Chennai', 'Pune'),
    'India',
    1 + MOD(N, 6),
    ROUND(300 + MOD(N * 977, 30000), 2),
    DATEADD('day', MOD(N * 13, 900), '2024-01-01'::DATE),
    DATEADD('day', MOD(N * 17, 900), '2024-01-01'::DATE)::TIMESTAMP_NTZ
FROM guests;

-- Quick profile of what was produced
SELECT 'ERP  DEMO.CUSTOMERS'          AS SOURCE, COUNT(*) AS ROWS_ FROM ACCEL_DB.DEMO.CUSTOMERS
UNION ALL SELECT 'CRM  C360_CRM.CRM_ACCOUNTS',  COUNT(*) FROM C360_CRM.CRM_ACCOUNTS
UNION ALL SELECT 'ECOM C360_ECOM.ECOM_CUSTOMERS', COUNT(*) FROM C360_ECOM.ECOM_CUSTOMERS;
