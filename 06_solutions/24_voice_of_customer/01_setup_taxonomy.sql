/* =============================================================================
   Asset 24 - Voice of Customer (VoC) analytics
   File  01_setup_taxonomy.sql
   Purpose
     Schema VOC, the topic taxonomy and sentiment aspects (-- EDIT ME), and the
     output tables that the enrichment procedure fills incrementally.
   Run as  ACCEL_ADMIN. Rerunnable - enriched results are kept
     (CREATE TABLE IF NOT EXISTS) so you never pay twice for the same ticket.
     To reprocess everything: TRUNCATE TABLE VOC.TICKET_ENRICHED;
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS VOC;
USE SCHEMA VOC;

-- Topic taxonomy used by AI_CLASSIFY.                                   -- EDIT ME
-- NOTE: the same labels/descriptions are written as a literal inside
-- VOC.ENRICH_TICKETS (02_enrich_tickets.sql). Change both together.
CREATE OR REPLACE TABLE VOC.TOPIC_TAXONOMY (TOPIC VARCHAR, DESCRIPTION VARCHAR, OWNER_TEAM VARCHAR);
INSERT INTO VOC.TOPIC_TAXONOMY VALUES
  ('delivery', 'Late, missing, damaged-in-transit or wrongly shipped orders; tracking and logistics problems', 'Logistics'),
  ('billing',  'Invoices, charges, refunds, payment failures, pricing disputes, credit notes, tax on invoice', 'Finance'),
  ('quality',  'Defective, faulty, poor-quality or not-as-described products; returns because of product defects', 'Quality'),
  ('service',  'Slow or unhelpful support, no response, rude staff, repeated follow-ups, account or access issues', 'Customer Service'),
  ('praise',   'Compliments, thanks, positive feedback about product, delivery or staff', 'Marketing'),
  ('other',    'Anything that does not fit the other topics, including general enquiries', 'Customer Service');

-- Aspects for aspect-based sentiment (AI_SENTIMENT categories).           -- EDIT ME (also literal in 02)
CREATE OR REPLACE TABLE VOC.SENTIMENT_ASPECTS (ASPECT VARCHAR);
INSERT INTO VOC.SENTIMENT_ASPECTS VALUES ('delivery'), ('price'), ('product quality'), ('customer service');

-- One row per processed ticket. Kept across reruns.
-- Column types are inherited from DEMO via CTAS (WHERE FALSE) so ids always line up.
CREATE TABLE IF NOT EXISTS VOC.TICKET_ENRICHED AS
SELECT t.TICKET_ID, t.CREATED_AT, t.CUSTOMER_ID, t.PRODUCT_ID,
       p.PRODUCT_NAME,
       p.CATEGORY                 AS PRODUCT_CATEGORY,
       t.CHANNEL, t.PRIORITY, t.STATUS, t.SUBJECT, t.BODY,
       NULL::VARIANT              AS SENTIMENT_RAW,      -- AI_SENTIMENT output (overall + aspects)
       NULL::VARCHAR              AS OVERALL_SENTIMENT,  -- positive / negative / neutral / mixed / unknown
       NULL::FLOAT                AS SENTIMENT_SCORE,    -- SNOWFLAKE.CORTEX.SENTIMENT, -1 .. 1
       NULL::VARIANT              AS CLASSIFY_RAW,       -- AI_CLASSIFY output
       NULL::VARCHAR              AS TOPIC,
       NULL::VARIANT              AS EXTRACT_RAW,        -- AI_EXTRACT output
       NULL::VARCHAR              AS ROOT_CAUSE,
       NULL::VARCHAR              AS PRODUCT_MENTIONED,
       NULL::TIMESTAMP_NTZ        AS PROCESSED_AT
FROM ACCEL_DB.DEMO.SUPPORT_TICKETS t
LEFT JOIN ACCEL_DB.DEMO.PRODUCTS p ON p.PRODUCT_ID = t.PRODUCT_ID
WHERE FALSE;

-- Weekly AI theme summaries per product category.
CREATE TABLE IF NOT EXISTS VOC.WEEKLY_THEMES (
    WEEK_START          DATE,
    PRODUCT_CATEGORY    VARCHAR,
    TICKETS             NUMBER,
    NEGATIVE_TICKETS    NUMBER,
    AVG_SENTIMENT_SCORE FLOAT,
    TOP_TOPIC           VARCHAR,
    THEME_SUMMARY       VARCHAR,
    BUILT_AT            TIMESTAMP_NTZ
);

-- Top recurring issues per topic (rolling window).
CREATE TABLE IF NOT EXISTS VOC.TOPIC_ISSUES (
    TOPIC               VARCHAR,
    WINDOW_START        DATE,
    WINDOW_END          DATE,
    TICKETS             NUMBER,
    NEGATIVE_SHARE      FLOAT,
    TOP_ISSUES          VARCHAR,
    BUILT_AT            TIMESTAMP_NTZ
);

-- Audit of every batch run (row counts help forecast AI cost).
CREATE TABLE IF NOT EXISTS VOC.PROCESSING_LOG (
    RUN_AT        TIMESTAMP_NTZ,
    STEP          VARCHAR,
    ROWS_PROCESSED NUMBER,
    NOTE          VARCHAR
);

SELECT COUNT(*) AS TICKETS_IN_DEMO,
       (SELECT COUNT(*) FROM VOC.TICKET_ENRICHED) AS ALREADY_ENRICHED
FROM ACCEL_DB.DEMO.SUPPORT_TICKETS;
