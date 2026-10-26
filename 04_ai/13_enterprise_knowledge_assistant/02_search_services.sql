/*=============================================================================
  ASSET 13 - Enterprise Knowledge Assistant (RAG)
  File 02   : Cortex Search services
              KB_SEARCH              - policy / SOP chunks (DOC_CHUNKS)
              SUPPORT_TICKET_SEARCH  - support tickets (also used by asset 10)
  Run as    : ACCEL_ADMIN
  Rerun     : KB_SEARCH is CREATE OR REPLACE (rebuilds the index).
              SUPPORT_TICKET_SEARCH is IF NOT EXISTS because asset 10's agent
              may already depend on it.
  Cost      : indexing runs on ACCEL_AI_WH at each refresh with changes;
              serving is billed per GB-month of indexed data (tiny here).
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS KNOWLEDGE;
USE SCHEMA KNOWLEDGE;

------------------------------------------------------------------------------
-- 1. Policy knowledge base
------------------------------------------------------------------------------
CREATE OR REPLACE CORTEX SEARCH SERVICE KB_SEARCH
  ON CHUNK_TEXT
  ATTRIBUTES CATEGORY, SOURCE
  WAREHOUSE = ACCEL_AI_WH
  TARGET_LAG = '1 hour'                                  -- EDIT ME: freshness vs cost
  EMBEDDING_MODEL = 'snowflake-arctic-embed-m-v1.5'      -- EDIT ME: e.g. snowflake-arctic-embed-l-v2.0 for multilingual
AS (
  SELECT CHUNK_ID, DOC_NAME, DOC_TITLE, CATEGORY, SOURCE, CHUNK_INDEX, CHUNK_TEXT
  FROM ACCEL_DB.KNOWLEDGE.DOC_CHUNKS
);

------------------------------------------------------------------------------
-- 2. Support tickets (same definition as asset 10 / 03_ticket_search_service.sql)
------------------------------------------------------------------------------
ALTER TABLE ACCEL_DB.DEMO.SUPPORT_TICKETS SET CHANGE_TRACKING = TRUE;
ALTER TABLE ACCEL_DB.DEMO.PRODUCTS        SET CHANGE_TRACKING = TRUE;

CREATE CORTEX SEARCH SERVICE IF NOT EXISTS SUPPORT_TICKET_SEARCH
  ON TICKET_TEXT
  ATTRIBUTES PRIORITY, STATUS, CHANNEL, CATEGORY
  WAREHOUSE = ACCEL_AI_WH
  TARGET_LAG = '1 day'                                   -- EDIT ME
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

------------------------------------------------------------------------------
-- 3. Access for analysts / the Streamlit app owner role
------------------------------------------------------------------------------
GRANT USAGE ON SCHEMA ACCEL_DB.KNOWLEDGE TO ROLE ACCEL_ANALYST;
GRANT USAGE ON CORTEX SEARCH SERVICE ACCEL_DB.KNOWLEDGE.KB_SEARCH             TO ROLE ACCEL_ANALYST;
GRANT USAGE ON CORTEX SEARCH SERVICE ACCEL_DB.KNOWLEDGE.SUPPORT_TICKET_SEARCH TO ROLE ACCEL_ANALYST;

SHOW CORTEX SEARCH SERVICES IN SCHEMA ACCEL_DB.KNOWLEDGE;

------------------------------------------------------------------------------
-- 4. Smoke tests
------------------------------------------------------------------------------
SELECT PARSE_JSON(
  SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'ACCEL_DB.KNOWLEDGE.KB_SEARCH',
    '{"query": "Can I fly business class to New York?", "columns": ["CHUNK_ID", "DOC_TITLE", "CHUNK_TEXT"], "limit": 3}'
  )
)['results'] AS RESULTS;

SELECT PARSE_JSON(
  SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'ACCEL_DB.KNOWLEDGE.KB_SEARCH',
    '{"query": "approval needed for a 40 lakh purchase", "columns": ["CHUNK_ID", "DOC_TITLE", "CHUNK_TEXT"], "filter": {"@eq": {"CATEGORY": "Procurement"}}, "limit": 3}'
  )
)['results'] AS RESULTS;

-- One-shot RAG in pure SQL (retrieve top 3 chunks, then answer with citations).
-- SEARCH_PREVIEW takes literal arguments, so the question appears twice.
SET LLM_MODEL = 'claude-sonnet-4-5';   -- EDIT ME: e.g. llama3.3-70b or mistral-large2 if Claude is not in your region

WITH hits AS (
  SELECT r.value:DOC_TITLE::VARCHAR  AS DOC_TITLE,
         r.value:CHUNK_ID::VARCHAR   AS CHUNK_ID,
         r.value:CHUNK_TEXT::VARCHAR AS CHUNK_TEXT,
         r.index + 1                 AS N
  FROM TABLE(FLATTEN(input => PARSE_JSON(
         SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
           'ACCEL_DB.KNOWLEDGE.KB_SEARCH',
           '{"query": "How many days of annual leave can I carry forward, and by when must I use them?", "columns": ["CHUNK_ID", "DOC_TITLE", "CHUNK_TEXT"], "limit": 3}'
         ))['results'])) r
),
ctx AS (
  SELECT LISTAGG('[' || N || '] ' || DOC_TITLE || ' (' || CHUNK_ID || '): ' || CHUNK_TEXT, '\n\n')
           WITHIN GROUP (ORDER BY N) AS CONTEXT
  FROM hits
)
SELECT AI_COMPLETE(
         $LLM_MODEL,
         'Answer the question using only the policy excerpts below. Cite sources as [n]. ' ||
         'If the answer is not in the excerpts, say you do not know.\n\nExcerpts:\n' || CONTEXT ||
         '\n\nQuestion: How many days of annual leave can I carry forward, and by when must I use them?'
       ) AS ANSWER,
       CONTEXT
FROM ctx;
