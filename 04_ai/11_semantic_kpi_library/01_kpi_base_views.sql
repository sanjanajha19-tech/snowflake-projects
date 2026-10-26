/*=============================================================================
  ASSET 11 - Semantic KPI Library
  File 01   : Base views / table that standardise KPI logic per domain
  Creates   : ACCEL_DB.KPI_LIBRARY.FIN_GL_PNL_V, SC_PURCHASE_ORDERS_V,
              SC_INVENTORY_DOS (table), HR_EMPLOYEES_V, CS_TICKETS_V
  Run as    : ACCEL_ADMIN
  Rerun     : safe (CREATE OR REPLACE). Rerun to refresh SC_INVENTORY_DOS
              (or convert it to a dynamic table for production).
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS KPI_LIBRARY COMMENT = 'Asset 11: reusable semantic views + KPI catalog';
USE SCHEMA KPI_LIBRARY;

------------------------------------------------------------------------------
-- FINANCE: P&L lines from the GL with sign-normalised measures
--   GL convention: debit +, credit -  => revenue is credit, so negate it.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW FIN_GL_PNL_V
  COMMENT = 'P&L journal lines (Revenue/COGS/Opex) with sign-normalised amounts'
AS
SELECT
    JOURNAL_ID,
    LINE_NO,
    POSTING_DATE,
    DATE_TRUNC('MONTH', POSTING_DATE)                                   AS FISCAL_MONTH,
    ENTITY,
    COST_CENTER,
    ACCOUNT_CODE,
    ACCOUNT_NAME,
    ACCOUNT_TYPE,
    SOURCE,
    CURRENCY,
    AMOUNT,
    IFF(ACCOUNT_TYPE = 'Revenue', -AMOUNT, 0)                           AS REVENUE_AMT,
    IFF(ACCOUNT_TYPE = 'COGS',     AMOUNT, 0)                           AS COGS_AMT,
    IFF(ACCOUNT_TYPE = 'Opex',     AMOUNT, 0)                           AS OPEX_AMT,
    -- Depreciation & amortisation (excluded from EBITDA). EDIT ME if the client
    -- chart of accounts identifies D&A by account code range instead of name.
    IFF(ACCOUNT_TYPE = 'Opex'
        AND (ACCOUNT_NAME ILIKE '%depreciation%' OR ACCOUNT_NAME ILIKE '%amorti%'),
        AMOUNT, 0)                                                      AS DA_AMT
FROM ACCEL_DB.DEMO.GL_JOURNAL
WHERE ACCOUNT_TYPE IN ('Revenue', 'COGS', 'Opex');

------------------------------------------------------------------------------
-- SUPPLY CHAIN: purchase orders with delivery performance flags
--   OTIF: no received quantity exists in the demo model, so "in full" is
--   assumed when a PO is received; OTIF = received on/before promised date.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW SC_PURCHASE_ORDERS_V
  COMMENT = 'Purchase orders with on-time / late / OTIF flags'
AS
SELECT
    PO_ID,
    PO_DATE,
    DATE_TRUNC('MONTH', PO_DATE)                                        AS PO_MONTH,
    SUPPLIER_ID,
    PLANT_ID,
    PRODUCT_ID,
    QUANTITY,
    UNIT_COST,
    QUANTITY * UNIT_COST                                                AS PO_VALUE,
    PROMISED_DATE,
    RECEIVED_DATE,
    STATUS                                                              AS PO_STATUS,
    IFF(STATUS <> 'Cancelled', 1, 0)                                    AS IS_ACTIVE_PO,
    IFF(STATUS <> 'Cancelled' AND RECEIVED_DATE IS NOT NULL, 1, 0)      AS IS_DELIVERED,
    IFF(STATUS <> 'Cancelled' AND RECEIVED_DATE IS NOT NULL
        AND RECEIVED_DATE <= PROMISED_DATE, 1, 0)                       AS IS_OTIF,
    IFF(STATUS <> 'Cancelled'
        AND (STATUS = 'Late'
             OR RECEIVED_DATE > PROMISED_DATE
             OR (RECEIVED_DATE IS NULL AND PROMISED_DATE < CURRENT_DATE())), 1, 0) AS IS_LATE,
    IFF(RECEIVED_DATE IS NOT NULL, DATEDIFF('day', PROMISED_DATE, RECEIVED_DATE), NULL) AS DELIVERY_DELAY_DAYS,
    IFF(RECEIVED_DATE IS NOT NULL, DATEDIFF('day', PO_DATE, RECEIVED_DATE), NULL)       AS LEAD_TIME_DAYS
FROM ACCEL_DB.DEMO.PURCHASE_ORDERS;

------------------------------------------------------------------------------
-- SUPPLY CHAIN: inventory with days of supply (materialised for speed)
--   Average daily demand = units ordered from the plant (excl. cancelled)
--   in the 91 days up to the snapshot date / 91.
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE SC_INVENTORY_DOS
  COMMENT = 'Weekly inventory snapshots with trailing-91-day demand, days of supply and stock-out risk'
AS
WITH weekly_demand AS (
    SELECT o.PLANT_ID,
           l.PRODUCT_ID,
           DATE_TRUNC('WEEK', o.ORDER_DATE) AS DEMAND_WEEK,
           SUM(l.QUANTITY)                  AS UNITS
    FROM ACCEL_DB.DEMO.ORDER_LINES l
    JOIN ACCEL_DB.DEMO.ORDERS o ON o.ORDER_ID = l.ORDER_ID
    WHERE o.STATUS <> 'Cancelled'
    GROUP BY 1, 2, 3
),
snap AS (
    SELECT s.SNAPSHOT_DATE, s.PLANT_ID, s.PRODUCT_ID,
           s.ON_HAND_QTY, s.REORDER_POINT, s.SAFETY_STOCK,
           COALESCE(SUM(d.UNITS), 0) / 91.0 AS AVG_DAILY_DEMAND
    FROM ACCEL_DB.DEMO.INVENTORY_SNAPSHOTS s
    LEFT JOIN weekly_demand d
      ON  d.PLANT_ID   = s.PLANT_ID
      AND d.PRODUCT_ID = s.PRODUCT_ID
      AND d.DEMAND_WEEK >  DATEADD('day', -91, s.SNAPSHOT_DATE)
      AND d.DEMAND_WEEK <= s.SNAPSHOT_DATE
    GROUP BY 1, 2, 3, 4, 5, 6
)
SELECT
    SNAPSHOT_DATE,
    PLANT_ID,
    PRODUCT_ID,
    ON_HAND_QTY,
    REORDER_POINT,
    SAFETY_STOCK,
    ROUND(AVG_DAILY_DEMAND, 4)                                            AS AVG_DAILY_DEMAND,
    IFF(AVG_DAILY_DEMAND > 0, ROUND(ON_HAND_QTY / AVG_DAILY_DEMAND, 1), NULL) AS DAYS_OF_SUPPLY,
    IFF(ON_HAND_QTY <= SAFETY_STOCK, 1, 0)                                AS IS_BELOW_SAFETY_STOCK,
    IFF(ON_HAND_QTY <= REORDER_POINT, 1, 0)                               AS IS_BELOW_REORDER_POINT,
    -- Stock-out risk: at/below safety stock, or less than 14 days of supply. EDIT ME threshold
    IFF(ON_HAND_QTY <= SAFETY_STOCK
        OR (AVG_DAILY_DEMAND > 0 AND ON_HAND_QTY / AVG_DAILY_DEMAND < 14), 1, 0) AS IS_STOCKOUT_RISK,
    IFF(SNAPSHOT_DATE = MAX(SNAPSHOT_DATE) OVER (), TRUE, FALSE)          AS IS_LATEST_SNAPSHOT
FROM snap;

------------------------------------------------------------------------------
-- HR: employees without PII (no name/email); tenure for active staff
--   The demo model has no exit date, so attrition = exited / all employees
--   ever on file (cumulative). With a real HRIS, use exits in period /
--   average headcount in period.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW HR_EMPLOYEES_V
  COMMENT = 'Employees (no PII) with active/exited flags, tenure and salary cost'
AS
SELECT
    EMPLOYEE_ID,
    DEPARTMENT,
    JOB_TITLE,
    LOCATION,
    HIRE_DATE,
    YEAR(HIRE_DATE)                                                    AS HIRE_YEAR,
    MANAGER_ID,
    STATUS                                                             AS EMPLOYMENT_STATUS,
    SALARY,
    IFF(STATUS = 'Active', 1, 0)                                       AS IS_ACTIVE,
    IFF(STATUS = 'Exited', 1, 0)                                       AS IS_EXITED,
    IFF(STATUS = 'Active', ROUND(DATEDIFF('day', HIRE_DATE, CURRENT_DATE()) / 365.25, 2), NULL) AS TENURE_YEARS,
    IFF(STATUS = 'Active', SALARY, 0)                                  AS ACTIVE_SALARY
FROM ACCEL_DB.DEMO.EMPLOYEES;

------------------------------------------------------------------------------
-- CUSTOMER SERVICE: tickets with resolution time, escalation, SLA flags
--   SLA hours by priority: Critical 8, High 24, Medium 72, Low 120 (EDIT ME)
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW CS_TICKETS_V
  COMMENT = 'Support tickets with resolution hours, escalation and SLA breach flags'
AS
SELECT
    TICKET_ID,
    CREATED_AT,
    TO_DATE(CREATED_AT)                                                AS CREATED_DATE,
    DATE_TRUNC('MONTH', CREATED_AT)::DATE                              AS CREATED_MONTH,
    CUSTOMER_ID,
    PRODUCT_ID,
    CHANNEL                                                            AS TICKET_CHANNEL,
    PRIORITY,
    STATUS                                                             AS TICKET_STATUS,
    RESOLVED_AT,
    IFF(RESOLVED_AT IS NOT NULL, DATEDIFF('minute', CREATED_AT, RESOLVED_AT) / 60.0, NULL) AS RESOLUTION_HOURS,
    IFF(RESOLVED_AT IS NOT NULL, 1, 0)                                 AS IS_RESOLVED,
    IFF(STATUS = 'Escalated', 1, 0)                                    AS IS_ESCALATED,
    IFF(STATUS = 'Open', 1, 0)                                         AS IS_OPEN,
    CASE PRIORITY WHEN 'Critical' THEN 8 WHEN 'High' THEN 24
                  WHEN 'Medium' THEN 72 ELSE 120 END                   AS SLA_HOURS,
    IFF(RESOLVED_AT IS NOT NULL
        AND DATEDIFF('minute', CREATED_AT, RESOLVED_AT) / 60.0 >
            CASE PRIORITY WHEN 'Critical' THEN 8 WHEN 'High' THEN 24
                          WHEN 'Medium' THEN 72 ELSE 120 END, 1, 0)    AS IS_SLA_BREACHED
FROM ACCEL_DB.DEMO.SUPPORT_TICKETS;

GRANT USAGE ON SCHEMA ACCEL_DB.KPI_LIBRARY TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ACCEL_DB.KPI_LIBRARY TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA ACCEL_DB.KPI_LIBRARY TO ROLE ACCEL_ANALYST;

SELECT 'FIN' AS DOMAIN, COUNT(*) AS ROWS_ FROM FIN_GL_PNL_V
UNION ALL SELECT 'SC_PO',  COUNT(*) FROM SC_PURCHASE_ORDERS_V
UNION ALL SELECT 'SC_INV', COUNT(*) FROM SC_INVENTORY_DOS
UNION ALL SELECT 'HR',     COUNT(*) FROM HR_EMPLOYEES_V
UNION ALL SELECT 'CS',     COUNT(*) FROM CS_TICKETS_V;
