/* =============================================================================
   Asset 24 - Voice of Customer (VoC) analytics
   File  03_weekly_themes.sql
   Purpose
     VOC.BUILD_WEEKLY_THEMES(WEEKS_BACK)
        AI_SUMMARIZE_AGG over enriched tickets per (week, product category) for
        the most recent WEEKS_BACK weeks of data -> VOC.WEEKLY_THEMES.
     VOC.BUILD_TOPIC_ISSUES(DAYS_BACK)
        AI_AGG per topic: "top recurring issues" over the last DAYS_BACK days
        -> VOC.TOPIC_ISSUES.
   COST NOTE  One aggregate AI call per (week, category) group and one per topic.
     12 weeks x ~8 categories is roughly 100 calls. Windows are relative to the
     latest ticket date in the data (demo data ends Sep 2026), not today.
   Run as  ACCEL_ADMIN after 02. Rerunnable (rebuilds the requested window only).
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS VOC;
USE SCHEMA VOC;

CREATE OR REPLACE PROCEDURE VOC.BUILD_WEEKLY_THEMES(WEEKS_BACK INTEGER)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    from_week DATE;
    n INTEGER DEFAULT 0;
BEGIN
    SELECT DATEADD('week', -1 * :WEEKS_BACK + 1, DATE_TRUNC('week', MAX(CREATED_AT))::DATE)
      INTO :from_week
      FROM ACCEL_DB.VOC.TICKET_ENRICHED;

    IF (from_week IS NULL) THEN
        RETURN 'No enriched tickets yet - run VOC.ENRICH_TICKETS first';
    END IF;

    DELETE FROM ACCEL_DB.VOC.WEEKLY_THEMES WHERE WEEK_START >= :from_week;

    INSERT INTO ACCEL_DB.VOC.WEEKLY_THEMES
        (WEEK_START, PRODUCT_CATEGORY, TICKETS, NEGATIVE_TICKETS, AVG_SENTIMENT_SCORE, TOP_TOPIC, THEME_SUMMARY, BUILT_AT)
    SELECT DATE_TRUNC('week', CREATED_AT)::DATE                       AS WEEK_START,
           COALESCE(PRODUCT_CATEGORY, 'Unknown')                      AS PRODUCT_CATEGORY,
           COUNT(*)                                                   AS TICKETS,
           COUNT_IF(OVERALL_SENTIMENT = 'negative')                   AS NEGATIVE_TICKETS,
           ROUND(AVG(SENTIMENT_SCORE), 3)                             AS AVG_SENTIMENT_SCORE,
           MODE(TOPIC)                                                AS TOP_TOPIC,
           AI_SUMMARIZE_AGG('[' || COALESCE(TOPIC, 'other') || ', ' || COALESCE(OVERALL_SENTIMENT, 'unknown') || '] '
                            || COALESCE(SUBJECT, '') || ': ' || COALESCE(BODY, ''))  AS THEME_SUMMARY,
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    FROM ACCEL_DB.VOC.TICKET_ENRICHED
    WHERE CREATED_AT >= :from_week
    GROUP BY 1, 2;

    n := SQLROWCOUNT;
    INSERT INTO ACCEL_DB.VOC.PROCESSING_LOG
    SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'BUILD_WEEKLY_THEMES', :n, 'from week ' || :from_week;
    RETURN 'Built ' || n || ' weekly theme summaries from ' || from_week;
END;
$$;

CREATE OR REPLACE PROCEDURE VOC.BUILD_TOPIC_ISSUES(DAYS_BACK INTEGER)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    window_end   DATE;
    window_start DATE;
    n INTEGER DEFAULT 0;
BEGIN
    SELECT MAX(CREATED_AT)::DATE INTO :window_end FROM ACCEL_DB.VOC.TICKET_ENRICHED;
    IF (window_end IS NULL) THEN
        RETURN 'No enriched tickets yet - run VOC.ENRICH_TICKETS first';
    END IF;
    window_start := DATEADD('day', -1 * DAYS_BACK, window_end);

    DELETE FROM ACCEL_DB.VOC.TOPIC_ISSUES;

    INSERT INTO ACCEL_DB.VOC.TOPIC_ISSUES
        (TOPIC, WINDOW_START, WINDOW_END, TICKETS, NEGATIVE_SHARE, TOP_ISSUES, BUILT_AT)
    SELECT COALESCE(TOPIC, 'other'),
           :window_start, :window_end,
           COUNT(*),
           ROUND(COUNT_IF(OVERALL_SENTIMENT = 'negative') / COUNT(*), 3),
           AI_AGG(COALESCE(SUBJECT, '') || ': ' || COALESCE(BODY, '') || ' (root cause: ' || COALESCE(ROOT_CAUSE, 'n/a') || ')',
                  'These are customer support tickets on one topic. List the top 3 recurring issues as short bullet points, '
                  || 'each with an estimated share of tickets and one recommended corrective action. Be concise.'),
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    FROM ACCEL_DB.VOC.TICKET_ENRICHED
    WHERE CREATED_AT::DATE > :window_start
    GROUP BY COALESCE(TOPIC, 'other');

    n := SQLROWCOUNT;
    INSERT INTO ACCEL_DB.VOC.PROCESSING_LOG
    SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'BUILD_TOPIC_ISSUES', :n, 'window ' || :window_start || ' to ' || :window_end;
    RETURN 'Built top issues for ' || n || ' topics';
END;
$$;

CALL VOC.BUILD_WEEKLY_THEMES(12);                                -- EDIT ME: weeks of history to summarise
CALL VOC.BUILD_TOPIC_ISSUES(90);                                 -- EDIT ME: rolling window in days

SELECT WEEK_START, PRODUCT_CATEGORY, TICKETS, NEGATIVE_TICKETS, TOP_TOPIC, THEME_SUMMARY
FROM VOC.WEEKLY_THEMES ORDER BY WEEK_START DESC, TICKETS DESC LIMIT 30;

SELECT TOPIC, TICKETS, NEGATIVE_SHARE, TOP_ISSUES FROM VOC.TOPIC_ISSUES ORDER BY TICKETS DESC;
