/* =============================================================================
   Asset 26 - ESG & Sustainability Hub
   File  04_data_quality_and_disclosures.sql
   Purpose
     ESG.EVIDENCE_TRACKER      - evidence / data-owner tracker per plant x month x
                                 activity (kept across reruns; seeded for the demo)
     ESG.DATA_QUALITY_SUMMARY  - completeness, estimated share, evidence coverage,
                                 placeholder factors, month-on-month outliers
     ESG.BRSR_P6_SUMMARY       - BRSR-style (India SEBI Business Responsibility and
                                 Sustainability Report, Principle 6) energy and GHG
                                 indicators by Indian financial year
     ESG.GHG_DISCLOSURE_SUMMARY - generic calendar-year GHG inventory summary
   These outputs SUPPORT disclosure preparation. They are not a substitute for the
   official BRSR format, the reporting entity's boundary decisions, or reasonable
   assurance by an accredited assurance provider.
   Run as  ACCEL_ADMIN after 03. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS ESG;
USE SCHEMA ESG;

-- -----------------------------------------------------------------------------
-- 1. Evidence tracker (persistent - edited by data owners)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ESG.EVIDENCE_TRACKER (
    PLANT_ID        VARCHAR,
    PERIOD_MONTH    DATE,
    ACTIVITY_TYPE   VARCHAR,
    EVIDENCE_TYPE   VARCHAR,     -- Utility bill / Fuel invoice / Meter reading / TMS extract / ERP report
    EVIDENCE_REF    VARCHAR,     -- document id or file path (e.g. stage URL)
    STATUS          VARCHAR,     -- Pending / Received / Verified / Rejected
    DATA_OWNER      VARCHAR,
    REVIEWED_BY     VARCHAR,
    REVIEWED_AT     TIMESTAMP_NTZ,
    NOTES           VARCHAR
);

-- Seed rows for activity rows not yet tracked (deterministic demo statuses).
INSERT INTO ESG.EVIDENCE_TRACKER
SELECT a.PLANT_ID::VARCHAR, a.PERIOD_MONTH, a.ACTIVITY_TYPE,
       CASE a.ACTIVITY_TYPE WHEN 'ELECTRICITY' THEN 'Utility bill'
                            WHEN 'DIESEL' THEN 'Fuel invoice'
                            WHEN 'NATURAL_GAS' THEN 'Meter reading'
                            WHEN 'FREIGHT' THEN 'TMS extract'
                            ELSE 'ERP report' END,
       IFF(h < 85, a.ACTIVITY_TYPE || '-' || a.PLANT_ID || '-' || TO_CHAR(a.PERIOD_MONTH, 'YYYYMM'), NULL),
       CASE WHEN a.DATA_STATUS = 'Projected' THEN 'Pending'
            WHEN h < 60 THEN 'Verified'
            WHEN h < 85 THEN 'Received'
            WHEN h < 95 THEN 'Pending'
            ELSE 'Rejected' END,
       'Plant ' || a.PLANT_ID || ' EHS lead',
       IFF(h < 60 AND a.DATA_STATUS = 'Actual', 'Sustainability controller', NULL),
       IFF(h < 60 AND a.DATA_STATUS = 'Actual', DATEADD('day', 20, LAST_DAY(a.PERIOD_MONTH))::TIMESTAMP_NTZ, NULL),
       IFF(h >= 95 AND a.DATA_STATUS = 'Actual', 'Bill period does not match reporting month - resubmit', NULL)
FROM (SELECT DISTINCT PLANT_ID, PERIOD_MONTH, ACTIVITY_TYPE, DATA_STATUS,
             MOD(ABS(HASH(PLANT_ID, PERIOD_MONTH, ACTIVITY_TYPE, 'ev')), 100) AS h
      FROM ESG.ACTIVITY_DATA) a
WHERE NOT EXISTS (SELECT 1 FROM ESG.EVIDENCE_TRACKER t
                  WHERE t.PLANT_ID = a.PLANT_ID::VARCHAR AND t.PERIOD_MONTH = a.PERIOD_MONTH
                    AND t.ACTIVITY_TYPE = a.ACTIVITY_TYPE);

-- -----------------------------------------------------------------------------
-- 2. Data quality summary per plant x activity x calendar year (actual months)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW ESG.DATA_QUALITY_SUMMARY AS
WITH act AS (
    SELECT PLANT_ID, PERIOD_MONTH, ACTIVITY_TYPE,
           SUM(QUANTITY)                       AS QUANTITY,
           MAX(IFF(DATA_QUALITY = 'Estimated', 1, 0)) AS IS_ESTIMATED
    FROM ESG.ACTIVITY_DATA
    WHERE DATA_STATUS = 'Actual'
    GROUP BY 1, 2, 3
),
mom AS (
    SELECT a.*,
           LAG(QUANTITY) OVER (PARTITION BY PLANT_ID, ACTIVITY_TYPE ORDER BY PERIOD_MONTH) AS PREV_QTY
    FROM act a
),
expected AS (
    SELECT YEAR(PERIOD_MONTH) AS CALENDAR_YEAR, COUNT(DISTINCT PERIOD_MONTH) AS EXPECTED_MONTHS
    FROM ESG.ACTIVITY_DATA WHERE DATA_STATUS = 'Actual' GROUP BY 1
)
SELECT m.PLANT_ID, m.ACTIVITY_TYPE, YEAR(m.PERIOD_MONTH) AS CALENDAR_YEAR,
       COUNT(*)                                                       AS MONTHS_REPORTED,
       MAX(x.EXPECTED_MONTHS)                                         AS MONTHS_EXPECTED,
       ROUND(COUNT(*) / MAX(x.EXPECTED_MONTHS), 3)                    AS COMPLETENESS,
       ROUND(AVG(m.IS_ESTIMATED), 3)                                  AS ESTIMATED_SHARE,
       COUNT_IF(m.PREV_QTY > 0 AND ABS(m.QUANTITY / m.PREV_QTY - 1) > 0.30) AS MOM_OUTLIERS_30PCT,
       ROUND(COUNT_IF(t.STATUS = 'Verified') / COUNT(*), 3)           AS EVIDENCE_VERIFIED_SHARE,
       COUNT_IF(t.STATUS IN ('Pending', 'Rejected') OR t.STATUS IS NULL) AS EVIDENCE_GAPS
FROM mom m
JOIN expected x ON x.CALENDAR_YEAR = YEAR(m.PERIOD_MONTH)
LEFT JOIN ESG.EVIDENCE_TRACKER t
       ON t.PLANT_ID = m.PLANT_ID::VARCHAR AND t.PERIOD_MONTH = m.PERIOD_MONTH AND t.ACTIVITY_TYPE = m.ACTIVITY_TYPE
GROUP BY m.PLANT_ID, m.ACTIVITY_TYPE, YEAR(m.PERIOD_MONTH);

-- -----------------------------------------------------------------------------
-- 3. BRSR-style Principle 6 summary (by Indian FY, actual months only)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW ESG.BRSR_P6_SUMMARY AS
WITH energy AS (
    SELECT d.INDIAN_FY,
           SUM(IFF(d.ACTIVITY_TYPE = 'ELECTRICITY', d.QUANTITY * c.GJ_PER_UNIT, 0))                 AS ELECTRICITY_GJ,
           SUM(IFF(d.ACTIVITY_TYPE IN ('DIESEL', 'NATURAL_GAS'), d.QUANTITY * c.GJ_PER_UNIT, 0))    AS FUEL_GJ,
           SUM(IFF(d.SCOPE = 'Scope 1', d.TCO2E, 0))                                                AS SCOPE1,
           SUM(IFF(d.SCOPE = 'Scope 2', d.TCO2E, 0))                                                AS SCOPE2,
           SUM(IFF(d.SCOPE = 'Scope 3', d.TCO2E, 0))                                                AS SCOPE3,
           COUNT(DISTINCT d.PERIOD_MONTH)                                                           AS MONTHS,
           ROUND(COUNT_IF(d.DATA_QUALITY = 'Estimated') / COUNT(*), 3)                              AS EST_SHARE,
           COUNT_IF(d.FACTOR_IS_PLACEHOLDER)                                                        AS PLACEHOLDER_ROWS
    FROM ESG.EMISSIONS_DETAIL d
    LEFT JOIN ESG.ENERGY_CONVERSION c ON c.ACTIVITY_TYPE = d.ACTIVITY_TYPE AND c.UNIT = d.UNIT
    WHERE d.DATA_STATUS = 'Actual'
    GROUP BY d.INDIAN_FY
),
turnover AS (
    SELECT 'FY' || TO_VARCHAR(YEAR(DATEADD('month', -3, PERIOD_MONTH))) || '-'
                || RIGHT(TO_VARCHAR(YEAR(DATEADD('month', -3, PERIOD_MONTH)) + 1), 2) AS INDIAN_FY,
           SUM(REVENUE_INR) AS TURNOVER_INR
    FROM ESG.REVENUE_MONTHLY
    GROUP BY 1
),
production AS (
    SELECT 'FY' || TO_VARCHAR(YEAR(DATEADD('month', -3, PERIOD_MONTH))) || '-'
                || RIGHT(TO_VARCHAR(YEAR(DATEADD('month', -3, PERIOD_MONTH)) + 1), 2) AS INDIAN_FY,
           SUM(UNITS_PRODUCED) AS UNITS
    FROM ESG.PLANT_PRODUCTION
    GROUP BY 1
),
fy AS (
    SELECT e.*, t.TURNOVER_INR, p.UNITS,
           IFF(e.MONTHS < 12, 'Partial year (' || e.MONTHS || ' months)', 'Full year') AS COVERAGE,
           IFF(e.PLACEHOLDER_ROWS > 0, 'Uses PLACEHOLDER emission factors - not for disclosure', 'Factors sourced') AS FACTOR_STATUS
    FROM energy e
    LEFT JOIN turnover t   ON t.INDIAN_FY = e.INDIAN_FY
    LEFT JOIN production p ON p.INDIAN_FY = e.INDIAN_FY
)
SELECT INDIAN_FY, 1 AS SORT_ORDER, 'P6-EI1' AS REF, 'Total electricity consumption (A)' AS INDICATOR,
       ROUND(ELECTRICITY_GJ, 1)::FLOAT AS VALUE, 'GJ' AS UNIT, COVERAGE, FACTOR_STATUS, EST_SHARE FROM fy
UNION ALL SELECT INDIAN_FY, 2, 'P6-EI1', 'Total fuel consumption (B)', ROUND(FUEL_GJ, 1), 'GJ', COVERAGE, FACTOR_STATUS, EST_SHARE FROM fy
UNION ALL SELECT INDIAN_FY, 3, 'P6-EI1', 'Total energy consumption (A+B)', ROUND(ELECTRICITY_GJ + FUEL_GJ, 1), 'GJ', COVERAGE, FACTOR_STATUS, EST_SHARE FROM fy
UNION ALL SELECT INDIAN_FY, 4, 'P6-EI1', 'Energy intensity per rupee of turnover', (ELECTRICITY_GJ + FUEL_GJ)::FLOAT / NULLIF(TURNOVER_INR, 0)::FLOAT, 'GJ / INR', COVERAGE, FACTOR_STATUS, EST_SHARE FROM fy
UNION ALL SELECT INDIAN_FY, 5, 'P6-EI1', 'Energy intensity per unit of physical output', ROUND((ELECTRICITY_GJ + FUEL_GJ) / NULLIF(UNITS, 0), 6), 'GJ / unit', COVERAGE, FACTOR_STATUS, EST_SHARE FROM fy
UNION ALL SELECT INDIAN_FY, 6, 'P6-EI7', 'Total Scope 1 emissions', ROUND(SCOPE1, 1), 'tCO2e', COVERAGE, FACTOR_STATUS, EST_SHARE FROM fy
UNION ALL SELECT INDIAN_FY, 7, 'P6-EI7', 'Total Scope 2 emissions (location-based)', ROUND(SCOPE2, 1), 'tCO2e', COVERAGE, FACTOR_STATUS, EST_SHARE FROM fy
UNION ALL SELECT INDIAN_FY, 8, 'P6-EI7', 'Scope 1 and 2 emission intensity per rupee of turnover', (SCOPE1 + SCOPE2)::FLOAT / NULLIF(TURNOVER_INR, 0)::FLOAT, 'tCO2e / INR', COVERAGE, FACTOR_STATUS, EST_SHARE FROM fy
UNION ALL SELECT INDIAN_FY, 9, 'P6-EI7', 'Scope 1 and 2 emission intensity per INR crore of turnover', ROUND((SCOPE1 + SCOPE2) / NULLIF(TURNOVER_INR / 1e7, 0), 4), 'tCO2e / INR crore', COVERAGE, FACTOR_STATUS, EST_SHARE FROM fy
UNION ALL SELECT INDIAN_FY, 10, 'P6-EI7', 'Scope 1 and 2 emission intensity per unit of physical output', ROUND((SCOPE1 + SCOPE2) / NULLIF(UNITS, 0) * 1000, 4), 'kgCO2e / unit', COVERAGE, FACTOR_STATUS, EST_SHARE FROM fy
UNION ALL SELECT INDIAN_FY, 11, 'P6-LI', 'Scope 3 emissions (Cat 1 spend-based + Cat 4 distance-based only)', ROUND(SCOPE3, 1), 'tCO2e', COVERAGE, FACTOR_STATUS, EST_SHARE FROM fy
UNION ALL SELECT INDIAN_FY, 12, 'P6-LI', 'Scope 3 emission intensity per INR crore of turnover', ROUND(SCOPE3 / NULLIF(TURNOVER_INR / 1e7, 0), 4), 'tCO2e / INR crore', COVERAGE, FACTOR_STATUS, EST_SHARE FROM fy;

-- -----------------------------------------------------------------------------
-- 4. Generic calendar-year GHG disclosure summary (GHG Protocol structure)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW ESG.GHG_DISCLOSURE_SUMMARY AS
SELECT d.CALENDAR_YEAR,
       d.SCOPE,
       d.GHG_CATEGORY,
       d.METHOD,
       ROUND(SUM(d.TCO2E), 1)                                         AS TCO2E,
       ROUND(RATIO_TO_REPORT(SUM(d.TCO2E)) OVER (PARTITION BY d.CALENDAR_YEAR), 4) AS SHARE_OF_TOTAL,
       COUNT(DISTINCT d.PERIOD_MONTH)                                 AS MONTHS_COVERED,
       ROUND(COUNT_IF(d.DATA_QUALITY = 'Estimated') / COUNT(*), 3)    AS ESTIMATED_SHARE,
       IFF(COUNT_IF(d.FACTOR_IS_PLACEHOLDER) > 0, 'PLACEHOLDER factors - replace before disclosure', 'Sourced') AS FACTOR_STATUS,
       'Operational control; location-based Scope 2; market-based Scope 2 not calculated (needs supplier-specific / REC data)' AS METHODOLOGY_NOTE
FROM ESG.EMISSIONS_DETAIL d
WHERE d.DATA_STATUS = 'Actual'
GROUP BY d.CALENDAR_YEAR, d.SCOPE, d.GHG_CATEGORY, d.METHOD;

GRANT USAGE ON SCHEMA ACCEL_DB.ESG TO ROLE ACCEL_ANALYST;
GRANT USAGE ON SCHEMA ACCEL_DB.ESG TO ROLE ACCEL_VIEWER;
GRANT SELECT ON ALL TABLES IN SCHEMA ACCEL_DB.ESG TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ACCEL_DB.ESG TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ACCEL_DB.ESG TO ROLE ACCEL_VIEWER;
GRANT UPDATE ON TABLE ACCEL_DB.ESG.EVIDENCE_TRACKER TO ROLE ACCEL_ANALYST;

SELECT * FROM ESG.BRSR_P6_SUMMARY ORDER BY INDIAN_FY, SORT_ORDER;
SELECT * FROM ESG.GHG_DISCLOSURE_SUMMARY ORDER BY CALENDAR_YEAR, SCOPE, GHG_CATEGORY;
