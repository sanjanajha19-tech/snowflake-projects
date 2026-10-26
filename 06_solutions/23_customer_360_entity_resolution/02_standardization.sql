/* =============================================================================
   Asset 23 - Customer 360 & Entity Resolution
   File  02_standardization.sql
   Purpose
     * SQL UDFs that normalise names, legal forms, phones, emails and PANs.
     * C360.CUSTOMER_RECORDS - one standardised row per source record
       (ERP + CRM + ECOM) with match keys. This is the input to matching.
   Run as  ACCEL_ADMIN after 01. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS C360;
USE SCHEMA C360;

-- -----------------------------------------------------------------------------
-- 1. Standardisation UDFs
-- -----------------------------------------------------------------------------

-- Upper-case, '&' -> AND, strip punctuation, collapse spaces, unify legal forms.
CREATE OR REPLACE FUNCTION C360.NORMALIZE_NAME(NAME VARCHAR)
RETURNS VARCHAR
COMMENT = 'Standardised organisation name with unified legal-form tokens (PVT LTD, LTD, INC, CORP, CO, LLP)'
AS
$$
    NULLIF(TRIM(
      REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
        ' ' || REGEXP_REPLACE(
                 REGEXP_REPLACE(REPLACE(UPPER(COALESCE(NAME, '')), '&', ' AND '), '[^A-Z0-9 ]', ' '),
                 ' +', ' ') || ' ',
        ' (PRIVATE|PVT) (LIMITED|LTD) ', ' PVT LTD '),
        ' LIMITED ', ' LTD '),
        ' INCORPORATED ', ' INC '),
        ' CORPORATION ', ' CORP '),
        ' COMPANY ', ' CO '),
        ' +', ' ')
    ), '')
$$;

-- Name with legal-form / filler tokens removed - used for fuzzy comparison.
CREATE OR REPLACE FUNCTION C360.NAME_CORE(NAME VARCHAR)
RETURNS VARCHAR
COMMENT = 'Normalised name without legal-form suffixes and filler words'
AS
$$
    NULLIF(TRIM(REGEXP_REPLACE(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          ' ' || ACCEL_DB.C360.NORMALIZE_NAME(NAME) || ' ',
          ' (PVT LTD|LTD|LLP|LLC|INC|CORP|CO|GMBH|AG|PLC|PTE|KK|THE|AND|M S) ', ' '),
        ' (PVT LTD|LTD|LLP|LLC|INC|CORP|CO|GMBH|AG|PLC|PTE|KK|THE|AND|M S) ', ' '),
      ' +', ' ')), '')
$$;

-- Digits only, leading zeros dropped, last 10 digits kept (strips country codes
-- for 10-digit national numbers). PHONE_MATCH_KEY uses the last 8 digits so that
-- 8-digit numbers (e.g. Singapore) still match when a country code is prefixed.
CREATE OR REPLACE FUNCTION C360.NORMALIZE_PHONE(PHONE VARCHAR)
RETURNS VARCHAR
AS
$$
    IFF(LENGTH(LTRIM(REGEXP_REPLACE(COALESCE(PHONE, ''), '[^0-9]', ''), '0')) < 7,
        NULL,
        RIGHT(LTRIM(REGEXP_REPLACE(COALESCE(PHONE, ''), '[^0-9]', ''), '0'), 10))
$$;

CREATE OR REPLACE FUNCTION C360.PHONE_MATCH_KEY(PHONE VARCHAR)
RETURNS VARCHAR
AS
$$
    IFF(ACCEL_DB.C360.NORMALIZE_PHONE(PHONE) IS NULL OR LENGTH(ACCEL_DB.C360.NORMALIZE_PHONE(PHONE)) < 8,
        NULL, RIGHT(ACCEL_DB.C360.NORMALIZE_PHONE(PHONE), 8))
$$;

-- Lower-case, trimmed, '+tag' removed from local part, NULL when not email-shaped.
CREATE OR REPLACE FUNCTION C360.NORMALIZE_EMAIL(EMAIL VARCHAR)
RETURNS VARCHAR
AS
$$
    IFF(REGEXP_LIKE(LOWER(TRIM(COALESCE(EMAIL, ''))), '[a-z0-9._%+-]+@[a-z0-9.-]+[.][a-z]{2,}'),
        REGEXP_REPLACE(SPLIT_PART(LOWER(TRIM(EMAIL)), '@', 1), '[+].*$', '')
          || '@' || SPLIT_PART(LOWER(TRIM(EMAIL)), '@', 2),
        NULL)
$$;

-- Indian PAN: 5 letters, 4 digits, 1 letter. Anything else -> NULL.
CREATE OR REPLACE FUNCTION C360.NORMALIZE_PAN(PAN VARCHAR)
RETURNS VARCHAR
AS
$$
    IFF(REGEXP_LIKE(UPPER(REGEXP_REPLACE(COALESCE(PAN, ''), '[^A-Za-z0-9]', '')), '[A-Z]{5}[0-9]{4}[A-Z]'),
        UPPER(REGEXP_REPLACE(PAN, '[^A-Za-z0-9]', '')),
        NULL)
$$;

CREATE OR REPLACE FUNCTION C360.NORMALIZE_CITY(CITY VARCHAR)
RETURNS VARCHAR
AS
$$
    CASE UPPER(TRIM(REGEXP_REPLACE(COALESCE(CITY, ''), ' +', ' ')))
        WHEN 'BANGALORE' THEN 'BENGALURU'
        WHEN 'BOMBAY'    THEN 'MUMBAI'
        WHEN 'MADRAS'    THEN 'CHENNAI'
        WHEN 'CALCUTTA'  THEN 'KOLKATA'
        WHEN 'GURGAON'   THEN 'GURUGRAM'
        WHEN 'NEW DELHI' THEN 'DELHI'
        WHEN ''          THEN NULL
        ELSE UPPER(TRIM(REGEXP_REPLACE(CITY, ' +', ' ')))
    END
$$;

-- Unit tests for the UDFs (all rows should show PASS)
SELECT TEST, IFF(EQUAL_NULL(ACTUAL, EXPECTED), 'PASS', 'FAIL') AS RESULT, ACTUAL, EXPECTED FROM (
    SELECT 'name pvt ltd'   AS TEST, C360.NORMALIZE_NAME('Sharma Traders Private Limited') AS ACTUAL, 'SHARMA TRADERS PVT LTD' AS EXPECTED
    UNION ALL SELECT 'name pvt. ltd.', C360.NORMALIZE_NAME('Sharma Traders Pvt. Ltd.'),  'SHARMA TRADERS PVT LTD'
    UNION ALL SELECT 'name &',         C360.NORMALIZE_NAME('Rao & Sons Limited'),        'RAO AND SONS LTD'
    UNION ALL SELECT 'core',           C360.NAME_CORE('The Rao & Sons Pvt Ltd'),        'RAO SONS'
    UNION ALL SELECT 'phone +91',      C360.NORMALIZE_PHONE('+91 98450-12345'),         '9845012345'
    UNION ALL SELECT 'phone 0 prefix', C360.NORMALIZE_PHONE('09845012345'),             '9845012345'
    UNION ALL SELECT 'phone key sg',   C360.PHONE_MATCH_KEY('+65 6123 4567'),           '61234567'
    UNION ALL SELECT 'email tag',      C360.NORMALIZE_EMAIL(' Priya.N+crm@Example.COM '), 'priya.n@example.com'
    UNION ALL SELECT 'email bad',      C360.NORMALIZE_EMAIL('not-an-email'),            NULL
    UNION ALL SELECT 'pan spaced',     C360.NORMALIZE_PAN('abcde 1234f'),               'ABCDE1234F'
    UNION ALL SELECT 'pan bad',        C360.NORMALIZE_PAN('12345ABCDE'),                NULL
    UNION ALL SELECT 'city alias',     C360.NORMALIZE_CITY(' bangalore '),              'BENGALURU'
);

-- -----------------------------------------------------------------------------
-- 2. Unified, standardised record table
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE C360.CUSTOMER_RECORDS AS
WITH unioned AS (
    SELECT 'ERP' AS SOURCE_SYSTEM, 1 AS SOURCE_PRIORITY, TO_VARCHAR(CUSTOMER_ID) AS SOURCE_ID,
           CUSTOMER_NAME AS RAW_NAME, EMAIL AS RAW_EMAIL, PHONE AS RAW_PHONE, PAN_NUMBER AS RAW_PAN,
           CITY AS RAW_CITY, COUNTRY AS RAW_COUNTRY,
           CUSTOMER_ID AS ERP_CUSTOMER_ID, SEGMENT, INDUSTRY, REGION, CREDIT_LIMIT,
           NULL::NUMBER AS ECOM_LIFETIME_ORDERS, NULL::NUMBER(14,2) AS ECOM_LIFETIME_SPEND_INR,
           NULL::DATE AS ECOM_LAST_ORDER_DATE, NULL::VARCHAR AS ACCOUNT_OWNER,
           CREATED_DATE::TIMESTAMP_NTZ AS LAST_UPDATED_AT
    FROM ACCEL_DB.DEMO.CUSTOMERS
    UNION ALL
    SELECT 'CRM', 2, CRM_ACCOUNT_ID, ACCOUNT_NAME, EMAIL_ADDRESS, PHONE_NUMBER, PAN, CITY, COUNTRY,
           NULL, CRM_SEGMENT, NULL, NULL, NULL, NULL, NULL, NULL, ACCOUNT_OWNER, LAST_MODIFIED_AT
    FROM ACCEL_DB.C360_CRM.CRM_ACCOUNTS
    UNION ALL
    SELECT 'ECOM', 3, ECOM_USER_ID, DISPLAY_NAME, LOGIN_EMAIL, MOBILE, PAN_FOR_INVOICE, SHIPPING_CITY,
           SHIPPING_COUNTRY, NULL, NULL, NULL, NULL, NULL, LIFETIME_ORDERS, LIFETIME_SPEND_INR,
           LAST_ORDER_DATE, NULL, UPDATED_AT
    FROM ACCEL_DB.C360_ECOM.ECOM_CUSTOMERS
)
SELECT
    SOURCE_SYSTEM || ':' || SOURCE_ID         AS RECORD_KEY,
    u.*,
    C360.NORMALIZE_NAME(RAW_NAME)             AS NAME_STD,
    C360.NAME_CORE(RAW_NAME)                  AS NAME_CORE,
    C360.NORMALIZE_EMAIL(RAW_EMAIL)           AS EMAIL_STD,
    C360.NORMALIZE_PHONE(RAW_PHONE)           AS PHONE_STD,
    C360.PHONE_MATCH_KEY(RAW_PHONE)           AS PHONE_KEY,
    C360.NORMALIZE_PAN(RAW_PAN)               AS PAN_STD,
    C360.NORMALIZE_CITY(RAW_CITY)             AS CITY_STD,
    UPPER(TRIM(RAW_COUNTRY))                  AS COUNTRY_STD,
    -- blocking keys
    SOUNDEX(C360.NAME_CORE(RAW_NAME)) || '|' || UPPER(TRIM(RAW_COUNTRY))                       AS BK_SOUNDEX_COUNTRY,
    LEFT(REPLACE(C360.NAME_CORE(RAW_NAME), ' ', ''), 4) || '|' || C360.NORMALIZE_CITY(RAW_CITY) AS BK_PREFIX_CITY
FROM unioned u;

SELECT SOURCE_SYSTEM, COUNT(*) AS RECORDS,
       COUNT(EMAIL_STD) AS WITH_EMAIL, COUNT(PHONE_KEY) AS WITH_PHONE, COUNT(PAN_STD) AS WITH_PAN
FROM C360.CUSTOMER_RECORDS GROUP BY 1 ORDER BY 1;
