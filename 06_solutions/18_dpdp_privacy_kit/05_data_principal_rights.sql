/*=============================================================================
  ACCELERATOR 18 - DPDP Privacy Kit
  File 05 : Data principal rights workflow (DPDP s.11-14)
            - Right to access information   -> SP_DSR_ACCESS
            - Right to correction           -> SP_DSR_CORRECTION
            - Right to erasure              -> SP_DSR_ERASURE (pseudonymise, logged)
            - Request tracking with SLA     -> DSR_REQUESTS
  Creates : DSR_REQUESTS, ERASURE_LOG, SP_DSR_ACCESS, SP_DSR_CORRECTION,
            SP_DSR_ERASURE, V_DSR_SLA
  Run as  : ACCEL_ADMIN (privacy office)
  Rerun   : safe (request history is kept; demo requests use fixed refs).
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS DPDP;
USE SCHEMA DPDP;

------------------------------------------------------------------------------
-- 1. Request register
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DSR_REQUESTS (
    REQUEST_REF        VARCHAR,
    REQUEST_TYPE       VARCHAR,       -- ACCESS | CORRECTION | ERASURE | GRIEVANCE | NOMINATION
    DATA_PRINCIPAL_ID  NUMBER,
    RECEIVED_AT        TIMESTAMP_NTZ,
    DUE_BY             TIMESTAMP_NTZ,
    STATUS             VARCHAR,       -- RECEIVED | IN_PROGRESS | COMPLETED | REJECTED
    COMPLETED_AT       TIMESTAMP_NTZ,
    CHANNEL            VARCHAR,
    HANDLED_BY         VARCHAR,
    OUTCOME            VARIANT
) COMMENT = 'DPDP kit: data principal requests (DSR) register';

CREATE TABLE IF NOT EXISTS ERASURE_LOG (
    REQUEST_REF        VARCHAR,
    DATA_PRINCIPAL_ID  NUMBER,
    PSEUDONYM          VARCHAR,
    EXECUTED_AT        TIMESTAMP_NTZ,
    EXECUTED_BY        VARCHAR,
    ROWS_AFFECTED      VARIANT,
    RETAINED_RECORDS   VARCHAR       -- what was kept and why (legal obligation)
) COMMENT = 'DPDP kit: evidence of erasure / pseudonymisation';

-- Synthetic historic requests for the dashboard (fixed refs -> idempotent)
MERGE INTO DSR_REQUESTS t
USING (
    SELECT 'DSR-HIST-' || LPAD(TO_VARCHAR(SEQ4() + 1), 4, '0') AS REQUEST_REF,
           DECODE(MOD(SEQ4(), 5), 0, 'ACCESS', 1, 'ERASURE', 2, 'CORRECTION', 3, 'ACCESS', 'GRIEVANCE') AS REQUEST_TYPE,
           1000 + SEQ4() * 7 AS DATA_PRINCIPAL_ID,
           DATEADD(DAY, -MOD(SEQ4() * 13, 180), '2026-09-30 10:00:00'::TIMESTAMP_NTZ) AS RECEIVED_AT,
           MOD(SEQ4(), 9) AS R
    FROM TABLE(GENERATOR(ROWCOUNT => 60))
) s
ON t.REQUEST_REF = s.REQUEST_REF
WHEN NOT MATCHED THEN INSERT
    (REQUEST_REF, REQUEST_TYPE, DATA_PRINCIPAL_ID, RECEIVED_AT, DUE_BY, STATUS, COMPLETED_AT, CHANNEL, HANDLED_BY, OUTCOME)
VALUES
    (s.REQUEST_REF, s.REQUEST_TYPE, s.DATA_PRINCIPAL_ID, s.RECEIVED_AT, DATEADD(DAY, 30, s.RECEIVED_AT),
     IFF(s.R < 7, 'COMPLETED', IFF(s.R = 7, 'IN_PROGRESS', 'RECEIVED')),
     IFF(s.R < 7, DATEADD(DAY, 3 + s.R * 5, s.RECEIVED_AT), NULL),
     IFF(s.R < 4, 'Web form', 'E-mail'), 'privacy.office', NULL);

------------------------------------------------------------------------------
-- 2. Right to access: everything held about a principal, as one JSON document
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DSR_ACCESS(P_CUSTOMER_ID NUMBER, P_REQUEST_REF VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    result VARIANT;
BEGIN
    SELECT OBJECT_CONSTRUCT(
        'request_ref',       :P_REQUEST_REF,
        'generated_at',      TO_VARCHAR(CURRENT_TIMESTAMP()),
        'data_principal_id', :P_CUSTOMER_ID,
        'profile', (SELECT OBJECT_CONSTRUCT(*) FROM ACCEL_DB.DPDP.CUSTOMERS WHERE CUSTOMER_ID = :P_CUSTOMER_ID),
        'orders', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('order_id', ORDER_ID, 'order_date', ORDER_DATE,
                                                       'channel', CHANNEL, 'status', STATUS,
                                                       'currency', CURRENCY, 'order_total', ORDER_TOTAL))
                   FROM ACCEL_DB.DPDP.ORDERS WHERE CUSTOMER_ID = :P_CUSTOMER_ID),
        'support_tickets', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('ticket_id', TICKET_ID, 'created_at', CREATED_AT,
                                                                'channel', CHANNEL, 'subject', SUBJECT, 'body', BODY,
                                                                'status', STATUS))
                            FROM ACCEL_DB.DPDP.SUPPORT_TICKETS WHERE CUSTOMER_ID = :P_CUSTOMER_ID),
        'consents', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('purpose', PURPOSE_CODE, 'status', CONSENT_STATUS,
                                                         'event_ts', EVENT_TS, 'expires_at', EXPIRES_AT,
                                                         'notice_version', NOTICE_VERSION, 'channel', CAPTURE_CHANNEL))
                     FROM ACCEL_DB.DPDP.CONSENT_REGISTER WHERE DATA_PRINCIPAL_ID = :P_CUSTOMER_ID),
        'processing_purposes', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('purpose', PURPOSE_NAME, 'basis', LAWFUL_BASIS,
                                                                    'retention_days', RETENTION_DAYS))
                                FROM ACCEL_DB.DPDP.PROCESSING_PURPOSES),
        'shared_with', ARRAY_CONSTRUCT('Logistics partner (order fulfilment)', 'Payment processor (order fulfilment)'),  -- EDIT ME: processors / recipients
        'grievance_contact', (SELECT MAX(CONFIG_VALUE) FROM ACCEL_DB.DPDP.KIT_CONFIG WHERE CONFIG_KEY = 'DPO_CONTACT')
    ) INTO :result;

    MERGE INTO ACCEL_DB.DPDP.DSR_REQUESTS t
    USING (SELECT :P_REQUEST_REF AS REF) s ON t.REQUEST_REF = s.REF
    WHEN MATCHED THEN UPDATE SET STATUS = 'COMPLETED', COMPLETED_AT = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
                                 HANDLED_BY = CURRENT_USER()
    WHEN NOT MATCHED THEN INSERT (REQUEST_REF, REQUEST_TYPE, DATA_PRINCIPAL_ID, RECEIVED_AT, DUE_BY, STATUS,
                                  COMPLETED_AT, CHANNEL, HANDLED_BY, OUTCOME)
        VALUES (:P_REQUEST_REF, 'ACCESS', :P_CUSTOMER_ID, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
                DATEADD(DAY, 30, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ), 'COMPLETED',
                CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'API', CURRENT_USER(), NULL);

    INSERT INTO ACCEL_DB.DPDP.DPDP_AUDIT_LOG (EVENT_TYPE, DATA_PRINCIPAL_ID, REQUEST_REF, ACTOR_USER, DETAILS)
    SELECT 'DSR_ACCESS', :P_CUSTOMER_ID, :P_REQUEST_REF, CURRENT_USER(),
           OBJECT_CONSTRUCT('orders_returned',  COALESCE(ARRAY_SIZE(GET(:result, 'orders')), 0),
                            'tickets_returned', COALESCE(ARRAY_SIZE(GET(:result, 'support_tickets')), 0));
    RETURN result;
END;
$$;

------------------------------------------------------------------------------
-- 3. Right to correction (whitelisted fields only)
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DSR_CORRECTION(P_CUSTOMER_ID NUMBER, P_FIELD VARCHAR, P_NEW_VALUE VARCHAR, P_REQUEST_REF VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    old_value VARCHAR;
    fld VARCHAR;
BEGIN
    fld := UPPER(P_FIELD);
    IF (fld = 'EMAIL') THEN
        SELECT MAX(EMAIL) INTO :old_value FROM ACCEL_DB.DPDP.CUSTOMERS WHERE CUSTOMER_ID = :P_CUSTOMER_ID;
        UPDATE ACCEL_DB.DPDP.CUSTOMERS SET EMAIL = :P_NEW_VALUE WHERE CUSTOMER_ID = :P_CUSTOMER_ID;
    ELSEIF (fld = 'PHONE') THEN
        SELECT MAX(PHONE) INTO :old_value FROM ACCEL_DB.DPDP.CUSTOMERS WHERE CUSTOMER_ID = :P_CUSTOMER_ID;
        UPDATE ACCEL_DB.DPDP.CUSTOMERS SET PHONE = :P_NEW_VALUE WHERE CUSTOMER_ID = :P_CUSTOMER_ID;
    ELSEIF (fld = 'CUSTOMER_NAME') THEN
        SELECT MAX(CUSTOMER_NAME) INTO :old_value FROM ACCEL_DB.DPDP.CUSTOMERS WHERE CUSTOMER_ID = :P_CUSTOMER_ID;
        UPDATE ACCEL_DB.DPDP.CUSTOMERS SET CUSTOMER_NAME = :P_NEW_VALUE WHERE CUSTOMER_ID = :P_CUSTOMER_ID;
    ELSEIF (fld = 'CITY') THEN
        SELECT MAX(CITY) INTO :old_value FROM ACCEL_DB.DPDP.CUSTOMERS WHERE CUSTOMER_ID = :P_CUSTOMER_ID;
        UPDATE ACCEL_DB.DPDP.CUSTOMERS SET CITY = :P_NEW_VALUE WHERE CUSTOMER_ID = :P_CUSTOMER_ID;
    ELSE
        RETURN 'Rejected: field ' || fld || ' is not correctable via this procedure';
    END IF;

    MERGE INTO ACCEL_DB.DPDP.DSR_REQUESTS t
    USING (SELECT :P_REQUEST_REF AS REF) s ON t.REQUEST_REF = s.REF
    WHEN MATCHED THEN UPDATE SET STATUS = 'COMPLETED', COMPLETED_AT = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, HANDLED_BY = CURRENT_USER()
    WHEN NOT MATCHED THEN INSERT (REQUEST_REF, REQUEST_TYPE, DATA_PRINCIPAL_ID, RECEIVED_AT, DUE_BY, STATUS, COMPLETED_AT, CHANNEL, HANDLED_BY)
        VALUES (:P_REQUEST_REF, 'CORRECTION', :P_CUSTOMER_ID, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
                DATEADD(DAY, 30, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ), 'COMPLETED', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
                'API', CURRENT_USER());

    -- Old value is stored hashed only, never in clear
    INSERT INTO ACCEL_DB.DPDP.DPDP_AUDIT_LOG (EVENT_TYPE, DATA_PRINCIPAL_ID, REQUEST_REF, ACTOR_USER, DETAILS)
    SELECT 'DSR_CORRECTION', :P_CUSTOMER_ID, :P_REQUEST_REF, CURRENT_USER(),
           OBJECT_CONSTRUCT('field', :fld, 'old_value_sha256', SHA2(COALESCE(:old_value, ''), 256));
    RETURN 'Corrected ' || fld || ' for principal ' || P_CUSTOMER_ID;
END;
$$;

------------------------------------------------------------------------------
-- 4. Right to erasure: pseudonymise identifiers across all tables, keep
--    transactional records required by law (tax / accounting) under a
--    pseudonymous key, withdraw all consents, and log evidence.
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DSR_ERASURE(P_CUSTOMER_ID NUMBER, P_REQUEST_REF VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    salt VARCHAR;
    pseudo VARCHAR;
    n_customers NUMBER DEFAULT 0;
    n_tickets NUMBER DEFAULT 0;
    n_consents NUMBER DEFAULT 0;
    n_orders NUMBER DEFAULT 0;
    rows_affected VARIANT;
BEGIN
    SELECT MAX(CONFIG_VALUE) INTO :salt FROM ACCEL_DB.DPDP.KIT_CONFIG WHERE CONFIG_KEY = 'PSEUDONYM_SALT';
    pseudo := LEFT(SHA2(COALESCE(salt, '') || TO_VARCHAR(P_CUSTOMER_ID), 256), 16);

    UPDATE ACCEL_DB.DPDP.CUSTOMERS
       SET CUSTOMER_NAME = 'ERASED-' || :pseudo,
           EMAIL         = :pseudo || '@erased.invalid',
           PHONE         = NULL,
           PAN_NUMBER    = NULL,
           CITY          = NULL
     WHERE CUSTOMER_ID = :P_CUSTOMER_ID
       AND CUSTOMER_NAME <> 'ERASED-' || :pseudo;
    n_customers := SQLROWCOUNT;

    UPDATE ACCEL_DB.DPDP.SUPPORT_TICKETS
       SET SUBJECT = '[erased]',
           BODY    = '[content erased under data principal request ' || :P_REQUEST_REF || ']'
     WHERE CUSTOMER_ID = :P_CUSTOMER_ID
       AND SUBJECT <> '[erased]';
    n_tickets := SQLROWCOUNT;

    UPDATE ACCEL_DB.DPDP.CONSENT_REGISTER
       SET CONSENT_STATUS = 'WITHDRAWN', EVENT_TS = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, EXPIRES_AT = NULL,
           EVIDENCE_REF = 'erasure://' || :P_REQUEST_REF
     WHERE DATA_PRINCIPAL_ID = :P_CUSTOMER_ID AND IS_CURRENT AND CONSENT_STATUS <> 'WITHDRAWN';
    n_consents := SQLROWCOUNT;

    SELECT COUNT(*) INTO :n_orders FROM ACCEL_DB.DPDP.ORDERS WHERE CUSTOMER_ID = :P_CUSTOMER_ID;

    rows_affected := OBJECT_CONSTRUCT('CUSTOMERS', n_customers, 'SUPPORT_TICKETS', n_tickets,
                                      'CONSENT_REGISTER', n_consents, 'ORDERS_RETAINED', n_orders);

    INSERT INTO ACCEL_DB.DPDP.ERASURE_LOG
    SELECT :P_REQUEST_REF, :P_CUSTOMER_ID, :pseudo, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, CURRENT_USER(),
           :rows_affected,
           'ORDERS retained under pseudonymous CUSTOMER_ID for statutory tax/accounting retention (EDIT ME: cite policy)';

    MERGE INTO ACCEL_DB.DPDP.DSR_REQUESTS t
    USING (SELECT :P_REQUEST_REF AS REF) s ON t.REQUEST_REF = s.REF
    WHEN MATCHED THEN UPDATE SET STATUS = 'COMPLETED', COMPLETED_AT = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
                                 HANDLED_BY = CURRENT_USER(), OUTCOME = :rows_affected
    WHEN NOT MATCHED THEN INSERT (REQUEST_REF, REQUEST_TYPE, DATA_PRINCIPAL_ID, RECEIVED_AT, DUE_BY, STATUS,
                                  COMPLETED_AT, CHANNEL, HANDLED_BY, OUTCOME)
        VALUES (:P_REQUEST_REF, 'ERASURE', :P_CUSTOMER_ID, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
                DATEADD(DAY, 30, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ), 'COMPLETED',
                CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'API', CURRENT_USER(), :rows_affected);

    INSERT INTO ACCEL_DB.DPDP.DPDP_AUDIT_LOG (EVENT_TYPE, DATA_PRINCIPAL_ID, REQUEST_REF, ACTOR_USER, DETAILS)
    SELECT 'DSR_ERASURE', :P_CUSTOMER_ID, :P_REQUEST_REF, CURRENT_USER(), :rows_affected;

    RETURN OBJECT_CONSTRUCT('request_ref', P_REQUEST_REF, 'pseudonym', pseudo, 'rows_affected', rows_affected);
END;
$$;

------------------------------------------------------------------------------
-- 5. SLA view
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_DSR_SLA AS
SELECT REQUEST_REF, REQUEST_TYPE, DATA_PRINCIPAL_ID, RECEIVED_AT, DUE_BY, STATUS, COMPLETED_AT,
       DATEDIFF(HOUR, RECEIVED_AT, COALESCE(COMPLETED_AT, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)) AS AGE_HOURS,
       CASE
           WHEN STATUS = 'COMPLETED' AND COMPLETED_AT <= DUE_BY THEN 'MET'
           WHEN STATUS = 'COMPLETED' THEN 'BREACHED'
           WHEN CURRENT_TIMESTAMP()::TIMESTAMP_NTZ > DUE_BY THEN 'OVERDUE'
           WHEN DATEDIFF(DAY, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, DUE_BY) <= 5 THEN 'DUE_SOON'
           ELSE 'ON_TRACK'
       END AS SLA_STATUS
FROM ACCEL_DB.DPDP.DSR_REQUESTS;

------------------------------------------------------------------------------
-- 6. Demo
------------------------------------------------------------------------------
CALL SP_DSR_ACCESS(101, 'DSR-DEMO-0001');
CALL SP_DSR_CORRECTION(101, 'CITY', 'Pune', 'DSR-DEMO-0002');
CALL SP_DSR_ERASURE(202, 'DSR-DEMO-0003');

SELECT CUSTOMER_ID, CUSTOMER_NAME, EMAIL, PHONE, PAN_NUMBER, CITY
FROM CUSTOMERS WHERE CUSTOMER_ID IN (101, 202);

SELECT * FROM ERASURE_LOG ORDER BY EXECUTED_AT DESC LIMIT 5;
SELECT * FROM DPDP_AUDIT_LOG ORDER BY EVENT_ID DESC LIMIT 10;
