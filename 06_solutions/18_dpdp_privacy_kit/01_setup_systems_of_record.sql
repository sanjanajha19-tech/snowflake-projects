/*=============================================================================
  ACCELERATOR 18 - DPDP Privacy Kit (India DPDP Act 2023 + general privacy)
  File 01 : Schema, working "systems of record" and audit log
  Creates : schema ACCEL_DB.DPDP
            - CUSTOMERS, ORDERS, SUPPORT_TICKETS, EMPLOYEES
              (zero-copy clones of ACCEL_DB.DEMO so erasure / retention demos
               never modify the shared demo data)
            - DPDP_AUDIT_LOG, SP_AUDIT(...)
            - KIT_CONFIG (salt, SLA days, reference values)
  Run as  : ACCEL_ADMIN
  Rerun   : resets the cloned tables to the DEMO state (audit log is kept).
  Disclaimer: technical accelerator, not legal advice.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS DPDP COMMENT = 'Accelerator 18: DPDP privacy kit';
USE SCHEMA DPDP;

------------------------------------------------------------------------------
-- 1. Systems of record (clones). In a client project these are the real
--    tables; point the procedures in files 05-06 at them instead.
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE CUSTOMERS       CLONE ACCEL_DB.DEMO.CUSTOMERS;
CREATE OR REPLACE TABLE ORDERS          CLONE ACCEL_DB.DEMO.ORDERS;
CREATE OR REPLACE TABLE SUPPORT_TICKETS CLONE ACCEL_DB.DEMO.SUPPORT_TICKETS;
CREATE OR REPLACE TABLE EMPLOYEES       CLONE ACCEL_DB.DEMO.EMPLOYEES;

-- Personal data tables are not readable by analysts directly; they get the
-- purpose-bound view from file 04 instead. (00_setup grants SELECT on future
-- tables in ACCEL_DB to ACCEL_ANALYST, so revoke it here.)
REVOKE SELECT ON TABLE CUSTOMERS       FROM ROLE ACCEL_ANALYST;
REVOKE SELECT ON TABLE ORDERS          FROM ROLE ACCEL_ANALYST;
REVOKE SELECT ON TABLE SUPPORT_TICKETS FROM ROLE ACCEL_ANALYST;
REVOKE SELECT ON TABLE EMPLOYEES       FROM ROLE ACCEL_ANALYST;

------------------------------------------------------------------------------
-- 2. Kit configuration
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS KIT_CONFIG (
    CONFIG_KEY   VARCHAR,
    CONFIG_VALUE VARCHAR,
    DESCRIPTION  VARCHAR
);

MERGE INTO KIT_CONFIG t
USING (
    SELECT 'PSEUDONYM_SALT' AS K, 'dpdp-accel-salt-2026' AS V, 'Secret salt for pseudonymisation hashes' AS D   -- EDIT ME
    UNION ALL SELECT 'DSR_SLA_DAYS', '30', 'Internal SLA (days) for closing data principal requests'             -- EDIT ME
    UNION ALL SELECT 'DPO_CONTACT', 'dpo@example.com', 'Contact of Data Protection Officer / grievance officer' -- EDIT ME
) s
ON t.CONFIG_KEY = s.K
WHEN NOT MATCHED THEN INSERT (CONFIG_KEY, CONFIG_VALUE, DESCRIPTION) VALUES (s.K, s.V, s.D);

------------------------------------------------------------------------------
-- 3. Audit log (append-only evidence of every privacy operation)
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DPDP_AUDIT_LOG (
    EVENT_ID          NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    EVENT_TS          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
    EVENT_TYPE        VARCHAR,     -- PII_SCAN, CONSENT_CHANGE, DSR_ACCESS, DSR_CORRECTION, DSR_ERASURE, RETENTION_RUN ...
    DATA_PRINCIPAL_ID NUMBER,
    REQUEST_REF       VARCHAR,
    ACTOR_USER        VARCHAR DEFAULT CURRENT_USER(),
    DETAILS           VARIANT
) COMMENT = 'DPDP kit: append-only audit trail of privacy operations';

CREATE OR REPLACE PROCEDURE SP_AUDIT(P_EVENT_TYPE VARCHAR, P_PRINCIPAL_ID NUMBER, P_REQUEST_REF VARCHAR, P_DETAILS VARIANT)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    INSERT INTO ACCEL_DB.DPDP.DPDP_AUDIT_LOG (EVENT_TYPE, DATA_PRINCIPAL_ID, REQUEST_REF, ACTOR_USER, DETAILS)
    SELECT :P_EVENT_TYPE, :P_PRINCIPAL_ID, :P_REQUEST_REF, CURRENT_USER(), :P_DETAILS;
    RETURN 'logged';
END;
$$;

CALL SP_AUDIT('KIT_SETUP', NULL, NULL, OBJECT_CONSTRUCT('step', '01_setup_systems_of_record', 'tables_cloned', 4));

SELECT 'CUSTOMERS' AS TBL, COUNT(*) AS ROWS_ FROM CUSTOMERS
UNION ALL SELECT 'ORDERS', COUNT(*) FROM ORDERS
UNION ALL SELECT 'SUPPORT_TICKETS', COUNT(*) FROM SUPPORT_TICKETS
UNION ALL SELECT 'EMPLOYEES', COUNT(*) FROM EMPLOYEES;
