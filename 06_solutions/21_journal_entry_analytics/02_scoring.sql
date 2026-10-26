/*=============================================================================
  ACCELERATOR 21 - Journal Entry Analytics
  File 02 : Scoring procedure -> JE_RISK_SCORES (score + reasons per journal)
  Creates : SP_SCORE_JOURNALS()  (re-scores the whole population from JE_RISK_RULES)
            JE_HEADER            materialised journal headers
            JE_BENFORD_DIGITS    first-digit distribution per user (observed vs Benford)
            JE_USER_BENFORD      MAD per user, Nigrini conformity band, flag
            JE_RULE_HITS         one row per journal x rule hit, with a reason text
            JE_RISK_SCORES       one row per journal: score 0-100, band, rules, reasons
            V_JE_RULE_SUMMARY, V_JE_USER_RISK
  Run as  : ACCEL_ADMIN
  Rerun   : safe. Rerun CALL SP_SCORE_JOURNALS() after changing JE_RISK_RULES.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS JE_ANALYTICS;
USE SCHEMA JE_ANALYTICS;

CREATE TABLE IF NOT EXISTS JE_RULE_HITS (
    JOURNAL_ID  NUMBER,
    RULE_CODE   VARCHAR,
    WEIGHT      NUMBER,
    DETAIL      VARCHAR
) COMMENT = 'Journal x rule hits with the reason text';

CREATE OR REPLACE PROCEDURE SP_SCORE_JOURNALS()
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    n_journals NUMBER DEFAULT 0;
    n_hits     NUMBER DEFAULT 0;
    n_high     NUMBER DEFAULT 0;
BEGIN
    --------------------------------------------------------------------------
    -- Journal headers (materialised once per run)
    --------------------------------------------------------------------------
    CREATE OR REPLACE TABLE ACCEL_DB.JE_ANALYTICS.JE_HEADER AS
    SELECT * FROM ACCEL_DB.JE_ANALYTICS.V_JE_HEADER;

    --------------------------------------------------------------------------
    -- Benford first-digit test per user (lines with |amount| >= 10)
    --------------------------------------------------------------------------
    CREATE OR REPLACE TABLE ACCEL_DB.JE_ANALYTICS.JE_BENFORD_DIGITS AS
    WITH d AS (
        SELECT CREATED_BY,
               TO_NUMBER(LEFT(TO_VARCHAR(FLOOR(ABS(AMOUNT))), 1)) AS DIGIT
        FROM ACCEL_DB.JE_ANALYTICS.V_GL_SCOPE
        WHERE ABS(AMOUNT) >= 10
    ),
    digits AS (
        SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS DIGIT FROM TABLE(GENERATOR(ROWCOUNT => 9))
    ),
    users AS (
        SELECT CREATED_BY, COUNT(*) AS N_LINES FROM d GROUP BY CREATED_BY
    ),
    obs AS (
        SELECT CREATED_BY, DIGIT, COUNT(*) AS CNT FROM d GROUP BY CREATED_BY, DIGIT
    )
    SELECT u.CREATED_BY, g.DIGIT, u.N_LINES,
           COALESCE(o.CNT, 0)                     AS OBSERVED_COUNT,
           COALESCE(o.CNT, 0) / u.N_LINES         AS OBSERVED_PCT,
           LOG(10, 1 + 1 / g.DIGIT)               AS BENFORD_PCT
    FROM users u
    CROSS JOIN digits g
    LEFT JOIN obs o ON o.CREATED_BY = u.CREATED_BY AND o.DIGIT = g.DIGIT;

    CREATE OR REPLACE TABLE ACCEL_DB.JE_ANALYTICS.JE_USER_BENFORD AS
    WITH m AS (
        SELECT CREATED_BY, MAX(N_LINES) AS N_LINES, AVG(ABS(OBSERVED_PCT - BENFORD_PCT)) AS MAD
        FROM ACCEL_DB.JE_ANALYTICS.JE_BENFORD_DIGITS
        GROUP BY CREATED_BY
    ),
    r AS (
        SELECT PARAM_1 AS MAD_MULTIPLE, PARAM_2 AS MIN_LINES
        FROM ACCEL_DB.JE_ANALYTICS.JE_RISK_RULES WHERE RULE_CODE = 'BENFORD_USER'
    ),
    med AS (
        SELECT MEDIAN(m.MAD) AS MEDIAN_MAD FROM m CROSS JOIN r WHERE m.N_LINES >= r.MIN_LINES
    )
    SELECT m.CREATED_BY, m.N_LINES, ROUND(m.MAD, 5) AS MAD, ROUND(med.MEDIAN_MAD, 5) AS PEER_MEDIAN_MAD,
           CASE WHEN m.MAD < 0.006 THEN 'Close conformity'          -- Nigrini first-digit MAD bands
                WHEN m.MAD < 0.012 THEN 'Acceptable conformity'
                WHEN m.MAD < 0.015 THEN 'Marginal conformity'
                ELSE 'Nonconformity' END AS NIGRINI_BAND,
           (m.N_LINES >= r.MIN_LINES AND m.MAD > r.MAD_MULTIPLE * med.MEDIAN_MAD) AS IS_FLAGGED
    FROM m CROSS JOIN r CROSS JOIN med;

    --------------------------------------------------------------------------
    -- Rule hits
    --------------------------------------------------------------------------
    TRUNCATE TABLE ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS;

    -- Weekend posting
    INSERT INTO ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS
    SELECT h.JOURNAL_ID, r.RULE_CODE, r.WEIGHT,
           'Posted ' || DAYNAME(h.POSTING_DATE) || ' ' || TO_VARCHAR(h.POSTING_DATE, 'YYYY-MM-DD')
             || ', entered ' || DAYNAME(h.ENTRY_TIMESTAMP)
    FROM ACCEL_DB.JE_ANALYTICS.JE_HEADER h
    JOIN ACCEL_DB.JE_ANALYTICS.JE_RISK_RULES r ON r.RULE_CODE = 'WEEKEND' AND r.IS_ACTIVE
    WHERE DAYOFWEEKISO(h.POSTING_DATE) IN (6, 7) OR DAYOFWEEKISO(h.ENTRY_TIMESTAMP) IN (6, 7);

    -- After-hours entry
    INSERT INTO ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS
    SELECT h.JOURNAL_ID, r.RULE_CODE, r.WEIGHT,
           'Entered at ' || TO_VARCHAR(h.ENTRY_TIMESTAMP, 'HH24:MI')
    FROM ACCEL_DB.JE_ANALYTICS.JE_HEADER h
    JOIN ACCEL_DB.JE_ANALYTICS.JE_RISK_RULES r ON r.RULE_CODE = 'AFTER_HOURS' AND r.IS_ACTIVE
    WHERE HOUR(h.ENTRY_TIMESTAMP) >= r.PARAM_1 OR HOUR(h.ENTRY_TIMESTAMP) < r.PARAM_2;

    -- Round amounts (any line)
    INSERT INTO ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS
    SELECT g.JOURNAL_ID, r.RULE_CODE, r.WEIGHT,
           'Round line amount ' || TO_VARCHAR(MAX(ABS(g.AMOUNT))) || ' ' || ANY_VALUE(g.CURRENCY)
    FROM ACCEL_DB.JE_ANALYTICS.V_GL_SCOPE g
    JOIN ACCEL_DB.JE_ANALYTICS.JE_RISK_RULES r ON r.RULE_CODE = 'ROUND_AMOUNT' AND r.IS_ACTIVE
    WHERE ABS(g.AMOUNT) >= r.PARAM_1
      AND MOD(ABS(g.AMOUNT), r.PARAM_2) = 0
    GROUP BY g.JOURNAL_ID, r.RULE_CODE, r.WEIGHT;

    -- Self-approval
    INSERT INTO ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS
    SELECT h.JOURNAL_ID, r.RULE_CODE, r.WEIGHT,
           'Created and approved by ' || h.CREATED_BY
    FROM ACCEL_DB.JE_ANALYTICS.JE_HEADER h
    JOIN ACCEL_DB.JE_ANALYTICS.JE_RISK_RULES r ON r.RULE_CODE = 'SELF_APPROVAL' AND r.IS_ACTIVE
    WHERE h.CREATED_BY = h.APPROVED_BY;

    -- Manual entries to revenue
    INSERT INTO ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS
    SELECT h.JOURNAL_ID, r.RULE_CODE, r.WEIGHT,
           h.SOURCE || ' journal posting to a revenue account (' || TO_VARCHAR(h.TOTAL_DEBIT) || ' ' || h.CURRENCY || ')'
    FROM ACCEL_DB.JE_ANALYTICS.JE_HEADER h
    JOIN ACCEL_DB.JE_ANALYTICS.JE_RISK_RULES r ON r.RULE_CODE = 'MANUAL_REVENUE' AND r.IS_ACTIVE
    WHERE h.SOURCE = r.PARAM_TEXT AND h.HAS_REVENUE_LINE;

    -- Just below the approval threshold
    INSERT INTO ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS
    SELECT h.JOURNAL_ID, r.RULE_CODE, r.WEIGHT,
           'USD ' || TO_VARCHAR(ROUND(h.TOTAL_DEBIT_USD)) || ' = ' || TO_VARCHAR(ROUND(100 * h.TOTAL_DEBIT_USD / r.PARAM_1, 1))
             || '% of the USD ' || TO_VARCHAR(r.PARAM_1::NUMBER) || ' approval limit'
    FROM ACCEL_DB.JE_ANALYTICS.JE_HEADER h
    JOIN ACCEL_DB.JE_ANALYTICS.JE_RISK_RULES r ON r.RULE_CODE = 'JUST_BELOW_THRESHOLD' AND r.IS_ACTIVE
    WHERE h.TOTAL_DEBIT_USD >= r.PARAM_1 * (1 - r.PARAM_2)
      AND h.TOTAL_DEBIT_USD <  r.PARAM_1;

    -- Unusual debit / credit account combinations
    INSERT INTO ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS
    WITH pairs AS (
        SELECT DISTINCT d.JOURNAL_ID, d.ACCOUNT_CODE AS DR_ACC, c.ACCOUNT_CODE AS CR_ACC,
               d.ACCOUNT_NAME AS DR_NAME, c.ACCOUNT_NAME AS CR_NAME
        FROM ACCEL_DB.JE_ANALYTICS.V_GL_SCOPE d
        JOIN ACCEL_DB.JE_ANALYTICS.V_GL_SCOPE c
          ON c.JOURNAL_ID = d.JOURNAL_ID AND d.AMOUNT > 0 AND c.AMOUNT < 0
    ),
    freq AS (
        SELECT DR_ACC, CR_ACC, COUNT(*) AS N_JOURNALS FROM pairs GROUP BY DR_ACC, CR_ACC
    )
    SELECT p.JOURNAL_ID, r.RULE_CODE, r.WEIGHT,
           'Rare pair Dr ' || p.DR_ACC || ' ' || p.DR_NAME || ' / Cr ' || p.CR_ACC || ' ' || p.CR_NAME
             || ' (used in ' || TO_VARCHAR(f.N_JOURNALS) || ' journal(s))'
    FROM pairs p
    JOIN freq f ON f.DR_ACC = p.DR_ACC AND f.CR_ACC = p.CR_ACC
    JOIN ACCEL_DB.JE_ANALYTICS.JE_RISK_RULES r ON r.RULE_CODE = 'UNUSUAL_ACCOUNT_COMBO' AND r.IS_ACTIVE
    WHERE f.N_JOURNALS <= r.PARAM_1
    QUALIFY ROW_NUMBER() OVER (PARTITION BY p.JOURNAL_ID ORDER BY f.N_JOURNALS, p.DR_ACC, p.CR_ACC) = 1;

    -- Benford deviation by user (every journal of a flagged user gets a small weight)
    INSERT INTO ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS
    SELECT h.JOURNAL_ID, r.RULE_CODE, r.WEIGHT,
           'User ' || h.CREATED_BY || ' first-digit MAD ' || TO_VARCHAR(b.MAD) || ' vs peer median '
             || TO_VARCHAR(b.PEER_MEDIAN_MAD) || ' (' || b.NIGRINI_BAND || ')'
    FROM ACCEL_DB.JE_ANALYTICS.JE_HEADER h
    JOIN ACCEL_DB.JE_ANALYTICS.JE_USER_BENFORD b ON b.CREATED_BY = h.CREATED_BY AND b.IS_FLAGGED
    JOIN ACCEL_DB.JE_ANALYTICS.JE_RISK_RULES r ON r.RULE_CODE = 'BENFORD_USER' AND r.IS_ACTIVE;

    -- Z-score of the journal total against the user's own history
    INSERT INTO ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS
    WITH s AS (
        SELECT CREATED_BY, AVG(TOTAL_DEBIT_USD) AS MU, STDDEV(TOTAL_DEBIT_USD) AS SD, COUNT(*) AS N
        FROM ACCEL_DB.JE_ANALYTICS.JE_HEADER
        GROUP BY CREATED_BY
    )
    SELECT h.JOURNAL_ID, r.RULE_CODE, r.WEIGHT,
           'USD ' || TO_VARCHAR(ROUND(h.TOTAL_DEBIT_USD)) || ' is ' || TO_VARCHAR(ROUND((h.TOTAL_DEBIT_USD - s.MU) / s.SD, 1))
             || ' std devs from ' || h.CREATED_BY || '''s mean of USD ' || TO_VARCHAR(ROUND(s.MU))
    FROM ACCEL_DB.JE_ANALYTICS.JE_HEADER h
    JOIN s ON s.CREATED_BY = h.CREATED_BY
    JOIN ACCEL_DB.JE_ANALYTICS.JE_RISK_RULES r ON r.RULE_CODE = 'ZSCORE_USER' AND r.IS_ACTIVE
    WHERE s.N >= r.PARAM_2
      AND s.SD > 0
      AND ABS((h.TOTAL_DEBIT_USD - s.MU) / s.SD) > r.PARAM_1;

    -- Possible duplicates (the later journal is flagged)
    INSERT INTO ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS
    SELECT b.JOURNAL_ID, r.RULE_CODE, r.WEIGHT,
           'Same entity, accounts and amounts as journal ' || TO_VARCHAR(a.JOURNAL_ID) || ' posted '
             || TO_VARCHAR(DATEDIFF(DAY, a.POSTING_DATE, b.POSTING_DATE)) || ' day(s) earlier'
    FROM ACCEL_DB.JE_ANALYTICS.JE_HEADER a
    JOIN ACCEL_DB.JE_ANALYTICS.JE_HEADER b
      ON  b.ENTITY = a.ENTITY
      AND b.LINE_SIGNATURE = a.LINE_SIGNATURE
      AND b.JOURNAL_ID <> a.JOURNAL_ID
      AND (a.POSTING_DATE < b.POSTING_DATE OR (a.POSTING_DATE = b.POSTING_DATE AND a.JOURNAL_ID < b.JOURNAL_ID))
    JOIN ACCEL_DB.JE_ANALYTICS.JE_RISK_RULES r ON r.RULE_CODE = 'DUPLICATE' AND r.IS_ACTIVE
    WHERE DATEDIFF(DAY, a.POSTING_DATE, b.POSTING_DATE) <= r.PARAM_1
    QUALIFY ROW_NUMBER() OVER (PARTITION BY b.JOURNAL_ID ORDER BY a.POSTING_DATE DESC, a.JOURNAL_ID DESC) = 1;

    --------------------------------------------------------------------------
    -- Scores: every journal (0 = no rule hit), capped at 100
    --------------------------------------------------------------------------
    CREATE OR REPLACE TABLE ACCEL_DB.JE_ANALYTICS.JE_RISK_SCORES AS
    SELECT h.JOURNAL_ID, h.ENTITY, h.POSTING_DATE, h.ENTRY_TIMESTAMP, h.CREATED_BY, h.APPROVED_BY,
           h.SOURCE, h.CURRENCY, h.DESCRIPTION, h.ORIGIN, h.N_LINES, h.TOTAL_DEBIT, h.TOTAL_DEBIT_USD,
           LEAST(100, COALESCE(SUM(x.WEIGHT), 0))                     AS RISK_SCORE,
           CASE WHEN LEAST(100, COALESCE(SUM(x.WEIGHT), 0)) >= 50 THEN 'High'      -- EDIT ME: band cut-offs
                WHEN LEAST(100, COALESCE(SUM(x.WEIGHT), 0)) >= 25 THEN 'Medium'
                WHEN LEAST(100, COALESCE(SUM(x.WEIGHT), 0)) >  0  THEN 'Low'
                ELSE 'None' END                                       AS RISK_BAND,
           COUNT(x.RULE_CODE)                                         AS RULES_HIT,
           ARRAY_AGG(x.RULE_CODE) WITHIN GROUP (ORDER BY x.WEIGHT DESC, x.RULE_CODE) AS RULE_CODES,
           LISTAGG(x.RULE_CODE || ': ' || x.DETAIL, ' | ') WITHIN GROUP (ORDER BY x.WEIGHT DESC, x.RULE_CODE) AS REASONS,
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ                         AS SCORED_AT
    FROM ACCEL_DB.JE_ANALYTICS.JE_HEADER h
    LEFT JOIN ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS x ON x.JOURNAL_ID = h.JOURNAL_ID
    GROUP BY h.JOURNAL_ID, h.ENTITY, h.POSTING_DATE, h.ENTRY_TIMESTAMP, h.CREATED_BY, h.APPROVED_BY,
             h.SOURCE, h.CURRENCY, h.DESCRIPTION, h.ORIGIN, h.N_LINES, h.TOTAL_DEBIT, h.TOTAL_DEBIT_USD;

    SELECT COUNT(*), COUNT_IF(RISK_BAND = 'High') INTO :n_journals, :n_high FROM ACCEL_DB.JE_ANALYTICS.JE_RISK_SCORES;
    SELECT COUNT(*) INTO :n_hits FROM ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS;

    RETURN OBJECT_CONSTRUCT('journals_scored', n_journals, 'rule_hits', n_hits, 'high_risk_journals', n_high);
END;
$$;

CALL SP_SCORE_JOURNALS();

------------------------------------------------------------------------------
-- Summary views
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_JE_RULE_SUMMARY AS
SELECT r.RULE_CODE, r.RULE_NAME, r.CATEGORY, r.WEIGHT, r.IS_ACTIVE,
       COUNT(DISTINCT x.JOURNAL_ID)                                         AS JOURNALS_FLAGGED,
       COUNT(DISTINCT IFF(s.ORIGIN = 'Seeded test case', x.JOURNAL_ID, NULL)) AS SEEDED_CASES_FLAGGED
FROM ACCEL_DB.JE_ANALYTICS.JE_RISK_RULES r
LEFT JOIN ACCEL_DB.JE_ANALYTICS.JE_RULE_HITS x ON x.RULE_CODE = r.RULE_CODE
LEFT JOIN ACCEL_DB.JE_ANALYTICS.JE_RISK_SCORES s ON s.JOURNAL_ID = x.JOURNAL_ID
GROUP BY r.RULE_CODE, r.RULE_NAME, r.CATEGORY, r.WEIGHT, r.IS_ACTIVE;

CREATE OR REPLACE VIEW V_JE_USER_RISK AS
SELECT s.CREATED_BY,
       COUNT(*)                                   AS JOURNALS,
       COUNT_IF(s.RISK_BAND = 'High')             AS HIGH_RISK,
       COUNT_IF(s.RISK_BAND = 'Medium')           AS MEDIUM_RISK,
       ROUND(AVG(s.RISK_SCORE), 1)                AS AVG_SCORE,
       ROUND(SUM(s.TOTAL_DEBIT_USD), 0)           AS TOTAL_USD,
       ANY_VALUE(b.MAD)                           AS BENFORD_MAD,
       ANY_VALUE(b.NIGRINI_BAND)                  AS BENFORD_BAND
FROM ACCEL_DB.JE_ANALYTICS.JE_RISK_SCORES s
LEFT JOIN ACCEL_DB.JE_ANALYTICS.JE_USER_BENFORD b ON b.CREATED_BY = s.CREATED_BY
GROUP BY s.CREATED_BY;

------------------------------------------------------------------------------
-- Results
------------------------------------------------------------------------------
SELECT * FROM V_JE_RULE_SUMMARY ORDER BY JOURNALS_FLAGGED DESC;

SELECT RISK_BAND, COUNT(*) AS JOURNALS, ROUND(SUM(TOTAL_DEBIT_USD)) AS TOTAL_USD
FROM JE_RISK_SCORES GROUP BY RISK_BAND ORDER BY MIN(RISK_SCORE) DESC;

SELECT JOURNAL_ID, ENTITY, POSTING_DATE, CREATED_BY, APPROVED_BY, SOURCE, TOTAL_DEBIT_USD, RISK_SCORE, REASONS
FROM JE_RISK_SCORES
ORDER BY RISK_SCORE DESC, TOTAL_DEBIT_USD DESC
LIMIT 25;

-- Every seeded test case must be flagged (expect 0 rows)
SELECT JOURNAL_ID, DESCRIPTION FROM JE_RISK_SCORES
WHERE ORIGIN = 'Seeded test case' AND RISK_SCORE = 0;
