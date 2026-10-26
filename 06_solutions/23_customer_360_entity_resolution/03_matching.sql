/* =============================================================================
   Asset 23 - Customer 360 & Entity Resolution
   File  03_matching.sql
   Purpose
     1. MATCH_CONFIG     - weights and thresholds (-- EDIT ME)
     2. CANDIDATE_PAIRS  - blocking: only compare records sharing a block key
     3. MATCH_PAIRS      - JAROWINKLER_SIMILARITY + EDITDISTANCE on names, exact
                           email / phone / PAN / city, weighted match score and
                           a rule decision (AUTO_MATCH / REVIEW / NO_MATCH)
     4. MATCH_ADJUDICATIONS, STEWARD_OVERRIDES (kept across reruns) and the
        MATCH_PAIRS_FINAL view that clustering consumes.
   Run as  ACCEL_ADMIN after 02. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS C360;
USE SCHEMA C360;

-- -----------------------------------------------------------------------------
-- 1. Configuration                                                    -- EDIT ME
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE C360.MATCH_CONFIG (PARAM VARCHAR, VALUE NUMBER(10,4), NOTE VARCHAR);
INSERT INTO C360.MATCH_CONFIG VALUES
  ('W_NAME',            0.30, 'Weight of name similarity (0-1 blend of Jaro-Winkler and edit distance)'),   -- EDIT ME
  ('W_EMAIL',           0.30, 'Weight of exact normalised email'),                                          -- EDIT ME
  ('W_PHONE',           0.20, 'Weight of exact phone key (last 8 digits)'),                                 -- EDIT ME
  ('W_PAN',             0.40, 'Weight of exact PAN'),                                                       -- EDIT ME
  ('W_CITY',            0.05, 'Weight of same city'),                                                       -- EDIT ME
  ('AUTO_THRESHOLD',    0.85, 'Score at/above which a pair with >= 2 evidence types auto-matches'),        -- EDIT ME
  ('REVIEW_THRESHOLD',  0.65, 'Score at/above which a pair goes to review (AI / data steward)'),          -- EDIT ME
  ('MAX_BLOCK_SIZE',    300,  'Blocks larger than this are skipped (prevents pair explosion)');           -- EDIT ME

-- -----------------------------------------------------------------------------
-- 2. Blocking -> candidate pairs
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE C360.CANDIDATE_PAIRS AS
WITH cfg AS (SELECT MAX(IFF(PARAM = 'MAX_BLOCK_SIZE', VALUE, NULL)) AS MAX_BLOCK FROM C360.MATCH_CONFIG),
keys AS (
    SELECT RECORD_KEY, 'EMAIL' AS BLOCK_RULE, EMAIL_STD AS BLOCK_KEY FROM C360.CUSTOMER_RECORDS WHERE EMAIL_STD IS NOT NULL
    UNION ALL SELECT RECORD_KEY, 'PHONE', PHONE_KEY FROM C360.CUSTOMER_RECORDS WHERE PHONE_KEY IS NOT NULL
    UNION ALL SELECT RECORD_KEY, 'PAN', PAN_STD FROM C360.CUSTOMER_RECORDS WHERE PAN_STD IS NOT NULL
    UNION ALL SELECT RECORD_KEY, 'SOUNDEX_COUNTRY', BK_SOUNDEX_COUNTRY FROM C360.CUSTOMER_RECORDS WHERE BK_SOUNDEX_COUNTRY IS NOT NULL
    UNION ALL SELECT RECORD_KEY, 'PREFIX_CITY', BK_PREFIX_CITY FROM C360.CUSTOMER_RECORDS WHERE BK_PREFIX_CITY IS NOT NULL
),
sized AS (
    SELECT k.*, COUNT(*) OVER (PARTITION BY BLOCK_RULE, BLOCK_KEY) AS BLOCK_SIZE
    FROM keys k
),
usable AS (
    SELECT s.* FROM sized s, cfg WHERE s.BLOCK_SIZE BETWEEN 2 AND cfg.MAX_BLOCK
)
SELECT a.RECORD_KEY AS RECORD_KEY_A,
       b.RECORD_KEY AS RECORD_KEY_B,
       ARRAY_AGG(DISTINCT a.BLOCK_RULE) AS BLOCK_RULES
FROM usable a
JOIN usable b
  ON a.BLOCK_RULE = b.BLOCK_RULE
 AND a.BLOCK_KEY  = b.BLOCK_KEY
 AND a.RECORD_KEY < b.RECORD_KEY
GROUP BY a.RECORD_KEY, b.RECORD_KEY;

SELECT COUNT(*) AS CANDIDATE_PAIRS FROM C360.CANDIDATE_PAIRS;

-- -----------------------------------------------------------------------------
-- 3. Pairwise comparison + weighted score
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE C360.MATCH_PAIRS AS
WITH cfg AS (
    SELECT MAX(IFF(PARAM = 'W_NAME',  VALUE, NULL)) AS W_NAME,
           MAX(IFF(PARAM = 'W_EMAIL', VALUE, NULL)) AS W_EMAIL,
           MAX(IFF(PARAM = 'W_PHONE', VALUE, NULL)) AS W_PHONE,
           MAX(IFF(PARAM = 'W_PAN',   VALUE, NULL)) AS W_PAN,
           MAX(IFF(PARAM = 'W_CITY',  VALUE, NULL)) AS W_CITY,
           MAX(IFF(PARAM = 'AUTO_THRESHOLD',   VALUE, NULL)) AS T_AUTO,
           MAX(IFF(PARAM = 'REVIEW_THRESHOLD', VALUE, NULL)) AS T_REVIEW
    FROM C360.MATCH_CONFIG
),
cmp AS (
    SELECT p.RECORD_KEY_A, p.RECORD_KEY_B, p.BLOCK_RULES,
           a.SOURCE_SYSTEM AS SOURCE_A, b.SOURCE_SYSTEM AS SOURCE_B,
           a.RAW_NAME AS NAME_A, b.RAW_NAME AS NAME_B,
           JAROWINKLER_SIMILARITY(COALESCE(a.NAME_CORE, ''), COALESCE(b.NAME_CORE, ''))     AS NAME_JW,      -- 0..100
           EDITDISTANCE(COALESCE(a.NAME_CORE, ''), COALESCE(b.NAME_CORE, ''))               AS NAME_EDIT_DISTANCE,
           GREATEST(LENGTH(COALESCE(a.NAME_CORE, '')), LENGTH(COALESCE(b.NAME_CORE, '')), 1) AS NAME_MAX_LEN,
           IFF(a.EMAIL_STD IS NULL OR b.EMAIL_STD IS NULL, NULL, IFF(a.EMAIL_STD = b.EMAIL_STD, 1, 0)) AS EMAIL_MATCH,
           IFF(a.PHONE_KEY IS NULL OR b.PHONE_KEY IS NULL, NULL, IFF(a.PHONE_KEY = b.PHONE_KEY, 1, 0)) AS PHONE_MATCH,
           IFF(a.PAN_STD   IS NULL OR b.PAN_STD   IS NULL, NULL, IFF(a.PAN_STD   = b.PAN_STD,   1, 0)) AS PAN_MATCH,
           IFF(a.CITY_STD  IS NULL OR b.CITY_STD  IS NULL, NULL, IFF(a.CITY_STD  = b.CITY_STD,  1, 0)) AS CITY_MATCH
    FROM C360.CANDIDATE_PAIRS p
    JOIN C360.CUSTOMER_RECORDS a ON a.RECORD_KEY = p.RECORD_KEY_A
    JOIN C360.CUSTOMER_RECORDS b ON b.RECORD_KEY = p.RECORD_KEY_B
),
scored AS (
    SELECT c.*,
           ROUND(0.6 * NAME_JW / 100 + 0.4 * (1 - NAME_EDIT_DISTANCE / NAME_MAX_LEN), 4) AS NAME_SIM,
           -- score = weighted average over the attributes that are present on BOTH records
           ROUND( ( cfg.W_NAME * (0.6 * NAME_JW / 100 + 0.4 * (1 - NAME_EDIT_DISTANCE / NAME_MAX_LEN))
                  + cfg.W_EMAIL * COALESCE(EMAIL_MATCH, 0)
                  + cfg.W_PHONE * COALESCE(PHONE_MATCH, 0)
                  + cfg.W_PAN   * COALESCE(PAN_MATCH,   0)
                  + cfg.W_CITY  * COALESCE(CITY_MATCH,  0) )
                / ( cfg.W_NAME
                  + IFF(EMAIL_MATCH IS NULL, 0, cfg.W_EMAIL)
                  + IFF(PHONE_MATCH IS NULL, 0, cfg.W_PHONE)
                  + IFF(PAN_MATCH   IS NULL, 0, cfg.W_PAN)
                  + IFF(CITY_MATCH  IS NULL, 0, cfg.W_CITY) ), 4)                      AS MATCH_SCORE,
           1 + IFF(EMAIL_MATCH = 1, 1, 0) + IFF(PHONE_MATCH = 1, 1, 0) + IFF(PAN_MATCH = 1, 1, 0) AS EVIDENCE_COUNT,
           cfg.T_AUTO, cfg.T_REVIEW
    FROM cmp c CROSS JOIN cfg
)
SELECT
    SHA2(RECORD_KEY_A || '~' || RECORD_KEY_B, 256)  AS PAIR_ID,
    RECORD_KEY_A, RECORD_KEY_B, SOURCE_A, SOURCE_B, NAME_A, NAME_B, BLOCK_RULES,
    NAME_JW, NAME_EDIT_DISTANCE, NAME_SIM, EMAIL_MATCH, PHONE_MATCH, PAN_MATCH, CITY_MATCH,
    MATCH_SCORE, EVIDENCE_COUNT,
    CASE
        WHEN PAN_MATCH = 1 AND NAME_SIM >= 0.50                               THEN 'AUTO_MATCH'  -- same legal entity id
        WHEN PAN_MATCH = 0                                                    THEN IFF(MATCH_SCORE >= T_REVIEW, 'REVIEW', 'NO_MATCH') -- conflicting PAN never auto-merges
        WHEN MATCH_SCORE >= T_AUTO AND EVIDENCE_COUNT >= 2                    THEN 'AUTO_MATCH'
        WHEN MATCH_SCORE >= T_REVIEW                                          THEN 'REVIEW'
        ELSE 'NO_MATCH'
    END AS RULE_DECISION,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS SCORED_AT
FROM scored;

-- -----------------------------------------------------------------------------
-- 4. Decisions that must survive reruns
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS C360.MATCH_ADJUDICATIONS (
    RECORD_KEY_A   VARCHAR,
    RECORD_KEY_B   VARCHAR,
    AI_DECISION    VARCHAR,          -- MATCH / NO_MATCH / UNRESOLVED
    AI_REASON      VARCHAR,
    AI_RAW_RESPONSE VARCHAR,
    MODEL          VARCHAR,
    ADJUDICATED_AT TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS C360.STEWARD_OVERRIDES (
    RECORD_KEY_A   VARCHAR,
    RECORD_KEY_B   VARCHAR,
    DECISION       VARCHAR,          -- MATCH / NO_MATCH
    STEWARD        VARCHAR DEFAULT CURRENT_USER(),
    COMMENT        VARCHAR,
    DECIDED_AT     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE VIEW C360.MATCH_PAIRS_FINAL AS
SELECT m.*,
       a.AI_DECISION, a.AI_REASON,
       s.DECISION AS STEWARD_DECISION,
       COALESCE(s.DECISION,
                CASE m.RULE_DECISION
                    WHEN 'AUTO_MATCH' THEN 'MATCH'
                    WHEN 'REVIEW'     THEN IFF(a.AI_DECISION IN ('MATCH', 'NO_MATCH'), a.AI_DECISION, 'UNRESOLVED')
                    ELSE 'NO_MATCH'
                END) AS FINAL_DECISION,
       CASE WHEN s.DECISION IS NOT NULL THEN 'STEWARD'
            WHEN m.RULE_DECISION = 'REVIEW' AND a.AI_DECISION IN ('MATCH', 'NO_MATCH') THEN 'AI'
            ELSE 'RULES' END AS DECIDED_BY
FROM C360.MATCH_PAIRS m
LEFT JOIN C360.MATCH_ADJUDICATIONS a
       ON a.RECORD_KEY_A = m.RECORD_KEY_A AND a.RECORD_KEY_B = m.RECORD_KEY_B
LEFT JOIN (SELECT * FROM C360.STEWARD_OVERRIDES
           QUALIFY ROW_NUMBER() OVER (PARTITION BY RECORD_KEY_A, RECORD_KEY_B ORDER BY DECIDED_AT DESC) = 1) s
       ON s.RECORD_KEY_A = m.RECORD_KEY_A AND s.RECORD_KEY_B = m.RECORD_KEY_B;

-- Match quality summary
SELECT RULE_DECISION, COUNT(*) AS PAIRS, ROUND(AVG(MATCH_SCORE), 3) AS AVG_SCORE,
       COUNT_IF(SOURCE_A <> SOURCE_B) AS CROSS_SOURCE_PAIRS
FROM C360.MATCH_PAIRS GROUP BY 1 ORDER BY 1;

-- Borderline examples to eyeball
SELECT NAME_A, NAME_B, NAME_JW, NAME_EDIT_DISTANCE, EMAIL_MATCH, PHONE_MATCH, PAN_MATCH, MATCH_SCORE, RULE_DECISION
FROM C360.MATCH_PAIRS WHERE RULE_DECISION = 'REVIEW' ORDER BY MATCH_SCORE DESC LIMIT 25;
