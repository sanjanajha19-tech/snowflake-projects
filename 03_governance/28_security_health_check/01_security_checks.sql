/* =============================================================================
   28 SECURITY HEALTH CHECK | 01_security_checks.sql
   V_USERS          : active users with normalised auth flags + auth method class
   V_AUTH_METHOD_MIX_30D : how people actually logged in (LOGIN_HISTORY)
   CHECK_CATALOG    : the checks. Each SQL check returns rows of
                      (SEVERITY, OBJECT_TYPE, OBJECT_NAME, DETAIL); zero rows = pass.
   Checks: MFA, ACCOUNTADMIN holders, password vs key-pair/SSO, service users,
   inactive users (90 days), network policies, failed logins, grants to PUBLIC,
   MANAGE GRANTS holders, MFA bypass.
   Source: SNOWFLAKE.ACCOUNT_USAGE (USERS, GRANTS_TO_USERS, GRANTS_TO_ROLES,
   LOGIN_HISTORY, NETWORK_POLICIES), latency up to ~2-3 h.
   Run as: ACCEL_ADMIN (IMPORTED PRIVILEGES on SNOWFLAKE from 00_setup).
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SECURITY_HC;
USE SCHEMA SECURITY_HC;

-- Active (not dropped, not disabled) users, booleans normalised
CREATE OR REPLACE VIEW V_USERS AS
WITH u AS (
  SELECT NAME AS USER_NAME, LOGIN_NAME, EMAIL, COALESCE(TYPE, 'PERSON') AS USER_TYPE,
         CREATED_ON, LAST_SUCCESS_LOGIN, DEFAULT_ROLE, BYPASS_MFA_UNTIL, EXT_AUTHN_UID,
         COALESCE(HAS_PASSWORD::VARCHAR, 'false')       ILIKE 'true' AS HAS_PASSWORD,
         COALESCE(HAS_MFA::VARCHAR, 'false')            ILIKE 'true' AS HAS_MFA,
         COALESCE(EXT_AUTHN_DUO::VARCHAR, 'false')      ILIKE 'true' AS EXT_AUTHN_DUO,
         COALESCE(HAS_RSA_PUBLIC_KEY::VARCHAR, 'false') ILIKE 'true' AS HAS_RSA_PUBLIC_KEY,
         COALESCE(HAS_PAT::VARCHAR, 'false')            ILIKE 'true' AS HAS_PAT
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  WHERE DELETED_ON IS NULL
    AND NOT (COALESCE(DISABLED::VARCHAR, 'false') ILIKE 'true')
    AND NAME <> 'SNOWFLAKE'            -- built-in Snowflake support user
)
SELECT u.*,
       (HAS_MFA OR EXT_AUTHN_DUO) AS MFA_ENROLLED,
       CASE WHEN HAS_PASSWORD AND (HAS_MFA OR EXT_AUTHN_DUO) THEN 'PASSWORD + MFA'
            WHEN HAS_PASSWORD AND HAS_RSA_PUBLIC_KEY        THEN 'PASSWORD + KEY-PAIR'
            WHEN HAS_PASSWORD                               THEN 'PASSWORD ONLY'
            WHEN HAS_RSA_PUBLIC_KEY                         THEN 'KEY-PAIR'
            WHEN HAS_PAT                                    THEN 'PAT'
            ELSE 'SSO / OAUTH / NO CREDENTIAL' END AS AUTH_CLASS
FROM u;

CREATE OR REPLACE VIEW V_AUTH_INVENTORY AS
SELECT USER_TYPE, AUTH_CLASS, COUNT(*) AS USERS
FROM V_USERS GROUP BY 1, 2;

CREATE OR REPLACE VIEW V_AUTH_METHOD_MIX_30D AS
SELECT FIRST_AUTHENTICATION_FACTOR,
       COALESCE(SECOND_AUTHENTICATION_FACTOR, '(none)') AS SECOND_AUTHENTICATION_FACTOR,
       IS_SUCCESS, COUNT(*) AS LOGINS, COUNT(DISTINCT USER_NAME) AS USERS
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE EVENT_TIMESTAMP >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3;

-- Direct holders of the high-privilege roles
CREATE OR REPLACE VIEW V_PRIVILEGED_USERS AS
SELECT g.ROLE, g.GRANTEE_NAME AS USER_NAME, g.CREATED_ON AS GRANTED_ON_TS, g.GRANTED_BY,
       u.USER_TYPE, u.AUTH_CLASS, u.MFA_ENROLLED, u.LAST_SUCCESS_LOGIN
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS g
LEFT JOIN V_USERS u ON u.USER_NAME = g.GRANTEE_NAME
WHERE g.DELETED_ON IS NULL
  AND g.ROLE IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN', 'USERADMIN', 'SYSADMIN');

-- ---------------------------------------------------------------------------
-- Check catalog
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE CHECK_CATALOG (
  CHECK_ID        VARCHAR,
  CHECK_NAME      VARCHAR,
  CATEGORY        VARCHAR,     -- AUTHENTICATION | PRIVILEGE | NETWORK | MONITORING | LIFECYCLE
  WEIGHT          NUMBER,      -- contribution to the score
  RECOMMENDATION  VARCHAR,
  CHECK_SQL       VARCHAR      -- NULL = implemented in the procedure (needs SHOW commands)
);

INSERT INTO CHECK_CATALOG VALUES
('SEC-01', 'Human users with a password but no MFA', 'AUTHENTICATION', 10,
 'Enforce MFA for all password users (CREATE AUTHENTICATION POLICY ... MFA_ENROLLMENT = REQUIRED) or move them to SSO; Snowflake is phasing out single-factor password sign-in.',
 $$SELECT 'HIGH' AS SEVERITY, 'USER' AS OBJECT_TYPE, USER_NAME AS OBJECT_NAME,
          'Password user without MFA; last login ' || COALESCE(TO_VARCHAR(LAST_SUCCESS_LOGIN, 'YYYY-MM-DD'), 'never') AS DETAIL
   FROM ACCEL_DB.SECURITY_HC.V_USERS
   WHERE USER_TYPE = 'PERSON' AND HAS_PASSWORD AND NOT MFA_ENROLLED$$),
('SEC-02', 'ACCOUNTADMIN holders without MFA', 'PRIVILEGE', 15,
 'Every ACCOUNTADMIN holder must use MFA (or SSO with MFA at the IdP). Treat as an emergency fix.',
 $$SELECT 'CRITICAL', 'USER', USER_NAME,
          'Holds ACCOUNTADMIN, auth = ' || COALESCE(AUTH_CLASS, 'unknown') AS DETAIL
   FROM ACCEL_DB.SECURITY_HC.V_PRIVILEGED_USERS
   WHERE ROLE = 'ACCOUNTADMIN' AND AUTH_CLASS IN ('PASSWORD ONLY', 'PASSWORD + KEY-PAIR')$$),
('SEC-03', 'Number of ACCOUNTADMIN holders', 'PRIVILEGE', 8,
 'Keep 2-3 named ACCOUNTADMIN holders (one break-glass). Use SYSADMIN / SECURITYADMIN / custom roles for daily work and never set ACCOUNTADMIN as a default role.',
 $$SELECT IFF(COUNT(*) > 3, 'HIGH', 'MEDIUM'), 'ROLE', 'ACCOUNTADMIN',
          COUNT(*) || ' users hold ACCOUNTADMIN directly: ' || LISTAGG(USER_NAME, ', ') WITHIN GROUP (ORDER BY USER_NAME)
   FROM ACCEL_DB.SECURITY_HC.V_PRIVILEGED_USERS WHERE ROLE = 'ACCOUNTADMIN'
   HAVING COUNT(*) > 3 OR COUNT(*) < 2
   UNION ALL
   SELECT 'MEDIUM', 'USER', USER_NAME, 'DEFAULT_ROLE = ACCOUNTADMIN'
   FROM ACCEL_DB.SECURITY_HC.V_USERS WHERE DEFAULT_ROLE = 'ACCOUNTADMIN'$$),
('SEC-04', 'Service users authenticating with passwords', 'AUTHENTICATION', 8,
 'Set TYPE = SERVICE for applications and use key-pair, OAuth or workload identity; remove passwords (ALTER USER ... UNSET PASSWORD). Migrate LEGACY_SERVICE users.',
 $$SELECT 'HIGH', 'USER', USER_NAME, USER_TYPE || ' user with a password' AS DETAIL
   FROM ACCEL_DB.SECURITY_HC.V_USERS WHERE USER_TYPE IN ('SERVICE', 'LEGACY_SERVICE') AND HAS_PASSWORD
   UNION ALL
   SELECT 'MEDIUM', 'USER', USER_NAME, 'LEGACY_SERVICE user type (being retired)'
   FROM ACCEL_DB.SECURITY_HC.V_USERS WHERE USER_TYPE = 'LEGACY_SERVICE' AND NOT HAS_PASSWORD$$),
('SEC-05', 'Single-factor password logins (30 days)', 'AUTHENTICATION', 6,
 'Users still signing in with password only: enrol MFA or move to SSO / key-pair.',
 $$SELECT 'MEDIUM', 'USER', USER_NAME,
          COUNT(*) || ' successful password-only logins in 30 days; last ' || TO_VARCHAR(MAX(EVENT_TIMESTAMP), 'YYYY-MM-DD')
   FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
   WHERE EVENT_TIMESTAMP >= DATEADD('day', -30, CURRENT_TIMESTAMP())
     AND IS_SUCCESS = 'YES' AND FIRST_AUTHENTICATION_FACTOR = 'PASSWORD'
     AND SECOND_AUTHENTICATION_FACTOR IS NULL
   GROUP BY USER_NAME$$),
('SEC-06', 'Inactive users (90 days)', 'LIFECYCLE', 6,
 'Disable users with no login in 90 days (ALTER USER ... SET DISABLED = TRUE) and drop after review; automate via your IdP / SCIM.',
 $$SELECT IFF(LAST_SUCCESS_LOGIN IS NULL, 'LOW', 'MEDIUM'), 'USER', USER_NAME,
          IFF(LAST_SUCCESS_LOGIN IS NULL,
              'Never logged in; created ' || TO_VARCHAR(CREATED_ON, 'YYYY-MM-DD'),
              'Last login ' || TO_VARCHAR(LAST_SUCCESS_LOGIN, 'YYYY-MM-DD') || ' (' || DATEDIFF('day', LAST_SUCCESS_LOGIN, CURRENT_TIMESTAMP()) || ' days)')
   FROM ACCEL_DB.SECURITY_HC.V_USERS
   WHERE USER_TYPE = 'PERSON'
     AND COALESCE(LAST_SUCCESS_LOGIN, CREATED_ON) < DATEADD('day', -90, CURRENT_TIMESTAMP())$$),
('SEC-07', 'Network policy coverage', 'NETWORK', 10,
 'Create network rules + a network policy and attach it to the account (ALTER ACCOUNT SET NETWORK_POLICY = ...); add stricter user-level policies for service users.',
 NULL),
('SEC-08', 'Repeated failed logins (7 days)', 'MONITORING', 6,
 'Investigate users / IPs with repeated failures (credential stuffing, stale credentials in tools); lock or rotate as needed.',
 $$SELECT IFF(COUNT(*) >= 20, 'HIGH', 'MEDIUM'), 'USER', USER_NAME,
          COUNT(*) || ' failed logins from ' || COUNT(DISTINCT CLIENT_IP) || ' IP(s); top error: ' || MODE(ERROR_MESSAGE)
   FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
   WHERE EVENT_TIMESTAMP >= DATEADD('day', -7, CURRENT_TIMESTAMP()) AND IS_SUCCESS = 'NO'
   GROUP BY USER_NAME HAVING COUNT(*) >= 5
   UNION ALL
   SELECT 'HIGH', 'CLIENT_IP', CLIENT_IP,
          COUNT(*) || ' failed logins against ' || COUNT(DISTINCT USER_NAME) || ' user name(s)'
   FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
   WHERE EVENT_TIMESTAMP >= DATEADD('day', -7, CURRENT_TIMESTAMP()) AND IS_SUCCESS = 'NO'
   GROUP BY CLIENT_IP HAVING COUNT(DISTINCT USER_NAME) >= 5$$),
('SEC-09', 'Privileges granted to PUBLIC', 'PRIVILEGE', 10,
 'Revoke object privileges from PUBLIC and grant them to functional roles instead (REVOKE ... FROM ROLE PUBLIC).',
 $$SELECT IFF(GRANTED_ON IN ('TABLE', 'VIEW', 'MATERIALIZED_VIEW', 'DYNAMIC_TABLE', 'EXTERNAL_TABLE', 'STAGE', 'INTEGRATION'), 'HIGH', 'MEDIUM'),
          GRANTED_ON,
          COALESCE(TABLE_CATALOG || '.', '') || COALESCE(TABLE_SCHEMA || '.', '') || NAME,
          'PUBLIC has: ' || LISTAGG(DISTINCT PRIVILEGE, ', ')
   FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
   WHERE GRANTEE_NAME = 'PUBLIC' AND GRANTED_TO = 'ROLE' AND DELETED_ON IS NULL
     AND COALESCE(TABLE_CATALOG, '') NOT IN ('SNOWFLAKE', 'SNOWFLAKE_SAMPLE_DATA')
     AND NAME NOT IN ('SNOWFLAKE', 'SNOWFLAKE_SAMPLE_DATA')
     AND GRANTED_ON NOT IN ('ROLE', 'DATABASE_ROLE', 'APPLICATION_ROLE')
   GROUP BY GRANTED_ON, TABLE_CATALOG, TABLE_SCHEMA, NAME$$),
('SEC-10', 'Roles holding MANAGE GRANTS', 'PRIVILEGE', 8,
 'MANAGE GRANTS lets a role grant any privilege on any object. Keep it on SECURITYADMIN only; revoke from custom roles (REVOKE MANAGE GRANTS ON ACCOUNT FROM ROLE ...).',
 $$SELECT 'HIGH', 'ROLE', GRANTEE_NAME,
          'MANAGE GRANTS on ACCOUNT, granted by ' || COALESCE(GRANTED_BY, 'unknown') || ' on ' || TO_VARCHAR(CREATED_ON, 'YYYY-MM-DD')
   FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
   WHERE PRIVILEGE = 'MANAGE GRANTS' AND GRANTED_ON = 'ACCOUNT' AND DELETED_ON IS NULL
     AND GRANTEE_NAME NOT IN ('SECURITYADMIN')$$),
('SEC-11', 'Active MFA bypass windows', 'AUTHENTICATION', 4,
 'MFA bypass should be short-lived; remove it (ALTER USER ... SET MINS_TO_BYPASS_MFA = 0) once the user has re-enrolled.',
 $$SELECT 'MEDIUM', 'USER', USER_NAME, 'MFA bypass active until ' || TO_VARCHAR(BYPASS_MFA_UNTIL, 'YYYY-MM-DD HH24:MI')
   FROM ACCEL_DB.SECURITY_HC.V_USERS WHERE BYPASS_MFA_UNTIL > CURRENT_TIMESTAMP()$$),
('SEC-12', 'Privileged role holders without recent login', 'LIFECYCLE', 5,
 'Remove admin roles from users who no longer use them (least privilege); review quarterly.',
 $$SELECT 'MEDIUM', 'USER', USER_NAME, 'Holds ' || ROLE || '; last login ' || COALESCE(TO_VARCHAR(LAST_SUCCESS_LOGIN, 'YYYY-MM-DD'), 'never')
   FROM ACCEL_DB.SECURITY_HC.V_PRIVILEGED_USERS
   WHERE ROLE IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN')
     AND COALESCE(LAST_SUCCESS_LOGIN, '1970-01-01'::TIMESTAMP_LTZ) < DATEADD('day', -90, CURRENT_TIMESTAMP())$$);

GRANT USAGE ON SCHEMA ACCEL_DB.SECURITY_HC TO ROLE ACCEL_ANALYST;   -- analysts see results only via file 03 views

SELECT CHECK_ID, CHECK_NAME, CATEGORY, WEIGHT FROM CHECK_CATALOG ORDER BY CHECK_ID;
SELECT * FROM V_AUTH_INVENTORY ORDER BY USER_TYPE, USERS DESC;
