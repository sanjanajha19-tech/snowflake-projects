/* =============================================================================
   Asset 23 - Customer 360 & Entity Resolution
   File  04_ai_adjudication_optional.sql   (OPTIONAL - uses Cortex AI credits)
   Purpose
     Sends borderline (RULE_DECISION = 'REVIEW') pairs that have no AI decision
     yet to AI_COMPLETE, in a LIMIT-controlled batch, and stores the verdict in
     C360.MATCH_ADJUDICATIONS. Steward overrides always win over AI.
   Cost  One short prompt (~200 tokens in, ~40 out) per pair. Start with 50.
   Run as  ACCEL_ADMIN after 03. Rerunnable - already adjudicated pairs are skipped.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS C360;
USE SCHEMA C360;

CREATE OR REPLACE PROCEDURE C360.ADJUDICATE_BORDERLINE_MATCHES(MAX_PAIRS INTEGER)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    n INTEGER DEFAULT 0;
BEGIN
    CREATE OR REPLACE TEMPORARY TABLE ACCEL_DB.C360.TMP_AI_BATCH AS
    SELECT m.RECORD_KEY_A, m.RECORD_KEY_B, m.MATCH_SCORE, m.PAIR_ID,
           'You are a master-data steward. Decide whether these two customer records refer to the SAME real-world customer. '
        || 'Legal-form differences (Pvt Ltd / Private Limited / Ltd), letter case, small typos and phone formatting do not make them different. '
        || 'A different PAN (Indian tax id) strongly indicates different customers. '
        || 'Answer with exactly one word, MATCH or NO_MATCH, then " | " and a reason of at most 20 words.\n'
        || 'Record A (' || a.SOURCE_SYSTEM || '): name=' || COALESCE(a.RAW_NAME, '?') || '; email=' || COALESCE(a.RAW_EMAIL, '?')
        || '; phone=' || COALESCE(a.RAW_PHONE, '?') || '; PAN=' || COALESCE(a.PAN_STD, '?') || '; city=' || COALESCE(a.RAW_CITY, '?')
        || '; country=' || COALESCE(a.RAW_COUNTRY, '?') || '\n'
        || 'Record B (' || b.SOURCE_SYSTEM || '): name=' || COALESCE(b.RAW_NAME, '?') || '; email=' || COALESCE(b.RAW_EMAIL, '?')
        || '; phone=' || COALESCE(b.RAW_PHONE, '?') || '; PAN=' || COALESCE(b.PAN_STD, '?') || '; city=' || COALESCE(b.RAW_CITY, '?')
        || '; country=' || COALESCE(b.RAW_COUNTRY, '?') AS PROMPT
    FROM ACCEL_DB.C360.MATCH_PAIRS m
    JOIN ACCEL_DB.C360.CUSTOMER_RECORDS a ON a.RECORD_KEY = m.RECORD_KEY_A
    JOIN ACCEL_DB.C360.CUSTOMER_RECORDS b ON b.RECORD_KEY = m.RECORD_KEY_B
    WHERE m.RULE_DECISION = 'REVIEW'
      AND NOT EXISTS (SELECT 1 FROM ACCEL_DB.C360.MATCH_ADJUDICATIONS x
                      WHERE x.RECORD_KEY_A = m.RECORD_KEY_A AND x.RECORD_KEY_B = m.RECORD_KEY_B);

    INSERT INTO ACCEL_DB.C360.MATCH_ADJUDICATIONS
        (RECORD_KEY_A, RECORD_KEY_B, AI_DECISION, AI_REASON, AI_RAW_RESPONSE, MODEL, ADJUDICATED_AT)
    WITH batch AS (
        -- limit FIRST, then call the model only for the selected pairs
        SELECT RECORD_KEY_A, RECORD_KEY_B, PROMPT
        FROM ACCEL_DB.C360.TMP_AI_BATCH
        QUALIFY ROW_NUMBER() OVER (ORDER BY MATCH_SCORE DESC, PAIR_ID) <= :MAX_PAIRS
    ),
    r AS (
        SELECT RECORD_KEY_A, RECORD_KEY_B,
               TRIM(AI_COMPLETE('llama3.1-70b', PROMPT)) AS RESP          -- EDIT ME: model available in your region
        FROM batch
    )
    SELECT RECORD_KEY_A, RECORD_KEY_B,
           CASE WHEN REGEXP_LIKE(UPPER(RESP), '^[^A-Z]*MATCH([^A-Z_].*)?', 's') THEN 'MATCH'      -- starts with MATCH
                WHEN REGEXP_LIKE(UPPER(RESP), '^[^A-Z]*NO[_ ]MATCH.*', 's')   THEN 'NO_MATCH'   -- starts with NO_MATCH
                ELSE 'UNRESOLVED' END,
           TRIM(IFF(CONTAINS(RESP, '|'), SPLIT_PART(RESP, '|', 2), RESP)),
           RESP,
           'llama3.1-70b',
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    FROM r;

    n := SQLROWCOUNT;
    RETURN 'Adjudicated ' || n || ' borderline pairs';
END;
$$;

-- Run a small batch first; increase once you are happy with cost and quality.
CALL C360.ADJUDICATE_BORDERLINE_MATCHES(50);                                     -- EDIT ME: batch size

SELECT f.NAME_A, f.NAME_B, f.MATCH_SCORE, f.AI_DECISION, f.AI_REASON, f.FINAL_DECISION
FROM C360.MATCH_PAIRS_FINAL f
WHERE f.RULE_DECISION = 'REVIEW' AND f.AI_DECISION IS NOT NULL
ORDER BY f.MATCH_SCORE DESC
LIMIT 50;

-- A data steward can always override (example - uncomment and edit keys):
-- INSERT INTO C360.STEWARD_OVERRIDES (RECORD_KEY_A, RECORD_KEY_B, DECISION, COMMENT)
-- VALUES ('CRM:CRM-123', 'ERP:123', 'MATCH', 'Confirmed by account owner');
