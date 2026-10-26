/* =============================================================================
   09 AI GOVERNANCE CONTROLS | 04_ai_complete_audit_wrapper.sql
   GOVERNED_AI_COMPLETE(prompt, model, use_case): a governed front door to AI_COMPLETE.
     1. Checks the use case is registered and ACTIVE (AI_USE_CASES).
     2. Checks the model is APPROVED/TRIAL and approved for the caller's role
        (APPROVED_MODELS). Model RBAC from file 03 is still enforced by Snowflake.
     3. Screens the prompt with the REGEXP patterns in PII_PATTERNS
        (e-mail, phone, PAN, Aadhaar, card number, GSTIN). The use case's
        ALLOWED_PII_MODE decides: BLOCK (refuse) | REDACT (mask, then send) | ALLOW.
     4. Calls AI_COMPLETE with temperature 0 and a token cap.
     5. Redacts PII found in the response (unless the use case is ALLOW).
     6. Logs every request to AI_REQUEST_LOG: user, role, model, use case,
        prompt as sent (never the raw PII), PII types found, action, response,
        latency, query id (joins to ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY).
   Caller's rights, so CURRENT_ROLE() is the real caller role. Callers get INSERT
   only on the log (no UPDATE / DELETE), so they cannot alter the audit trail.
   Run as: ACCEL_ADMIN. Prerequisite: 02_policy_register.sql.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS AI_GOVERNANCE;
USE SCHEMA AI_GOVERNANCE;

CREATE TABLE IF NOT EXISTS AI_REQUEST_LOG (
  REQUEST_ID         VARCHAR,
  REQUEST_TS         TIMESTAMP_LTZ,
  USER_NAME          VARCHAR,
  ROLE_NAME          VARCHAR,
  SESSION_ID         NUMBER,
  USE_CASE           VARCHAR,
  MODEL_NAME         VARCHAR,
  PII_MODE           VARCHAR,       -- BLOCK | REDACT | ALLOW (from AI_USE_CASES)
  PROMPT_PII_FOUND   ARRAY,         -- pattern names found in the prompt
  ACTION             VARCHAR,       -- ALLOWED | REDACTED | BLOCKED_PII | BLOCKED_MODEL | BLOCKED_USE_CASE | ERROR
  PROMPT_LOGGED      VARCHAR,       -- prompt with PII masked (what was / would have been sent)
  PROMPT_CHARS       NUMBER,
  RESPONSE           VARCHAR,       -- response after PII redaction
  RESPONSE_PII_FOUND ARRAY,
  LATENCY_MS         NUMBER,
  AI_QUERY_ID        VARCHAR,
  ERROR_MESSAGE      VARCHAR
);

CREATE OR REPLACE PROCEDURE GOVERNED_AI_COMPLETE(
  P_PROMPT   VARCHAR,
  P_MODEL    VARCHAR DEFAULT 'llama3.1-70b',
  P_USE_CASE VARCHAR DEFAULT 'GENERAL'
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  req_id        VARCHAR;
  model_lc      VARCHAR;
  use_case_uc   VARCHAR;
  pii_mode      VARCHAR;
  model_ok      INTEGER DEFAULT 0;
  prompt_masked VARCHAR;
  prompt_found  VARCHAR DEFAULT '';
  resp          VARCHAR;
  resp_masked   VARCHAR;
  resp_found    VARCHAR DEFAULT '';
  action        VARCHAR;
  err_msg       VARCHAR;
  ai_qid        VARCHAR;
  hits          INTEGER;
  pname         VARCHAR;
  rx            VARCHAR;
  t0            TIMESTAMP_LTZ;
  latency       NUMBER;
  stmt          VARCHAR;
  result        VARIANT;
  rs            RESULTSET;
  c_prompt CURSOR FOR
    SELECT PATTERN_NAME, REGEX FROM ACCEL_DB.AI_GOVERNANCE.PII_PATTERNS WHERE ACTIVE
    ORDER BY CASE PATTERN_NAME WHEN 'EMAIL' THEN 1 WHEN 'CARD_NUMBER' THEN 2 WHEN 'AADHAAR' THEN 3
                               WHEN 'GSTIN' THEN 4 WHEN 'PAN' THEN 5 WHEN 'PHONE' THEN 6 ELSE 9 END, PATTERN_NAME;
  c_resp CURSOR FOR
    SELECT PATTERN_NAME, REGEX FROM ACCEL_DB.AI_GOVERNANCE.PII_PATTERNS WHERE ACTIVE
    ORDER BY CASE PATTERN_NAME WHEN 'EMAIL' THEN 1 WHEN 'CARD_NUMBER' THEN 2 WHEN 'AADHAAR' THEN 3
                               WHEN 'GSTIN' THEN 4 WHEN 'PAN' THEN 5 WHEN 'PHONE' THEN 6 ELSE 9 END, PATTERN_NAME;
BEGIN
  req_id        := UUID_STRING();
  t0            := CURRENT_TIMESTAMP();
  model_lc      := LOWER(TRIM(COALESCE(P_MODEL, '')));
  use_case_uc   := UPPER(TRIM(COALESCE(P_USE_CASE, '')));
  prompt_masked := COALESCE(P_PROMPT, '');

  -- 1. Use case must be registered and ACTIVE
  SELECT MAX(ALLOWED_PII_MODE) INTO :pii_mode
  FROM ACCEL_DB.AI_GOVERNANCE.AI_USE_CASES
  WHERE USE_CASE = :use_case_uc AND STATUS = 'ACTIVE';

  -- 2. Model must be approved for the caller's current role
  SELECT COUNT(*) INTO :model_ok
  FROM ACCEL_DB.AI_GOVERNANCE.APPROVED_MODELS
  WHERE LOWER(MODEL_NAME) = :model_lc
    AND STATUS IN ('APPROVED', 'TRIAL')
    AND ARRAY_CONTAINS(CURRENT_ROLE()::VARIANT, SPLIT(REPLACE(UPPER(APPROVED_FOR_ROLES), ' ', ''), ','));

  -- 3. Prompt PII screening (each pattern masks before the next one runs, so
  --    e.g. a card number is not also reported as a phone number)
  FOR p IN c_prompt DO
    pname := p.PATTERN_NAME;
    rx    := p.REGEX;
    SELECT REGEXP_COUNT(:prompt_masked, :rx),
           REGEXP_REPLACE(:prompt_masked, :rx, '[' || :pname || '_REDACTED]')
      INTO :hits, :prompt_masked;
    IF (hits > 0) THEN
      prompt_found := prompt_found || pname || ',';
    END IF;
  END FOR;

  -- 4. Decide
  IF (pii_mode IS NULL) THEN
    action := 'BLOCKED_USE_CASE';
    resp   := 'Request refused: use case ' || use_case_uc || ' is not registered or not ACTIVE in AI_USE_CASES.';
  ELSEIF (model_ok = 0) THEN
    action := 'BLOCKED_MODEL';
    resp   := 'Request refused: model ' || model_lc || ' is not approved for role ' || CURRENT_ROLE() || ' (APPROVED_MODELS).';
  ELSEIF (prompt_found <> '' AND pii_mode = 'BLOCK') THEN
    action := 'BLOCKED_PII';
    resp   := 'Request refused: the prompt contains personal data (' || RTRIM(prompt_found, ',')
              || '). Remove it, or use a use case approved for redaction.';
  ELSE
    IF (prompt_found <> '' AND pii_mode = 'REDACT') THEN
      action := 'REDACTED';
    ELSE
      action := 'ALLOWED';
    END IF;
    -- The model name is validated against APPROVED_MODELS above and checked against a
    -- strict character set here before being written into the statement; the prompt is a bind.
    IF (NOT REGEXP_LIKE(model_lc, '[a-z0-9._-]+')) THEN
      action := 'BLOCKED_MODEL';
      resp   := 'Request refused: invalid model name.';
    ELSE
      stmt := 'SELECT AI_COMPLETE(''' || model_lc || ''', ?, {''temperature'': 0, ''max_tokens'': 2048}) AS R';
      BEGIN
        IF (action = 'REDACTED') THEN
          rs := (EXECUTE IMMEDIATE :stmt USING (prompt_masked));
        ELSE
          rs := (EXECUTE IMMEDIATE :stmt USING (P_PROMPT));
        END IF;
        ai_qid := LAST_QUERY_ID();
        LET c_out CURSOR FOR rs;
        OPEN c_out;
        FETCH c_out INTO resp;
        CLOSE c_out;
      EXCEPTION
        WHEN OTHER THEN
          action  := 'ERROR';
          err_msg := SQLERRM;
          resp    := 'AI_COMPLETE failed: ' || SQLERRM;
      END;
    END IF;
  END IF;

  -- 5. Response PII screening (only for real model output, not for refusal text)
  resp_masked := resp;
  IF (action IN ('ALLOWED', 'REDACTED') AND pii_mode <> 'ALLOW') THEN
    FOR r IN c_resp DO
      pname := r.PATTERN_NAME;
      rx    := r.REGEX;
      SELECT REGEXP_COUNT(:resp_masked, :rx),
             REGEXP_REPLACE(:resp_masked, :rx, '[' || :pname || '_REDACTED]')
        INTO :hits, :resp_masked;
      IF (hits > 0) THEN
        resp_found := resp_found || pname || ',';
      END IF;
    END FOR;
  END IF;

  latency := DATEDIFF('millisecond', t0, CURRENT_TIMESTAMP());

  -- 6. Audit log (raw prompt is never stored; PROMPT_LOGGED is the masked text)
  INSERT INTO ACCEL_DB.AI_GOVERNANCE.AI_REQUEST_LOG
  SELECT :req_id, CURRENT_TIMESTAMP(), CURRENT_USER(), CURRENT_ROLE(), CURRENT_SESSION()::NUMBER,
         :use_case_uc, :model_lc, :pii_mode,
         IFF(:prompt_found = '', ARRAY_CONSTRUCT(), SPLIT(RTRIM(:prompt_found, ','), ',')),
         :action, :prompt_masked, LENGTH(:P_PROMPT), :resp_masked,
         IFF(:resp_found = '', ARRAY_CONSTRUCT(), SPLIT(RTRIM(:resp_found, ','), ',')),
         :latency, :ai_qid, :err_msg;

  SELECT OBJECT_CONSTRUCT(
           'request_id', :req_id,
           'action', :action,
           'model', :model_lc,
           'use_case', :use_case_uc,
           'prompt_pii_found', IFF(:prompt_found = '', ARRAY_CONSTRUCT(), SPLIT(RTRIM(:prompt_found, ','), ',')),
           'response_pii_found', IFF(:resp_found = '', ARRAY_CONSTRUCT(), SPLIT(RTRIM(:resp_found, ','), ',')),
           'response', :resp_masked)
    INTO :result;
  RETURN result;
END;
$$;

-- Summary views for dashboards and auditors
CREATE OR REPLACE VIEW V_AI_REQUEST_SUMMARY AS
SELECT DATE_TRUNC('day', REQUEST_TS)::DATE AS REQUEST_DATE, USER_NAME, ROLE_NAME, USE_CASE, MODEL_NAME, ACTION,
       COUNT(*) AS REQUESTS, AVG(LATENCY_MS) AS AVG_LATENCY_MS
FROM AI_REQUEST_LOG
GROUP BY 1, 2, 3, 4, 5, 6;

CREATE OR REPLACE VIEW V_AI_PII_EVENTS AS
SELECT REQUEST_TS, USER_NAME, ROLE_NAME, USE_CASE, MODEL_NAME, ACTION,
       PROMPT_PII_FOUND, RESPONSE_PII_FOUND, PROMPT_LOGGED
FROM AI_REQUEST_LOG
WHERE ARRAY_SIZE(PROMPT_PII_FOUND) > 0 OR ARRAY_SIZE(RESPONSE_PII_FOUND) > 0;

-- Callers: run the wrapper, append to the log, read the policy tables. No UPDATE/DELETE on the log.
GRANT USAGE ON PROCEDURE GOVERNED_AI_COMPLETE(VARCHAR, VARCHAR, VARCHAR) TO ROLE ACCEL_ANALYST;
GRANT USAGE ON PROCEDURE GOVERNED_AI_COMPLETE(VARCHAR, VARCHAR, VARCHAR) TO ROLE ACCEL_DEVELOPER;
GRANT USAGE ON SCHEMA ACCEL_DB.AI_GOVERNANCE TO ROLE ACCEL_DEVELOPER;
GRANT INSERT ON TABLE AI_REQUEST_LOG TO ROLE ACCEL_ANALYST;
GRANT INSERT ON TABLE AI_REQUEST_LOG TO ROLE ACCEL_DEVELOPER;
GRANT SELECT ON TABLE APPROVED_MODELS TO ROLE ACCEL_DEVELOPER;
GRANT SELECT ON TABLE AI_USE_CASES    TO ROLE ACCEL_DEVELOPER;
GRANT SELECT ON TABLE PII_PATTERNS    TO ROLE ACCEL_DEVELOPER;
GRANT SELECT ON VIEW V_AI_REQUEST_SUMMARY TO ROLE ACCEL_ANALYST;

-- ---------------------------------------------------------------------------
-- Demo
-- ---------------------------------------------------------------------------
-- a) Clean prompt -> ALLOWED
CALL GOVERNED_AI_COMPLETE('In two sentences, explain what a data catalog is.', 'llama3.1-70b', 'GENERAL');

-- b) Prompt with an e-mail and phone number under GENERAL (BLOCK) -> BLOCKED_PII, no model call
CALL GOVERNED_AI_COMPLETE('Write a reminder to priya.sharma@example.com, mobile +91 98765 43210, about her overdue invoice.',
                          'llama3.1-70b', 'GENERAL');

-- c) Same kind of data under TICKET_SUMMARY (REDACT) -> PII masked, then sent
CALL GOVERNED_AI_COMPLETE('Summarise this ticket: Customer with PAN ABCDE1234F (email a.kumar@example.in) says the invoice total is wrong and wants a refund.',
                          'llama3.1-70b', 'TICKET_SUMMARY');

-- d) Model not on the approved list -> BLOCKED_MODEL
CALL GOVERNED_AI_COMPLETE('Hello', 'some-unapproved-model', 'GENERAL');

-- e) Unregistered use case -> BLOCKED_USE_CASE
CALL GOVERNED_AI_COMPLETE('Hello', 'llama3.1-70b', 'SHADOW_PROJECT');

-- f) Real data: summarise a demo support ticket through the wrapper
SET TICKET_TEXT = (SELECT SUBJECT || '. ' || BODY FROM ACCEL_DB.DEMO.SUPPORT_TICKETS ORDER BY TICKET_ID LIMIT 1);
CALL GOVERNED_AI_COMPLETE('Summarise this support ticket in one sentence: ' || $TICKET_TEXT, 'llama3.1-70b', 'TICKET_SUMMARY');

SELECT REQUEST_TS, USER_NAME, ROLE_NAME, USE_CASE, MODEL_NAME, ACTION, PROMPT_PII_FOUND,
       LEFT(PROMPT_LOGGED, 120) AS PROMPT_LOGGED, LEFT(RESPONSE, 160) AS RESPONSE, LATENCY_MS
FROM AI_REQUEST_LOG ORDER BY REQUEST_TS DESC LIMIT 20;
