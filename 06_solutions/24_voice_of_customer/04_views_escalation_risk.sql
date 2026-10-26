/* =============================================================================
   Asset 24 - Voice of Customer (VoC) analytics
   File  04_views_escalation_risk.sql
   Purpose
     Reporting views for the dashboard:
       VOC.TICKET_ASPECT_SENTIMENT  - one row per ticket x aspect
       VOC.SENTIMENT_TREND_WEEKLY   - volume / sentiment / topic mix by week
       VOC.TOPIC_SUMMARY            - topic volumes, negativity, resolution time
       VOC.ESCALATION_RISK          - open tickets scored for escalation risk
   Run as  ACCEL_ADMIN after 02. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS VOC;
USE SCHEMA VOC;

CREATE OR REPLACE VIEW VOC.TICKET_ASPECT_SENTIMENT AS
SELECT e.TICKET_ID, e.CREATED_AT, e.PRODUCT_CATEGORY, e.TOPIC,
       LOWER(f.value:name::VARCHAR)      AS ASPECT,
       LOWER(f.value:sentiment::VARCHAR) AS ASPECT_SENTIMENT
FROM VOC.TICKET_ENRICHED e,
     LATERAL FLATTEN(input => e.SENTIMENT_RAW:categories) f
WHERE LOWER(f.value:name::VARCHAR) <> 'overall'
  AND LOWER(f.value:sentiment::VARCHAR) <> 'unknown';   -- aspect not discussed in the ticket

CREATE OR REPLACE VIEW VOC.SENTIMENT_TREND_WEEKLY AS
SELECT DATE_TRUNC('week', CREATED_AT)::DATE                  AS WEEK_START,
       COUNT(*)                                              AS TICKETS,
       ROUND(AVG(SENTIMENT_SCORE), 3)                        AS AVG_SENTIMENT_SCORE,
       COUNT_IF(OVERALL_SENTIMENT = 'positive')              AS POSITIVE,
       COUNT_IF(OVERALL_SENTIMENT = 'neutral')               AS NEUTRAL,
       COUNT_IF(OVERALL_SENTIMENT = 'mixed')                 AS MIXED,
       COUNT_IF(OVERALL_SENTIMENT = 'negative')              AS NEGATIVE,
       ROUND(COUNT_IF(OVERALL_SENTIMENT = 'negative') / COUNT(*), 3) AS NEGATIVE_SHARE,
       COUNT_IF(TOPIC = 'delivery') AS DELIVERY,
       COUNT_IF(TOPIC = 'billing')  AS BILLING,
       COUNT_IF(TOPIC = 'quality')  AS QUALITY,
       COUNT_IF(TOPIC = 'service')  AS SERVICE,
       COUNT_IF(TOPIC = 'praise')   AS PRAISE,
       COUNT_IF(TOPIC = 'other')    AS OTHER
FROM VOC.TICKET_ENRICHED
GROUP BY 1;

CREATE OR REPLACE VIEW VOC.TOPIC_SUMMARY AS
SELECT e.TOPIC,
       tx.DESCRIPTION,
       tx.OWNER_TEAM,
       COUNT(*)                                                       AS TICKETS,
       ROUND(AVG(e.SENTIMENT_SCORE), 3)                               AS AVG_SENTIMENT_SCORE,
       ROUND(COUNT_IF(e.OVERALL_SENTIMENT = 'negative') / COUNT(*), 3) AS NEGATIVE_SHARE,
       COUNT_IF(t.STATUS = 'Escalated')                               AS ESCALATED,
       COUNT_IF(t.STATUS = 'Open')                                    AS OPEN_NOW,
       ROUND(AVG(IFF(t.RESOLVED_AT IS NOT NULL, DATEDIFF('hour', t.CREATED_AT, t.RESOLVED_AT), NULL)), 1)
                                                                      AS AVG_RESOLUTION_HOURS,
       MODE(NULLIF(LOWER(e.ROOT_CAUSE), 'none'))                      AS MOST_COMMON_ROOT_CAUSE
FROM VOC.TICKET_ENRICHED e
JOIN ACCEL_DB.DEMO.SUPPORT_TICKETS t ON t.TICKET_ID = e.TICKET_ID
LEFT JOIN VOC.TOPIC_TAXONOMY tx ON tx.TOPIC = e.TOPIC
GROUP BY e.TOPIC, tx.DESCRIPTION, tx.OWNER_TEAM;

-- Escalation-risk score (0-100) for tickets that are still open.       -- EDIT ME weights
-- Uses the live ticket status from DEMO (status may have changed since enrichment).
CREATE OR REPLACE VIEW VOC.ESCALATION_RISK AS
WITH asof AS (SELECT MAX(CREATED_AT) AS AS_OF_TS FROM ACCEL_DB.DEMO.SUPPORT_TICKETS),
history AS (
    SELECT t.TICKET_ID,
           COUNT(p.TICKET_ID) AS PRIOR_TICKETS_90D,
           COUNT_IF(p.STATUS = 'Escalated') AS PRIOR_ESCALATIONS_90D
    FROM ACCEL_DB.DEMO.SUPPORT_TICKETS t
    LEFT JOIN ACCEL_DB.DEMO.SUPPORT_TICKETS p
           ON p.CUSTOMER_ID = t.CUSTOMER_ID
          AND p.CREATED_AT <  t.CREATED_AT
          AND p.CREATED_AT >= DATEADD('day', -90, t.CREATED_AT)
    WHERE t.STATUS = 'Open'
    GROUP BY t.TICKET_ID
),
scored AS (
    SELECT t.TICKET_ID, t.CREATED_AT, t.CUSTOMER_ID, c.CUSTOMER_NAME, c.SEGMENT, t.CHANNEL, t.PRIORITY,
           t.SUBJECT, e.TOPIC, e.OVERALL_SENTIMENT, e.SENTIMENT_SCORE, e.ROOT_CAUSE, e.PRODUCT_CATEGORY,
           h.PRIOR_TICKETS_90D, h.PRIOR_ESCALATIONS_90D,
           DATEDIFF('hour', t.CREATED_AT, a.AS_OF_TS) AS AGE_HOURS,
           ( CASE e.OVERALL_SENTIMENT WHEN 'negative' THEN 30 WHEN 'mixed' THEN 15 ELSE 0 END
           + CASE t.PRIORITY WHEN 'Critical' THEN 25 WHEN 'High' THEN 15 WHEN 'Medium' THEN 5 ELSE 0 END
           + CASE WHEN e.TOPIC IN ('delivery', 'billing', 'quality') THEN 10 ELSE 0 END
           + CASE WHEN c.SEGMENT = 'Enterprise' THEN 10 WHEN c.SEGMENT = 'Mid-Market' THEN 5 ELSE 0 END
           + LEAST(COALESCE(h.PRIOR_TICKETS_90D, 0) * 5, 15)
           + LEAST(COALESCE(h.PRIOR_ESCALATIONS_90D, 0) * 10, 10)
           + CASE WHEN DATEDIFF('hour', t.CREATED_AT, a.AS_OF_TS) > 72 THEN 10 ELSE 0 END
           ) AS RISK_SCORE
    FROM ACCEL_DB.DEMO.SUPPORT_TICKETS t
    CROSS JOIN asof a
    JOIN history h ON h.TICKET_ID = t.TICKET_ID
    LEFT JOIN VOC.TICKET_ENRICHED e ON e.TICKET_ID = t.TICKET_ID
    LEFT JOIN ACCEL_DB.DEMO.CUSTOMERS c ON c.CUSTOMER_ID = t.CUSTOMER_ID
    WHERE t.STATUS = 'Open'
)
SELECT s.*,
       LEAST(s.RISK_SCORE, 100) AS RISK_SCORE_CAPPED,
       CASE WHEN s.RISK_SCORE >= 60 THEN 'High'
            WHEN s.RISK_SCORE >= 35 THEN 'Medium'
            ELSE 'Low' END AS RISK_BAND,
       IFF(s.TOPIC IS NULL, 'Not yet enriched', NULL) AS NOTE
FROM scored s;

GRANT USAGE ON SCHEMA ACCEL_DB.VOC TO ROLE ACCEL_ANALYST;
GRANT USAGE ON SCHEMA ACCEL_DB.VOC TO ROLE ACCEL_VIEWER;
GRANT SELECT ON ALL TABLES IN SCHEMA ACCEL_DB.VOC TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ACCEL_DB.VOC TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ACCEL_DB.VOC TO ROLE ACCEL_VIEWER;

SELECT RISK_BAND, COUNT(*) AS OPEN_TICKETS FROM VOC.ESCALATION_RISK GROUP BY 1 ORDER BY 1;

SELECT TICKET_ID, CUSTOMER_NAME, SEGMENT, PRIORITY, TOPIC, OVERALL_SENTIMENT, AGE_HOURS, RISK_SCORE, SUBJECT
FROM VOC.ESCALATION_RISK ORDER BY RISK_SCORE DESC LIMIT 20;
