/* =============================================================================
   09 AI GOVERNANCE CONTROLS | 05_controls_checklist.sql
   AI_CONTROLS : control library mapped to AI risk themes
                 (data leakage, hallucination, bias, access, cost, auditability,
                 model risk). Each control names the Snowflake mechanism and an
                 evidence query that returns ONE number (VALUE).
   RUN_CONTROL_EVIDENCE() : runs every evidence query, compares VALUE with the
                 control's expectation and writes CONTROL_EVIDENCE.
   V_CONTROL_STATUS : latest result per control = the auditor's checklist.
   Expectation: ZERO    -> PASS when VALUE = 0 (number of exceptions)
                NONZERO -> PASS when VALUE > 0 (the control is producing evidence)
                INFO    -> metric only, always INFO
   Run as: ACCEL_ADMIN. Prerequisite: files 01, 02, 04 (03 recommended).
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS AI_GOVERNANCE;
USE SCHEMA AI_GOVERNANCE;

CREATE TABLE IF NOT EXISTS AI_CONTROLS (
  CONTROL_ID        VARCHAR,
  RISK_THEME        VARCHAR,    -- DATA_LEAKAGE | HALLUCINATION | BIAS | ACCESS | COST | AUDITABILITY | MODEL_RISK
  RISK              VARCHAR,
  CONTROL           VARCHAR,
  SNOWFLAKE_CONTROL VARCHAR,
  IMPLEMENTED_IN    VARCHAR,
  EVIDENCE_QUERY    VARCHAR,    -- must return one row, one numeric column named VALUE
  EXPECTATION       VARCHAR,    -- ZERO | NONZERO | INFO
  OWNER             VARCHAR,
  FREQUENCY         VARCHAR
);

MERGE INTO AI_CONTROLS t
USING (
  SELECT * FROM VALUES
  -- DATA LEAKAGE ------------------------------------------------------------
  ('AIC-01', 'DATA_LEAKAGE', 'Personal data sent to an LLM in a prompt',
   'Prompts are screened for PII; BLOCK or REDACT by use case',
   'GOVERNED_AI_COMPLETE + PII_PATTERNS (REGEXP)', '04_ai_complete_audit_wrapper.sql',
   $$SELECT COUNT(*) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.AI_REQUEST_LOG
     WHERE REQUEST_TS >= DATEADD('day', -30, CURRENT_TIMESTAMP())
       AND ARRAY_SIZE(PROMPT_PII_FOUND) > 0 AND ACTION = 'ALLOWED' AND PII_MODE <> 'ALLOW'$$,
   'ZERO', 'DPO', 'Monthly'),
  ('AIC-02', 'DATA_LEAKAGE', 'PII columns readable in clear text by AI users',
   'Masking policies on PII columns used as AI input',
   'Dynamic data masking (CREATE MASKING POLICY) + POLICY_REFERENCES', 'asset: data masking / classification',
   $$SELECT COUNT(*) AS VALUE
     FROM (SELECT * FROM VALUES ('CUSTOMERS','EMAIL'),('CUSTOMERS','PHONE'),('CUSTOMERS','PAN_NUMBER'),
                                ('EMPLOYEES','EMAIL'),('EMPLOYEES','SALARY')) v(TBL, COL)
     WHERE NOT EXISTS (SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES p
                       WHERE p.REF_DATABASE_NAME = 'ACCEL_DB' AND p.REF_SCHEMA_NAME = 'DEMO'
                         AND p.REF_ENTITY_NAME = v.TBL AND p.REF_COLUMN_NAME = v.COL
                         AND p.POLICY_KIND = 'MASKING_POLICY')$$,
   'ZERO', 'CISO', 'Monthly'),
  ('AIC-03', 'DATA_LEAKAGE', 'Model output repeats personal data',
   'Responses are screened and redacted before being returned',
   'GOVERNED_AI_COMPLETE response screening', '04_ai_complete_audit_wrapper.sql',
   $$SELECT COUNT(*) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.AI_REQUEST_LOG
     WHERE REQUEST_TS >= DATEADD('day', -30, CURRENT_TIMESTAMP()) AND ARRAY_SIZE(RESPONSE_PII_FOUND) > 0$$,
   'INFO', 'DPO', 'Monthly'),
  -- HALLUCINATION -----------------------------------------------------------
  ('AIC-04', 'HALLUCINATION', 'Unreviewed AI output used for material decisions',
   'Medium/high-risk use cases require human review',
   'AI_USE_CASES.REQUIRES_HUMAN_REVIEW + process', '02_policy_register.sql',
   $$SELECT COUNT(*) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.AI_USE_CASES
     WHERE STATUS = 'ACTIVE' AND RISK_TIER IN ('MEDIUM', 'HIGH') AND NOT REQUIRES_HUMAN_REVIEW$$,
   'ZERO', 'AI Governance Board', 'Quarterly'),
  ('AIC-05', 'HALLUCINATION', 'Non-deterministic, unbounded generations',
   'Governed calls use temperature 0 and a max_tokens cap; failures are logged',
   'AI_COMPLETE model_parameters in GOVERNED_AI_COMPLETE', '04_ai_complete_audit_wrapper.sql',
   $$SELECT COUNT(*) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.AI_REQUEST_LOG
     WHERE REQUEST_TS >= DATEADD('day', -30, CURRENT_TIMESTAMP()) AND ACTION = 'ERROR'$$,
   'ZERO', 'Platform owner', 'Monthly'),
  -- BIAS --------------------------------------------------------------------
  ('AIC-06', 'BIAS', 'AI used for decisions about people without elevated controls',
   'People-related use cases (HR, hiring, credit, attrition) must be HIGH risk tier',
   'AI_USE_CASES risk tiering', '02_policy_register.sql',
   $$SELECT COUNT(*) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.AI_USE_CASES
     WHERE REGEXP_LIKE(USE_CASE || ' ' || DESCRIPTION, '.*(HR|EMPLOYEE|EXIT|HIRING|CANDIDATE|CREDIT|ATTRITION|SALARY).*', 'i')
       AND RISK_TIER <> 'HIGH'$$,
   'ZERO', 'CHRO office', 'Quarterly'),
  ('AIC-07', 'BIAS', 'High-risk people use cases without human oversight',
   'HIGH risk use cases require human review before action',
   'AI_USE_CASES.REQUIRES_HUMAN_REVIEW', '02_policy_register.sql',
   $$SELECT COUNT(*) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.AI_USE_CASES
     WHERE RISK_TIER = 'HIGH' AND NOT REQUIRES_HUMAN_REVIEW$$,
   'ZERO', 'AI Governance Board', 'Quarterly'),
  -- ACCESS ------------------------------------------------------------------
  ('AIC-08', 'ACCESS', 'Every user can call AI functions by default',
   'CORTEX_USER is not granted to PUBLIC; AI access only via named roles',
   'REVOKE DATABASE ROLE SNOWFLAKE.CORTEX_USER FROM ROLE PUBLIC', '00_setup roles',
   $$SELECT COUNT(*) AS VALUE FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
     WHERE GRANTEE_NAME = 'PUBLIC' AND GRANTED_ON = 'DATABASE_ROLE'
       AND NAME ILIKE '%CORTEX_USER%' AND DELETED_ON IS NULL$$,
   'ZERO', 'CISO', 'Monthly'),
  ('AIC-09', 'ACCESS', 'Roles use models they are not approved for',
   'Model RBAC grants follow APPROVED_MODELS; allowlist switched off',
   'SNOWFLAKE."CORTEX-MODEL-ROLE-*" application roles + CORTEX_MODELS_ALLOWLIST', '03_model_allowlist.sql',
   $$SELECT COUNT(*) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.AI_REQUEST_LOG
     WHERE REQUEST_TS >= DATEADD('day', -30, CURRENT_TIMESTAMP()) AND ACTION = 'BLOCKED_MODEL'$$,
   'INFO', 'Platform owner', 'Monthly'),
  -- COST --------------------------------------------------------------------
  ('AIC-10', 'COST', 'Runaway AI spend by a single user',
   'Per-user AI credits monitored; users above 10 credits / 30 days reviewed',   -- threshold: EDIT ME
   'ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY + Budgets', '01_ai_usage_views.sql',
   $$SELECT COUNT(*) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.V_AI_TOP_USERS_30D WHERE CREDITS > 10$$,
   'ZERO', 'FinOps lead', 'Monthly'),
  ('AIC-11', 'COST', 'AI spend not visible to finance',
   'Daily AI credits are reported',
   'ACCOUNT_USAGE.METERING_DAILY_HISTORY (AI_SERVICES)', '01_ai_usage_views.sql',
   $$SELECT COALESCE(SUM(CREDITS_USED), 0) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.V_AI_CREDITS_DAILY
     WHERE USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE())$$,
   'INFO', 'FinOps lead', 'Monthly'),
  -- AUDITABILITY ------------------------------------------------------------
  ('AIC-12', 'AUDITABILITY', 'AI requests cannot be attributed',
   'Every governed request is logged with user, role, model, use case',
   'AI_REQUEST_LOG (insert-only for callers)', '04_ai_complete_audit_wrapper.sql',
   $$SELECT COUNT(*) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.AI_REQUEST_LOG
     WHERE REQUEST_TS >= DATEADD('day', -30, CURRENT_TIMESTAMP())$$,
   'NONZERO', 'CISO', 'Monthly'),
  ('AIC-13', 'AUDITABILITY', 'AI calls bypass the governed wrapper',
   'AI function queries are reconciled against the wrapper log',
   'ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY vs AI_REQUEST_LOG', '01 + 04',
   $$SELECT COUNT(DISTINCT h.QUERY_ID) AS VALUE
     FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
     WHERE h.START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
       AND h.QUERY_ID NOT IN (SELECT AI_QUERY_ID FROM ACCEL_DB.AI_GOVERNANCE.AI_REQUEST_LOG WHERE AI_QUERY_ID IS NOT NULL)$$,
   'INFO', 'CISO', 'Weekly'),
  -- MODEL RISK --------------------------------------------------------------
  ('AIC-14', 'MODEL_RISK', 'Unapproved models in use',
   'Only models on APPROVED_MODELS (APPROVED/TRIAL) are used',
   'APPROVED_MODELS + model RBAC + usage history', '01 + 02 + 03',
   $$SELECT COUNT(DISTINCT MODEL_NAME) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.V_AI_USAGE_BY_USER_MODEL
     WHERE USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE()) AND MODEL_NAME <> '(default)'
       AND LOWER(MODEL_NAME) NOT IN (SELECT LOWER(MODEL_NAME) FROM ACCEL_DB.AI_GOVERNANCE.APPROVED_MODELS
                                     WHERE STATUS IN ('APPROVED', 'TRIAL'))$$,
   'ZERO', 'Chief Data Officer', 'Monthly'),
  ('AIC-15', 'MODEL_RISK', 'Trial models drift into permanent use',
   'TRIAL approvals expire after 90 days unless re-approved',
   'APPROVED_MODELS.STATUS / APPROVED_ON', '02_policy_register.sql',
   $$SELECT COUNT(*) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.APPROVED_MODELS
     WHERE STATUS = 'TRIAL' AND APPROVED_ON < DATEADD('day', -90, CURRENT_DATE())$$,
   'ZERO', 'Chief Data Officer', 'Quarterly'),
  ('AIC-16', 'MODEL_RISK', 'AI policies not reviewed',
   'Active policies are reviewed by their NEXT_REVIEW date',
   'AI_POLICY_REGISTER', '02_policy_register.sql',
   $$SELECT COUNT(*) AS VALUE FROM ACCEL_DB.AI_GOVERNANCE.AI_POLICY_REGISTER
     WHERE STATUS = 'ACTIVE' AND NEXT_REVIEW < CURRENT_DATE()$$,
   'ZERO', 'AI Governance Board', 'Quarterly')
  AS s(CONTROL_ID, RISK_THEME, RISK, CONTROL, SNOWFLAKE_CONTROL, IMPLEMENTED_IN, EVIDENCE_QUERY, EXPECTATION, OWNER, FREQUENCY)
) s
ON t.CONTROL_ID = s.CONTROL_ID
WHEN MATCHED THEN UPDATE SET t.RISK_THEME = s.RISK_THEME, t.RISK = s.RISK, t.CONTROL = s.CONTROL,
  t.SNOWFLAKE_CONTROL = s.SNOWFLAKE_CONTROL, t.IMPLEMENTED_IN = s.IMPLEMENTED_IN, t.EVIDENCE_QUERY = s.EVIDENCE_QUERY,
  t.EXPECTATION = s.EXPECTATION, t.OWNER = s.OWNER, t.FREQUENCY = s.FREQUENCY
WHEN NOT MATCHED THEN INSERT (CONTROL_ID, RISK_THEME, RISK, CONTROL, SNOWFLAKE_CONTROL, IMPLEMENTED_IN, EVIDENCE_QUERY, EXPECTATION, OWNER, FREQUENCY)
  VALUES (s.CONTROL_ID, s.RISK_THEME, s.RISK, s.CONTROL, s.SNOWFLAKE_CONTROL, s.IMPLEMENTED_IN, s.EVIDENCE_QUERY, s.EXPECTATION, s.OWNER, s.FREQUENCY);

CREATE TABLE IF NOT EXISTS CONTROL_EVIDENCE (
  RUN_TS      TIMESTAMP_LTZ,
  CONTROL_ID  VARCHAR,
  VALUE       NUMBER(38, 4),
  STATUS      VARCHAR,      -- PASS | FAIL | INFO | ERROR
  RUN_BY      VARCHAR,
  MESSAGE     VARCHAR
);

CREATE OR REPLACE PROCEDURE RUN_CONTROL_EVIDENCE()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  run_ts  TIMESTAMP_LTZ;
  cid     VARCHAR;
  q       VARCHAR;
  expct   VARCHAR;
  val     NUMBER(38, 4);
  status  VARCHAR;
  msg     VARCHAR;
  n_fail  INTEGER DEFAULT 0;
  n_all   INTEGER DEFAULT 0;
  c1 CURSOR FOR SELECT CONTROL_ID, EVIDENCE_QUERY, EXPECTATION FROM ACCEL_DB.AI_GOVERNANCE.AI_CONTROLS ORDER BY CONTROL_ID;
BEGIN
  run_ts := CURRENT_TIMESTAMP();
  FOR rec IN c1 DO
    cid   := rec.CONTROL_ID;
    q     := rec.EVIDENCE_QUERY;
    expct := rec.EXPECTATION;
    val   := NULL;
    msg   := NULL;
    BEGIN
      EXECUTE IMMEDIATE :q;
      SELECT MAX($1)::NUMBER(38, 4) INTO :val FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
      val := COALESCE(val, 0);
      IF (expct = 'INFO') THEN
        status := 'INFO';
      ELSEIF (expct = 'NONZERO') THEN
        status := IFF(val > 0, 'PASS', 'FAIL');
      ELSE
        status := IFF(val = 0, 'PASS', 'FAIL');
      END IF;
    EXCEPTION
      WHEN OTHER THEN
        status := 'ERROR';
        msg    := SQLERRM;
    END;
    IF (status = 'FAIL') THEN n_fail := n_fail + 1; END IF;
    n_all := n_all + 1;
    INSERT INTO ACCEL_DB.AI_GOVERNANCE.CONTROL_EVIDENCE (RUN_TS, CONTROL_ID, VALUE, STATUS, RUN_BY, MESSAGE)
      SELECT :run_ts, :cid, :val, :status, CURRENT_USER(), :msg;
  END FOR;
  RETURN n_all || ' controls evaluated, ' || n_fail || ' failing';
END;
$$;

CREATE OR REPLACE VIEW V_CONTROL_STATUS AS
SELECT c.CONTROL_ID, c.RISK_THEME, c.RISK, c.CONTROL, c.SNOWFLAKE_CONTROL, c.IMPLEMENTED_IN,
       c.OWNER, c.FREQUENCY, c.EXPECTATION,
       e.VALUE, COALESCE(e.STATUS, 'NOT RUN') AS STATUS, e.RUN_TS AS LAST_RUN, e.MESSAGE,
       c.EVIDENCE_QUERY
FROM AI_CONTROLS c
LEFT JOIN (
  SELECT * FROM CONTROL_EVIDENCE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CONTROL_ID ORDER BY RUN_TS DESC) = 1
) e ON e.CONTROL_ID = c.CONTROL_ID;

CREATE OR REPLACE VIEW V_CONTROL_SCORECARD AS
SELECT RISK_THEME,
       COUNT(*)                                   AS CONTROLS,
       COUNT_IF(STATUS = 'PASS')                  AS PASSING,
       COUNT_IF(STATUS = 'FAIL')                  AS FAILING,
       COUNT_IF(STATUS IN ('INFO'))               AS INFO_ONLY,
       COUNT_IF(STATUS IN ('ERROR', 'NOT RUN'))   AS NO_EVIDENCE
FROM V_CONTROL_STATUS
GROUP BY RISK_THEME;

-- Monthly evidence collection (created suspended; resume to automate)
CREATE OR REPLACE TASK TASK_AI_CONTROL_EVIDENCE
  WAREHOUSE = ACCEL_WH
  SCHEDULE = 'USING CRON 0 6 1 * * Asia/Kolkata'   -- EDIT ME: 1st of month 06:00 IST
AS
  CALL ACCEL_DB.AI_GOVERNANCE.RUN_CONTROL_EVIDENCE();
-- ALTER TASK TASK_AI_CONTROL_EVIDENCE RESUME;

GRANT SELECT ON TABLE AI_CONTROLS      TO ROLE ACCEL_ANALYST;
GRANT SELECT ON TABLE CONTROL_EVIDENCE TO ROLE ACCEL_ANALYST;
GRANT SELECT ON VIEW V_CONTROL_STATUS    TO ROLE ACCEL_ANALYST;
GRANT SELECT ON VIEW V_CONTROL_SCORECARD TO ROLE ACCEL_ANALYST;

CALL RUN_CONTROL_EVIDENCE();

SELECT CONTROL_ID, RISK_THEME, CONTROL, SNOWFLAKE_CONTROL, VALUE, STATUS, MESSAGE
FROM V_CONTROL_STATUS ORDER BY CONTROL_ID;

SELECT * FROM V_CONTROL_SCORECARD ORDER BY RISK_THEME;
