/*=============================================================================
  MIGRATION ASSESSMENT 05 (optional) - AI summary of legacy code
  Uses AI_COMPLETE to describe each view / procedure / script: business
  purpose, conversion risks and a suggested Snowflake approach.
  Results: AI_CODE_INSIGHTS (joined into the Streamlit drill-down).
  Run as : ACCEL_ADMIN (has SNOWFLAKE.CORTEX_USER). Rerun: safe (rebuilds table).
  Cost   : one AI_COMPLETE call per code object (19 in the sample inventory).
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS MIGRATION_ASSESSMENT;
USE SCHEMA MIGRATION_ASSESSMENT;

-- Model must be available in your region (or enable cross-region inference).
-- Alternatives: 'claude-3-5-sonnet', 'mistral-large2', 'llama3.3-70b', 'snowflake-arctic'
SET AI_MODEL = 'llama3.1-70b';   -- EDIT ME

CREATE OR REPLACE TABLE AI_CODE_INSIGHTS AS
WITH src AS (
  SELECT o.FULL_NAME, o.SOURCE_PLATFORM, o.OBJECT_TYPE, c.CODE_TEXT
  FROM SRC_OBJECTS o
  JOIN SRC_CODE c ON c.FULL_NAME = o.FULL_NAME
  WHERE o.OBJECT_TYPE IN ('VIEW', 'PROCEDURE', 'PACKAGE', 'FUNCTION', 'MACRO', 'BTEQ_SCRIPT', 'TRIGGER')
),
ai AS (
  SELECT src.*,
         AI_COMPLETE(
           $AI_MODEL,
           'You are a senior data-warehouse migration architect moving a ' || SOURCE_PLATFORM
           || ' workload to Snowflake. Analyse the ' || OBJECT_TYPE || ' below.\n'
           || 'Respond with ONLY a JSON object, no markdown, using exactly these keys:\n'
           || '{"purpose": "<one sentence business purpose>", '
           || '"conversion_risks": ["<short risk>", "..."], '
           || '"snowflake_approach": "<two sentences on how to implement it in Snowflake>", '
           || '"difficulty": "Low|Medium|High"}\n'
           || 'Mention concrete constructs (for example BTEQ commands, PERIOD types, CONNECT BY, '
           || 'autonomous transactions, triggers, DBMS_ packages) only if they appear in the code.\n\n'
           || 'Object: ' || FULL_NAME || '\nCode:\n' || LEFT(CODE_TEXT, 12000)
         ) AS RAW_RESPONSE
  FROM src
),
parsed AS (
  SELECT ai.*,
         TRY_PARSE_JSON(REGEXP_SUBSTR(RAW_RESPONSE, '[{].*[}]', 1, 1, 's')) AS J
  FROM ai
)
SELECT FULL_NAME,
       SOURCE_PLATFORM,
       OBJECT_TYPE,
       $AI_MODEL                          AS MODEL,
       J:purpose::STRING                  AS PURPOSE,
       J:conversion_risks                 AS CONVERSION_RISKS,
       J:snowflake_approach::STRING       AS SNOWFLAKE_APPROACH,
       J:difficulty::STRING               AS AI_DIFFICULTY,
       RAW_RESPONSE,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS GENERATED_AT
FROM parsed;

-- Compare AI difficulty with the rule-based band
SELECT a.FULL_NAME, r.COMPLEXITY AS RULE_BASED, a.AI_DIFFICULTY, a.PURPOSE,
       IFF(IS_ARRAY(a.CONVERSION_RISKS), ARRAY_TO_STRING(a.CONVERSION_RISKS::ARRAY, '; '),
           a.CONVERSION_RISKS::STRING) AS RISKS
FROM AI_CODE_INSIGHTS a
LEFT JOIN ASSESSMENT_RESULT r ON r.FULL_NAME = a.FULL_NAME
ORDER BY r.COMPLEXITY_SCORE DESC NULLS LAST;
