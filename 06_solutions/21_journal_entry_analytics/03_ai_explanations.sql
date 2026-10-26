/*=============================================================================
  ACCELERATOR 21 - Journal Entry Analytics
  File 03 : AI explanations for the top-N risk journals (AI_COMPLETE)
            For each journal the model gets the lines, the rules that fired and
            the preparer's normal behaviour, and writes a short reviewer note:
            why it is risky, what to ask for, and a suggested test.
  Creates : JE_AI_EXPLANATIONS
  Run as  : ACCEL_ADMIN, warehouse ACCEL_AI_WH
  Rerun   : safe - replaces explanations for the journals in the current top N.
  Cost    : one AI_COMPLETE call per journal (50 by default).
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_AI_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS JE_ANALYTICS;
USE SCHEMA JE_ANALYTICS;

SET AI_MODEL = 'llama3.1-70b';   -- EDIT ME: any AI_COMPLETE model available in your region (e.g. 'claude-3-5-sonnet', 'mistral-large2')
SET TOP_N    = 50;               -- EDIT ME

CREATE TABLE IF NOT EXISTS JE_AI_EXPLANATIONS (
    JOURNAL_ID    NUMBER,
    RISK_SCORE    NUMBER,
    MODEL         VARCHAR,
    PROMPT        VARCHAR,
    EXPLANATION   VARCHAR,
    GENERATED_AT  TIMESTAMP_NTZ
) COMMENT = 'AI-written reviewer notes for the highest-risk journals';

CREATE OR REPLACE TEMPORARY TABLE TMP_JE_TOP AS
SELECT s.*
FROM JE_RISK_SCORES s
WHERE s.RISK_SCORE > 0
QUALIFY ROW_NUMBER() OVER (ORDER BY s.RISK_SCORE DESC, s.TOTAL_DEBIT_USD DESC, s.JOURNAL_ID) <= $TOP_N;

DELETE FROM JE_AI_EXPLANATIONS WHERE JOURNAL_ID IN (SELECT JOURNAL_ID FROM TMP_JE_TOP);

INSERT INTO JE_AI_EXPLANATIONS (JOURNAL_ID, RISK_SCORE, MODEL, PROMPT, EXPLANATION, GENERATED_AT)
WITH lines AS (
    SELECT g.JOURNAL_ID,
           LISTAGG('Line ' || g.LINE_NO || ': ' || g.ACCOUNT_CODE || ' ' || g.ACCOUNT_NAME || ' (' || g.ACCOUNT_TYPE || ') '
                   || IFF(g.AMOUNT >= 0, 'Dr ', 'Cr ') || TO_VARCHAR(ABS(g.AMOUNT)) || ' ' || g.CURRENCY
                   || ', cost center ' || g.COST_CENTER, '\n')
             WITHIN GROUP (ORDER BY g.LINE_NO) AS LINES_TXT
    FROM V_GL_SCOPE g
    WHERE g.JOURNAL_ID IN (SELECT JOURNAL_ID FROM TMP_JE_TOP)
    GROUP BY g.JOURNAL_ID
),
usr AS (
    SELECT CREATED_BY,
           COUNT(*) AS N_JOURNALS,
           ROUND(MEDIAN(TOTAL_DEBIT_USD)) AS MEDIAN_USD,
           ROUND(100 * COUNT_IF(SOURCE = 'Manual') / COUNT(*), 1) AS PCT_MANUAL,
           LISTAGG(DISTINCT ENTITY, ', ') AS ENTITIES
    FROM JE_RISK_SCORES
    GROUP BY CREATED_BY
),
p AS (
    SELECT t.JOURNAL_ID, t.RISK_SCORE,
           'You are a senior internal auditor reviewing journal entries for fraud and error risk. '
        || 'Write a reviewer note of at most 120 words with three labelled parts: '
        || '"Why flagged" (plain English, reference the specific rules), '
        || '"Questions for the preparer" (2-3 bullet points), '
        || '"Suggested test" (one concrete audit procedure). '
        || 'Be factual, do not assume fraud, and do not invent facts that are not given.\n\n'
        || 'Journal ' || t.JOURNAL_ID || ' | entity ' || t.ENTITY || ' | source ' || t.SOURCE
        || ' | posting date ' || TO_VARCHAR(t.POSTING_DATE, 'YYYY-MM-DD') || ' (' || DAYNAME(t.POSTING_DATE) || ')'
        || ' | entered ' || TO_VARCHAR(t.ENTRY_TIMESTAMP, 'YYYY-MM-DD HH24:MI')
        || ' | created by ' || t.CREATED_BY || ' | approved by ' || t.APPROVED_BY
        || ' | description: ' || t.DESCRIPTION
        || ' | total debit USD ' || TO_VARCHAR(ROUND(t.TOTAL_DEBIT_USD)) || '\n'
        || 'Lines:\n' || l.LINES_TXT || '\n'
        || 'Risk score ' || t.RISK_SCORE || '/100. Rules triggered: ' || t.REASONS || '\n'
        || 'Preparer profile: ' || u.N_JOURNALS || ' journals, median USD ' || TO_VARCHAR(u.MEDIAN_USD)
        || ', ' || TO_VARCHAR(u.PCT_MANUAL) || '% manual, entities ' || u.ENTITIES || '.' AS PROMPT
    FROM TMP_JE_TOP t
    JOIN lines l ON l.JOURNAL_ID = t.JOURNAL_ID
    JOIN usr u ON u.CREATED_BY = t.CREATED_BY
)
SELECT p.JOURNAL_ID, p.RISK_SCORE, $AI_MODEL, p.PROMPT,
       AI_COMPLETE($AI_MODEL, p.PROMPT),
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM p;

SELECT e.JOURNAL_ID, e.RISK_SCORE, s.CREATED_BY, s.REASONS, e.EXPLANATION
FROM JE_AI_EXPLANATIONS e
JOIN JE_RISK_SCORES s ON s.JOURNAL_ID = e.JOURNAL_ID
ORDER BY e.RISK_SCORE DESC
LIMIT 10;
