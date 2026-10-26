/* =============================================================================
   Asset 26 - ESG & Sustainability Hub
   File  02_activity_data.sql
   Purpose
     Synthetic, deterministic activity data per plant per month, Jan 2024 - Dec 2026:
       ESG.PLANT_PRODUCTION  - units produced (capacity x utilisation)
       ESG.ACTIVITY_DATA     - electricity kWh, diesel litres, natural gas m3,
                               freight tonne-km by mode, purchased-goods spend (INR)
     Spend comes from DEMO.PURCHASE_ORDERS (real demo data) by supplier category.
     Months after the last DEMO order month are flagged DATA_STATUS = 'Projected'.
     A ~3%/year efficiency trend and ~10% "Estimated" readings make the demo realistic.
     In a real deployment, replace this file with loads from utility bills, fuel
     cards, TMS and ERP.
   Run as  ACCEL_ADMIN after 01. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS ESG;
USE SCHEMA ESG;

CREATE OR REPLACE TABLE ESG.PLANT_PRODUCTION AS
WITH months AS (
    SELECT DATEADD('month', ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2024-01-01'::DATE) AS PERIOD_MONTH
    FROM TABLE(GENERATOR(ROWCOUNT => 36))
)
SELECT p.PLANT_ID, p.PLANT_NAME, p.COUNTRY, m.PERIOD_MONTH,
       ROUND(COALESCE(p.CAPACITY_UNITS_PER_DAY, 1000)
             * DAY(LAST_DAY(m.PERIOD_MONTH))
             * (0.65 + MOD(ABS(HASH(p.PLANT_ID, m.PERIOD_MONTH, 'util')), 26) / 100), 0) AS UNITS_PRODUCED
FROM ACCEL_DB.DEMO.PLANTS p
CROSS JOIN months m;

CREATE OR REPLACE TABLE ESG.ACTIVITY_DATA AS
WITH last_actual AS (
    SELECT DATE_TRUNC('month', MAX(ORDER_DATE))::DATE AS LAST_ACTUAL_MONTH FROM ACCEL_DB.DEMO.ORDERS
),
base AS (
    SELECT pp.*,
           -- efficiency improves ~3% per year from Jan 2024
           1 - 0.03 * DATEDIFF('month', '2024-01-01'::DATE, pp.PERIOD_MONTH) / 12 AS EFF,
           1 + MOD(ABS(HASH(pp.PLANT_ID, 'intensity')), 40) / 100               AS PLANT_INTENSITY,
           MOD(ABS(HASH(pp.PLANT_ID, pp.PERIOD_MONTH, 'dq')), 100)              AS H_DQ
    FROM ESG.PLANT_PRODUCTION pp
),
energy AS (
    SELECT PLANT_ID, PERIOD_MONTH, 'ELECTRICITY' AS ACTIVITY_TYPE, 'GRID' AS SUB_TYPE,
           ROUND((40000 + UNITS_PRODUCED * 2.8 * PLANT_INTENSITY) * EFF, 0) AS QUANTITY, 'kWh' AS UNIT,
           'Utility bill' AS DATA_SOURCE, IFF(H_DQ < 8, 'Estimated', 'Measured') AS DATA_QUALITY
    FROM base
    UNION ALL
    SELECT PLANT_ID, PERIOD_MONTH, 'DIESEL', 'STATIONARY',
           ROUND((1500 + UNITS_PRODUCED * 0.012 * PLANT_INTENSITY) * EFF, 0), 'litre',
           'Fuel invoices', IFF(H_DQ BETWEEN 8 AND 17, 'Estimated', 'Measured')
    FROM base
    UNION ALL
    SELECT PLANT_ID, PERIOD_MONTH, 'NATURAL_GAS', 'STATIONARY',
           ROUND(UNITS_PRODUCED * 0.09 * PLANT_INTENSITY * EFF, 0), 'm3',
           'Gas meter', IFF(H_DQ BETWEEN 18 AND 22, 'Estimated', 'Measured')
    FROM base
    -- one plant in five has no gas connection
    WHERE MOD(ABS(HASH(PLANT_ID, 'gas')), 5) <> 0
),
freight AS (
    -- inbound tonnage ~ 4 kg of material per unit; average haul 450 km; mode split by plant
    SELECT b.PLANT_ID, b.PERIOD_MONTH, 'FREIGHT' AS ACTIVITY_TYPE, m.MODE AS SUB_TYPE,
           ROUND(b.UNITS_PRODUCED * 0.004 * 450 * m.SHARE, 0) AS QUANTITY, 'tonne-km' AS UNIT,
           'Transport management system' AS DATA_SOURCE,
           IFF(b.H_DQ BETWEEN 23 AND 30, 'Estimated', 'Measured') AS DATA_QUALITY
    FROM base b
    CROSS JOIN (SELECT * FROM VALUES ('ROAD', 0.72), ('RAIL', 0.15), ('SEA', 0.12), ('AIR', 0.01) AS v(MODE, SHARE)) m
),
spend AS (
    SELECT po.PLANT_ID,
           DATE_TRUNC('month', po.PO_DATE)::DATE                      AS PERIOD_MONTH,
           'PURCHASED_GOODS'                                          AS ACTIVITY_TYPE,
           COALESCE(s.CATEGORY, 'DEFAULT')                            AS SUB_TYPE,
           ROUND(SUM(po.QUANTITY * po.UNIT_COST) * MAX(COALESCE(fx.INR_PER_UNIT, 1)), 2) AS QUANTITY,
           'INR'                                                      AS UNIT,
           'ERP purchase orders'                                      AS DATA_SOURCE,
           'Measured'                                                 AS DATA_QUALITY
    FROM ACCEL_DB.DEMO.PURCHASE_ORDERS po
    LEFT JOIN ACCEL_DB.DEMO.SUPPLIERS s ON s.SUPPLIER_ID = po.SUPPLIER_ID
    LEFT JOIN ESG.SETTINGS st ON st.PARAM = 'PO_CURRENCY'
    LEFT JOIN ESG.FX_TO_INR fx ON fx.CURRENCY = st.VALUE
    WHERE po.STATUS <> 'Cancelled'
      AND po.PO_DATE >= '2024-01-01' AND po.PO_DATE < '2027-01-01'
    GROUP BY 1, 2, 3, 4
)
SELECT a.*,
       IFF(a.PERIOD_MONTH > la.LAST_ACTUAL_MONTH, 'Projected', 'Actual') AS DATA_STATUS,
       pl.COUNTRY AS PLANT_COUNTRY
FROM (SELECT * FROM energy UNION ALL SELECT * FROM freight UNION ALL SELECT * FROM spend) a
CROSS JOIN last_actual la
LEFT JOIN ACCEL_DB.DEMO.PLANTS pl ON pl.PLANT_ID = a.PLANT_ID;

SELECT ACTIVITY_TYPE, UNIT, DATA_STATUS, COUNT(*) AS ROWS_, ROUND(SUM(QUANTITY), 0) AS TOTAL_QUANTITY,
       COUNT_IF(DATA_QUALITY = 'Estimated') AS ESTIMATED_ROWS
FROM ESG.ACTIVITY_DATA GROUP BY 1, 2, 3 ORDER BY 1, 3;
