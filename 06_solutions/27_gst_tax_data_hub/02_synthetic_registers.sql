/* =============================================================================
   Asset 27 - GST Tax Data Hub
   File  02_synthetic_registers.sql
   Purpose
     GST.SUPPLIER_GST_MASTER  - one GSTIN per DEMO supplier. Uses DEMO.SUPPLIERS.GSTIN
                                when it passes GST.IS_VALID_GSTIN, otherwise synthesises
                                a structurally valid GSTIN (state + PAN-like + 1Z + check char)
     GST.PURCHASE_REGISTER    - "books": one purchase invoice per received PO from
                                FY2025-26 onward, taxable value, GST rate, IGST or CGST+SGST
     GST.GSTR2B_INVOICES      - GSTR-2B-style supplier-filed invoices derived from
                                the books with deliberate, deterministic mismatches:
                                  ~6%  missing in 2B (supplier did not file)
                                  ~2%  small value difference (0.2-0.6%)
                                  ~3%  large value difference (5-14%)
                                  ~3%  GSTIN typo (one character - fails check digit)
                                  ~5%  invoice date difference (1-20 days)
                                  ~5%  invoice number format variation (INV-2025-123)
                                  ~2%  invoice number typo (last character)
                                  ~2%  extra invoices not in books
                                DEMO_SCENARIO records what was injected (for the demo
                                only - real 2B data has no such column).
   All amounts are treated as INR. Rates are ILLUSTRATIVE (see GST.GST_RATES).
   Run as  ACCEL_ADMIN after 01. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS GST;
USE SCHEMA GST;

-- -----------------------------------------------------------------------------
-- 1. Supplier GST master
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE GST.SUPPLIER_GST_MASTER AS
WITH s AS (
    SELECT sup.SUPPLIER_ID, sup.SUPPLIER_NAME, sup.COUNTRY, sup.CATEGORY,
           sup.GSTIN AS SOURCE_GSTIN,
           GST.IS_VALID_GSTIN(sup.GSTIN) AS SOURCE_GSTIN_VALID,
           ARRAY_CONSTRUCT('27', '29', '33', '07', '24', '36', '06', '09', '19', '08')
               [MOD(ABS(HASH(sup.SUPPLIER_ID, 'state')), 10)]::VARCHAR
           || CHR(65 + MOD(ABS(HASH(sup.SUPPLIER_ID, 'l1')), 26))
           || CHR(65 + MOD(ABS(HASH(sup.SUPPLIER_ID, 'l2')), 26))
           || CHR(65 + MOD(ABS(HASH(sup.SUPPLIER_ID, 'l3')), 26))
           || 'C'                                                          -- 4th PAN char: C = company
           || CHR(65 + MOD(ABS(HASH(sup.SUPPLIER_ID, 'l5')), 26))
           || LPAD(TO_VARCHAR(MOD(ABS(HASH(sup.SUPPLIER_ID, 'num')), 10000)), 4, '0')
           || CHR(65 + MOD(ABS(HASH(sup.SUPPLIER_ID, 'l10')), 26))
           || '1Z'                                                         AS SYNTH_FIRST14
    FROM ACCEL_DB.DEMO.SUPPLIERS sup
)
SELECT SUPPLIER_ID, SUPPLIER_NAME, COUNTRY, CATEGORY, SOURCE_GSTIN, SOURCE_GSTIN_VALID,
       IFF(SOURCE_GSTIN_VALID, UPPER(TRIM(SOURCE_GSTIN)), SYNTH_FIRST14 || GST.GSTIN_CHECK_CHAR(SYNTH_FIRST14)) AS GSTIN,
       IFF(SOURCE_GSTIN_VALID, 'DEMO.SUPPLIERS', 'Synthesised - source GSTIN missing or invalid')           AS GSTIN_SOURCE
FROM s;

-- -----------------------------------------------------------------------------
-- 2. Purchase register (books)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE GST.PURCHASE_REGISTER AS
WITH cfg AS (
    SELECT TO_DATE(TO_VARCHAR(MAX(IFF(PARAM = 'BOOKS_FROM_DATE_YYYYMMDD', VALUE, NULL))::INT), 'YYYYMMDD') AS BOOKS_FROM
    FROM GST.RECON_CONFIG
),
po AS (
    SELECT p.*,
           DATEADD('day', -MOD(ABS(HASH(p.PO_ID, 'invd')), 4), p.RECEIVED_DATE) AS INVOICE_DATE
    FROM ACCEL_DB.DEMO.PURCHASE_ORDERS p
    WHERE p.RECEIVED_DATE IS NOT NULL AND p.STATUS <> 'Cancelled'
),
lines AS (
    SELECT po.PO_ID, po.PLANT_ID, po.PRODUCT_ID, po.INVOICE_DATE,
           sm.SUPPLIER_ID, sm.SUPPLIER_NAME, sm.GSTIN AS SUPPLIER_GSTIN,
           LEFT(sm.GSTIN, 2)                                        AS SUPPLIER_STATE_CODE,
           ps.STATE_CODE                                            AS BUYER_STATE_CODE,
           'INV/' || TO_CHAR(po.INVOICE_DATE, 'YYYY') || '/'
             || LPAD(TO_VARCHAR(po.PO_ID), GREATEST(6, LENGTH(TO_VARCHAR(po.PO_ID))), '0') AS INVOICE_NO,
           ROUND(po.QUANTITY * po.UNIT_COST, 2)                      AS TAXABLE_VALUE,
           COALESCE(r.GST_RATE, d.GST_RATE)                          AS GST_RATE
    FROM po
    CROSS JOIN cfg
    JOIN GST.SUPPLIER_GST_MASTER sm ON sm.SUPPLIER_ID = po.SUPPLIER_ID
    LEFT JOIN GST.PLANT_GST_STATE ps ON ps.PLANT_ID = po.PLANT_ID
    LEFT JOIN ACCEL_DB.DEMO.PRODUCTS pr ON pr.PRODUCT_ID = po.PRODUCT_ID
    LEFT JOIN GST.GST_RATES r ON r.PRODUCT_CATEGORY = pr.CATEGORY
    LEFT JOIN GST.GST_RATES d ON d.PRODUCT_CATEGORY = 'DEFAULT'
    WHERE po.INVOICE_DATE >= cfg.BOOKS_FROM
)
SELECT 'PR-' || TO_VARCHAR(PO_ID)                                         AS BOOKS_ID,
       PO_ID, PLANT_ID, PRODUCT_ID, SUPPLIER_ID, SUPPLIER_NAME, SUPPLIER_GSTIN,
       SUPPLIER_STATE_CODE, COALESCE(BUYER_STATE_CODE, '27')               AS BUYER_STATE_CODE,
       INVOICE_NO, INVOICE_DATE,
       TO_CHAR(INVOICE_DATE, 'MMYYYY')                                     AS RETURN_PERIOD,
       TAXABLE_VALUE, GST_RATE,
       (SUPPLIER_STATE_CODE <> COALESCE(BUYER_STATE_CODE, '27'))           AS IS_INTER_STATE,
       IFF(SUPPLIER_STATE_CODE <> COALESCE(BUYER_STATE_CODE, '27'), ROUND(TAXABLE_VALUE * GST_RATE, 2), 0)     AS IGST,
       IFF(SUPPLIER_STATE_CODE <> COALESCE(BUYER_STATE_CODE, '27'), 0, ROUND(TAXABLE_VALUE * GST_RATE / 2, 2)) AS CGST,
       IFF(SUPPLIER_STATE_CODE <> COALESCE(BUYER_STATE_CODE, '27'), 0, ROUND(TAXABLE_VALUE * GST_RATE / 2, 2)) AS SGST,
       IGST + CGST + SGST                                                  AS TOTAL_TAX,
       TAXABLE_VALUE + IGST + CGST + SGST                                  AS INVOICE_VALUE,
       IGST + CGST + SGST                                                  AS ITC_CLAIMED
FROM lines;

-- -----------------------------------------------------------------------------
-- 3. GSTR-2B-style supplier-filed invoices with injected mismatches
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE GST.GSTR2B_INVOICES AS
WITH b AS (
    SELECT pr.*,
           MOD(ABS(HASH(pr.PO_ID, '2b')),   100) AS H,
           MOD(ABS(HASH(pr.PO_ID, '2b_x')), 100) AS H2,
           MOD(ABS(HASH(pr.PO_ID, '2b_e')), 100) AS H3
    FROM GST.PURCHASE_REGISTER pr
),
v AS (
    SELECT b.*,
           CASE WHEN H < 6  THEN 'MISSING_IN_2B'
                WHEN H < 8  THEN 'SMALL_VALUE_DIFF'
                WHEN H < 11 THEN 'LARGE_VALUE_DIFF'
                WHEN H < 14 THEN 'GSTIN_TYPO'
                WHEN H < 19 THEN 'DATE_DIFF'
                WHEN H < 24 THEN 'INVOICE_FORMAT'
                WHEN H < 26 THEN 'INVOICE_TYPO'
                ELSE 'CLEAN' END                                        AS DEMO_SCENARIO,
           3 + MOD(H2, 10)                                              AS GSTIN_POS,
           LENGTH(INVOICE_NO)                                           AS INV_POS
    FROM b
),
derived AS (
    SELECT v.BOOKS_ID, v.SUPPLIER_NAME, v.BUYER_STATE_CODE, v.IS_INTER_STATE, v.GST_RATE, v.DEMO_SCENARIO,
           CASE v.DEMO_SCENARIO
               WHEN 'GSTIN_TYPO' THEN
                   SUBSTR(v.SUPPLIER_GSTIN, 1, v.GSTIN_POS - 1)
                   || CASE WHEN SUBSTR(v.SUPPLIER_GSTIN, v.GSTIN_POS, 1) BETWEEN '0' AND '9'
                               THEN TO_VARCHAR(MOD(TO_NUMBER(SUBSTR(v.SUPPLIER_GSTIN, v.GSTIN_POS, 1)) + 1, 10))
                           WHEN SUBSTR(v.SUPPLIER_GSTIN, v.GSTIN_POS, 1) = 'Z' THEN 'A'
                           ELSE CHR(ASCII(SUBSTR(v.SUPPLIER_GSTIN, v.GSTIN_POS, 1)) + 1) END
                   || SUBSTR(v.SUPPLIER_GSTIN, v.GSTIN_POS + 1)
               ELSE v.SUPPLIER_GSTIN END                                AS SUPPLIER_GSTIN,
           CASE v.DEMO_SCENARIO
               WHEN 'INVOICE_FORMAT' THEN 'INV-' || TO_CHAR(v.INVOICE_DATE, 'YYYY') || '-' || TO_VARCHAR(v.PO_ID)
               WHEN 'INVOICE_TYPO' THEN
                   SUBSTR(v.INVOICE_NO, 1, v.INV_POS - 1)
                   || CASE WHEN SUBSTR(v.INVOICE_NO, v.INV_POS, 1) BETWEEN '0' AND '9'
                               THEN TO_VARCHAR(MOD(TO_NUMBER(SUBSTR(v.INVOICE_NO, v.INV_POS, 1)) + 1, 10))
                           WHEN SUBSTR(v.INVOICE_NO, v.INV_POS, 1) = 'Z' THEN 'A'
                           ELSE CHR(ASCII(SUBSTR(v.INVOICE_NO, v.INV_POS, 1)) + 1) END
               ELSE v.INVOICE_NO END                                    AS INVOICE_NO,
           IFF(v.DEMO_SCENARIO = 'DATE_DIFF', DATEADD('day', 1 + MOD(v.H2, 20), v.INVOICE_DATE), v.INVOICE_DATE) AS INVOICE_DATE,
           CASE v.DEMO_SCENARIO
               WHEN 'SMALL_VALUE_DIFF' THEN ROUND(v.TAXABLE_VALUE * (1 + IFF(MOD(v.H2, 2) = 0, 1, -1) * (0.002 + MOD(v.H2, 5) / 1000)), 2)
               WHEN 'LARGE_VALUE_DIFF' THEN ROUND(v.TAXABLE_VALUE * (1 + IFF(MOD(v.H2, 2) = 0, 1, -1) * (0.05 + MOD(v.H2, 10) / 100)), 2)
               ELSE v.TAXABLE_VALUE END                                 AS TAXABLE_VALUE
    FROM v
    WHERE v.DEMO_SCENARIO <> 'MISSING_IN_2B'
    UNION ALL
    -- invoices the supplier filed but which are not in our books
    SELECT 'NONE', b.SUPPLIER_NAME, b.BUYER_STATE_CODE, b.IS_INTER_STATE, b.GST_RATE, 'MISSING_IN_BOOKS',
           b.SUPPLIER_GSTIN,
           'INV/' || TO_CHAR(b.INVOICE_DATE, 'YYYY') || '/9' || LPAD(TO_VARCHAR(b.PO_ID), GREATEST(6, LENGTH(TO_VARCHAR(b.PO_ID))), '0'),
           DATEADD('day', 3, b.INVOICE_DATE),
           ROUND(b.TAXABLE_VALUE * (0.4 + b.H3 / 100), 2)
    FROM b
    WHERE b.H3 < 2
)
SELECT '2B-' || LPAD(TO_VARCHAR(ROW_NUMBER() OVER (ORDER BY d.INVOICE_DATE, d.SUPPLIER_GSTIN, d.INVOICE_NO)), 7, '0') AS GSTR2B_ID,
       TO_CHAR(d.INVOICE_DATE, 'MMYYYY')                                      AS RETURN_PERIOD,
       d.SUPPLIER_GSTIN,
       UPPER(d.SUPPLIER_NAME)                                                 AS SUPPLIER_TRADE_NAME,
       d.INVOICE_NO,
       d.INVOICE_DATE,
       'R'                                                                    AS INVOICE_TYPE,      -- Regular
       d.BUYER_STATE_CODE                                                     AS PLACE_OF_SUPPLY,
       'N'                                                                    AS REVERSE_CHARGE,
       d.TAXABLE_VALUE,
       IFF(d.IS_INTER_STATE, ROUND(d.TAXABLE_VALUE * d.GST_RATE, 2), 0)       AS IGST,
       IFF(d.IS_INTER_STATE, 0, ROUND(d.TAXABLE_VALUE * d.GST_RATE / 2, 2))   AS CGST,
       IFF(d.IS_INTER_STATE, 0, ROUND(d.TAXABLE_VALUE * d.GST_RATE / 2, 2))   AS SGST,
       0::NUMBER(14,2)                                                        AS CESS,
       IGST + CGST + SGST                                                     AS TOTAL_TAX,
       'Y'                                                                    AS ITC_AVAILABLE,
       DATEADD('day', 11, LAST_DAY(d.INVOICE_DATE))                           AS SUPPLIER_FILING_DATE,
       d.DEMO_SCENARIO,
       NULLIF(d.BOOKS_ID, 'NONE')                                             AS DEMO_SOURCE_BOOKS_ID
FROM derived d;

SELECT 'Purchase register' AS REGISTER, COUNT(*) AS INVOICES, ROUND(SUM(TAXABLE_VALUE), 0) AS TAXABLE, ROUND(SUM(TOTAL_TAX), 0) AS TAX
FROM GST.PURCHASE_REGISTER
UNION ALL
SELECT 'GSTR-2B', COUNT(*), ROUND(SUM(TAXABLE_VALUE), 0), ROUND(SUM(TOTAL_TAX), 0) FROM GST.GSTR2B_INVOICES;

SELECT DEMO_SCENARIO, COUNT(*) AS INVOICES FROM GST.GSTR2B_INVOICES GROUP BY 1 ORDER BY 2 DESC;

SELECT GSTIN_SOURCE, COUNT(*) AS SUPPLIERS FROM GST.SUPPLIER_GST_MASTER GROUP BY 1;
