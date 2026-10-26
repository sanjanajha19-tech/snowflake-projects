/*=============================================================================
  ACCELERATOR 18 - DPDP Privacy Kit
  File 06 : Storage limitation / retention (DPDP s.8(7))
            Personal data is erased or anonymised once the purpose is served
            and the retention period has lapsed, unless the law requires keeping it.
  Creates : RETENTION_RULES, RETENTION_RUN_LOG, SP_APPLY_RETENTION(dry_run),
            TSK_DPDP_RETENTION_MONTHLY (created SUSPENDED)
  Run as  : ACCEL_ADMIN
  Rerun   : safe. The demo call is a DRY RUN; the live call is commented out.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS DPDP;
USE SCHEMA DPDP;

------------------------------------------------------------------------------
-- 1. Retention rules (one row per rule; procedure logic per RULE_CODE)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE RETENTION_RULES (
    RULE_CODE        VARCHAR,
    TABLE_NAME       VARCHAR,
    DESCRIPTION      VARCHAR,
    RETENTION_DAYS   NUMBER,
    ACTION           VARCHAR,     -- ANONYMISE | DELETE
    LEGAL_REFERENCE  VARCHAR,
    IS_ACTIVE        BOOLEAN
);

INSERT INTO RETENTION_RULES VALUES
  ('TICKET_TEXT',      'SUPPORT_TICKETS',
   'Free text of resolved tickets is anonymised after the retention period; metadata kept for statistics',
   540,  'ANONYMISE', 'Purpose CUSTOMER_SUPPORT served; internal policy', TRUE),             -- EDIT ME
  ('INACTIVE_CUSTOMER', 'CUSTOMERS',
   'Customers with no orders, no active consent and no open request for N days are anonymised',
   730,  'ANONYMISE', 'DPDP s.8(7); DPDP Rules Third Schedule uses 3 years for specified classes', TRUE),  -- EDIT ME (e.g. 1095)
  ('EXITED_EMPLOYEE',  'EMPLOYEES',
   'Contact details of exited employees anonymised after the retention period',
   2555, 'ANONYMISE', 'Employment / tax record-keeping obligations', TRUE),                  -- EDIT ME
  ('AUDIT_LOG',        'DPDP_AUDIT_LOG',
   'Audit events older than the retention period are deleted',
   2920, 'DELETE',    'Evidence retention policy', TRUE);                                   -- EDIT ME

CREATE TABLE IF NOT EXISTS RETENTION_RUN_LOG (
    RUN_TS        TIMESTAMP_NTZ,
    DRY_RUN       BOOLEAN,
    RULE_CODE     VARCHAR,
    ROWS_MATCHED  NUMBER,
    ROWS_CHANGED  NUMBER,
    EXECUTED_BY   VARCHAR
);

------------------------------------------------------------------------------
-- 2. Retention procedure
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_APPLY_RETENTION(P_DRY_RUN BOOLEAN)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    run_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;
    d_ticket NUMBER;  a_ticket BOOLEAN;
    d_cust   NUMBER;  a_cust   BOOLEAN;
    d_emp    NUMBER;  a_emp    BOOLEAN;
    d_audit  NUMBER;  a_audit  BOOLEAN;
    m_ticket NUMBER DEFAULT 0;  c_ticket NUMBER DEFAULT 0;
    m_cust   NUMBER DEFAULT 0;  c_cust   NUMBER DEFAULT 0;
    m_emp    NUMBER DEFAULT 0;  c_emp    NUMBER DEFAULT 0;
    m_audit  NUMBER DEFAULT 0;  c_audit  NUMBER DEFAULT 0;
    salt VARCHAR;
BEGIN
    SELECT MAX(IFF(RULE_CODE = 'TICKET_TEXT',       RETENTION_DAYS, NULL)),
           BOOLOR_AGG(RULE_CODE = 'TICKET_TEXT'       AND IS_ACTIVE),
           MAX(IFF(RULE_CODE = 'INACTIVE_CUSTOMER', RETENTION_DAYS, NULL)),
           BOOLOR_AGG(RULE_CODE = 'INACTIVE_CUSTOMER' AND IS_ACTIVE),
           MAX(IFF(RULE_CODE = 'EXITED_EMPLOYEE',   RETENTION_DAYS, NULL)),
           BOOLOR_AGG(RULE_CODE = 'EXITED_EMPLOYEE'   AND IS_ACTIVE),
           MAX(IFF(RULE_CODE = 'AUDIT_LOG',         RETENTION_DAYS, NULL)),
           BOOLOR_AGG(RULE_CODE = 'AUDIT_LOG'         AND IS_ACTIVE)
      INTO :d_ticket, :a_ticket, :d_cust, :a_cust, :d_emp, :a_emp, :d_audit, :a_audit
      FROM ACCEL_DB.DPDP.RETENTION_RULES;

    SELECT MAX(CONFIG_VALUE) INTO :salt FROM ACCEL_DB.DPDP.KIT_CONFIG WHERE CONFIG_KEY = 'PSEUDONYM_SALT';

    -- Candidates: inactive customers
    CREATE OR REPLACE TRANSIENT TABLE ACCEL_DB.DPDP.TMP_RET_CUSTOMERS AS   -- working table (rebuilt each run)
    SELECT c.CUSTOMER_ID
    FROM ACCEL_DB.DPDP.CUSTOMERS c
    WHERE c.CREATED_DATE < DATEADD(DAY, -1 * :d_cust, CURRENT_DATE())
      AND NOT STARTSWITH(c.CUSTOMER_NAME, 'ERASED-')
      AND NOT EXISTS (SELECT 1 FROM ACCEL_DB.DPDP.ORDERS o
                      WHERE o.CUSTOMER_ID = c.CUSTOMER_ID
                        AND o.ORDER_DATE >= DATEADD(DAY, -1 * :d_cust, CURRENT_DATE()))
      AND NOT EXISTS (SELECT 1 FROM ACCEL_DB.DPDP.V_CONSENT_CURRENT v
                      WHERE v.DATA_PRINCIPAL_ID = c.CUSTOMER_ID AND v.EFFECTIVE_STATUS = 'ACTIVE')
      AND NOT EXISTS (SELECT 1 FROM ACCEL_DB.DPDP.DSR_REQUESTS r
                      WHERE r.DATA_PRINCIPAL_ID = c.CUSTOMER_ID AND r.STATUS IN ('RECEIVED', 'IN_PROGRESS'));

    SELECT COUNT(*) INTO :m_cust FROM ACCEL_DB.DPDP.TMP_RET_CUSTOMERS;
    SELECT COUNT(*) INTO :m_ticket FROM ACCEL_DB.DPDP.SUPPORT_TICKETS
     WHERE STATUS = 'Resolved' AND RESOLVED_AT < DATEADD(DAY, -1 * :d_ticket, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)
       AND BODY NOT LIKE '[%';
    SELECT COUNT(*) INTO :m_emp FROM ACCEL_DB.DPDP.EMPLOYEES
     WHERE STATUS = 'Exited' AND HIRE_DATE < DATEADD(DAY, -1 * :d_emp, CURRENT_DATE())
       AND NOT STARTSWITH(FULL_NAME, 'ANON-');
    SELECT COUNT(*) INTO :m_audit FROM ACCEL_DB.DPDP.DPDP_AUDIT_LOG
     WHERE EVENT_TS < DATEADD(DAY, -1 * :d_audit, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);

    IF (NOT P_DRY_RUN) THEN
        IF (a_ticket) THEN
            UPDATE ACCEL_DB.DPDP.SUPPORT_TICKETS
               SET SUBJECT = '[anonymised - retention]', BODY = '[anonymised - retention rule TICKET_TEXT]'
             WHERE STATUS = 'Resolved' AND RESOLVED_AT < DATEADD(DAY, -1 * :d_ticket, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)
               AND BODY NOT LIKE '[%';
            c_ticket := SQLROWCOUNT;
        END IF;
        IF (a_cust) THEN
            UPDATE ACCEL_DB.DPDP.CUSTOMERS c
               SET CUSTOMER_NAME = 'ERASED-' || LEFT(SHA2(COALESCE(:salt, '') || TO_VARCHAR(c.CUSTOMER_ID), 256), 16),
                   EMAIL = LEFT(SHA2(COALESCE(:salt, '') || TO_VARCHAR(c.CUSTOMER_ID), 256), 16) || '@erased.invalid',
                   PHONE = NULL, PAN_NUMBER = NULL, CITY = NULL
              FROM ACCEL_DB.DPDP.TMP_RET_CUSTOMERS t
             WHERE c.CUSTOMER_ID = t.CUSTOMER_ID;
            c_cust := SQLROWCOUNT;
        END IF;
        IF (a_emp) THEN
            UPDATE ACCEL_DB.DPDP.EMPLOYEES
               SET FULL_NAME = 'ANON-' || EMPLOYEE_ID, EMAIL = 'anon-' || EMPLOYEE_ID || '@erased.invalid'
             WHERE STATUS = 'Exited' AND HIRE_DATE < DATEADD(DAY, -1 * :d_emp, CURRENT_DATE())
               AND NOT STARTSWITH(FULL_NAME, 'ANON-');
            c_emp := SQLROWCOUNT;
        END IF;
        IF (a_audit) THEN
            DELETE FROM ACCEL_DB.DPDP.DPDP_AUDIT_LOG
             WHERE EVENT_TS < DATEADD(DAY, -1 * :d_audit, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);
            c_audit := SQLROWCOUNT;
        END IF;
    END IF;

    INSERT INTO ACCEL_DB.DPDP.RETENTION_RUN_LOG
              SELECT :run_ts, :P_DRY_RUN, 'TICKET_TEXT',       :m_ticket, :c_ticket, CURRENT_USER()
    UNION ALL SELECT :run_ts, :P_DRY_RUN, 'INACTIVE_CUSTOMER', :m_cust,   :c_cust,   CURRENT_USER()
    UNION ALL SELECT :run_ts, :P_DRY_RUN, 'EXITED_EMPLOYEE',   :m_emp,    :c_emp,    CURRENT_USER()
    UNION ALL SELECT :run_ts, :P_DRY_RUN, 'AUDIT_LOG',         :m_audit,  :c_audit,  CURRENT_USER();

    INSERT INTO ACCEL_DB.DPDP.DPDP_AUDIT_LOG (EVENT_TYPE, ACTOR_USER, DETAILS)
    SELECT 'RETENTION_RUN', CURRENT_USER(),
           OBJECT_CONSTRUCT('dry_run', :P_DRY_RUN,
                            'matched', OBJECT_CONSTRUCT('TICKET_TEXT', :m_ticket, 'INACTIVE_CUSTOMER', :m_cust,
                                                        'EXITED_EMPLOYEE', :m_emp, 'AUDIT_LOG', :m_audit),
                            'changed', OBJECT_CONSTRUCT('TICKET_TEXT', :c_ticket, 'INACTIVE_CUSTOMER', :c_cust,
                                                        'EXITED_EMPLOYEE', :c_emp, 'AUDIT_LOG', :c_audit));

    RETURN OBJECT_CONSTRUCT('dry_run', P_DRY_RUN,
                            'matched', OBJECT_CONSTRUCT('TICKET_TEXT', m_ticket, 'INACTIVE_CUSTOMER', m_cust,
                                                        'EXITED_EMPLOYEE', m_emp, 'AUDIT_LOG', m_audit),
                            'changed', OBJECT_CONSTRUCT('TICKET_TEXT', c_ticket, 'INACTIVE_CUSTOMER', c_cust,
                                                        'EXITED_EMPLOYEE', c_emp, 'AUDIT_LOG', c_audit));
END;
$$;

------------------------------------------------------------------------------
-- 3. Schedule (created suspended - resume after sign-off by the DPO)
------------------------------------------------------------------------------
CREATE OR REPLACE TASK TSK_DPDP_RETENTION_MONTHLY
  WAREHOUSE = ACCEL_WH
  SCHEDULE = 'USING CRON 0 2 1 * * Asia/Kolkata'
  COMMENT = 'DPDP kit: monthly retention run'
AS
  CALL ACCEL_DB.DPDP.SP_APPLY_RETENTION(FALSE);
-- ALTER TASK TSK_DPDP_RETENTION_MONTHLY RESUME;   -- EDIT ME: enable after approval

------------------------------------------------------------------------------
-- 4. Demo: dry run shows what WOULD change; uncomment the live run to apply
------------------------------------------------------------------------------
CALL SP_APPLY_RETENTION(TRUE);
-- CALL SP_APPLY_RETENTION(FALSE);

SELECT * FROM RETENTION_RUN_LOG ORDER BY RUN_TS DESC, RULE_CODE LIMIT 8;
