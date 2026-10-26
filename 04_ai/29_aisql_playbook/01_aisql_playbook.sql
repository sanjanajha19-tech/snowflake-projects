/*=============================================================================
  ASSET 29 - AI SQL Playbook
  File 01   : Every Cortex AI SQL function on the demo support tickets, framed
              as business scenarios. Run section by section or top to bottom.
  Functions : AI_SENTIMENT, AI_CLASSIFY, AI_SUMMARIZE_AGG, AI_FILTER,
              AI_TRANSLATE, AI_COMPLETE (structured output), AI_EMBED,
              AI_SIMILARITY, AI_AGG
  Creates   : ACCEL_DB.AISQL.TICKET_SAMPLE, TICKET_ENRICHED,
              TICKET_TRIAGE, TICKET_EMBEDDINGS
  Run as    : ACCEL_ADMIN (any role with SNOWFLAKE.CORTEX_USER works)
  Rerun     : safe (CREATE OR REPLACE)

  COST AWARENESS
  - AI functions bill per token (input + output), per row. 2,000 tickets x
    9 functions adds up; this playbook works on a SAMPLE (default 100 rows)
    and uses LIMIT everywhere. Increase SAMPLE_SIZE only when needed.
  - Prefer task-specific functions (AI_SENTIMENT, AI_CLASSIFY, AI_FILTER)
    over AI_COMPLETE: cheaper and more consistent.
  - Materialise results (CREATE TABLE AS) instead of re-running AI calls in
    dashboards. Use a dedicated warehouse (ACCEL_WH is enough: AI compute is
    serverless; the warehouse only orchestrates).
  - Track spend: SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY
    (see the last section).
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS AISQL COMMENT = 'Asset 29: AI SQL playbook';
USE SCHEMA AISQL;

SET LLM_MODEL   = 'claude-sonnet-4-5';   -- EDIT ME: e.g. llama3.3-70b, mistral-large2, claude-haiku-4-5
SET SAMPLE_SIZE = 100;                   -- EDIT ME: rows to send to AI functions

------------------------------------------------------------------------------
-- 0. Deterministic sample of tickets (with product + customer context)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE TICKET_SAMPLE AS
SELECT t.TICKET_ID, t.CREATED_AT, t.CHANNEL, t.PRIORITY, t.STATUS,
       t.SUBJECT, t.BODY,
       p.PRODUCT_NAME, p.CATEGORY AS PRODUCT_CATEGORY,
       c.SEGMENT, c.REGION
FROM ACCEL_DB.DEMO.SUPPORT_TICKETS t
LEFT JOIN ACCEL_DB.DEMO.PRODUCTS  p ON p.PRODUCT_ID  = t.PRODUCT_ID
LEFT JOIN ACCEL_DB.DEMO.CUSTOMERS c ON c.CUSTOMER_ID = t.CUSTOMER_ID
QUALIFY ROW_NUMBER() OVER (ORDER BY t.TICKET_ID) <= $SAMPLE_SIZE;

SELECT COUNT(*) AS SAMPLE_ROWS FROM TICKET_SAMPLE;

------------------------------------------------------------------------------
-- 1. Scenario "Voice of customer": AI_SENTIMENT (overall + aspects)
--    and AI_CLASSIFY (issue category with label descriptions + multi-label tags)
--    Results are materialised once and reused below.
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE TICKET_ENRICHED AS
SELECT s.*,
       PARSE_JSON(TO_VARCHAR(AI_SENTIMENT(
           s.SUBJECT || '. ' || s.BODY,
           ['Delivery', 'Product quality', 'Billing', 'Support experience']
       ))) AS SENTIMENT_RAW,
       PARSE_JSON(TO_VARCHAR(AI_CLASSIFY(
           s.SUBJECT || '. ' || s.BODY,
           [
             {'label': 'Delivery',        'description': 'late, missing, damaged or wrong shipments'},
             {'label': 'Product defect',  'description': 'product does not work, breaks or has poor quality'},
             {'label': 'Billing',         'description': 'invoices, charges, payments, refunds or credit notes'},
             {'label': 'Account access',  'description': 'login, password, portal or user access problems'},
             {'label': 'How-to question', 'description': 'questions about usage, setup or configuration'},
             {'label': 'Other',           'description': 'anything else'}
           ],
           {'task_description': 'Classify the main issue in a B2B customer support ticket'}
       ))) AS CATEGORY_RAW,
       PARSE_JSON(TO_VARCHAR(AI_CLASSIFY(
           s.SUBJECT || '. ' || s.BODY,
           ['refund request', 'escalation threat', 'churn risk', 'urgent', 'compliment'],
           {'output_mode': 'multi'}
       ))) AS TAGS_RAW
FROM TICKET_SAMPLE s;

-- Readable view of the enrichment
SELECT e.TICKET_ID, e.SUBJECT, e.PRIORITY,
       f.value:sentiment::VARCHAR                       AS OVERALL_SENTIMENT,
       e.CATEGORY_RAW:labels[0]::VARCHAR                AS ISSUE_CATEGORY,
       ARRAY_TO_STRING(e.TAGS_RAW:labels::ARRAY, ', ')  AS TAGS
FROM TICKET_ENRICHED e,
     LATERAL FLATTEN(input => e.SENTIMENT_RAW:categories) f
WHERE f.value:name::VARCHAR = 'overall'
ORDER BY e.TICKET_ID
LIMIT 20;

-- Sentiment by aspect across the sample (where is the pain?)
SELECT f.value:name::VARCHAR      AS ASPECT,
       f.value:sentiment::VARCHAR AS SENTIMENT,
       COUNT(*)                   AS TICKETS
FROM TICKET_ENRICHED e,
     LATERAL FLATTEN(input => e.SENTIMENT_RAW:categories) f
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

-- Category mix vs priority
SELECT CATEGORY_RAW:labels[0]::VARCHAR AS ISSUE_CATEGORY,
       COUNT(*) AS TICKETS,
       COUNT_IF(PRIORITY IN ('High', 'Critical')) AS HIGH_OR_CRITICAL
FROM TICKET_ENRICHED
GROUP BY 1
ORDER BY 2 DESC;

------------------------------------------------------------------------------
-- 2. Scenario "Product quality review": AI_SUMMARIZE_AGG of complaints per
--    product category (negative / mixed tickets only). One call per group.
------------------------------------------------------------------------------
SELECT e.PRODUCT_CATEGORY,
       COUNT(*) AS COMPLAINTS,
       AI_SUMMARIZE_AGG(e.SUBJECT || '. ' || e.BODY) AS COMPLAINT_SUMMARY
FROM TICKET_ENRICHED e,
     LATERAL FLATTEN(input => e.SENTIMENT_RAW:categories) f
WHERE f.value:name::VARCHAR = 'overall'
  AND f.value:sentiment::VARCHAR IN ('negative', 'mixed')
GROUP BY e.PRODUCT_CATEGORY
ORDER BY COMPLAINTS DESC
LIMIT 5;

------------------------------------------------------------------------------
-- 3. Scenario "Finance: refund exposure": AI_FILTER as a natural-language WHERE
------------------------------------------------------------------------------
SELECT TICKET_ID, CREATED_AT::DATE AS CREATED, PRODUCT_NAME, PRIORITY, SUBJECT, BODY
FROM TICKET_SAMPLE
WHERE AI_FILTER(PROMPT('The customer in this support ticket asks for a refund, credit note or money back: {0}',
                       SUBJECT || '. ' || BODY))
ORDER BY CREATED_AT DESC
LIMIT 20;

------------------------------------------------------------------------------
-- 4. Scenario "Global support desk": AI_TRANSLATE to Hindi, Japanese, German
--    (source '' = auto-detect)
------------------------------------------------------------------------------
SELECT TICKET_ID,
       BODY,
       AI_TRANSLATE(BODY, '', 'hi') AS BODY_HINDI,
       AI_TRANSLATE(BODY, '', 'ja') AS BODY_JAPANESE,
       AI_TRANSLATE(BODY, '', 'de') AS BODY_GERMAN
FROM TICKET_SAMPLE
ORDER BY TICKET_ID
LIMIT 5;

------------------------------------------------------------------------------
-- 5. Scenario "Auto-triage": AI_COMPLETE with structured output
--    (response_format JSON schema -> returns an object matching the schema)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE TICKET_TRIAGE AS
SELECT TICKET_ID, SUBJECT, PRIORITY AS CURRENT_PRIORITY, TRIAGE
FROM (
  SELECT s.TICKET_ID, s.SUBJECT, s.PRIORITY,
         PARSE_JSON(TO_VARCHAR(AI_COMPLETE(
           model  => $LLM_MODEL,
           prompt => 'You triage B2B customer support tickets. Analyse this ticket and fill every field. ' ||
                     'Product: ' || COALESCE(s.PRODUCT_NAME, 'unknown') || '. Ticket: ' || s.SUBJECT || '. ' || s.BODY,
           model_parameters => {'temperature': 0, 'max_tokens': 600},
           response_format => {
             'type': 'json',
             'schema': {
               'type': 'object',
               'properties': {
                 'issue_type':         {'type': 'string', 'enum': ['delivery', 'defect', 'billing', 'access', 'question', 'other']},
                 'urgency':            {'type': 'string', 'enum': ['low', 'medium', 'high', 'critical']},
                 'customer_intent':    {'type': 'string'},
                 'requested_action':   {'type': 'string'},
                 'needs_callback':     {'type': 'boolean'},
                 'churn_risk':         {'type': 'string', 'enum': ['low', 'medium', 'high']},
                 'suggested_reply':    {'type': 'string'}
               },
               'required': ['issue_type', 'urgency', 'customer_intent', 'requested_action',
                            'needs_callback', 'churn_risk', 'suggested_reply'],
               'additionalProperties': false
             }
           }
         ))) AS TRIAGE
  FROM TICKET_SAMPLE s
  ORDER BY s.TICKET_ID
  LIMIT 20                                                  -- EDIT ME: LLM calls are the most expensive
);

SELECT TICKET_ID, SUBJECT, CURRENT_PRIORITY,
       TRIAGE:issue_type::VARCHAR       AS ISSUE_TYPE,
       TRIAGE:urgency::VARCHAR          AS AI_URGENCY,
       TRIAGE:churn_risk::VARCHAR       AS CHURN_RISK,
       TRIAGE:needs_callback::BOOLEAN   AS NEEDS_CALLBACK,
       TRIAGE:requested_action::VARCHAR AS REQUESTED_ACTION,
       TRIAGE:suggested_reply::VARCHAR  AS SUGGESTED_REPLY
FROM TICKET_TRIAGE
ORDER BY TICKET_ID;

-- Where does the AI disagree with the agent-assigned priority?
SELECT CURRENT_PRIORITY, TRIAGE:urgency::VARCHAR AS AI_URGENCY, COUNT(*) AS TICKETS
FROM TICKET_TRIAGE
GROUP BY 1, 2
ORDER BY 1, 2;

------------------------------------------------------------------------------
-- 6. Scenario "Duplicate ticket detection": AI_EMBED + vector similarity,
--    confirmed with AI_SIMILARITY on the candidate pairs
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE TICKET_EMBEDDINGS AS
SELECT TICKET_ID, SUBJECT, BODY, REGION, PRODUCT_NAME,
       AI_EMBED('snowflake-arctic-embed-m-v1.5', SUBJECT || '. ' || BODY) AS EMBEDDING   -- EDIT ME: model
FROM TICKET_SAMPLE;

-- Candidate pairs: cheap vector math on stored embeddings (no extra AI cost)
CREATE OR REPLACE TEMPORARY TABLE DUPLICATE_CANDIDATES AS
SELECT a.TICKET_ID AS TICKET_A, b.TICKET_ID AS TICKET_B,
       a.SUBJECT AS SUBJECT_A, b.SUBJECT AS SUBJECT_B,
       a.BODY AS BODY_A, b.BODY AS BODY_B,
       ROUND(VECTOR_COSINE_SIMILARITY(a.EMBEDDING, b.EMBEDDING), 4) AS VECTOR_SIMILARITY
FROM TICKET_EMBEDDINGS a
JOIN TICKET_EMBEDDINGS b ON a.TICKET_ID < b.TICKET_ID
QUALIFY ROW_NUMBER() OVER (ORDER BY VECTOR_COSINE_SIMILARITY(a.EMBEDDING, b.EMBEDDING) DESC) <= 10;

-- Confirm the top candidates with AI_SIMILARITY (one AI call per pair)
SELECT TICKET_A, TICKET_B, SUBJECT_A, SUBJECT_B, VECTOR_SIMILARITY,
       ROUND(AI_SIM, 4) AS AI_SIMILARITY_SCORE,
       IFF(AI_SIM >= 0.85, 'Likely duplicate', 'Related') AS VERDICT   -- EDIT ME threshold
FROM (
  SELECT d.*, AI_SIMILARITY(d.BODY_A, d.BODY_B) AS AI_SIM
  FROM DUPLICATE_CANDIDATES d
)
ORDER BY VECTOR_SIMILARITY DESC;

------------------------------------------------------------------------------
-- 7. Scenario "Executive insight": AI_AGG - free-form instruction over many rows
------------------------------------------------------------------------------
SELECT AI_AGG(
         'Category: ' || COALESCE(PRODUCT_CATEGORY, 'n/a') || ' | Region: ' || COALESCE(REGION, 'n/a') ||
         ' | Priority: ' || PRIORITY || ' | ' || SUBJECT || '. ' || BODY,
         'You are a VP of Customer Experience. From these support tickets, list the top 5 recurring issues ' ||
         'with an estimated share of tickets, the product categories and regions most affected, and one ' ||
         'concrete action per issue. Use short bullet points.'
       ) AS EXECUTIVE_INSIGHTS
FROM TICKET_SAMPLE;

-- Same, grouped: one paragraph per region
SELECT REGION,
       COUNT(*) AS TICKETS,
       AI_AGG(SUBJECT || '. ' || BODY,
              'In two sentences, what is the main customer problem in this region and what should the regional manager do first?') AS REGION_INSIGHT
FROM TICKET_SAMPLE
GROUP BY REGION
ORDER BY TICKETS DESC;

------------------------------------------------------------------------------
-- 8. Cost tracking (ACCOUNT_USAGE latency: up to a few hours).
--    ACCEL_ADMIN has IMPORTED PRIVILEGES on the SNOWFLAKE database.
------------------------------------------------------------------------------
-- SELECT FUNCTION_NAME, MODEL_NAME,
--        SUM(TOKENS)       AS TOKENS,
--        SUM(TOKEN_CREDITS) AS CREDITS
-- FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY
-- WHERE START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
-- GROUP BY 1, 2
-- ORDER BY CREDITS DESC;

GRANT USAGE ON SCHEMA ACCEL_DB.AISQL TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA ACCEL_DB.AISQL TO ROLE ACCEL_ANALYST;
