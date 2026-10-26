/* =============================================================================
   Asset 26 - ESG & Sustainability Hub
   File  03_ghg_calculations.sql
   Purpose
     ESG.EMISSIONS_DETAIL            - every activity row x matched factor -> tCO2e,
                                       with scope / GHG Protocol category and the
                                       factor's source and placeholder flag (audit trail)
     ESG.SCOPE1_EMISSIONS            - stationary combustion (diesel, natural gas)
     ESG.SCOPE2_LOCATION_BASED       - purchased electricity x grid factor
     ESG.SCOPE3_CAT1_PURCHASED_GOODS - spend-based
     ESG.SCOPE3_CAT4_UPSTREAM_TRANSPORT - distance-based (tonne-km)
     ESG.EMISSIONS_MONTHLY           - plant x month x scope roll-up
     ESG.REVENUE_MONTHLY             - INR revenue per plant-month from DEMO orders
     ESG.INTENSITY_MONTHLY / ESG.INTENSITY_ANNUAL
                                     - tCO2e per unit produced and per INR crore revenue
   Factor matching: country-specific row first, then COUNTRY = '*'; for spend,
   the supplier-category row first, then SUB_TYPE = 'DEFAULT'.
   Run as  ACCEL_ADMIN after 02. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS ESG;
USE SCHEMA ESG;

CREATE OR REPLACE VIEW ESG.EMISSIONS_DETAIL AS
WITH matched AS (
    SELECT a.*,
           COALESCE(f_cty.KG_CO2E_PER_UNIT, f_any.KG_CO2E_PER_UNIT, f_def.KG_CO2E_PER_UNIT) AS KG_CO2E_PER_UNIT,
           COALESCE(f_cty.SOURCE_REFERENCE, f_any.SOURCE_REFERENCE, f_def.SOURCE_REFERENCE) AS FACTOR_SOURCE,
           COALESCE(f_cty.IS_PLACEHOLDER,   f_any.IS_PLACEHOLDER,   f_def.IS_PLACEHOLDER)   AS FACTOR_IS_PLACEHOLDER,
           CASE WHEN f_cty.KG_CO2E_PER_UNIT IS NOT NULL THEN 'Country-specific'
                WHEN f_any.KG_CO2E_PER_UNIT IS NOT NULL THEN 'Generic'
                WHEN f_def.KG_CO2E_PER_UNIT IS NOT NULL THEN 'Default category'
                ELSE 'NO FACTOR' END                                                      AS FACTOR_MATCH
    FROM ESG.ACTIVITY_DATA a
    LEFT JOIN ESG.EMISSION_FACTORS f_cty
           ON f_cty.ACTIVITY_TYPE = a.ACTIVITY_TYPE AND f_cty.SUB_TYPE = a.SUB_TYPE
          AND f_cty.COUNTRY = a.PLANT_COUNTRY AND f_cty.UNIT = a.UNIT
    LEFT JOIN ESG.EMISSION_FACTORS f_any
           ON f_any.ACTIVITY_TYPE = a.ACTIVITY_TYPE AND f_any.SUB_TYPE = a.SUB_TYPE
          AND f_any.COUNTRY = '*' AND f_any.UNIT = a.UNIT
    LEFT JOIN ESG.EMISSION_FACTORS f_def
           ON f_def.ACTIVITY_TYPE = a.ACTIVITY_TYPE AND f_def.SUB_TYPE = 'DEFAULT'
          AND f_def.COUNTRY = '*' AND f_def.UNIT = a.UNIT
)
SELECT m.PLANT_ID, m.PLANT_COUNTRY, m.PERIOD_MONTH, YEAR(m.PERIOD_MONTH) AS CALENDAR_YEAR,
       -- Indian financial year (April - March), e.g. FY2024-25
       'FY' || TO_VARCHAR(YEAR(DATEADD('month', -3, m.PERIOD_MONTH))) || '-'
            || RIGHT(TO_VARCHAR(YEAR(DATEADD('month', -3, m.PERIOD_MONTH)) + 1), 2) AS INDIAN_FY,
       CASE m.ACTIVITY_TYPE
           WHEN 'DIESEL'          THEN 'Scope 1'
           WHEN 'NATURAL_GAS'     THEN 'Scope 1'
           WHEN 'ELECTRICITY'     THEN 'Scope 2'
           ELSE 'Scope 3' END                                              AS SCOPE,
       CASE m.ACTIVITY_TYPE
           WHEN 'DIESEL'          THEN 'Stationary combustion'
           WHEN 'NATURAL_GAS'     THEN 'Stationary combustion'
           WHEN 'ELECTRICITY'     THEN 'Purchased electricity (location-based)'
           WHEN 'PURCHASED_GOODS' THEN 'Cat 1 - Purchased goods and services'
           WHEN 'FREIGHT'         THEN 'Cat 4 - Upstream transportation and distribution'
       END                                                                 AS GHG_CATEGORY,
       m.ACTIVITY_TYPE, m.SUB_TYPE, m.QUANTITY, m.UNIT,
       m.KG_CO2E_PER_UNIT,
       ROUND(m.QUANTITY * m.KG_CO2E_PER_UNIT / 1000, 4)                     AS TCO2E,
       m.FACTOR_MATCH, m.FACTOR_SOURCE, m.FACTOR_IS_PLACEHOLDER,
       CASE m.ACTIVITY_TYPE WHEN 'PURCHASED_GOODS' THEN 'Spend-based'
                            WHEN 'FREIGHT'         THEN 'Distance-based'
                            ELSE 'Activity-based' END                      AS METHOD,
       m.DATA_SOURCE, m.DATA_QUALITY, m.DATA_STATUS
FROM matched m;

CREATE OR REPLACE VIEW ESG.SCOPE1_EMISSIONS AS
SELECT * FROM ESG.EMISSIONS_DETAIL WHERE SCOPE = 'Scope 1';

CREATE OR REPLACE VIEW ESG.SCOPE2_LOCATION_BASED AS
SELECT * FROM ESG.EMISSIONS_DETAIL WHERE SCOPE = 'Scope 2';

CREATE OR REPLACE VIEW ESG.SCOPE3_CAT1_PURCHASED_GOODS AS
SELECT * FROM ESG.EMISSIONS_DETAIL WHERE ACTIVITY_TYPE = 'PURCHASED_GOODS';

CREATE OR REPLACE VIEW ESG.SCOPE3_CAT4_UPSTREAM_TRANSPORT AS
SELECT * FROM ESG.EMISSIONS_DETAIL WHERE ACTIVITY_TYPE = 'FREIGHT';

CREATE OR REPLACE VIEW ESG.EMISSIONS_MONTHLY AS
SELECT PLANT_ID, PLANT_COUNTRY, PERIOD_MONTH, CALENDAR_YEAR, INDIAN_FY, DATA_STATUS,
       ROUND(SUM(IFF(SCOPE = 'Scope 1', TCO2E, 0)), 3)                             AS SCOPE1_TCO2E,
       ROUND(SUM(IFF(SCOPE = 'Scope 2', TCO2E, 0)), 3)                             AS SCOPE2_LOCATION_TCO2E,
       ROUND(SUM(IFF(ACTIVITY_TYPE = 'PURCHASED_GOODS', TCO2E, 0)), 3)             AS SCOPE3_CAT1_TCO2E,
       ROUND(SUM(IFF(ACTIVITY_TYPE = 'FREIGHT', TCO2E, 0)), 3)                     AS SCOPE3_CAT4_TCO2E,
       ROUND(SUM(TCO2E), 3)                                                        AS TOTAL_TCO2E,
       ROUND(SUM(IFF(ACTIVITY_TYPE = 'ELECTRICITY', QUANTITY, 0)), 0)              AS ELECTRICITY_KWH,
       COUNT_IF(DATA_QUALITY = 'Estimated')                                        AS ESTIMATED_ROWS,
       COUNT_IF(FACTOR_IS_PLACEHOLDER)                                             AS PLACEHOLDER_FACTOR_ROWS,
       COUNT_IF(FACTOR_MATCH = 'NO FACTOR')                                        AS ROWS_WITHOUT_FACTOR
FROM ESG.EMISSIONS_DETAIL
GROUP BY PLANT_ID, PLANT_COUNTRY, PERIOD_MONTH, CALENDAR_YEAR, INDIAN_FY, DATA_STATUS;

-- Revenue per plant-month in INR (cancelled and returned orders excluded)
CREATE OR REPLACE VIEW ESG.REVENUE_MONTHLY AS
SELECT o.PLANT_ID,
       DATE_TRUNC('month', o.ORDER_DATE)::DATE                     AS PERIOD_MONTH,
       SUM(o.ORDER_TOTAL * COALESCE(fx.INR_PER_UNIT, 1))           AS REVENUE_INR,
       SUM(o.ORDER_TOTAL * COALESCE(fx.INR_PER_UNIT, 1)) / 1e7     AS REVENUE_INR_CRORE
FROM ACCEL_DB.DEMO.ORDERS o
LEFT JOIN ESG.FX_TO_INR fx ON fx.CURRENCY = o.CURRENCY
WHERE o.STATUS NOT IN ('Cancelled', 'Returned')
GROUP BY 1, 2;

CREATE OR REPLACE VIEW ESG.INTENSITY_MONTHLY AS
SELECT e.*, p.UNITS_PRODUCED, ROUND(r.REVENUE_INR_CRORE, 4) AS REVENUE_INR_CRORE,
       ROUND((e.SCOPE1_TCO2E + e.SCOPE2_LOCATION_TCO2E) / NULLIF(p.UNITS_PRODUCED, 0) * 1000, 4)
                                                                            AS S12_KGCO2E_PER_UNIT,
       ROUND((e.SCOPE1_TCO2E + e.SCOPE2_LOCATION_TCO2E) / NULLIF(r.REVENUE_INR_CRORE, 0), 4)
                                                                            AS S12_TCO2E_PER_INR_CRORE,
       ROUND(e.TOTAL_TCO2E / NULLIF(r.REVENUE_INR_CRORE, 0), 4)             AS TOTAL_TCO2E_PER_INR_CRORE
FROM ESG.EMISSIONS_MONTHLY e
LEFT JOIN ESG.PLANT_PRODUCTION p ON p.PLANT_ID = e.PLANT_ID AND p.PERIOD_MONTH = e.PERIOD_MONTH
LEFT JOIN ESG.REVENUE_MONTHLY r  ON r.PLANT_ID = e.PLANT_ID AND r.PERIOD_MONTH = e.PERIOD_MONTH;

-- Actual months only (projected months after the last DEMO order are excluded).
CREATE OR REPLACE VIEW ESG.INTENSITY_ANNUAL AS
SELECT CALENDAR_YEAR,
       COUNT(DISTINCT PERIOD_MONTH)                             AS MONTHS_COVERED,
       ROUND(SUM(SCOPE1_TCO2E), 1)                              AS SCOPE1_TCO2E,
       ROUND(SUM(SCOPE2_LOCATION_TCO2E), 1)                     AS SCOPE2_LOCATION_TCO2E,
       ROUND(SUM(SCOPE3_CAT1_TCO2E), 1)                         AS SCOPE3_CAT1_TCO2E,
       ROUND(SUM(SCOPE3_CAT4_TCO2E), 1)                         AS SCOPE3_CAT4_TCO2E,
       ROUND(SUM(TOTAL_TCO2E), 1)                               AS TOTAL_TCO2E,
       SUM(UNITS_PRODUCED)                                      AS UNITS_PRODUCED,
       ROUND(SUM(REVENUE_INR_CRORE), 2)                         AS REVENUE_INR_CRORE,
       ROUND((SUM(SCOPE1_TCO2E) + SUM(SCOPE2_LOCATION_TCO2E)) / NULLIF(SUM(UNITS_PRODUCED), 0) * 1000, 4)
                                                                AS S12_KGCO2E_PER_UNIT,
       ROUND((SUM(SCOPE1_TCO2E) + SUM(SCOPE2_LOCATION_TCO2E)) / NULLIF(SUM(REVENUE_INR_CRORE), 0), 4)
                                                                AS S12_TCO2E_PER_INR_CRORE,
       ROUND(SUM(TOTAL_TCO2E) / NULLIF(SUM(REVENUE_INR_CRORE), 0), 4) AS TOTAL_TCO2E_PER_INR_CRORE
FROM ESG.INTENSITY_MONTHLY
WHERE DATA_STATUS = 'Actual'
GROUP BY CALENDAR_YEAR;

SELECT * FROM ESG.INTENSITY_ANNUAL ORDER BY CALENDAR_YEAR;

-- Any activity without a factor? (should return no rows)
SELECT ACTIVITY_TYPE, SUB_TYPE, PLANT_COUNTRY, COUNT(*) AS ROWS_
FROM ESG.EMISSIONS_DETAIL WHERE FACTOR_MATCH = 'NO FACTOR' GROUP BY 1, 2, 3;
