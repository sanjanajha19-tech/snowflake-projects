/* =============================================================================
   Asset 25 - Supply Chain Control Tower
   File  03_exceptions_and_alert.sql
   Purpose
     SCT.EXCEPTIONS               - actionable exception queue (one row per issue)
     SCT.REFRESH_EXCEPTIONS()     - procedure that (re)populates the queue for the
                                    current as-of date, preserving owner/status
                                    already set by planners
     SCT.ALERT_LOG                - history of alert firings
     SCT.CRITICAL_STOCKOUT_ALERT  - ALERT: when any plant-product is CRITICAL,
                                    refresh exceptions and log the event (optional
                                    email via SYSTEM$SEND_EMAIL, commented)
   Prerequisite: ACCEL_ADMIN has EXECUTE ALERT (granted by 00_setup).
   Run as  ACCEL_ADMIN after 01-02. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SCT;
USE SCHEMA SCT;

CREATE TABLE IF NOT EXISTS SCT.EXCEPTIONS (
    EXCEPTION_KEY     VARCHAR,          -- stable key: type + entity ids
    AS_OF_DATE        DATE,
    EXCEPTION_TYPE    VARCHAR,          -- STOCKOUT_RISK / LATE_PO / SUPPLIER_OTIF / EXCESS_STOCK
    SEVERITY          VARCHAR,          -- Critical / High / Medium
    PLANT_ID          VARCHAR,
    PRODUCT_ID        VARCHAR,
    SUPPLIER_ID       VARCHAR,
    PO_ID             VARCHAR,
    METRIC_NAME       VARCHAR,
    METRIC_VALUE      FLOAT,
    REVENUE_AT_RISK   NUMBER(18,2),
    DESCRIPTION       VARCHAR,
    RECOMMENDED_ACTION VARCHAR,
    OWNER             VARCHAR,
    STATUS            VARCHAR,          -- New / Acknowledged / Resolved
    DETECTED_AT       TIMESTAMP_NTZ,
    UPDATED_AT        TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS SCT.ALERT_LOG (
    FIRED_AT          TIMESTAMP_NTZ,
    ALERT_NAME        VARCHAR,
    CRITICAL_ITEMS    NUMBER,
    REVENUE_AT_RISK   NUMBER(18,2),
    MESSAGE           VARCHAR
);

CREATE OR REPLACE PROCEDURE SCT.REFRESH_EXCEPTIONS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    n INTEGER DEFAULT 0;
BEGIN
    CREATE OR REPLACE TEMPORARY TABLE ACCEL_DB.SCT.TMP_EXCEPTIONS AS
    -- 1. stockout risk
    SELECT 'STOCKOUT|' || sr.PLANT_ID || '|' || sr.PRODUCT_ID       AS EXCEPTION_KEY,
           sr.AS_OF_DATE, 'STOCKOUT_RISK' AS EXCEPTION_TYPE,
           IFF(sr.RISK_LEVEL = 'CRITICAL', 'Critical', 'High')       AS SEVERITY,
           sr.PLANT_ID::VARCHAR AS PLANT_ID, sr.PRODUCT_ID::VARCHAR AS PRODUCT_ID,
           NULL::VARCHAR AS SUPPLIER_ID, NULL::VARCHAR AS PO_ID,
           'DAYS_OF_SUPPLY' AS METRIC_NAME, sr.DAYS_OF_SUPPLY::FLOAT AS METRIC_VALUE,
           sr.REVENUE_AT_RISK,
           sr.PRODUCT_NAME || ' at ' || COALESCE(sr.PLANT_NAME, sr.PLANT_ID::VARCHAR) || ': on hand ' || sr.ON_HAND_QTY
             || ', projected ' || sr.PROJECTED_ON_HAND || ' in ' || sr.HORIZON_DAYS || ' days (safety stock '
             || sr.SAFETY_STOCK || ')' AS DESCRIPTION,
           IFF(sr.LATE_OPEN_POS > 0, 'Expedite ' || sr.LATE_OPEN_POS || ' late PO(s); consider stock transfer',
               'Raise PO / transfer stock from another plant') AS RECOMMENDED_ACTION
    FROM ACCEL_DB.SCT.STOCKOUT_RISK sr
    WHERE sr.RISK_LEVEL IN ('CRITICAL', 'HIGH')
    UNION ALL
    -- 2. late POs beyond the tolerance
    SELECT 'LATE_PO|' || li.PO_ID, cfg.AS_OF_DATE, 'LATE_PO',
           CASE WHEN li.STOCKOUT_RISK_LEVEL = 'CRITICAL' THEN 'Critical'
                WHEN li.STOCKOUT_RISK_LEVEL = 'HIGH' OR li.DAYS_LATE > 30 THEN 'High'
                ELSE 'Medium' END,
           li.PLANT_ID::VARCHAR, li.PRODUCT_ID::VARCHAR, li.SUPPLIER_ID::VARCHAR, li.PO_ID::VARCHAR,
           'DAYS_LATE', li.DAYS_LATE::FLOAT, li.REVENUE_AT_RISK,
           'PO ' || li.PO_ID || ' from ' || COALESCE(li.SUPPLIER_NAME, '?') || ' is ' || li.DAYS_LATE
             || ' days late (' || li.LATE_QTY || ' units); ' || li.OPEN_CUSTOMER_ORDERS || ' open customer orders exposed',
           li.RECOMMENDED_ACTION
    FROM ACCEL_DB.SCT.LATE_PO_IMPACT li
    CROSS JOIN ACCEL_DB.SCT.CONFIG_V cfg
    WHERE li.DAYS_LATE >= cfg.LATE_PO_DAYS
    UNION ALL
    -- 3. supplier OTIF below target
    SELECT 'SUPPLIER_OTIF|' || sc.SUPPLIER_ID, cfg.AS_OF_DATE, 'SUPPLIER_OTIF',
           IFF(sc.COMPUTED_RISK_RATING = 'High', 'High', 'Medium'),
           NULL, NULL, sc.SUPPLIER_ID::VARCHAR, NULL,
           'OTIF_PCT', sc.OTIF_PCT::FLOAT, NULL,
           sc.SUPPLIER_NAME || ': OTIF ' || ROUND(sc.OTIF_PCT * 100, 1) || '% vs target '
             || ROUND(cfg.OTIF_TARGET * 100, 0) || '%, avg delay when late ' || COALESCE(sc.AVG_DELAY_WHEN_LATE, 0) || ' days',
           'Supplier performance review; agree corrective action plan'
    FROM ACCEL_DB.SCT.SUPPLIER_SCORECARD sc
    CROSS JOIN ACCEL_DB.SCT.CONFIG_V cfg
    WHERE sc.BELOW_OTIF_TARGET
    UNION ALL
    -- 4. excess stock (working capital)
    SELECT 'EXCESS|' || ip.PLANT_ID || '|' || ip.PRODUCT_ID, cfg.AS_OF_DATE, 'EXCESS_STOCK', 'Medium',
           ip.PLANT_ID::VARCHAR, ip.PRODUCT_ID::VARCHAR, NULL, NULL,
           'DAYS_OF_SUPPLY', ip.DAYS_OF_SUPPLY::FLOAT, NULL,
           ip.PRODUCT_NAME || ' at ' || COALESCE(ip.PLANT_NAME, ip.PLANT_ID::VARCHAR) || ': ' || ip.DAYS_OF_SUPPLY
             || ' days of supply, ' || ip.INVENTORY_VALUE_AT_COST || ' tied up at cost',
           'Pause replenishment; transfer to plants at risk'
    FROM ACCEL_DB.SCT.INVENTORY_POSITION ip
    CROSS JOIN ACCEL_DB.SCT.CONFIG_V cfg
    WHERE ip.DAYS_OF_SUPPLY > cfg.EXCESS_DOS;

    -- keep planner-maintained OWNER / STATUS for exceptions that are still present
    MERGE INTO ACCEL_DB.SCT.EXCEPTIONS t
    USING ACCEL_DB.SCT.TMP_EXCEPTIONS s
       ON t.EXCEPTION_KEY = s.EXCEPTION_KEY AND t.STATUS <> 'Resolved'
    WHEN MATCHED THEN UPDATE SET
         t.AS_OF_DATE = s.AS_OF_DATE, t.SEVERITY = s.SEVERITY, t.METRIC_VALUE = s.METRIC_VALUE,
         t.REVENUE_AT_RISK = s.REVENUE_AT_RISK, t.DESCRIPTION = s.DESCRIPTION,
         t.RECOMMENDED_ACTION = s.RECOMMENDED_ACTION, t.UPDATED_AT = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    WHEN NOT MATCHED THEN INSERT
         (EXCEPTION_KEY, AS_OF_DATE, EXCEPTION_TYPE, SEVERITY, PLANT_ID, PRODUCT_ID, SUPPLIER_ID, PO_ID,
          METRIC_NAME, METRIC_VALUE, REVENUE_AT_RISK, DESCRIPTION, RECOMMENDED_ACTION, OWNER, STATUS,
          DETECTED_AT, UPDATED_AT)
    VALUES (s.EXCEPTION_KEY, s.AS_OF_DATE, s.EXCEPTION_TYPE, s.SEVERITY, s.PLANT_ID, s.PRODUCT_ID, s.SUPPLIER_ID,
            s.PO_ID, s.METRIC_NAME, s.METRIC_VALUE, s.REVENUE_AT_RISK, s.DESCRIPTION, s.RECOMMENDED_ACTION,
            NULL, 'New', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ);

    -- open exceptions that no longer occur are auto-resolved
    UPDATE ACCEL_DB.SCT.EXCEPTIONS t
       SET STATUS = 'Resolved', UPDATED_AT = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
     WHERE t.STATUS <> 'Resolved'
       AND NOT EXISTS (SELECT 1 FROM ACCEL_DB.SCT.TMP_EXCEPTIONS s WHERE s.EXCEPTION_KEY = t.EXCEPTION_KEY);

    SELECT COUNT(*) INTO :n FROM ACCEL_DB.SCT.EXCEPTIONS WHERE STATUS <> 'Resolved';
    RETURN n || ' open exceptions';
END;
$$;

CALL SCT.REFRESH_EXCEPTIONS();

-- Procedure the alert calls: refresh the queue and log the firing.
CREATE OR REPLACE PROCEDURE SCT.RAISE_CRITICAL_STOCKOUT_ALERT()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    items INTEGER DEFAULT 0;
    rar   NUMBER(18,2) DEFAULT 0;
    msg   VARCHAR;
BEGIN
    CALL ACCEL_DB.SCT.REFRESH_EXCEPTIONS();
    SELECT COUNT(*), COALESCE(SUM(REVENUE_AT_RISK), 0) INTO :items, :rar
      FROM ACCEL_DB.SCT.STOCKOUT_RISK WHERE RISK_LEVEL = 'CRITICAL';
    msg := items || ' plant-products at CRITICAL stockout risk; revenue at risk ' || rar;
    INSERT INTO ACCEL_DB.SCT.ALERT_LOG (FIRED_AT, ALERT_NAME, CRITICAL_ITEMS, REVENUE_AT_RISK, MESSAGE)
    VALUES (CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 'CRITICAL_STOCKOUT_ALERT', :items, :rar, :msg);
    -- Optional e-mail. Requires an email notification integration (ACCEL_ADMIN has CREATE INTEGRATION), e.g.
    --   CREATE NOTIFICATION INTEGRATION ACCEL_EMAIL_INT TYPE = EMAIL ENABLED = TRUE
    --     ALLOWED_RECIPIENTS = ('planner@yourcompany.com');
    --   (recipients must be verified users in this account)
    -- then uncomment:                                                   -- EDIT ME
    -- CALL SYSTEM$SEND_EMAIL('ACCEL_EMAIL_INT', 'planner@yourcompany.com', 'Critical stockout risk', :msg);
    RETURN msg;
END;
$$;

CREATE OR REPLACE ALERT SCT.CRITICAL_STOCKOUT_ALERT
  WAREHOUSE = ACCEL_WH
  SCHEDULE = 'USING CRON 45 7 * * * Asia/Kolkata'                -- EDIT ME: daily 07:45 IST
  IF (EXISTS (SELECT 1 FROM ACCEL_DB.SCT.STOCKOUT_RISK WHERE RISK_LEVEL = 'CRITICAL'))
  THEN CALL ACCEL_DB.SCT.RAISE_CRITICAL_STOCKOUT_ALERT();

ALTER ALERT SCT.CRITICAL_STOCKOUT_ALERT RESUME;

-- Fire the alert logic once now for the demo (same effect as the alert action):
CALL SCT.RAISE_CRITICAL_STOCKOUT_ALERT();

SELECT * FROM SCT.ALERT_LOG ORDER BY FIRED_AT DESC LIMIT 10;

SELECT EXCEPTION_TYPE, SEVERITY, COUNT(*) AS OPEN_EXCEPTIONS, ROUND(SUM(REVENUE_AT_RISK), 0) AS REVENUE_AT_RISK
FROM SCT.EXCEPTIONS WHERE STATUS <> 'Resolved'
GROUP BY 1, 2 ORDER BY 1, 2;

-- Alert run history:
-- SELECT * FROM TABLE(ACCEL_DB.INFORMATION_SCHEMA.ALERT_HISTORY(
--     SCHEDULED_TIME_RANGE_START => DATEADD('day', -7, CURRENT_TIMESTAMP()))) ORDER BY SCHEDULED_TIME DESC;
-- To stop it: ALTER ALERT SCT.CRITICAL_STOCKOUT_ALERT SUSPEND;
