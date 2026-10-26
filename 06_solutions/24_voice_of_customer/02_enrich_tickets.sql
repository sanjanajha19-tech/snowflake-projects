/* =============================================================================
   Asset 24 - Voice of Customer (VoC) analytics
   File  02_enrich_tickets.sql
   Purpose
     VOC.ENRICH_TICKETS(BATCH_SIZE) - picks up to BATCH_SIZE tickets that are
     not yet in VOC.TICKET_ENRICHED (oldest first) and enriches them with:
       * AI_SENTIMENT  - overall + aspect-based sentiment (delivery, price,
                         product quality, customer service)
       * SNOWFLAKE.CORTEX.SENTIMENT - numeric score -1..1 for trending
       * AI_CLASSIFY   - topic from the taxonomy (labels with descriptions)
       * AI_EXTRACT    - root cause and product mentioned
     Already-processed tickets are never sent to the model again.

   COST NOTE  Four AI calls per ticket on short text (subject + 2-4 sentences,
     roughly 100 tokens). The default batch of 200 tickets is small; the full
     2,000-ticket demo set is about 8,000 short AI calls. Check actual spend in
     SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY after the first batch
     before raising BATCH_SIZE. Calls are billed per token, the warehouse only
     orchestrates (XSMALL is enough).
   Run as  ACCEL_ADMIN after 01. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS VOC;
USE SCHEMA VOC;

CREATE OR REPLACE PROCEDURE VOC.ENRICH_TICKETS(BATCH_SIZE INTEGER)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    inserted INTEGER DEFAULT 0;
BEGIN
    INSERT INTO ACCEL_DB.VOC.TICKET_ENRICHED
        (TICKET_ID, CREATED_AT, CUSTOMER_ID, PRODUCT_ID, PRODUCT_NAME, PRODUCT_CATEGORY, CHANNEL, PRIORITY,
         STATUS, SUBJECT, BODY, SENTIMENT_RAW, OVERALL_SENTIMENT, SENTIMENT_SCORE, CLASSIFY_RAW, TOPIC,
         EXTRACT_RAW, ROOT_CAUSE, PRODUCT_MENTIONED, PROCESSED_AT)
    WITH batch AS (
        SELECT t.TICKET_ID, t.CREATED_AT, t.CUSTOMER_ID, t.PRODUCT_ID,
               p.PRODUCT_NAME, p.CATEGORY AS PRODUCT_CATEGORY,
               t.CHANNEL, t.PRIORITY, t.STATUS, t.SUBJECT, t.BODY,
               COALESCE(t.SUBJECT, '') || '. ' || COALESCE(t.BODY, '') AS TXT
        FROM ACCEL_DB.DEMO.SUPPORT_TICKETS t
        LEFT JOIN ACCEL_DB.DEMO.PRODUCTS p ON p.PRODUCT_ID = t.PRODUCT_ID
        WHERE NOT EXISTS (SELECT 1 FROM ACCEL_DB.VOC.TICKET_ENRICHED e WHERE e.TICKET_ID = t.TICKET_ID)
        QUALIFY ROW_NUMBER() OVER (ORDER BY t.CREATED_AT, t.TICKET_ID) <= :BATCH_SIZE
    ),
    ai AS (
        SELECT b.*,
               -- EDIT ME: aspects must match VOC.SENTIMENT_ASPECTS
               AI_SENTIMENT(b.TXT, ['delivery', 'price', 'product quality', 'customer service']) AS S_RAW,
               SNOWFLAKE.CORTEX.SENTIMENT(b.TXT)                                                 AS S_SCORE,
               -- EDIT ME: labels/descriptions must match VOC.TOPIC_TAXONOMY
               AI_CLASSIFY(
                   b.TXT,
                   [
                     {'label': 'delivery', 'description': 'Late, missing, damaged-in-transit or wrongly shipped orders; tracking and logistics problems'},
                     {'label': 'billing',  'description': 'Invoices, charges, refunds, payment failures, pricing disputes, credit notes, tax on invoice'},
                     {'label': 'quality',  'description': 'Defective, faulty, poor-quality or not-as-described products; returns because of product defects'},
                     {'label': 'service',  'description': 'Slow or unhelpful support, no response, rude staff, repeated follow-ups, account or access issues'},
                     {'label': 'praise',   'description': 'Compliments, thanks, positive feedback about product, delivery or staff'},
                     {'label': 'other',    'description': 'Anything that does not fit the other topics, including general enquiries'}
                   ],
                   {'task_description': 'Classify the main topic of this customer support ticket'}
               )                                                                                  AS C_RAW,
               AI_EXTRACT(
                   text => b.TXT,
                   responseFormat => {
                       'root_cause':        'In at most 12 words, what is the most likely root cause of the customer problem? Answer none if there is no problem.',
                       'product_mentioned': 'Which product, item or service does the customer mention? Answer none if not mentioned.'
                   }
               )                                                                                  AS X_RAW
        FROM batch b
    )
    SELECT TICKET_ID, CREATED_AT, CUSTOMER_ID, PRODUCT_ID, PRODUCT_NAME, PRODUCT_CATEGORY, CHANNEL, PRIORITY,
           STATUS, SUBJECT, BODY,
           S_RAW,
           NULL,                                   -- overall sentiment filled from S_RAW below
           S_SCORE,
           C_RAW,
           LOWER(C_RAW:labels[0]::VARCHAR),
           X_RAW,
           COALESCE(X_RAW:response:root_cause, X_RAW:root_cause)::VARCHAR,
           COALESCE(X_RAW:response:product_mentioned, X_RAW:product_mentioned)::VARCHAR,
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    FROM ai;

    inserted := SQLROWCOUNT;

    -- overall sentiment = the 'overall' entry in AI_SENTIMENT's categories array
    UPDATE ACCEL_DB.VOC.TICKET_ENRICHED t
       SET OVERALL_SENTIMENT = o.SENTIMENT
      FROM (SELECT e.TICKET_ID, LOWER(f.value:sentiment::VARCHAR) AS SENTIMENT
            FROM ACCEL_DB.VOC.TICKET_ENRICHED e,
                 LATERAL FLATTEN(input => e.SENTIMENT_RAW:categories) f
            WHERE e.OVERALL_SENTIMENT IS NULL
              AND LOWER(f.value:name::VARCHAR) = 'overall') o
     WHERE t.TICKET_ID = o.TICKET_ID
       AND t.OVERALL_SENTIMENT IS NULL;

    -- fall back to the numeric score if the overall entry was not returned
    UPDATE ACCEL_DB.VOC.TICKET_ENRICHED
       SET OVERALL_SENTIMENT = CASE WHEN SENTIMENT_SCORE >  0.25 THEN 'positive'
                                    WHEN SENTIMENT_SCORE < -0.25 THEN 'negative'
                                    ELSE 'neutral' END
     WHERE OVERALL_SENTIMENT IS NULL AND SENTIMENT_SCORE IS NOT NULL;

    INSERT INTO ACCEL_DB.VOC.PROCESSING_LOG
    SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'ENRICH_TICKETS', :inserted, 'batch size ' || :BATCH_SIZE;

    RETURN 'Enriched ' || inserted || ' tickets';
END;
$$;

-- -----------------------------------------------------------------------------
-- Initial load in controlled batches. Run the first CALL, check cost and
-- quality, then run the rest with the larger CALLs below.
-- -----------------------------------------------------------------------------
CALL VOC.ENRICH_TICKETS(200);                                    -- EDIT ME: batch size

SELECT TOPIC, OVERALL_SENTIMENT, COUNT(*) AS TICKETS
FROM VOC.TICKET_ENRICHED GROUP BY 1, 2 ORDER BY 1, 2;

SELECT TICKET_ID, SUBJECT, TOPIC, OVERALL_SENTIMENT, ROUND(SENTIMENT_SCORE, 2) AS SCORE,
       ROOT_CAUSE, PRODUCT_MENTIONED, SENTIMENT_RAW
FROM VOC.TICKET_ENRICHED ORDER BY PROCESSED_AT DESC LIMIT 20;

-- Uncomment to process the remaining demo backlog now (about 9 more batches):
-- CALL VOC.ENRICH_TICKETS(1000);
-- CALL VOC.ENRICH_TICKETS(1000);

-- Cost check (ACCOUNT_USAGE has up to a few hours of latency):
-- SELECT FUNCTION_NAME, MODEL_NAME, SUM(TOKENS) AS TOKENS, SUM(TOKEN_CREDITS) AS CREDITS
-- FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY
-- WHERE START_TIME > DATEADD('day', -1, CURRENT_TIMESTAMP())
-- GROUP BY 1, 2 ORDER BY CREDITS DESC;
