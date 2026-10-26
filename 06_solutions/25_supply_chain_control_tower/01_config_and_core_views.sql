/* =============================================================================
   Asset 25 - Supply Chain Control Tower
   File  01_config_and_core_views.sql
   Purpose
     SCT.CONFIG                - thresholds and horizons (-- EDIT ME)
     SCT.PO_RECEIPTS           - received quantity per PO (synthetic in-full signal)
     SCT.SUPPLIER_SCORECARD    - OTIF, average delay, open late POs, computed risk rating
     SCT.DEMAND_WEEKLY         - weekly demand per plant-product from customer orders
     SCT.DEMAND_FORECAST       - trailing N-week average demand (default 8)
     SCT.INVENTORY_POSITION    - latest snapshot + days of supply
     SCT.STOCKOUT_RISK         - projected on-hand at horizon vs demand, risk level,
                                 shortfall and revenue at risk
   All "as of" logic uses the latest inventory snapshot in the data (demo data ends
   Sep 2026), not CURRENT_DATE, so the demo always shows a live-looking picture.
   Run as  ACCEL_ADMIN. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SCT;
USE SCHEMA SCT;

-- -----------------------------------------------------------------------------
-- Configuration                                                        -- EDIT ME
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE SCT.CONFIG (PARAM VARCHAR, VALUE NUMBER(12,4), NOTE VARCHAR);
INSERT INTO SCT.CONFIG VALUES
  ('DEMAND_WEEKS',          8,    'Trailing weeks of demand used for the forecast'),                 -- EDIT ME
  ('HORIZON_DAYS',          28,   'Projection horizon for stockout risk'),                           -- EDIT ME
  ('CRITICAL_DOS',          7,    'Days of supply below which a SKU is critical if no inbound arrives'), -- EDIT ME
  ('EXCESS_DOS',            120,  'Days of supply above which stock is flagged as excess'),          -- EDIT ME
  ('OTIF_TARGET',           0.90, 'Supplier OTIF target (share of receipts)'),                       -- EDIT ME
  ('LATE_PO_DAYS',          7,    'Open PO this many days past promise date becomes an exception'),  -- EDIT ME
  ('IN_FULL_TOLERANCE',     0.98, 'Received/ordered ratio counted as in full'),                      -- EDIT ME
  ('SCORECARD_DAYS',        365,  'Look-back window for supplier scorecard'),                        -- EDIT ME
  ('OPEN_ORDER_DAYS',       30,   'Customer orders with STATUS = Shipped in the last N days are treated as open'); -- EDIT ME

CREATE OR REPLACE VIEW SCT.CONFIG_V AS
SELECT c.*, a.AS_OF_DATE
FROM (
    SELECT MAX(IFF(PARAM = 'DEMAND_WEEKS',      VALUE, NULL))::INT AS DEMAND_WEEKS,
           MAX(IFF(PARAM = 'HORIZON_DAYS',      VALUE, NULL))::INT AS HORIZON_DAYS,
           MAX(IFF(PARAM = 'CRITICAL_DOS',      VALUE, NULL))      AS CRITICAL_DOS,
           MAX(IFF(PARAM = 'EXCESS_DOS',        VALUE, NULL))      AS EXCESS_DOS,
           MAX(IFF(PARAM = 'OTIF_TARGET',       VALUE, NULL))      AS OTIF_TARGET,
           MAX(IFF(PARAM = 'LATE_PO_DAYS',      VALUE, NULL))::INT AS LATE_PO_DAYS,
           MAX(IFF(PARAM = 'IN_FULL_TOLERANCE', VALUE, NULL))      AS IN_FULL_TOLERANCE,
           MAX(IFF(PARAM = 'SCORECARD_DAYS',    VALUE, NULL))::INT AS SCORECARD_DAYS,
           MAX(IFF(PARAM = 'OPEN_ORDER_DAYS',   VALUE, NULL))::INT AS OPEN_ORDER_DAYS
    FROM SCT.CONFIG
) c
CROSS JOIN (SELECT MAX(SNAPSHOT_DATE) AS AS_OF_DATE FROM ACCEL_DB.DEMO.INVENTORY_SNAPSHOTS) a;

-- -----------------------------------------------------------------------------
-- Receipt quantities. DEMO.PURCHASE_ORDERS has no received-quantity column, so a
-- deterministic ~8% of receipts are short-shipped (85-97% of ordered). Replace
-- this table with your goods-receipt (GRN) data in a real deployment.  -- EDIT ME
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE SCT.PO_RECEIPTS AS
SELECT PO_ID,
       QUANTITY AS ORDERED_QTY,
       IFF(MOD(ABS(HASH(PO_ID, 'short')), 100) < 8,
           FLOOR(QUANTITY * (0.85 + MOD(ABS(HASH(PO_ID, 'pct')), 13) / 100)),
           QUANTITY) AS RECEIVED_QTY,
       RECEIVED_DATE
FROM ACCEL_DB.DEMO.PURCHASE_ORDERS
WHERE RECEIVED_DATE IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Supplier scorecard
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SCT.SUPPLIER_SCORECARD AS
WITH cfg AS (SELECT * FROM SCT.CONFIG_V),
po AS (
    SELECT p.*, r.RECEIVED_QTY,
           DATEDIFF('day', p.PROMISED_DATE, p.RECEIVED_DATE) AS DELAY_DAYS
    FROM ACCEL_DB.DEMO.PURCHASE_ORDERS p
    LEFT JOIN SCT.PO_RECEIPTS r ON r.PO_ID = p.PO_ID
    CROSS JOIN cfg
    WHERE p.PO_DATE > DATEADD('day', -cfg.SCORECARD_DAYS, cfg.AS_OF_DATE)
      AND p.STATUS <> 'Cancelled'
),
agg AS (
    SELECT po.SUPPLIER_ID,
           COUNT(*)                                                       AS POS_PLACED,
           COUNT(po.RECEIVED_DATE)                                        AS POS_RECEIVED,
           COUNT_IF(po.RECEIVED_DATE IS NOT NULL AND po.DELAY_DAYS <= 0)  AS ON_TIME_RECEIPTS,
           COUNT_IF(po.RECEIVED_DATE IS NOT NULL
                    AND po.RECEIVED_QTY >= po.QUANTITY * cfg.IN_FULL_TOLERANCE) AS IN_FULL_RECEIPTS,
           COUNT_IF(po.RECEIVED_DATE IS NOT NULL AND po.DELAY_DAYS <= 0
                    AND po.RECEIVED_QTY >= po.QUANTITY * cfg.IN_FULL_TOLERANCE) AS OTIF_RECEIPTS,
           AVG(IFF(po.RECEIVED_DATE IS NOT NULL, GREATEST(po.DELAY_DAYS, 0), NULL)) AS AVG_DELAY_DAYS,
           AVG(IFF(po.DELAY_DAYS > 0, po.DELAY_DAYS, NULL))               AS AVG_DELAY_WHEN_LATE,
           COUNT_IF(po.RECEIVED_DATE IS NULL AND po.PROMISED_DATE < cfg.AS_OF_DATE) AS OPEN_LATE_POS,
           SUM(IFF(po.RECEIVED_DATE IS NULL, po.QUANTITY * po.UNIT_COST, 0)) AS OPEN_PO_VALUE,
           SUM(po.QUANTITY * po.UNIT_COST)                                AS SPEND
    FROM po CROSS JOIN cfg
    GROUP BY po.SUPPLIER_ID
),
scored AS (
    SELECT a.*,
           ROUND(a.ON_TIME_RECEIPTS / NULLIF(a.POS_RECEIVED, 0), 4) AS ON_TIME_PCT,
           ROUND(a.IN_FULL_RECEIPTS / NULLIF(a.POS_RECEIVED, 0), 4) AS IN_FULL_PCT,
           ROUND(a.OTIF_RECEIPTS    / NULLIF(a.POS_RECEIVED, 0), 4) AS OTIF_PCT,
           -- 0-100 risk score: OTIF gap (60), delay (25), open late share (15)   -- EDIT ME weights
           ROUND( 60 * (1 - COALESCE(a.OTIF_RECEIPTS / NULLIF(a.POS_RECEIVED, 0), 0))
                + 25 * LEAST(COALESCE(a.AVG_DELAY_WHEN_LATE, 0), 20) / 20
                + 15 * LEAST(a.OPEN_LATE_POS / NULLIF(a.POS_PLACED, 0) * 5, 1), 1) AS RISK_SCORE
    FROM agg a
)
SELECT s.SUPPLIER_ID, sup.SUPPLIER_NAME, sup.COUNTRY, sup.CATEGORY,
       s.POS_PLACED, s.POS_RECEIVED, s.ON_TIME_PCT, s.IN_FULL_PCT, s.OTIF_PCT,
       ROUND(s.AVG_DELAY_DAYS, 1)       AS AVG_DELAY_DAYS,
       ROUND(s.AVG_DELAY_WHEN_LATE, 1)  AS AVG_DELAY_WHEN_LATE,
       s.OPEN_LATE_POS,
       ROUND(s.OPEN_PO_VALUE, 2)        AS OPEN_PO_VALUE,
       ROUND(s.SPEND, 2)                AS SPEND,
       s.RISK_SCORE,
       CASE WHEN s.RISK_SCORE >= 40 THEN 'High'
            WHEN s.RISK_SCORE >= 20 THEN 'Medium'
            ELSE 'Low' END              AS COMPUTED_RISK_RATING,
       sup.RISK_RATING                  AS MASTER_DATA_RISK_RATING,
       sup.ON_TIME_DELIVERY_PCT         AS MASTER_DATA_ON_TIME_PCT,
       IFF(s.OTIF_PCT < cfg.OTIF_TARGET, TRUE, FALSE) AS BELOW_OTIF_TARGET
FROM scored s
JOIN ACCEL_DB.DEMO.SUPPLIERS sup ON sup.SUPPLIER_ID = s.SUPPLIER_ID
CROSS JOIN SCT.CONFIG_V cfg;

-- -----------------------------------------------------------------------------
-- Demand
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SCT.DEMAND_WEEKLY AS
SELECT o.PLANT_ID, l.PRODUCT_ID,
       DATE_TRUNC('week', o.ORDER_DATE)::DATE AS WEEK_START,
       SUM(l.QUANTITY)                        AS UNITS,
       SUM(l.NET_AMOUNT)                      AS NET_AMOUNT,
       COUNT(DISTINCT o.ORDER_ID)             AS ORDERS
FROM ACCEL_DB.DEMO.ORDERS o
JOIN ACCEL_DB.DEMO.ORDER_LINES l ON l.ORDER_ID = o.ORDER_ID
WHERE o.STATUS <> 'Cancelled'
GROUP BY 1, 2, 3;

-- Trailing-average forecast: total units in the last N complete weeks / N
-- (weeks with zero demand count as zero).
CREATE OR REPLACE VIEW SCT.DEMAND_FORECAST AS
WITH cfg AS (SELECT * FROM SCT.CONFIG_V),
win AS (
    SELECT cfg.AS_OF_DATE,
           DATEADD('week', -cfg.DEMAND_WEEKS, DATE_TRUNC('week', cfg.AS_OF_DATE))::DATE AS FROM_WEEK,
           DATE_TRUNC('week', cfg.AS_OF_DATE)::DATE AS TO_WEEK_EXCL,
           cfg.DEMAND_WEEKS
    FROM cfg
)
SELECT d.PLANT_ID, d.PRODUCT_ID,
       ROUND(SUM(d.UNITS) / MAX(w.DEMAND_WEEKS), 2)          AS AVG_WEEKLY_DEMAND,
       ROUND(SUM(d.UNITS) / MAX(w.DEMAND_WEEKS) / 7, 4)      AS AVG_DAILY_DEMAND,
       ROUND(SUM(d.NET_AMOUNT) / NULLIF(SUM(d.UNITS), 0), 2) AS AVG_NET_UNIT_PRICE,
       MAX(w.FROM_WEEK) AS WINDOW_FROM, MAX(w.TO_WEEK_EXCL) AS WINDOW_TO_EXCL
FROM SCT.DEMAND_WEEKLY d
CROSS JOIN win w
WHERE d.WEEK_START >= w.FROM_WEEK AND d.WEEK_START < w.TO_WEEK_EXCL
GROUP BY d.PLANT_ID, d.PRODUCT_ID;

-- -----------------------------------------------------------------------------
-- Inventory position and days of supply
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SCT.INVENTORY_POSITION AS
WITH latest AS (
    SELECT i.*
    FROM ACCEL_DB.DEMO.INVENTORY_SNAPSHOTS i
    QUALIFY ROW_NUMBER() OVER (PARTITION BY i.PLANT_ID, i.PRODUCT_ID ORDER BY i.SNAPSHOT_DATE DESC) = 1
)
SELECT l.PLANT_ID, pl.PLANT_NAME, l.PRODUCT_ID, pr.SKU, pr.PRODUCT_NAME, pr.CATEGORY,
       l.SNAPSHOT_DATE, l.ON_HAND_QTY, l.REORDER_POINT, l.SAFETY_STOCK,
       COALESCE(f.AVG_WEEKLY_DEMAND, 0) AS AVG_WEEKLY_DEMAND,
       COALESCE(f.AVG_DAILY_DEMAND, 0)  AS AVG_DAILY_DEMAND,
       ROUND(l.ON_HAND_QTY / NULLIF(f.AVG_DAILY_DEMAND, 0), 1) AS DAYS_OF_SUPPLY,
       COALESCE(f.AVG_NET_UNIT_PRICE, pr.LIST_PRICE) AS UNIT_PRICE,
       pr.UNIT_COST,
       ROUND(l.ON_HAND_QTY * pr.UNIT_COST, 2) AS INVENTORY_VALUE_AT_COST
FROM latest l
LEFT JOIN SCT.DEMAND_FORECAST f ON f.PLANT_ID = l.PLANT_ID AND f.PRODUCT_ID = l.PRODUCT_ID
LEFT JOIN ACCEL_DB.DEMO.PLANTS pl ON pl.PLANT_ID = l.PLANT_ID
LEFT JOIN ACCEL_DB.DEMO.PRODUCTS pr ON pr.PRODUCT_ID = l.PRODUCT_ID;

-- -----------------------------------------------------------------------------
-- Stockout risk over the horizon
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SCT.STOCKOUT_RISK AS
WITH cfg AS (SELECT * FROM SCT.CONFIG_V),
inbound AS (
    SELECT p.PLANT_ID, p.PRODUCT_ID,
           SUM(IFF(p.PROMISED_DATE >= cfg.AS_OF_DATE
                   AND p.PROMISED_DATE < DATEADD('day', cfg.HORIZON_DAYS, cfg.AS_OF_DATE), p.QUANTITY, 0)) AS INBOUND_IN_HORIZON_QTY,
           SUM(IFF(p.PROMISED_DATE < cfg.AS_OF_DATE, p.QUANTITY, 0))                                    AS LATE_INBOUND_QTY,
           COUNT_IF(p.PROMISED_DATE < cfg.AS_OF_DATE)                                                    AS LATE_OPEN_POS,
           MIN(IFF(p.PROMISED_DATE >= cfg.AS_OF_DATE, p.PROMISED_DATE, NULL))                            AS NEXT_INBOUND_DATE
    FROM ACCEL_DB.DEMO.PURCHASE_ORDERS p CROSS JOIN cfg
    WHERE p.RECEIVED_DATE IS NULL AND p.STATUS <> 'Cancelled'
    GROUP BY p.PLANT_ID, p.PRODUCT_ID
),
proj AS (
    SELECT ip.*,
           cfg.AS_OF_DATE, cfg.HORIZON_DAYS, cfg.CRITICAL_DOS,
           COALESCE(ib.INBOUND_IN_HORIZON_QTY, 0) AS INBOUND_IN_HORIZON_QTY,
           COALESCE(ib.LATE_INBOUND_QTY, 0)       AS LATE_INBOUND_QTY,
           COALESCE(ib.LATE_OPEN_POS, 0)          AS LATE_OPEN_POS,
           ib.NEXT_INBOUND_DATE,
           ROUND(ip.AVG_DAILY_DEMAND * cfg.HORIZON_DAYS, 0) AS DEMAND_IN_HORIZON,
           -- late (overdue) POs are NOT counted as inbound: conservative view
           ROUND(ip.ON_HAND_QTY + COALESCE(ib.INBOUND_IN_HORIZON_QTY, 0)
                 - ip.AVG_DAILY_DEMAND * cfg.HORIZON_DAYS, 0) AS PROJECTED_ON_HAND,
           DATEADD('day', LEAST(FLOOR(ip.ON_HAND_QTY / NULLIF(ip.AVG_DAILY_DEMAND, 0)), 3650), cfg.AS_OF_DATE) AS STOCKOUT_DATE_NO_INBOUND
    FROM SCT.INVENTORY_POSITION ip
    CROSS JOIN cfg
    LEFT JOIN inbound ib ON ib.PLANT_ID = ip.PLANT_ID AND ib.PRODUCT_ID = ip.PRODUCT_ID
)
SELECT p.*,
       GREATEST(p.DEMAND_IN_HORIZON - p.ON_HAND_QTY - p.INBOUND_IN_HORIZON_QTY, 0)                  AS SHORTFALL_QTY,
       ROUND(GREATEST(p.DEMAND_IN_HORIZON - p.ON_HAND_QTY - p.INBOUND_IN_HORIZON_QTY, 0) * p.UNIT_PRICE, 2) AS REVENUE_AT_RISK,
       CASE
           WHEN p.AVG_DAILY_DEMAND = 0                                                     THEN 'NO_DEMAND'
           WHEN p.PROJECTED_ON_HAND < 0                                                    THEN 'CRITICAL'
           WHEN p.DAYS_OF_SUPPLY < p.CRITICAL_DOS
                AND (p.NEXT_INBOUND_DATE IS NULL OR p.NEXT_INBOUND_DATE > p.STOCKOUT_DATE_NO_INBOUND) THEN 'CRITICAL'
           WHEN p.PROJECTED_ON_HAND < p.SAFETY_STOCK                                       THEN 'HIGH'
           WHEN p.PROJECTED_ON_HAND < p.REORDER_POINT                                      THEN 'MEDIUM'
           ELSE 'OK'
       END AS RISK_LEVEL
FROM proj p;

GRANT USAGE ON SCHEMA ACCEL_DB.SCT TO ROLE ACCEL_ANALYST;
GRANT USAGE ON SCHEMA ACCEL_DB.SCT TO ROLE ACCEL_VIEWER;
GRANT SELECT ON ALL TABLES IN SCHEMA ACCEL_DB.SCT TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ACCEL_DB.SCT TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ACCEL_DB.SCT TO ROLE ACCEL_VIEWER;

SELECT RISK_LEVEL, COUNT(*) AS PLANT_PRODUCTS, ROUND(SUM(REVENUE_AT_RISK), 0) AS REVENUE_AT_RISK
FROM SCT.STOCKOUT_RISK GROUP BY 1 ORDER BY 1;

SELECT * FROM SCT.SUPPLIER_SCORECARD ORDER BY RISK_SCORE DESC LIMIT 10;
