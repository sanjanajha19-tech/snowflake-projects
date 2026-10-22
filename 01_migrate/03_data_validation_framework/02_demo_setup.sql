/*=============================================================================
  DATA VALIDATION FRAMEWORK 02 - Demo: simulated legacy source + config
  Copies DEMO.ORDERS / ORDER_LINES / CUSTOMERS into schema SOURCE_SIM (the
  "legacy extract") and then plants typical migration defects in the copy,
  so validating SOURCE_SIM (source) against DEMO (migrated target) shows:
    ORDERS      - 3 orders dropped by the migration (MISSING_IN_TARGET),
                  5 totals off by 0.01 (rounding), 2 status-code mapping errors
    ORDER_LINES - 4 discounts NULL in legacy but defaulted in target,
                  2 lines duplicated by a re-run load (MISSING_IN_SOURCE)
    CUSTOMERS   - clean (PASS)
  DEMO tables are not modified.
  Run as : ACCEL_ADMIN, after 00_setup/02_demo_data.sql and 01_framework.sql.
  Rerun  : safe (recreates SOURCE_SIM tables, upserts config).
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SOURCE_SIM COMMENT = 'Simulated legacy source for the validation demo';
USE SCHEMA SOURCE_SIM;

------------------------------------------------------------------------------
-- 1. Copy the "legacy" tables
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE SOURCE_SIM.ORDERS      AS SELECT * FROM ACCEL_DB.DEMO.ORDERS;
CREATE OR REPLACE TABLE SOURCE_SIM.ORDER_LINES AS SELECT * FROM ACCEL_DB.DEMO.ORDER_LINES;
CREATE OR REPLACE TABLE SOURCE_SIM.CUSTOMERS   AS SELECT * FROM ACCEL_DB.DEMO.CUSTOMERS;

------------------------------------------------------------------------------
-- 2. Plant defects (all relative to the migrated target in DEMO)
------------------------------------------------------------------------------
-- 2a. Three legacy orders never reached the target (e.g. rejected by a NOT NULL rule)
INSERT INTO SOURCE_SIM.ORDERS (ORDER_ID, ORDER_DATE, CUSTOMER_ID, PLANT_ID, CHANNEL, STATUS, CURRENCY, ORDER_TOTAL)
SELECT 1900000 + ROW_NUMBER() OVER (ORDER BY ORDER_ID), ORDER_DATE, CUSTOMER_ID, PLANT_ID, CHANNEL, STATUS,
       CURRENCY, ORDER_TOTAL
FROM ACCEL_DB.DEMO.ORDERS
WHERE ORDER_ID IN (1050000, 1050001, 1050002);

-- 2b. Rounding difference: legacy totals 0.01 higher on five orders
UPDATE SOURCE_SIM.ORDERS
   SET ORDER_TOTAL = ORDER_TOTAL + 0.01
 WHERE ORDER_ID IN (1012345, 1023456, 1034567, 1045678, 1056789);

-- 2c. Status-code mapping error on two orders
UPDATE SOURCE_SIM.ORDERS
   SET STATUS = IFF(STATUS = 'Returned', 'Delivered', 'Returned')
 WHERE ORDER_ID IN (1067890, 1078901);

-- 2d. Legacy has NULL discounts; the migration defaulted them
UPDATE SOURCE_SIM.ORDER_LINES
   SET DISCOUNT_PCT = NULL
 WHERE LINE_NO = 1 AND ORDER_ID IN (1003000, 1004000, 1005000, 1006000);

-- 2e. Two target lines are duplicates from a re-run load: remove them from the "source"
DELETE FROM SOURCE_SIM.ORDER_LINES
 WHERE LINE_NO = 1 AND ORDER_ID IN (1000100, 1000200);

------------------------------------------------------------------------------
-- 3. Register the three pairs
------------------------------------------------------------------------------
MERGE INTO ACCEL_DB.VALIDATION.VALIDATION_CONFIG c
USING (
  SELECT $1 AS PAIR_ID, $2 AS PAIR_NAME, $3 AS SOURCE_TABLE, $4 AS TARGET_TABLE, $5 AS KEY_COLUMNS,
         $6 AS EXCLUDE_COLUMNS, $7 AS NUMERIC_TOLERANCE_PCT, $8 AS SAMPLE_PCT, $9 AS DIFF_SAMPLE_ROWS,
         $10 AS DATA_OWNER, $11 AS NOTES
  FROM VALUES
    (1, 'Orders',      'ACCEL_DB.SOURCE_SIM.ORDERS',      'ACCEL_DB.DEMO.ORDERS',      'ORDER_ID',         '', 0, 100, 20, 'Sales Ops', 'Order headers'),
    (2, 'Order lines', 'ACCEL_DB.SOURCE_SIM.ORDER_LINES', 'ACCEL_DB.DEMO.ORDER_LINES', 'ORDER_ID,LINE_NO', '', 0, 100, 20, 'Sales Ops', 'Order lines'),
    (3, 'Customers',   'ACCEL_DB.SOURCE_SIM.CUSTOMERS',   'ACCEL_DB.DEMO.CUSTOMERS',   'CUSTOMER_ID',      '', 0, 100, 20, 'CRM team',  'Customer master')
) v
ON c.PAIR_ID = v.PAIR_ID
WHEN MATCHED THEN UPDATE SET
  PAIR_NAME = v.PAIR_NAME, SOURCE_TABLE = v.SOURCE_TABLE, TARGET_TABLE = v.TARGET_TABLE,
  KEY_COLUMNS = v.KEY_COLUMNS, EXCLUDE_COLUMNS = NULLIF(v.EXCLUDE_COLUMNS, ''),
  NUMERIC_TOLERANCE_PCT = v.NUMERIC_TOLERANCE_PCT, SAMPLE_PCT = v.SAMPLE_PCT,
  DIFF_SAMPLE_ROWS = v.DIFF_SAMPLE_ROWS, IS_ACTIVE = TRUE, DATA_OWNER = v.DATA_OWNER, NOTES = v.NOTES
WHEN NOT MATCHED THEN INSERT
  (PAIR_ID, PAIR_NAME, SOURCE_TABLE, TARGET_TABLE, KEY_COLUMNS, EXCLUDE_COLUMNS,
   NUMERIC_TOLERANCE_PCT, SAMPLE_PCT, DIFF_SAMPLE_ROWS, IS_ACTIVE, DATA_OWNER, NOTES)
VALUES
  (v.PAIR_ID, v.PAIR_NAME, v.SOURCE_TABLE, v.TARGET_TABLE, v.KEY_COLUMNS, NULLIF(v.EXCLUDE_COLUMNS, ''),
   v.NUMERIC_TOLERANCE_PCT, v.SAMPLE_PCT, v.DIFF_SAMPLE_ROWS, TRUE, v.DATA_OWNER, v.NOTES);

-- Add your own pairs the same way, e.g.:
-- INSERT INTO ACCEL_DB.VALIDATION.VALIDATION_CONFIG
--   (PAIR_ID, PAIR_NAME, SOURCE_TABLE, TARGET_TABLE, KEY_COLUMNS, EXCLUDE_COLUMNS, NUMERIC_TOLERANCE_PCT)
-- VALUES (10, 'GL lines', 'LEGACY_DB.FINDW.GL_JOURNAL_LINES', 'EDW.FINANCE.GL_JOURNAL_LINES',   -- EDIT ME
--         'JE_HEADER_ID,JE_LINE_NUM', 'LOAD_TS', 0.001);

SELECT * FROM ACCEL_DB.VALIDATION.VALIDATION_CONFIG ORDER BY PAIR_ID;

-- Expected differences (run before validating to see what the framework should find)
SELECT 'ORDERS source - target' AS CHECK_NAME,
       (SELECT COUNT(*) FROM SOURCE_SIM.ORDERS) - (SELECT COUNT(*) FROM ACCEL_DB.DEMO.ORDERS) AS ROW_DIFF
UNION ALL
SELECT 'ORDER_LINES source - target',
       (SELECT COUNT(*) FROM SOURCE_SIM.ORDER_LINES) - (SELECT COUNT(*) FROM ACCEL_DB.DEMO.ORDER_LINES);
