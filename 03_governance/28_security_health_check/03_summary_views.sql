/* =============================================================================
   28 SECURITY HEALTH CHECK | 03_summary_views.sql
   V_LATEST_FINDINGS   : findings from the latest run, worst first
   V_SECURITY_SUMMARY  : one row per check for the latest run (status, counts by
                         severity, recommendation), the executive checklist
   V_SECURITY_SCORE_TREND : score and severity counts per run
   Run as: ACCEL_ADMIN. Prerequisite: 02_scoring_procedure.sql.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SECURITY_HC;
USE SCHEMA SECURITY_HC;

CREATE OR REPLACE VIEW V_LATEST_RUN AS
SELECT * FROM HC_RUNS
QUALIFY ROW_NUMBER() OVER (ORDER BY RUN_TS DESC) = 1;

CREATE OR REPLACE VIEW V_LATEST_FINDINGS AS
SELECT f.CHECK_ID, f.CHECK_NAME, f.CATEGORY, f.SEVERITY, f.OBJECT_TYPE, f.OBJECT_NAME, f.DETAIL, f.RECOMMENDATION, f.RUN_TS
FROM FINDINGS f
JOIN V_LATEST_RUN r ON r.RUN_ID = f.RUN_ID
ORDER BY CASE f.SEVERITY WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 4 ELSE 5 END,
         f.CHECK_ID, f.OBJECT_NAME;

CREATE OR REPLACE VIEW V_SECURITY_SUMMARY AS
SELECT c.CHECK_ID, c.CHECK_NAME, c.CATEGORY, c.WEIGHT,
       COALESCE(cr.STATUS, 'NOT RUN')                                AS STATUS,
       COUNT_IF(f.SEVERITY = 'CRITICAL')                             AS CRITICAL,
       COUNT_IF(f.SEVERITY = 'HIGH')                                 AS HIGH,
       COUNT_IF(f.SEVERITY = 'MEDIUM')                               AS MEDIUM,
       COUNT_IF(f.SEVERITY = 'LOW')                                  AS LOW,
       COUNT_IF(f.SEVERITY = 'INFO')                                 AS INFO,
       c.RECOMMENDATION,
       cr.MESSAGE                                                    AS ERROR_MESSAGE,
       r.RUN_TS                                                      AS LAST_RUN,
       r.SCORE                                                       AS OVERALL_SCORE
FROM CHECK_CATALOG c
CROSS JOIN V_LATEST_RUN r
LEFT JOIN CHECK_RESULTS cr ON cr.RUN_ID = r.RUN_ID AND cr.CHECK_ID = c.CHECK_ID
LEFT JOIN FINDINGS f       ON f.RUN_ID = r.RUN_ID AND f.CHECK_ID = c.CHECK_ID
GROUP BY c.CHECK_ID, c.CHECK_NAME, c.CATEGORY, c.WEIGHT, cr.STATUS, c.RECOMMENDATION, cr.MESSAGE, r.RUN_TS, r.SCORE;

CREATE OR REPLACE VIEW V_SECURITY_SCORE_TREND AS
SELECT RUN_TS, SCORE, CHECKS_RUN, CHECKS_FAILED, CRITICAL, HIGH, MEDIUM, LOW, RUN_BY, RUN_ROLE
FROM HC_RUNS;

-- Results are security-sensitive: share them with security / admin roles only.  -- EDIT ME
GRANT SELECT ON VIEW V_SECURITY_SUMMARY     TO ROLE ACCEL_ANALYST;
GRANT SELECT ON VIEW V_SECURITY_SCORE_TREND TO ROLE ACCEL_ANALYST;

SELECT OVERALL_SCORE, CHECK_ID, CHECK_NAME, STATUS, CRITICAL, HIGH, MEDIUM, LOW
FROM V_SECURITY_SUMMARY ORDER BY CHECK_ID;

SELECT * FROM V_LATEST_FINDINGS LIMIT 100;
