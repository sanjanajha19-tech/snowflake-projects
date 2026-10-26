/*=============================================================================
  ACCELERATOR 20 - SAP Finance Accelerator
  File 01 : Synthetic SAP ECC / S/4HANA-style RAW layer (as replicated)
            Tables use SAP names and field names. Like a real raw replica:
              - dates are CHAR(8) 'YYYYMMDD', empty date = '00000000'
              - customer / vendor / document numbers keep leading zeros
              - amounts are unsigned; SHKZG (S = debit, H = credit) gives the sign
            Generated from ACCEL_DB.DEMO (customers, suppliers, products,
            orders Jul-2025..Sep-2026, purchase orders) so numbers reconcile.
  Creates : schema ACCEL_DB.SAPFIN with T001, TCURR, SKA1, SKAT, KNA1, LFA1,
            VBAK, VBAP, EKKO, EKPO, BKPF, BSEG (+ helper ZACCEL_COUNTRY)
  Run as  : ACCEL_ADMIN
  Rerun   : safe (all CREATE OR REPLACE).
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SAPFIN COMMENT = 'Accelerator 20: SAP finance raw + canonical model';
USE SCHEMA SAPFIN;

------------------------------------------------------------------------------
-- 0. Configuration: client (MANDT), scope and extraction date
------------------------------------------------------------------------------
SET SAP_MANDT    = '100';           -- EDIT ME: SAP client
SET SCOPE_FROM   = '2025-07-01';    -- first posting date generated
SET EXTRACT_DATE = '2026-09-30';    -- documents after this date are not in the extract

------------------------------------------------------------------------------
-- 1. Org / config tables
------------------------------------------------------------------------------
-- T001: company codes
CREATE OR REPLACE TABLE T001 (
    MANDT VARCHAR(3), BUKRS VARCHAR(4), BUTXT VARCHAR(25), ORT01 VARCHAR(25),
    LAND1 VARCHAR(3), WAERS VARCHAR(5), KTOPL VARCHAR(4), SPRAS VARCHAR(1)
) COMMENT = 'SAP T001 - company codes';
INSERT INTO T001
SELECT $SAP_MANDT, $1, $2, $3, $4, $5, $6, $7
FROM (VALUES
    ('IN01', 'Accel India Pvt Ltd',   'Pune',       'IN', 'INR', 'INT', 'E'),
    ('US01', 'Accel Americas Inc',     'Houston',    'US', 'USD', 'INT', 'E'),
    ('UK01', 'Accel UK Ltd',           'Manchester', 'GB', 'GBP', 'INT', 'E'),
    ('DE01', 'Accel Deutschland GmbH', 'Stuttgart',  'DE', 'EUR', 'INT', 'D'));

-- TCURR: exchange rates (type M, from USD), one validity date for simplicity
CREATE OR REPLACE TABLE TCURR (
    MANDT VARCHAR(3), KURST VARCHAR(4), FCURR VARCHAR(5), TCURR VARCHAR(5), GDATU VARCHAR(8), UKURS NUMBER(9,5)
) COMMENT = 'SAP TCURR - exchange rates (GDATU stored as plain YYYYMMDD here, not inverted)';
INSERT INTO TCURR
SELECT $SAP_MANDT, $1, $2, $3, $4, $5
FROM (VALUES
    ('M', 'USD', 'USD', '20250101', 1.00000),
    ('M', 'USD', 'INR', '20250101', 83.00000),     -- EDIT ME: rates
    ('M', 'USD', 'GBP', '20250101', 0.79000),
    ('M', 'USD', 'EUR', '20250101', 0.92000));

-- Helper (customer Z-table): country name -> SAP country key and company code
CREATE OR REPLACE TABLE ZACCEL_COUNTRY (COUNTRY_NAME VARCHAR, LAND1 VARCHAR(3), BUKRS VARCHAR(4))
COMMENT = 'Helper Z-table: demo country -> SAP LAND1 / owning company code';
INSERT INTO ZACCEL_COUNTRY VALUES
    ('India', 'IN', 'IN01'), ('USA', 'US', 'US01'), ('UK', 'GB', 'UK01'), ('Germany', 'DE', 'DE01'),
    ('Japan', 'JP', 'US01'), ('Singapore', 'SG', 'US01'), ('China', 'CN', 'US01'),
    ('Vietnam', 'VN', 'US01'), ('Taiwan', 'TW', 'US01');

------------------------------------------------------------------------------
-- 2. Chart of accounts: SKA1 (master) + SKAT (texts)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE SKA1 (
    MANDT VARCHAR(3), KTOPL VARCHAR(4), SAKNR VARCHAR(10), XBILK VARCHAR(1), GVTYP VARCHAR(2), KTOKS VARCHAR(4), ERDAT VARCHAR(8)
) COMMENT = 'SAP SKA1 - G/L account master (chart of accounts)';
CREATE OR REPLACE TABLE SKAT (
    MANDT VARCHAR(3), SPRAS VARCHAR(1), KTOPL VARCHAR(4), SAKNR VARCHAR(10), TXT20 VARCHAR(20), TXT50 VARCHAR(50)
) COMMENT = 'SAP SKAT - G/L account texts';

CREATE OR REPLACE TEMPORARY TABLE TMP_COA AS
SELECT $1 AS SAKNR, $2 AS IS_BS, $3 AS TXT20, $4 AS TXT50
FROM (VALUES
    ('0000070000', TRUE,  'Share capital',      'Subscribed share capital'),
    ('0000113100', TRUE,  'Bank current acct',  'Bank - current account'),
    ('0000140000', TRUE,  'Trade receivables',  'Receivables from customers (reconciliation)'),
    ('0000160000', TRUE,  'Trade payables',     'Payables to vendors (reconciliation)'),
    ('0000300000', TRUE,  'Inventory',          'Inventory - trading goods'),
    ('0000440000', FALSE, 'Salaries',           'Salaries and wages'),
    ('0000476000', FALSE, 'Office expenses',    'Office and administration expenses'),
    ('0000800000', FALSE, 'Sales revenue',      'Sales revenue - goods'));

INSERT INTO SKA1
SELECT $SAP_MANDT, 'INT', SAKNR, IFF(IS_BS, 'X', ''), IFF(IS_BS, '', 'X'), IFF(IS_BS, 'BS', 'PL'), '20200101' FROM TMP_COA;
INSERT INTO SKAT
SELECT $SAP_MANDT, 'E', 'INT', SAKNR, TXT20, TXT50 FROM TMP_COA;

------------------------------------------------------------------------------
-- 3. Business partners: KNA1 (customers) and LFA1 (vendors)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE KNA1 (
    MANDT VARCHAR(3), KUNNR VARCHAR(10), NAME1 VARCHAR(35), LAND1 VARCHAR(3), ORT01 VARCHAR(35),
    KTOKD VARCHAR(4), BRSCH VARCHAR(4), STCD1 VARCHAR(16), ERDAT VARCHAR(8), LOEVM VARCHAR(1)
) COMMENT = 'SAP KNA1 - customer master (general data)';

INSERT INTO KNA1
SELECT $SAP_MANDT,
       LPAD(TO_VARCHAR(c.CUSTOMER_ID), 10, '0'),
       LEFT(c.CUSTOMER_NAME, 35),
       m.LAND1,
       LEFT(c.CITY, 35),
       IFF(c.SEGMENT = 'Consumer', 'CPD', 'KUNA'),
       UPPER(LEFT(REPLACE(c.INDUSTRY, ' ', ''), 4)),
       IFF(c.COUNTRY = 'India', c.PAN_NUMBER, NULL),
       TO_VARCHAR(c.CREATED_DATE, 'YYYYMMDD'),
       ''
FROM ACCEL_DB.DEMO.CUSTOMERS c
JOIN ZACCEL_COUNTRY m ON m.COUNTRY_NAME = c.COUNTRY;

CREATE OR REPLACE TABLE LFA1 (
    MANDT VARCHAR(3), LIFNR VARCHAR(10), NAME1 VARCHAR(35), LAND1 VARCHAR(3), ORT01 VARCHAR(35),
    KTOKK VARCHAR(4), STCD3 VARCHAR(18), ERDAT VARCHAR(8), LOEVM VARCHAR(1), SPERR VARCHAR(1)
) COMMENT = 'SAP LFA1 - vendor master (general data)';

INSERT INTO LFA1
SELECT $SAP_MANDT,
       LPAD(TO_VARCHAR(100000 + s.SUPPLIER_ID), 10, '0'),
       LEFT(s.SUPPLIER_NAME, 35),
       m.LAND1,
       NULL,
       'KRED',
       s.GSTIN,
       '20230101',
       '',
       IFF(s.RISK_RATING = 'High' AND MOD(s.SUPPLIER_ID, 2) = 0, 'X', '')     -- posting block on some high-risk vendors
FROM ACCEL_DB.DEMO.SUPPLIERS s
JOIN ZACCEL_COUNTRY m ON m.COUNTRY_NAME = s.COUNTRY;

------------------------------------------------------------------------------
-- 4. Sales documents: VBAK (header) / VBAP (item)  ~ 10% sample of orders in scope
------------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE TMP_SO AS
SELECT o.ORDER_ID, o.ORDER_DATE, o.CUSTOMER_ID, o.PLANT_ID, o.CHANNEL, o.STATUS, o.CURRENCY, o.ORDER_TOTAL,
       c.SEGMENT, m.BUKRS
FROM ACCEL_DB.DEMO.ORDERS o
JOIN ACCEL_DB.DEMO.CUSTOMERS c ON c.CUSTOMER_ID = o.CUSTOMER_ID
JOIN ZACCEL_COUNTRY m ON m.COUNTRY_NAME = c.COUNTRY
WHERE o.ORDER_DATE BETWEEN $SCOPE_FROM::DATE AND $EXTRACT_DATE::DATE
  AND MOD(o.ORDER_ID, 10) = 0;

CREATE OR REPLACE TABLE VBAK (
    MANDT VARCHAR(3), VBELN VARCHAR(10), ERDAT VARCHAR(8), ERNAM VARCHAR(12), AUART VARCHAR(4),
    VKORG VARCHAR(4), VTWEG VARCHAR(2), SPART VARCHAR(2), KUNNR VARCHAR(10), NETWR NUMBER(15,2),
    WAERK VARCHAR(5), BUKRS_VF VARCHAR(4), GBSTK VARCHAR(1), VDATU VARCHAR(8)
) COMMENT = 'SAP VBAK - sales document header';

INSERT INTO VBAK
SELECT $SAP_MANDT,
       LPAD(TO_VARCHAR(ORDER_ID), 10, '0'),
       TO_VARCHAR(ORDER_DATE, 'YYYYMMDD'),
       IFF(CHANNEL = 'E-commerce', 'WEBSHOP', 'SD_USER'),
       IFF(STATUS = 'Returned', 'RE', 'OR'),
       REPLACE(BUKRS, '01', '10'),
       DECODE(CHANNEL, 'Direct', '10', 'Distributor', '20', 'E-commerce', '30', '40'),
       '00',
       LPAD(TO_VARCHAR(CUSTOMER_ID), 10, '0'),
       ORDER_TOTAL,
       CURRENCY,
       BUKRS,
       DECODE(STATUS, 'Delivered', 'C', 'Returned', 'C', 'Shipped', 'B', 'Cancelled', 'C', 'A'),
       TO_VARCHAR(DATEADD(DAY, 7, ORDER_DATE), 'YYYYMMDD')
FROM TMP_SO;

CREATE OR REPLACE TABLE VBAP (
    MANDT VARCHAR(3), VBELN VARCHAR(10), POSNR VARCHAR(6), MATNR VARCHAR(18), ARKTX VARCHAR(40),
    KWMENG NUMBER(15,3), VRKME VARCHAR(3), NETPR NUMBER(11,2), NETWR NUMBER(15,2), WAERK VARCHAR(5),
    WERKS VARCHAR(4), ABGRU VARCHAR(2), PSTYV VARCHAR(4)
) COMMENT = 'SAP VBAP - sales document item';

INSERT INTO VBAP
SELECT $SAP_MANDT,
       LPAD(TO_VARCHAR(s.ORDER_ID), 10, '0'),
       LPAD(TO_VARCHAR(ol.LINE_NO * 10), 6, '0'),
       p.SKU,
       LEFT(p.PRODUCT_NAME, 40),
       ol.QUANTITY,
       'EA',
       ROUND(ol.UNIT_PRICE * (1 - ol.DISCOUNT_PCT / 100), 2),
       ol.NET_AMOUNT,
       s.CURRENCY,
       '1' || LPAD(TO_VARCHAR(s.PLANT_ID), 3, '0'),
       IFF(s.STATUS = 'Cancelled', '01', ''),
       'TAN'
FROM TMP_SO s
JOIN ACCEL_DB.DEMO.ORDER_LINES ol ON ol.ORDER_ID = s.ORDER_ID
JOIN ACCEL_DB.DEMO.PRODUCTS p ON p.PRODUCT_ID = ol.PRODUCT_ID;

------------------------------------------------------------------------------
-- 5. Purchasing documents: EKKO (header) / EKPO (item)  ~ 1/3 of POs in scope
------------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE TMP_PO AS
SELECT po.*, pm.BUKRS
FROM ACCEL_DB.DEMO.PURCHASE_ORDERS po
JOIN ACCEL_DB.DEMO.PLANTS pl ON pl.PLANT_ID = po.PLANT_ID
JOIN ZACCEL_COUNTRY pm ON pm.COUNTRY_NAME = pl.COUNTRY
WHERE po.PO_DATE BETWEEN $SCOPE_FROM::DATE AND $EXTRACT_DATE::DATE
  AND MOD(po.PO_ID, 3) = 0;

CREATE OR REPLACE TABLE EKKO (
    MANDT VARCHAR(3), EBELN VARCHAR(10), BUKRS VARCHAR(4), BSTYP VARCHAR(1), BSART VARCHAR(4),
    LIFNR VARCHAR(10), EKORG VARCHAR(4), EKGRP VARCHAR(3), BEDAT VARCHAR(8), WAERS VARCHAR(5),
    ZTERM VARCHAR(4), ERNAM VARCHAR(12), LOEKZ VARCHAR(1)
) COMMENT = 'SAP EKKO - purchasing document header';

INSERT INTO EKKO
SELECT $SAP_MANDT,
       TO_VARCHAR(4500000000 + (PO_ID - 4500000)),
       BUKRS, 'F', 'NB',
       LPAD(TO_VARCHAR(100000 + SUPPLIER_ID), 10, '0'),
       REPLACE(BUKRS, '01', '00'),
       '00' || TO_VARCHAR(MOD(SUPPLIER_ID, 3) + 1),
       TO_VARCHAR(PO_DATE, 'YYYYMMDD'),
       'USD',
       'NT45',
       'MM_BUYER',
       IFF(STATUS = 'Cancelled', 'L', '')
FROM TMP_PO;

CREATE OR REPLACE TABLE EKPO (
    MANDT VARCHAR(3), EBELN VARCHAR(10), EBELP VARCHAR(5), MATNR VARCHAR(18), TXZ01 VARCHAR(40),
    WERKS VARCHAR(4), MENGE NUMBER(13,3), MEINS VARCHAR(3), NETPR NUMBER(11,2), PEINH NUMBER(5),
    NETWR NUMBER(15,2), ELIKZ VARCHAR(1), LOEKZ VARCHAR(1), EINDT VARCHAR(8)
) COMMENT = 'SAP EKPO - purchasing document item (EINDT normally lives in EKET; kept here for simplicity)';

INSERT INTO EKPO
SELECT $SAP_MANDT,
       TO_VARCHAR(4500000000 + (t.PO_ID - 4500000)),
       '00010',
       p.SKU,
       LEFT(p.PRODUCT_NAME, 40),
       '1' || LPAD(TO_VARCHAR(t.PLANT_ID), 3, '0'),
       t.QUANTITY, 'EA', t.UNIT_COST, 1,
       ROUND(t.QUANTITY * t.UNIT_COST, 2),
       IFF(t.RECEIVED_DATE IS NOT NULL, 'X', ''),
       IFF(t.STATUS = 'Cancelled', 'L', ''),
       TO_VARCHAR(t.PROMISED_DATE, 'YYYYMMDD')
FROM TMP_PO t
JOIN ACCEL_DB.DEMO.PRODUCTS p ON p.PRODUCT_ID = t.PRODUCT_ID;

------------------------------------------------------------------------------
-- 6. FI documents: BKPF (header) / BSEG (line items)
--    Document families:
--      RV 90xxxxxxxx  customer invoice (from VBAK, not cancelled)
--      DZ 14xxxxxxxx  customer payment  (clears the invoice line)
--      RE 51xxxxxxxx  vendor invoice    (from received POs)
--      KZ 15xxxxxxxx  vendor payment    (clears the vendor line)
--      SA 10xxxxxxxx  opening capital + monthly payroll / office costs
------------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE TMP_DOCS (
    DOC_FAMILY VARCHAR, BUKRS VARCHAR, BELNR VARCHAR, BLART VARCHAR, BUDAT DATE, USNAM VARCHAR, TCODE VARCHAR,
    XBLNR VARCHAR, BKTXT VARCHAR, WAERS VARCHAR, FX NUMBER(9,5), WRBTR NUMBER(15,2),
    PARTNER VARCHAR, ZTERM VARCHAR, ZBD1T NUMBER, CLEAR_DATE DATE, CLEAR_DOC VARCHAR,
    DEBIT_ACCT VARCHAR, CREDIT_ACCT VARCHAR, EBELN VARCHAR, VBELN VARCHAR, ENTRY_SECS NUMBER
);

-- 6a. Customer invoices + payments
INSERT INTO TMP_DOCS
WITH inv AS (
    SELECT s.*, ROW_NUMBER() OVER (ORDER BY s.ORDER_ID) AS N,
           DECODE(s.SEGMENT, 'Enterprise', 60, 'Mid-Market', 45, 'SMB', 30, 15) AS TERMS,
           MOD(ABS(HASH(s.ORDER_ID, 'pay')), 100) AS RP,
           MOD(ABS(HASH(s.ORDER_ID, 'pd')), 40)   AS RD
    FROM TMP_SO s
    WHERE s.STATUS <> 'Cancelled'
),
pay AS (
    SELECT inv.*,
           DATEADD(DAY, TERMS + CASE WHEN RP < 15 THEN -MOD(RD, 10)          -- early
                                     WHEN RP < 70 THEN MOD(RD, 10)           -- around due date
                                     WHEN RP < 90 THEN 10 + RD               -- late
                                     ELSE 60 + RD * 3 END,                   -- very slow payers
                   ORDER_DATE) AS PAY_DATE
    FROM inv
)
SELECT 'AR_INV', p.BUKRS, '90' || LPAD(TO_VARCHAR(p.N), 8, '0'), 'RV', p.ORDER_DATE, 'SD_BILLING', 'VF01',
       LPAD(TO_VARCHAR(p.ORDER_ID), 10, '0'), 'Billing doc', 'USD', fx.UKURS, p.ORDER_TOTAL,
       LPAD(TO_VARCHAR(p.CUSTOMER_ID), 10, '0'), 'NT' || p.TERMS, p.TERMS,
       IFF(p.PAY_DATE <= $EXTRACT_DATE::DATE, p.PAY_DATE, NULL),
       IFF(p.PAY_DATE <= $EXTRACT_DATE::DATE, '14' || LPAD(TO_VARCHAR(p.N), 8, '0'), NULL),
       '0000140000', '0000800000', NULL, LPAD(TO_VARCHAR(p.ORDER_ID), 10, '0'),
       36000 + MOD(ABS(HASH(p.ORDER_ID, 'cpu')), 30000)
FROM pay p
JOIN T001 t ON t.BUKRS = p.BUKRS
JOIN TCURR fx ON fx.FCURR = 'USD' AND fx.TCURR = t.WAERS
UNION ALL
SELECT 'AR_PAY', p.BUKRS, '14' || LPAD(TO_VARCHAR(p.N), 8, '0'), 'DZ', p.PAY_DATE, 'FI_CASH', 'F-28',
       'BANKSTMT' || TO_VARCHAR(p.PAY_DATE, 'YYMMDD'), 'Incoming payment', 'USD', fx.UKURS, p.ORDER_TOTAL,
       LPAD(TO_VARCHAR(p.CUSTOMER_ID), 10, '0'), NULL, NULL,
       p.PAY_DATE, '14' || LPAD(TO_VARCHAR(p.N), 8, '0'),
       '0000113100', '0000140000', NULL, LPAD(TO_VARCHAR(p.ORDER_ID), 10, '0'),
       30000 + MOD(ABS(HASH(p.ORDER_ID, 'cpu2')), 20000)
FROM pay p
JOIN T001 t ON t.BUKRS = p.BUKRS
JOIN TCURR fx ON fx.FCURR = 'USD' AND fx.TCURR = t.WAERS
WHERE p.PAY_DATE <= $EXTRACT_DATE::DATE;

-- 6b. Vendor invoices + payments (received POs only)
INSERT INTO TMP_DOCS
WITH inv AS (
    SELECT t.*, ROW_NUMBER() OVER (ORDER BY t.PO_ID) AS N,
           ROUND(t.QUANTITY * t.UNIT_COST, 2) AS AMT,
           MOD(ABS(HASH(t.PO_ID, 'vp')), 100) AS RP,
           MOD(ABS(HASH(t.PO_ID, 'vd')), 30)  AS RD
    FROM TMP_PO t
    WHERE t.RECEIVED_DATE IS NOT NULL
),
pay AS (
    SELECT inv.*,
           DATEADD(DAY, 45 + CASE WHEN RP < 20 THEN -10 + MOD(RD, 10)
                                  WHEN RP < 85 THEN MOD(RD, 7)
                                  ELSE 15 + RD END,
                   RECEIVED_DATE) AS PAY_DATE
    FROM inv
)
SELECT 'AP_INV', p.BUKRS, '51' || LPAD(TO_VARCHAR(p.N), 8, '0'), 'RE', p.RECEIVED_DATE, 'AP_CLERK', 'MIRO',
       'VINV-' || TO_VARCHAR(p.PO_ID), 'Vendor invoice', 'USD', fx.UKURS, p.AMT,
       LPAD(TO_VARCHAR(100000 + p.SUPPLIER_ID), 10, '0'), 'NT45', 45,
       IFF(p.PAY_DATE <= $EXTRACT_DATE::DATE, p.PAY_DATE, NULL),
       IFF(p.PAY_DATE <= $EXTRACT_DATE::DATE, '15' || LPAD(TO_VARCHAR(p.N), 8, '0'), NULL),
       '0000300000', '0000160000', TO_VARCHAR(4500000000 + (p.PO_ID - 4500000)), NULL,
       34000 + MOD(ABS(HASH(p.PO_ID, 'cpu')), 28000)
FROM pay p
JOIN T001 t ON t.BUKRS = p.BUKRS
JOIN TCURR fx ON fx.FCURR = 'USD' AND fx.TCURR = t.WAERS
UNION ALL
SELECT 'AP_PAY', p.BUKRS, '15' || LPAD(TO_VARCHAR(p.N), 8, '0'), 'KZ', p.PAY_DATE, 'FI_PAYRUN', 'F110',
       'PAYRUN' || TO_VARCHAR(p.PAY_DATE, 'YYMMDD'), 'Outgoing payment', 'USD', fx.UKURS, p.AMT,
       LPAD(TO_VARCHAR(100000 + p.SUPPLIER_ID), 10, '0'), NULL, NULL,
       p.PAY_DATE, '15' || LPAD(TO_VARCHAR(p.N), 8, '0'),
       '0000160000', '0000113100', TO_VARCHAR(4500000000 + (p.PO_ID - 4500000)), NULL,
       79200
FROM pay p
JOIN T001 t ON t.BUKRS = p.BUKRS
JOIN TCURR fx ON fx.FCURR = 'USD' AND fx.TCURR = t.WAERS
WHERE p.PAY_DATE <= $EXTRACT_DATE::DATE;

-- 6c. Opening capital (one per company code) + monthly payroll and office costs
INSERT INTO TMP_DOCS
WITH cc AS (
    SELECT t.BUKRS, fx.UKURS AS FX,
           DECODE(t.BUKRS, 'IN01', 9000000, 'US01', 12000000, 'UK01', 4000000, 3500000) AS CAPITAL_USD,
           DECODE(t.BUKRS, 'IN01', 380000, 'US01', 520000, 'UK01', 160000, 140000)      AS PAYROLL_USD
    FROM T001 t JOIN TCURR fx ON fx.FCURR = 'USD' AND fx.TCURR = t.WAERS
),
months AS (
    SELECT LAST_DAY(DATEADD(MONTH, SEQ4(), $SCOPE_FROM::DATE)) AS ME
    FROM TABLE(GENERATOR(ROWCOUNT => 15))
),
gl AS (
    SELECT 'OPEN' AS KIND, cc.BUKRS, cc.FX, DATEADD(DAY, -1, $SCOPE_FROM::DATE) AS BUDAT, cc.CAPITAL_USD AS USD_AMT,
           '0000113100' AS DR, '0000070000' AS CR, 'Opening capital' AS TXT, 0 AS K
    FROM cc
    UNION ALL
    SELECT 'PAYROLL', cc.BUKRS, cc.FX, m.ME, cc.PAYROLL_USD * (0.97 + MOD(ABS(HASH(cc.BUKRS, m.ME)), 7) / 100),
           '0000440000', '0000113100', 'Payroll ' || TO_VARCHAR(m.ME, 'MON YYYY'), 1
    FROM cc CROSS JOIN months m WHERE m.ME <= $EXTRACT_DATE::DATE
    UNION ALL
    SELECT 'OFFICE', cc.BUKRS, cc.FX, DATEADD(DAY, -3, m.ME), cc.PAYROLL_USD * 0.12,
           '0000476000', '0000113100', 'Office costs ' || TO_VARCHAR(m.ME, 'MON YYYY'), 2
    FROM cc CROSS JOIN months m WHERE m.ME <= $EXTRACT_DATE::DATE
)
SELECT 'GL_' || KIND, BUKRS, '10' || LPAD(TO_VARCHAR(ROW_NUMBER() OVER (ORDER BY BUDAT, BUKRS, K)), 8, '0'),
       'SA', BUDAT, 'GL_ACCOUNTANT', 'FB50', NULL, TXT, 'USD', FX, ROUND(USD_AMT, 2),
       NULL, NULL, NULL, NULL, NULL, DR, CR, NULL, NULL, 54000
FROM gl;

-- 6d. BKPF
CREATE OR REPLACE TABLE BKPF (
    MANDT VARCHAR(3), BUKRS VARCHAR(4), BELNR VARCHAR(10), GJAHR VARCHAR(4), BLART VARCHAR(2),
    BLDAT VARCHAR(8), BUDAT VARCHAR(8), MONAT VARCHAR(2), CPUDT VARCHAR(8), CPUTM VARCHAR(6),
    USNAM VARCHAR(12), TCODE VARCHAR(20), XBLNR VARCHAR(16), BKTXT VARCHAR(25),
    WAERS VARCHAR(5), HWAER VARCHAR(5), KURSF NUMBER(9,5), STBLG VARCHAR(10)
) COMMENT = 'SAP BKPF - accounting document header';

INSERT INTO BKPF
SELECT $SAP_MANDT, d.BUKRS, d.BELNR, TO_VARCHAR(YEAR(d.BUDAT)), d.BLART,
       TO_VARCHAR(d.BUDAT, 'YYYYMMDD'), TO_VARCHAR(d.BUDAT, 'YYYYMMDD'), LPAD(TO_VARCHAR(MONTH(d.BUDAT)), 2, '0'),
       TO_VARCHAR(d.BUDAT, 'YYYYMMDD'),
       LPAD(TO_VARCHAR(FLOOR(d.ENTRY_SECS / 3600)), 2, '0') || LPAD(TO_VARCHAR(FLOOR(MOD(d.ENTRY_SECS, 3600) / 60)), 2, '0')
         || LPAD(TO_VARCHAR(MOD(d.ENTRY_SECS, 60)), 2, '0'),
       d.USNAM, d.TCODE, d.XBLNR, d.BKTXT, d.WAERS, t.WAERS, d.FX, ''
FROM TMP_DOCS d
JOIN T001 t ON t.BUKRS = d.BUKRS;

-- 6e. BSEG: two lines per document
CREATE OR REPLACE TABLE BSEG (
    MANDT VARCHAR(3), BUKRS VARCHAR(4), BELNR VARCHAR(10), GJAHR VARCHAR(4), BUZEI VARCHAR(3),
    BSCHL VARCHAR(2), KOART VARCHAR(1), SHKZG VARCHAR(1), DMBTR NUMBER(15,2), WRBTR NUMBER(15,2),
    HKONT VARCHAR(10), KUNNR VARCHAR(10), LIFNR VARCHAR(10), KOSTL VARCHAR(10),
    ZFBDT VARCHAR(8), ZTERM VARCHAR(4), ZBD1T NUMBER(3), AUGDT VARCHAR(8), AUGBL VARCHAR(10),
    EBELN VARCHAR(10), EBELP VARCHAR(5), VBEL2 VARCHAR(10), SGTXT VARCHAR(50)
) COMMENT = 'SAP BSEG - accounting document line items';

INSERT INTO BSEG
SELECT $SAP_MANDT, d.BUKRS, d.BELNR, TO_VARCHAR(YEAR(d.BUDAT)), l.BUZEI,
       -- posting key
       CASE d.DOC_FAMILY
           WHEN 'AR_INV' THEN IFF(l.BUZEI = '001', '01', '50')
           WHEN 'AR_PAY' THEN IFF(l.BUZEI = '001', '40', '15')
           WHEN 'AP_INV' THEN IFF(l.BUZEI = '001', '40', '31')
           WHEN 'AP_PAY' THEN IFF(l.BUZEI = '001', '25', '50')
           ELSE               IFF(l.BUZEI = '001', '40', '50') END,
       -- account type: D customer, K vendor, S G/L
       CASE WHEN d.DOC_FAMILY = 'AR_INV' AND l.BUZEI = '001' THEN 'D'
            WHEN d.DOC_FAMILY = 'AR_PAY' AND l.BUZEI = '002' THEN 'D'
            WHEN d.DOC_FAMILY = 'AP_INV' AND l.BUZEI = '002' THEN 'K'
            WHEN d.DOC_FAMILY = 'AP_PAY' AND l.BUZEI = '001' THEN 'K'
            ELSE 'S' END,
       IFF(l.BUZEI = '001', 'S', 'H'),
       ROUND(d.WRBTR * d.FX, 2),
       d.WRBTR,
       IFF(l.BUZEI = '001', d.DEBIT_ACCT, d.CREDIT_ACCT),
       IFF(d.DOC_FAMILY IN ('AR_INV', 'AR_PAY')
           AND ((d.DOC_FAMILY = 'AR_INV' AND l.BUZEI = '001') OR (d.DOC_FAMILY = 'AR_PAY' AND l.BUZEI = '002')),
           d.PARTNER, NULL),
       IFF(d.DOC_FAMILY IN ('AP_INV', 'AP_PAY')
           AND ((d.DOC_FAMILY = 'AP_INV' AND l.BUZEI = '002') OR (d.DOC_FAMILY = 'AP_PAY' AND l.BUZEI = '001')),
           d.PARTNER, NULL),
       IFF(IFF(l.BUZEI = '001', d.DEBIT_ACCT, d.CREDIT_ACCT) IN ('0000440000', '0000476000', '0000800000'),
           d.BUKRS || '-' || DECODE(IFF(l.BUZEI = '001', d.DEBIT_ACCT, d.CREDIT_ACCT),
                                    '0000800000', 'SALES', '0000440000', 'ADMIN', 'OFFC'), NULL),
       -- baseline date / terms only on open-item (partner) lines
       IFF(d.ZTERM IS NOT NULL AND ((d.DOC_FAMILY = 'AR_INV' AND l.BUZEI = '001') OR (d.DOC_FAMILY = 'AP_INV' AND l.BUZEI = '002')),
           TO_VARCHAR(d.BUDAT, 'YYYYMMDD'), '00000000'),
       IFF((d.DOC_FAMILY = 'AR_INV' AND l.BUZEI = '001') OR (d.DOC_FAMILY = 'AP_INV' AND l.BUZEI = '002'), d.ZTERM, ''),
       IFF((d.DOC_FAMILY = 'AR_INV' AND l.BUZEI = '001') OR (d.DOC_FAMILY = 'AP_INV' AND l.BUZEI = '002'), d.ZBD1T, 0),
       -- clearing: invoice partner line + payment partner line
       CASE WHEN ((d.DOC_FAMILY = 'AR_INV' AND l.BUZEI = '001') OR (d.DOC_FAMILY = 'AP_INV' AND l.BUZEI = '002')
                  OR (d.DOC_FAMILY = 'AR_PAY' AND l.BUZEI = '002') OR (d.DOC_FAMILY = 'AP_PAY' AND l.BUZEI = '001'))
                 AND d.CLEAR_DATE IS NOT NULL
            THEN TO_VARCHAR(d.CLEAR_DATE, 'YYYYMMDD') ELSE '00000000' END,
       CASE WHEN ((d.DOC_FAMILY = 'AR_INV' AND l.BUZEI = '001') OR (d.DOC_FAMILY = 'AP_INV' AND l.BUZEI = '002')
                  OR (d.DOC_FAMILY = 'AR_PAY' AND l.BUZEI = '002') OR (d.DOC_FAMILY = 'AP_PAY' AND l.BUZEI = '001'))
                 AND d.CLEAR_DOC IS NOT NULL
            THEN d.CLEAR_DOC ELSE '' END,
       COALESCE(d.EBELN, ''), IFF(d.EBELN IS NOT NULL, '00010', ''),
       COALESCE(d.VBELN, ''),
       LEFT(d.BKTXT || COALESCE(' ' || d.XBLNR, ''), 50)
FROM TMP_DOCS d
CROSS JOIN (SELECT '001' AS BUZEI UNION ALL SELECT '002') l;

------------------------------------------------------------------------------
-- 7. Row counts
------------------------------------------------------------------------------
SELECT 'KNA1' AS SAP_TABLE, COUNT(*) AS ROWS_ FROM KNA1
UNION ALL SELECT 'LFA1', COUNT(*) FROM LFA1
UNION ALL SELECT 'SKA1', COUNT(*) FROM SKA1
UNION ALL SELECT 'VBAK', COUNT(*) FROM VBAK
UNION ALL SELECT 'VBAP', COUNT(*) FROM VBAP
UNION ALL SELECT 'EKKO', COUNT(*) FROM EKKO
UNION ALL SELECT 'EKPO', COUNT(*) FROM EKPO
UNION ALL SELECT 'BKPF', COUNT(*) FROM BKPF
UNION ALL SELECT 'BSEG', COUNT(*) FROM BSEG;

-- Every document must balance (expect 0 rows)
SELECT BUKRS, BELNR, GJAHR, SUM(IFF(SHKZG = 'S', DMBTR, -DMBTR)) AS BALANCE
FROM BSEG GROUP BY 1, 2, 3 HAVING BALANCE <> 0;
