/*=============================================================================
  ASSET 10 - Talk to your Data Agent
  File 03   : Cortex Search service over support tickets (used by the agent)
  Creates   : ACCEL_DB.KNOWLEDGE.SUPPORT_TICKET_SEARCH (only if it does not exist)
  Run as    : ACCEL_ADMIN
  Rerun     : safe (IF NOT EXISTS)
  Notes     : This is the SAME service that asset 13 (Enterprise Knowledge
              Assistant) builds. If you already ran 13, this file is a no-op.
              Cost: the service bills for indexing (warehouse) and serving
              (per GB-month of indexed data). 2,000 tickets is tiny.
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS KNOWLEDGE COMMENT = 'Asset 13: enterprise knowledge assistant (RAG)';
USE SCHEMA KNOWLEDGE;

-- Cortex Search needs change tracking on the base tables (it tries to enable
-- it automatically when the role owns them; done explicitly here).
ALTER TABLE ACCEL_DB.DEMO.SUPPORT_TICKETS SET CHANGE_TRACKING = TRUE;
ALTER TABLE ACCEL_DB.DEMO.PRODUCTS        SET CHANGE_TRACKING = TRUE;

CREATE CORTEX SEARCH SERVICE IF NOT EXISTS SUPPORT_TICKET_SEARCH
  ON TICKET_TEXT
  ATTRIBUTES PRIORITY, STATUS, CHANNEL, CATEGORY
  WAREHOUSE = ACCEL_AI_WH
  TARGET_LAG = '1 day'                                   -- EDIT ME: freshness vs cost
  EMBEDDING_MODEL = 'snowflake-arctic-embed-m-v1.5'
AS (
  SELECT
      t.TICKET_ID,
      t.SUBJECT,
      t.SUBJECT || '. ' || t.BODY          AS TICKET_TEXT,
      t.PRIORITY,
      t.STATUS,
      t.CHANNEL,
      p.CATEGORY,
      p.PRODUCT_NAME,
      t.CUSTOMER_ID,
      TO_VARCHAR(t.CREATED_AT, 'YYYY-MM-DD') AS CREATED_DATE
  FROM ACCEL_DB.DEMO.SUPPORT_TICKETS t
  LEFT JOIN ACCEL_DB.DEMO.PRODUCTS p ON p.PRODUCT_ID = t.PRODUCT_ID
);

GRANT USAGE ON SCHEMA ACCEL_DB.KNOWLEDGE TO ROLE ACCEL_ANALYST;
GRANT USAGE ON CORTEX SEARCH SERVICE ACCEL_DB.KNOWLEDGE.SUPPORT_TICKET_SEARCH TO ROLE ACCEL_ANALYST;

-- Smoke test (returns JSON with a "results" array)
SELECT PARSE_JSON(
  SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'ACCEL_DB.KNOWLEDGE.SUPPORT_TICKET_SEARCH',
    '{"query": "late delivery complaint", "columns": ["TICKET_ID", "SUBJECT", "PRIORITY", "CATEGORY"], "limit": 5}'
  )
)['results'] AS RESULTS;
