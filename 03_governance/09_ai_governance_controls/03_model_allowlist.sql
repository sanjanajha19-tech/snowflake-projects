/* =============================================================================
   09 AI GOVERNANCE CONTROLS | 03_model_allowlist.sql
   Restrict which LLMs can be called, and by whom.

   Two Snowflake mechanisms exist. Access to a model is granted if EITHER is true:
     a) CORTEX_MODELS_ALLOWLIST (account parameter, ACCOUNTADMIN only)
        'All' (default) | 'None' | 'model1,model2' (lowercase names).
        DEPRECATED: since August 2026 the parameter can no longer be changed to a
        new value list; it can only be set to 'None'. It will then be removed.
     b) Model RBAC (the replacement): every Cortex model is an object in
        SNOWFLAKE.MODELS with an application role SNOWFLAKE."CORTEX-MODEL-ROLE-<MODEL>".
        Granting that application role to an account role gives that role the model.

   Target state = allowlist 'None' (switched off) + RBAC grants driven by
   ACCEL_DB.AI_GOVERNANCE.APPROVED_MODELS (file 02). Then only roles listed in
   APPROVED_FOR_ROLES can call a model, whatever SQL path they use.

   This script:
     1. shows the current allowlist value
     2. refreshes the model objects and lists the model application roles
     3. grants model roles to account roles from APPROVED_MODELS (idempotent)
     4. records the grants in MODEL_ACCESS_GRANTS
     5. (commented, deliberate one-way step) sets the allowlist to 'None'

   Run as: ACCOUNTADMIN. Reason: ALTER ACCOUNT parameters, CORTEX_BASE_MODELS_REFRESH
   and granting SNOWFLAKE application roles all require ACCOUNTADMIN.
   Prerequisite: 02_policy_register.sql (APPROVED_MODELS).
============================================================================= */
USE ROLE ACCOUNTADMIN;   -- account parameter + SNOWFLAKE application roles need ACCOUNTADMIN
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS AI_GOVERNANCE;
USE SCHEMA AI_GOVERNANCE;

-- ---------------------------------------------------------------------------
-- 1. Current allowlist value ('All' on a new account = every model is open)
-- ---------------------------------------------------------------------------
SHOW PARAMETERS LIKE 'CORTEX_MODELS_ALLOWLIST' IN ACCOUNT;

-- ---------------------------------------------------------------------------
-- 2. Model objects and their application roles
-- ---------------------------------------------------------------------------
CALL SNOWFLAKE.MODELS.CORTEX_BASE_MODELS_REFRESH();
SHOW MODELS IN SNOWFLAKE.MODELS;
SHOW APPLICATION ROLES LIKE 'CORTEX-MODEL%' IN APPLICATION SNOWFLAKE;

-- ---------------------------------------------------------------------------
-- 3. Grant model roles from APPROVED_MODELS (APPROVED + TRIAL rows)
--    Models not available in this region are skipped and reported.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS MODEL_ACCESS_GRANTS (
  RUN_TS      TIMESTAMP_LTZ,
  MODEL_NAME  VARCHAR,
  APP_ROLE    VARCHAR,
  GRANTEE     VARCHAR,
  OUTCOME     VARCHAR      -- GRANTED | MODEL_NOT_AVAILABLE | ERROR: <message>
);

EXECUTE IMMEDIATE $$
DECLARE
  stmt    VARCHAR;
  outcome VARCHAR;
  n_ok    INTEGER DEFAULT 0;
  n_skip  INTEGER DEFAULT 0;
  m_name  VARCHAR;
  a_role  VARCHAR;
  g_role  VARCHAR;
BEGIN
  SHOW APPLICATION ROLES LIKE 'CORTEX-MODEL-ROLE-%' IN APPLICATION SNOWFLAKE;
  CREATE OR REPLACE TEMPORARY TABLE ACCEL_DB.AI_GOVERNANCE.TMP_MODEL_APP_ROLES AS
    SELECT "name"::VARCHAR AS APP_ROLE FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

  LET c1 CURSOR FOR
    WITH wanted AS (
      SELECT LOWER(m.MODEL_NAME)                        AS MODEL_NAME,
             'CORTEX-MODEL-ROLE-' || UPPER(m.MODEL_NAME) AS APP_ROLE,
             UPPER(TRIM(f.VALUE::VARCHAR))              AS GRANTEE
      FROM ACCEL_DB.AI_GOVERNANCE.APPROVED_MODELS m,
           LATERAL SPLIT_TO_TABLE(m.APPROVED_FOR_ROLES, ',') f
      WHERE m.STATUS IN ('APPROVED', 'TRIAL')
        AND TRIM(f.VALUE::VARCHAR) <> ''
    )
    SELECT w.MODEL_NAME, w.APP_ROLE, w.GRANTEE, (r.APP_ROLE IS NOT NULL) AS AVAILABLE
    FROM wanted w
    LEFT JOIN ACCEL_DB.AI_GOVERNANCE.TMP_MODEL_APP_ROLES r ON r.APP_ROLE = w.APP_ROLE;

  FOR rec IN c1 DO
    IF (rec.AVAILABLE) THEN
      stmt := 'GRANT APPLICATION ROLE SNOWFLAKE."' || rec.APP_ROLE || '" TO ROLE ' || rec.GRANTEE;
      BEGIN
        EXECUTE IMMEDIATE :stmt;
        outcome := 'GRANTED';
        n_ok := n_ok + 1;
      EXCEPTION
        WHEN OTHER THEN
          outcome := 'ERROR: ' || SQLERRM;
      END;
    ELSE
      outcome := 'MODEL_NOT_AVAILABLE';
      n_skip := n_skip + 1;
    END IF;
    m_name := rec.MODEL_NAME;
    a_role := rec.APP_ROLE;
    g_role := rec.GRANTEE;
    INSERT INTO ACCEL_DB.AI_GOVERNANCE.MODEL_ACCESS_GRANTS (RUN_TS, MODEL_NAME, APP_ROLE, GRANTEE, OUTCOME)
      SELECT CURRENT_TIMESTAMP(), :m_name, :a_role, :g_role, :outcome;
  END FOR;

  DROP TABLE IF EXISTS ACCEL_DB.AI_GOVERNANCE.TMP_MODEL_APP_ROLES;
  RETURN n_ok || ' model grants applied, ' || n_skip || ' skipped (model not available in this region)';
END;
$$;

SELECT * FROM MODEL_ACCESS_GRANTS
WHERE RUN_TS = (SELECT MAX(RUN_TS) FROM MODEL_ACCESS_GRANTS)
ORDER BY MODEL_NAME, GRANTEE;

-- What a role can now use:
SHOW GRANTS TO ROLE ACCEL_ANALYST;

GRANT SELECT ON TABLE MODEL_ACCESS_GRANTS TO ROLE ACCEL_ANALYST;

-- ---------------------------------------------------------------------------
-- 4. Remove a model from a role (when APPROVED_MODELS changes to BLOCKED):
--    REVOKE APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-LLAMA3.1-8B" FROM ROLE ACCEL_DEVELOPER;
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 5. Switch the allowlist off so ONLY the RBAC grants above decide access.
--    One-way step: after August 2026 the parameter cannot be set back to a model
--    list. Every role without a CORTEX-MODEL-ROLE grant (including PUBLIC and other
--    teams roles) immediately loses access to all models. Check
--    V_AI_USAGE_BY_USER_MODEL (file 01) for current users first, grant them the
--    model roles they need, then uncomment:                          -- EDIT ME
-- ---------------------------------------------------------------------------
-- ALTER ACCOUNT SET CORTEX_MODELS_ALLOWLIST = 'None';
-- SHOW PARAMETERS LIKE 'CORTEX_MODELS_ALLOWLIST' IN ACCOUNT;

-- Test as an analyst (an approved model works, a non-granted model fails once the allowlist is 'None'):
-- USE ROLE ACCEL_ANALYST;
-- SELECT AI_COMPLETE('llama3.1-70b', 'Reply with the single word OK');
