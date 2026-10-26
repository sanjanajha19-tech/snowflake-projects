/*=============================================================================
  ACCELERATOR 18 - DPDP Privacy Kit
  File 03 : Processing purposes and consent register (DPDP s.5-6 notice & consent)
  Creates : PROCESSING_PURPOSES, CONSENT_REGISTER (synthetic history),
            V_CONSENT_CURRENT, SP_RECORD_CONSENT(...)
  Run as  : ACCEL_ADMIN
  Rerun   : recreates the synthetic consent register.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS DPDP;
USE SCHEMA DPDP;

------------------------------------------------------------------------------
-- 1. Purposes. LAWFUL_BASIS:
--    CONSENT        -> processing allowed only with a current GRANTED consent
--    LEGITIMATE_USE -> DPDP s.7 legitimate uses (e.g. fulfilling a purchase the
--                      principal initiated, legal obligations); no consent check
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE PROCESSING_PURPOSES (
    PURPOSE_CODE       VARCHAR,
    PURPOSE_NAME       VARCHAR,
    DESCRIPTION        VARCHAR,
    LAWFUL_BASIS       VARCHAR,
    DATA_CATEGORIES    ARRAY,
    RETENTION_DAYS     NUMBER,
    CONSENT_VALID_DAYS NUMBER
);

INSERT INTO PROCESSING_PURPOSES
SELECT $1, $2, $3, $4, SPLIT($5, ','), $6, $7
FROM (VALUES
  ('ORDER_FULFILMENT',    'Order fulfilment',            'Process, ship and invoice orders the customer placed',              'LEGITIMATE_USE', 'NAME,EMAIL,PHONE,CITY',  2920, NULL),
  ('CUSTOMER_SUPPORT',    'Customer support',            'Respond to tickets raised by the customer',                         'LEGITIMATE_USE', 'NAME,EMAIL,PHONE',       540,  NULL),
  ('MARKETING',           'Direct marketing',            'Send offers by e-mail / SMS / WhatsApp',                             'CONSENT',        'NAME,EMAIL,PHONE',       730,  365),
  ('ANALYTICS',           'Personalisation & analytics', 'Use purchase history for recommendations and customer analytics',   'CONSENT',        'PURCHASES,CITY,SEGMENT', 1095, 730),
  ('THIRD_PARTY_SHARING', 'Sharing with partners',       'Share contact details with co-marketing partners',                  'CONSENT',        'NAME,EMAIL',             365,  365));
-- EDIT ME: replace with the client's purpose register / notice

------------------------------------------------------------------------------
-- 2. Consent register: one row per consent event (append-only history).
--    IS_CURRENT marks the latest event per principal + purpose.
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE CONSENT_REGISTER (
    CONSENT_ID          VARCHAR,
    DATA_PRINCIPAL_ID   NUMBER,          -- CUSTOMER_ID
    PRINCIPAL_TYPE      VARCHAR,         -- CUSTOMER | EMPLOYEE
    PURPOSE_CODE        VARCHAR,
    CONSENT_STATUS      VARCHAR,         -- GRANTED | WITHDRAWN | DENIED
    NOTICE_VERSION      VARCHAR,
    NOTICE_LANGUAGE     VARCHAR,         -- DPDP: notice in English or an Eighth Schedule language
    CAPTURE_CHANNEL     VARCHAR,         -- Web | Mobile App | Store | Call Centre | Consent Manager
    CONSENT_MANAGER_ID  VARCHAR,         -- registered Consent Manager, if used
    EVENT_TS            TIMESTAMP_NTZ,
    EXPIRES_AT          TIMESTAMP_NTZ,
    IS_CURRENT          BOOLEAN,
    EVIDENCE_REF        VARCHAR          -- pointer to stored notice / click-stream evidence
) COMMENT = 'DPDP kit: consent register (synthetic)';

-- Synthetic history: initial decision for every customer x consent purpose,
-- then a withdrawal for ~12% of granted consents.
INSERT INTO CONSENT_REGISTER
WITH base AS (
    SELECT c.CUSTOMER_ID, c.CREATED_DATE, p.PURPOSE_CODE, p.CONSENT_VALID_DAYS,
           MOD(ABS(HASH(c.CUSTOMER_ID, p.PURPOSE_CODE)), 100) AS R,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'lang')), 100)          AS RL,
           MOD(ABS(HASH(c.CUSTOMER_ID, 'chan')), 5)            AS RC
    FROM ACCEL_DB.DPDP.CUSTOMERS c
    CROSS JOIN ACCEL_DB.DPDP.PROCESSING_PURPOSES p
    WHERE p.LAWFUL_BASIS = 'CONSENT'
),
initial AS (
    SELECT CUSTOMER_ID, PURPOSE_CODE, CONSENT_VALID_DAYS, R, RL, RC,
           CASE PURPOSE_CODE
               WHEN 'MARKETING'           THEN IFF(R < 62, 'GRANTED', 'DENIED')
               WHEN 'ANALYTICS'           THEN IFF(R < 78, 'GRANTED', 'DENIED')
               ELSE                            IFF(R < 35, 'GRANTED', 'DENIED')
           END AS STATUS,
           DATEADD(MINUTE, MOD(ABS(HASH(CUSTOMER_ID, PURPOSE_CODE, 't')), 1440),
                   GREATEST(COALESCE(CREATED_DATE, '2024-01-01'::DATE), '2024-01-01'::DATE)::TIMESTAMP_NTZ) AS TS
    FROM base
),
events AS (
    SELECT CUSTOMER_ID, PURPOSE_CODE, CONSENT_VALID_DAYS, RL, RC, STATUS, TS, 1 AS SEQ
    FROM initial
    UNION ALL
    SELECT CUSTOMER_ID, PURPOSE_CODE, CONSENT_VALID_DAYS, RL, RC, 'WITHDRAWN',
           DATEADD(DAY, 30 + MOD(ABS(HASH(CUSTOMER_ID, PURPOSE_CODE, 'w')), 600), TS), 2
    FROM initial
    WHERE STATUS = 'GRANTED' AND MOD(ABS(HASH(CUSTOMER_ID, PURPOSE_CODE, 'wd')), 100) < 12
)
SELECT
    'CN-' || CUSTOMER_ID || '-' || PURPOSE_CODE || '-' || SEQ,
    CUSTOMER_ID,
    'CUSTOMER',
    PURPOSE_CODE,
    STATUS,
    IFF(TS < '2025-11-14'::TIMESTAMP_NTZ, 'NOTICE-v1.0', 'NOTICE-v2.0-DPDP'),
    CASE WHEN RL < 70 THEN 'English' WHEN RL < 85 THEN 'Hindi' WHEN RL < 92 THEN 'Tamil' ELSE 'Marathi' END,
    DECODE(RC, 0, 'Web', 1, 'Mobile App', 2, 'Store', 3, 'Call Centre', 'Consent Manager'),
    IFF(RC = 4, 'CM-' || LPAD(TO_VARCHAR(MOD(CUSTOMER_ID, 3) + 1), 3, '0'), NULL),
    TS,
    IFF(STATUS = 'GRANTED' AND CONSENT_VALID_DAYS IS NOT NULL, DATEADD(DAY, CONSENT_VALID_DAYS, TS), NULL),
    SEQ = MAX(SEQ) OVER (PARTITION BY CUSTOMER_ID, PURPOSE_CODE),
    'evidence://consent/' || CUSTOMER_ID || '/' || PURPOSE_CODE || '/' || SEQ
FROM events;

------------------------------------------------------------------------------
-- 3. Current consent position per principal and purpose
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_CONSENT_CURRENT AS
SELECT DATA_PRINCIPAL_ID, PURPOSE_CODE, CONSENT_STATUS, EVENT_TS AS STATUS_SINCE, EXPIRES_AT,
       CASE
           WHEN CONSENT_STATUS = 'GRANTED' AND (EXPIRES_AT IS NULL OR EXPIRES_AT > CURRENT_TIMESTAMP()) THEN 'ACTIVE'
           WHEN CONSENT_STATUS = 'GRANTED' THEN 'EXPIRED'
           ELSE CONSENT_STATUS
       END AS EFFECTIVE_STATUS,
       NOTICE_VERSION, NOTICE_LANGUAGE, CAPTURE_CHANNEL, CONSENT_MANAGER_ID
FROM ACCEL_DB.DPDP.CONSENT_REGISTER
WHERE IS_CURRENT;

------------------------------------------------------------------------------
-- 4. Record a new consent event (grant / withdraw) - used by apps & consent managers
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_RECORD_CONSENT(
    P_PRINCIPAL_ID NUMBER, P_PURPOSE_CODE VARCHAR, P_STATUS VARCHAR,
    P_CHANNEL VARCHAR, P_NOTICE_VERSION VARCHAR, P_LANGUAGE VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    valid_days NUMBER;
    new_id VARCHAR;
BEGIN
    IF (P_STATUS NOT IN ('GRANTED', 'WITHDRAWN', 'DENIED')) THEN
        RETURN 'Rejected: status must be GRANTED, WITHDRAWN or DENIED';
    END IF;
    SELECT MAX(CONSENT_VALID_DAYS) INTO :valid_days
    FROM ACCEL_DB.DPDP.PROCESSING_PURPOSES WHERE PURPOSE_CODE = :P_PURPOSE_CODE;

    new_id := 'CN-' || P_PRINCIPAL_ID || '-' || P_PURPOSE_CODE || '-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3');

    UPDATE ACCEL_DB.DPDP.CONSENT_REGISTER
       SET IS_CURRENT = FALSE
     WHERE DATA_PRINCIPAL_ID = :P_PRINCIPAL_ID AND PURPOSE_CODE = :P_PURPOSE_CODE AND IS_CURRENT;

    INSERT INTO ACCEL_DB.DPDP.CONSENT_REGISTER
    SELECT :new_id, :P_PRINCIPAL_ID, 'CUSTOMER', :P_PURPOSE_CODE, :P_STATUS, :P_NOTICE_VERSION, :P_LANGUAGE,
           :P_CHANNEL, NULL, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
           IFF(:P_STATUS = 'GRANTED' AND :valid_days IS NOT NULL,
               DATEADD(DAY, :valid_days, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ), NULL),
           TRUE, 'evidence://consent/' || :new_id;

    INSERT INTO ACCEL_DB.DPDP.DPDP_AUDIT_LOG (EVENT_TYPE, DATA_PRINCIPAL_ID, REQUEST_REF, ACTOR_USER, DETAILS)
    SELECT 'CONSENT_CHANGE', :P_PRINCIPAL_ID, :new_id, CURRENT_USER(),
           OBJECT_CONSTRUCT('purpose', :P_PURPOSE_CODE, 'status', :P_STATUS, 'channel', :P_CHANNEL);
    RETURN 'Recorded ' || new_id;
END;
$$;

-- Demo: customer 42 withdraws marketing consent
CALL SP_RECORD_CONSENT(42, 'MARKETING', 'WITHDRAWN', 'Mobile App', 'NOTICE-v2.0-DPDP', 'English');

SELECT PURPOSE_CODE, EFFECTIVE_STATUS, COUNT(*) AS PRINCIPALS
FROM V_CONSENT_CURRENT
GROUP BY 1, 2
ORDER BY 1, 2;
