/* =============================================================================
   28 SECURITY HEALTH CHECK | 02_scoring_procedure.sql
   RUN_SECURITY_HEALTH_CHECK() runs every check in CHECK_CATALOG and writes
     FINDINGS     : one row per issue (check, severity, object, detail, recommendation)
     CHECK_RESULTS: PASS / FAIL / ERROR per check per run
     HC_RUNS      : score per run
   Score = 100 x (weight of passing checks) / (weight of all checks that ran).
   A check passes when it has no findings above INFO.
   SEC-07 (network policies) uses ACCOUNT_USAGE.NETWORK_POLICIES plus
   SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT. If the role cannot read the
   account parameter, an INFO finding says so.
   TASK_SECURITY_HEALTH_WEEKLY: created suspended.
   Run as: ACCEL_ADMIN. Prerequisite: 01_security_checks.sql.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SECURITY_HC;
USE SCHEMA SECURITY_HC;

CREATE TABLE IF NOT EXISTS HC_RUNS (
  RUN_ID          VARCHAR,
  RUN_TS          TIMESTAMP_LTZ,
  RUN_BY          VARCHAR,
  RUN_ROLE        VARCHAR,
  SCORE           NUMBER(5,1),
  CHECKS_RUN      NUMBER,
  CHECKS_FAILED   NUMBER,
  CRITICAL        NUMBER,
  HIGH            NUMBER,
  MEDIUM          NUMBER,
  LOW             NUMBER
);

CREATE TABLE IF NOT EXISTS CHECK_RESULTS (
  RUN_ID     VARCHAR,
  RUN_TS     TIMESTAMP_LTZ,
  CHECK_ID   VARCHAR,
  STATUS     VARCHAR,     -- PASS | FAIL | ERROR
  FINDINGS   NUMBER,
  WEIGHT     NUMBER,
  MESSAGE    VARCHAR
);

CREATE TABLE IF NOT EXISTS FINDINGS (
  RUN_ID          VARCHAR,
  RUN_TS          TIMESTAMP_LTZ,
  CHECK_ID        VARCHAR,
  CHECK_NAME      VARCHAR,
  CATEGORY        VARCHAR,
  SEVERITY        VARCHAR,     -- CRITICAL | HIGH | MEDIUM | LOW | INFO
  OBJECT_TYPE     VARCHAR,
  OBJECT_NAME     VARCHAR,
  DETAIL          VARCHAR,
  RECOMMENDATION  VARCHAR
);

CREATE OR REPLACE PROCEDURE RUN_SECURITY_HEALTH_CHECK()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  run_id    VARCHAR;
  run_ts    TIMESTAMP_LTZ;
  cid       VARCHAR;
  cname     VARCHAR;
  ccat      VARCHAR;
  cweight   NUMBER;
  creco     VARCHAR;
  csql      VARCHAR;
  n_find    INTEGER;
  n_pol     INTEGER DEFAULT 0;
  n_open    INTEGER DEFAULT 0;
  acct_pol  VARCHAR;
  status    VARCHAR;
  msg       VARCHAR;
  score     NUMBER(5,1);
  c1 CURSOR FOR
    SELECT CHECK_ID, CHECK_NAME, CATEGORY, WEIGHT, RECOMMENDATION, CHECK_SQL
    FROM ACCEL_DB.SECURITY_HC.CHECK_CATALOG ORDER BY CHECK_ID;
BEGIN
  run_id := UUID_STRING();
  run_ts := CURRENT_TIMESTAMP();

  FOR rec IN c1 DO
    cid := rec.CHECK_ID;  cname := rec.CHECK_NAME;  ccat := rec.CATEGORY;
    cweight := rec.WEIGHT; creco := rec.RECOMMENDATION; csql := rec.CHECK_SQL;
    msg := NULL;
    BEGIN
      IF (csql IS NOT NULL) THEN
        -- Generic SQL check: columns 1-4 = SEVERITY, OBJECT_TYPE, OBJECT_NAME, DETAIL
        EXECUTE IMMEDIATE :csql;
        INSERT INTO ACCEL_DB.SECURITY_HC.FINDINGS
        SELECT :run_id, :run_ts, :cid, :cname, :ccat, $1::VARCHAR, $2::VARCHAR, $3::VARCHAR, $4::VARCHAR, :creco
        FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
      ELSEIF (cid = 'SEC-07') THEN
        -- Network policies: do any exist, are any wide open, is one attached to the account?
        SELECT COUNT(*), COUNT_IF(ALLOWED_IP_LIST ILIKE '%0.0.0.0/0%')
          INTO :n_pol, :n_open
        FROM SNOWFLAKE.ACCOUNT_USAGE.NETWORK_POLICIES WHERE DELETED IS NULL;
        IF (n_pol = 0) THEN
          INSERT INTO ACCEL_DB.SECURITY_HC.FINDINGS
          SELECT :run_id, :run_ts, :cid, :cname, :ccat, 'HIGH', 'ACCOUNT', CURRENT_ACCOUNT_NAME(),
                 'No network policies exist: Snowflake is reachable from any IP address', :creco;
        END IF;
        IF (n_open > 0) THEN
          INSERT INTO ACCEL_DB.SECURITY_HC.FINDINGS
          SELECT :run_id, :run_ts, :cid, :cname, :ccat, 'MEDIUM', 'NETWORK_POLICY', NAME,
                 'Allowed IP list contains 0.0.0.0/0', :creco
          FROM SNOWFLAKE.ACCOUNT_USAGE.NETWORK_POLICIES
          WHERE DELETED IS NULL AND ALLOWED_IP_LIST ILIKE '%0.0.0.0/0%';
        END IF;
        IF (n_pol > 0) THEN
          BEGIN
            SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT;
            SELECT MAX("value"::VARCHAR) INTO :acct_pol FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
            IF (COALESCE(acct_pol, '') = '') THEN
              INSERT INTO ACCEL_DB.SECURITY_HC.FINDINGS
              SELECT :run_id, :run_ts, :cid, :cname, :ccat, 'HIGH', 'ACCOUNT', CURRENT_ACCOUNT_NAME(),
                     :n_pol || ' network policies exist but none is attached at account level', :creco;
            END IF;
          EXCEPTION
            WHEN OTHER THEN
              INSERT INTO ACCEL_DB.SECURITY_HC.FINDINGS
              SELECT :run_id, :run_ts, :cid, :cname, :ccat, 'INFO', 'ACCOUNT', CURRENT_ACCOUNT_NAME(),
                     'Could not read the account NETWORK_POLICY parameter with role ' || CURRENT_ROLE()
                     || '; run as SECURITYADMIN / ACCOUNTADMIN to verify attachment', :creco;
          END;
        END IF;
      END IF;

      SELECT COUNT(*) INTO :n_find FROM ACCEL_DB.SECURITY_HC.FINDINGS
      WHERE RUN_ID = :run_id AND CHECK_ID = :cid AND SEVERITY <> 'INFO';
      status := IFF(n_find = 0, 'PASS', 'FAIL');
    EXCEPTION
      WHEN OTHER THEN
        status := 'ERROR';
        n_find := 0;
        msg    := SQLERRM;
    END;
    INSERT INTO ACCEL_DB.SECURITY_HC.CHECK_RESULTS
    SELECT :run_id, :run_ts, :cid, :status, :n_find, :cweight, :msg;
  END FOR;

  SELECT ROUND(100 * SUM(IFF(STATUS = 'PASS', WEIGHT, 0)) / NULLIF(SUM(WEIGHT), 0), 1)
    INTO :score
  FROM ACCEL_DB.SECURITY_HC.CHECK_RESULTS
  WHERE RUN_ID = :run_id AND STATUS <> 'ERROR';

  INSERT INTO ACCEL_DB.SECURITY_HC.HC_RUNS
  SELECT :run_id, :run_ts, CURRENT_USER(), CURRENT_ROLE(), :score,
         (SELECT COUNT(*)       FROM ACCEL_DB.SECURITY_HC.CHECK_RESULTS WHERE RUN_ID = :run_id AND STATUS <> 'ERROR'),
         (SELECT COUNT_IF(STATUS = 'FAIL') FROM ACCEL_DB.SECURITY_HC.CHECK_RESULTS WHERE RUN_ID = :run_id),
         COUNT_IF(SEVERITY = 'CRITICAL'), COUNT_IF(SEVERITY = 'HIGH'),
         COUNT_IF(SEVERITY = 'MEDIUM'),   COUNT_IF(SEVERITY = 'LOW')
  FROM ACCEL_DB.SECURITY_HC.FINDINGS WHERE RUN_ID = :run_id;

  RETURN 'Security score ' || COALESCE(TO_VARCHAR(score), 'n/a') || ' / 100 (run ' || run_id || ')';
END;
$$;

-- Weekly run (created suspended)
CREATE OR REPLACE TASK TASK_SECURITY_HEALTH_WEEKLY
  WAREHOUSE = ACCEL_WH
  SCHEDULE = 'USING CRON 0 7 * * 1 Asia/Kolkata'   -- EDIT ME: Mondays 07:00 IST
AS
  CALL ACCEL_DB.SECURITY_HC.RUN_SECURITY_HEALTH_CHECK();
-- ALTER TASK TASK_SECURITY_HEALTH_WEEKLY RESUME;

CALL RUN_SECURITY_HEALTH_CHECK();

SELECT * FROM HC_RUNS ORDER BY RUN_TS DESC LIMIT 5;
