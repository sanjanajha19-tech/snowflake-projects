/*=============================================================================
  ACCELERATOR 20 - SAP Finance Accelerator
  File 03 : Canonical finance model (views over the SAP raw layer)
            Business-friendly names, typed dates, signed amounts, no leading zeros.
            Field translations are documented in SAP_FIELD_MAPPING (file 02).
  Creates : SAPFIN_PARAMS, FIN_COMPANY, FIN_GL_ACCOUNT, FIN_CUSTOMER, FIN_VENDOR,
            FIN_SALES_ORDER, FIN_SALES_ORDER_LINE, FIN_PURCHASE_ORDER,
            FIN_GL_ENTRY
  Run as  : ACCEL_ADMIN
  Rerun   : safe.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SAPFIN;
USE SCHEMA SAPFIN;

------------------------------------------------------------------------------
-- Parameters used by views and reports
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE SAPFIN_PARAMS (
    MANDT       VARCHAR(3),
    KEY_DATE    DATE,          -- as-of date for open items, ageing, DSO / DPO
    SPRAS       VARCHAR(1)     -- language for texts
);
INSERT INTO SAPFIN_PARAMS VALUES ('100', '2026-09-30', 'E');   -- EDIT ME: client, key date (e.g. CURRENT_DATE()), language

------------------------------------------------------------------------------
-- Master data
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW FIN_COMPANY AS
SELECT t.BUKRS AS COMPANY_CODE, t.BUTXT AS COMPANY_NAME, t.ORT01 AS CITY, t.LAND1 AS COUNTRY_CODE,
       t.WAERS AS LOCAL_CURRENCY, t.KTOPL AS CHART_OF_ACCOUNTS
FROM ACCEL_DB.SAPFIN.T001 t
JOIN ACCEL_DB.SAPFIN.SAPFIN_PARAMS p ON p.MANDT = t.MANDT;

CREATE OR REPLACE VIEW FIN_GL_ACCOUNT AS
SELECT LTRIM(a.SAKNR, '0')                                   AS GL_ACCOUNT,
       a.SAKNR                                               AS GL_ACCOUNT_SAP,
       t.TXT20                                               AS ACCOUNT_SHORT_NAME,
       t.TXT50                                               AS ACCOUNT_NAME,
       IFF(a.XBILK = 'X', 'Balance Sheet', 'Profit & Loss')   AS ACCOUNT_CLASS,
       a.KTOKS                                               AS ACCOUNT_GROUP,
       a.KTOPL                                               AS CHART_OF_ACCOUNTS
FROM ACCEL_DB.SAPFIN.SKA1 a
JOIN ACCEL_DB.SAPFIN.SAPFIN_PARAMS p ON p.MANDT = a.MANDT
LEFT JOIN ACCEL_DB.SAPFIN.SKAT t
       ON t.MANDT = a.MANDT AND t.KTOPL = a.KTOPL AND t.SAKNR = a.SAKNR AND t.SPRAS = p.SPRAS;

CREATE OR REPLACE VIEW FIN_CUSTOMER AS
SELECT LTRIM(k.KUNNR, '0')                                       AS CUSTOMER_ID,
       TRIM(k.NAME1)                                             AS CUSTOMER_NAME,
       k.LAND1                                                   AS COUNTRY_CODE,
       INITCAP(k.ORT01)                                          AS CITY,
       IFF(k.KTOKD = 'CPD', 'One-time / Consumer', 'Business')   AS CUSTOMER_TYPE,
       k.BRSCH                                                   AS INDUSTRY_CODE,
       NULLIF(TRIM(k.STCD1), '')                                 AS TAX_ID,
       TRY_TO_DATE(NULLIF(k.ERDAT, '00000000'), 'YYYYMMDD')      AS CREATED_DATE,
       (k.LOEVM = 'X')                                           AS IS_DELETED
FROM ACCEL_DB.SAPFIN.KNA1 k
JOIN ACCEL_DB.SAPFIN.SAPFIN_PARAMS p ON p.MANDT = k.MANDT;

CREATE OR REPLACE VIEW FIN_VENDOR AS
SELECT LTRIM(v.LIFNR, '0')                                       AS VENDOR_ID,
       TRIM(v.NAME1)                                             AS VENDOR_NAME,
       v.LAND1                                                   AS COUNTRY_CODE,
       NULLIF(TRIM(v.STCD3), '')                                 AS TAX_ID,
       TRY_TO_DATE(NULLIF(v.ERDAT, '00000000'), 'YYYYMMDD')      AS CREATED_DATE,
       (v.SPERR = 'X')                                           AS IS_POSTING_BLOCKED,
       (v.LOEVM = 'X')                                           AS IS_DELETED
FROM ACCEL_DB.SAPFIN.LFA1 v
JOIN ACCEL_DB.SAPFIN.SAPFIN_PARAMS p ON p.MANDT = v.MANDT;

------------------------------------------------------------------------------
-- Sales and purchasing
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW FIN_SALES_ORDER AS
SELECT LTRIM(h.VBELN, '0')                                      AS SALES_ORDER_ID,
       TRY_TO_DATE(h.ERDAT, 'YYYYMMDD')                         AS ORDER_DATE,
       DECODE(h.AUART, 'OR', 'Standard order', 'RE', 'Returns', h.AUART) AS ORDER_TYPE,
       h.BUKRS_VF                                               AS COMPANY_CODE,
       h.VKORG                                                  AS SALES_ORG,
       DECODE(h.VTWEG, '10', 'Direct', '20', 'Distributor', '30', 'E-commerce', '40', 'Retail', h.VTWEG) AS CHANNEL,
       LTRIM(h.KUNNR, '0')                                      AS CUSTOMER_ID,
       h.NETWR                                                  AS NET_VALUE,
       h.WAERK                                                  AS CURRENCY,
       DECODE(h.GBSTK, 'A', 'Open', 'B', 'In process', 'C', 'Completed', h.GBSTK) AS PROCESSING_STATUS,
       TRY_TO_DATE(NULLIF(h.VDATU, '00000000'), 'YYYYMMDD')     AS REQUESTED_DELIVERY_DATE
FROM ACCEL_DB.SAPFIN.VBAK h
JOIN ACCEL_DB.SAPFIN.SAPFIN_PARAMS p ON p.MANDT = h.MANDT;

CREATE OR REPLACE VIEW FIN_SALES_ORDER_LINE AS
SELECT LTRIM(i.VBELN, '0')            AS SALES_ORDER_ID,
       TO_NUMBER(i.POSNR)             AS LINE_NUMBER,
       TRIM(i.MATNR)                  AS PRODUCT_SKU,
       i.ARKTX                        AS PRODUCT_DESCRIPTION,
       i.KWMENG                       AS QUANTITY,
       i.VRKME                        AS UNIT,
       i.NETPR                        AS NET_PRICE,
       i.NETWR                        AS NET_VALUE,
       i.WAERK                        AS CURRENCY,
       i.WERKS                        AS PLANT,
       (NULLIF(i.ABGRU, '') IS NOT NULL) AS IS_REJECTED
FROM ACCEL_DB.SAPFIN.VBAP i
JOIN ACCEL_DB.SAPFIN.SAPFIN_PARAMS p ON p.MANDT = i.MANDT;

CREATE OR REPLACE VIEW FIN_PURCHASE_ORDER AS
SELECT h.EBELN                                         AS PURCHASE_ORDER_ID,
       TO_NUMBER(i.EBELP)                              AS LINE_NUMBER,
       h.BUKRS                                         AS COMPANY_CODE,
       DECODE(h.BSART, 'NB', 'Standard PO', h.BSART)   AS PO_TYPE,
       LTRIM(h.LIFNR, '0')                             AS VENDOR_ID,
       TRY_TO_DATE(h.BEDAT, 'YYYYMMDD')                AS PO_DATE,
       h.ZTERM                                         AS PAYMENT_TERMS,
       TRIM(i.MATNR)                                   AS PRODUCT_SKU,
       i.TXZ01                                         AS DESCRIPTION,
       i.WERKS                                         AS PLANT,
       i.MENGE                                         AS QUANTITY,
       i.MEINS                                         AS UNIT,
       i.NETPR / NULLIF(i.PEINH, 0)                    AS UNIT_PRICE,
       i.NETWR                                         AS NET_VALUE,
       h.WAERS                                         AS CURRENCY,
       TRY_TO_DATE(NULLIF(i.EINDT, '00000000'), 'YYYYMMDD') AS PROMISED_DATE,
       (i.ELIKZ = 'X')                                 AS IS_DELIVERED,
       (i.LOEKZ = 'L' OR h.LOEKZ = 'L')                AS IS_CANCELLED
FROM ACCEL_DB.SAPFIN.EKKO h
JOIN ACCEL_DB.SAPFIN.EKPO i ON i.MANDT = h.MANDT AND i.EBELN = h.EBELN
JOIN ACCEL_DB.SAPFIN.SAPFIN_PARAMS p ON p.MANDT = h.MANDT;

------------------------------------------------------------------------------
-- General ledger entries (BKPF + BSEG)
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW FIN_GL_ENTRY AS
SELECT h.BUKRS                                                   AS COMPANY_CODE,
       TO_NUMBER(h.GJAHR)                                        AS FISCAL_YEAR,
       TO_NUMBER(h.MONAT)                                        AS FISCAL_PERIOD,
       h.BELNR                                                   AS DOCUMENT_NUMBER,
       TO_NUMBER(l.BUZEI)                                        AS LINE_NUMBER,
       h.BLART                                                   AS DOCUMENT_TYPE,
       dt.DESCRIPTION                                            AS DOCUMENT_TYPE_DESC,
       dt.PROCESS                                                AS BUSINESS_PROCESS,
       TRY_TO_DATE(h.BUDAT, 'YYYYMMDD')                          AS POSTING_DATE,
       TRY_TO_DATE(h.BLDAT, 'YYYYMMDD')                          AS DOCUMENT_DATE,
       TRY_TO_TIMESTAMP_NTZ(h.CPUDT || h.CPUTM, 'YYYYMMDDHH24MISS') AS ENTERED_AT,
       h.USNAM                                                   AS ENTERED_BY,
       h.TCODE                                                   AS TRANSACTION_CODE,
       NULLIF(h.XBLNR, '')                                       AS REFERENCE,
       h.BKTXT                                                   AS HEADER_TEXT,
       l.BSCHL                                                   AS POSTING_KEY,
       pk.DESCRIPTION                                            AS POSTING_KEY_DESC,
       DECODE(l.KOART, 'D', 'Customer', 'K', 'Vendor', 'S', 'G/L', 'A', 'Asset', 'M', 'Material', l.KOART) AS ACCOUNT_TYPE,
       IFF(l.SHKZG = 'S', 'Debit', 'Credit')                     AS DEBIT_CREDIT,
       LTRIM(l.HKONT, '0')                                       AS GL_ACCOUNT,
       ga.ACCOUNT_NAME                                           AS GL_ACCOUNT_NAME,
       ga.ACCOUNT_CLASS                                          AS ACCOUNT_CLASS,
       IFF(l.SHKZG = 'S', l.DMBTR, -l.DMBTR)                     AS AMOUNT_LOCAL,
       h.HWAER                                                   AS LOCAL_CURRENCY,
       IFF(l.SHKZG = 'S', l.WRBTR, -l.WRBTR)                     AS AMOUNT_DOCUMENT,
       h.WAERS                                                   AS DOCUMENT_CURRENCY,
       NULLIF(LTRIM(l.KUNNR, '0'), '')                           AS CUSTOMER_ID,
       NULLIF(LTRIM(l.LIFNR, '0'), '')                           AS VENDOR_ID,
       NULLIF(l.KOSTL, '')                                       AS COST_CENTER,
       TRY_TO_DATE(NULLIF(l.ZFBDT, '00000000'), 'YYYYMMDD')      AS BASELINE_DATE,
       NULLIF(l.ZTERM, '')                                       AS PAYMENT_TERMS,
       DATEADD(DAY, COALESCE(l.ZBD1T, 0), TRY_TO_DATE(NULLIF(l.ZFBDT, '00000000'), 'YYYYMMDD')) AS DUE_DATE,
       TRY_TO_DATE(NULLIF(l.AUGDT, '00000000'), 'YYYYMMDD')      AS CLEARING_DATE,
       NULLIF(l.AUGBL, '')                                       AS CLEARING_DOCUMENT,
       NULLIF(l.EBELN, '')                                       AS PURCHASE_ORDER_ID,
       NULLIF(LTRIM(l.VBEL2, '0'), '')                           AS SALES_ORDER_ID,
       l.SGTXT                                                   AS LINE_TEXT
FROM ACCEL_DB.SAPFIN.BKPF h
JOIN ACCEL_DB.SAPFIN.BSEG l
  ON l.MANDT = h.MANDT AND l.BUKRS = h.BUKRS AND l.BELNR = h.BELNR AND l.GJAHR = h.GJAHR
JOIN ACCEL_DB.SAPFIN.SAPFIN_PARAMS p ON p.MANDT = h.MANDT
LEFT JOIN ACCEL_DB.SAPFIN.SAP_DOCUMENT_TYPES dt ON dt.BLART = h.BLART
LEFT JOIN ACCEL_DB.SAPFIN.SAP_POSTING_KEYS   pk ON pk.BSCHL = l.BSCHL
LEFT JOIN ACCEL_DB.SAPFIN.FIN_GL_ACCOUNT     ga ON ga.GL_ACCOUNT_SAP = l.HKONT;

------------------------------------------------------------------------------
-- Checks
------------------------------------------------------------------------------
SELECT COMPANY_CODE, FISCAL_YEAR, COUNT(DISTINCT DOCUMENT_NUMBER) AS DOCUMENTS,
       SUM(AMOUNT_LOCAL) AS NET_MUST_BE_ZERO
FROM FIN_GL_ENTRY
GROUP BY 1, 2
ORDER BY 1, 2;

SELECT * FROM FIN_GL_ENTRY WHERE DOCUMENT_TYPE = 'RV' LIMIT 10;
