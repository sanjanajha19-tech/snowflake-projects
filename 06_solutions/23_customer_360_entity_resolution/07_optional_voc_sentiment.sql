/* =============================================================================
   Asset 23 - Customer 360 & Entity Resolution
   File  07_optional_voc_sentiment.sql   (OPTIONAL)
   Purpose
     Adds ticket sentiment to the Customer 360 once asset 24 (Voice of Customer)
     has populated ACCEL_DB.VOC.TICKET_ENRICHED. Skip this file if you have not
     installed asset 24 - creating the view would fail without that table.
   Run as  ACCEL_ADMIN after 06 and after 24/02_enrich_tickets.sql. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS C360;
USE SCHEMA C360;

CREATE OR REPLACE VIEW C360.CUSTOMER_360_WITH_SENTIMENT AS
WITH s AS (
    SELECT x.GOLDEN_ID,
           COUNT(*)                                             AS ENRICHED_TICKETS,
           ROUND(AVG(e.SENTIMENT_SCORE), 3)                     AS AVG_SENTIMENT_SCORE,
           COUNT_IF(e.OVERALL_SENTIMENT = 'negative')           AS NEGATIVE_TICKETS,
           MAX_BY(e.OVERALL_SENTIMENT, e.CREATED_AT)            AS LATEST_TICKET_SENTIMENT,
           MODE(e.TOPIC)                                        AS MOST_COMMON_TOPIC
    FROM C360.CUSTOMER_XREF x
    JOIN ACCEL_DB.VOC.TICKET_ENRICHED e ON e.CUSTOMER_ID = x.ERP_CUSTOMER_ID
    WHERE x.SOURCE_SYSTEM = 'ERP'
    GROUP BY x.GOLDEN_ID
)
SELECT c.*,
       s.ENRICHED_TICKETS, s.AVG_SENTIMENT_SCORE, s.NEGATIVE_TICKETS,
       s.LATEST_TICKET_SENTIMENT, s.MOST_COMMON_TOPIC,
       CASE WHEN c.OPEN_HIGH_PRIORITY_TICKETS > 0 AND s.LATEST_TICKET_SENTIMENT = 'negative' THEN 'Red'
            WHEN s.AVG_SENTIMENT_SCORE < -0.2 OR c.OPEN_TICKETS > 2                          THEN 'Amber'
            ELSE 'Green' END AS RELATIONSHIP_HEALTH
FROM C360.CUSTOMER_360 c
LEFT JOIN s ON s.GOLDEN_ID = c.GOLDEN_ID;

GRANT SELECT ON VIEW ACCEL_DB.C360.CUSTOMER_360_WITH_SENTIMENT TO ROLE ACCEL_ANALYST;

SELECT RELATIONSHIP_HEALTH, COUNT(*) AS CUSTOMERS, ROUND(SUM(LIFETIME_VALUE_INR) / 1e7, 2) AS LTV_INR_CRORE
FROM C360.CUSTOMER_360_WITH_SENTIMENT GROUP BY 1 ORDER BY 1;
