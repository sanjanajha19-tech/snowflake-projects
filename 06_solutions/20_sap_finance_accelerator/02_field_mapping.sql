/*=============================================================================
  ACCELERATOR 20 - SAP Finance Accelerator
  File 02 : SAP -> canonical field mapping (documentation as data)
            Every column used by the canonical views in file 03 is listed with
            its SAP meaning and the transformation applied. Query it, publish
            it in a data catalog, or generate documentation from it.
  Creates : SAP_FIELD_MAPPING, SAP_DOCUMENT_TYPES, SAP_POSTING_KEYS
  Run as  : ACCEL_ADMIN
  Rerun   : safe.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SAPFIN;
USE SCHEMA SAPFIN;

CREATE OR REPLACE TABLE SAP_FIELD_MAPPING (
    SAP_TABLE         VARCHAR,
    SAP_FIELD         VARCHAR,
    SAP_DESCRIPTION   VARCHAR,
    CANONICAL_ENTITY  VARCHAR,
    CANONICAL_FIELD   VARCHAR,
    TRANSFORMATION    VARCHAR
) COMMENT = 'SAP to canonical finance model: field-level lineage and translation';

INSERT INTO SAP_FIELD_MAPPING
SELECT $1, $2, $3, $4, $5, $6 FROM (VALUES
  -- General
  ('*',    'MANDT',  'Client',                               '(all)',              '-',                    'Filtered to the configured client; not exposed'),
  -- Company codes
  ('T001', 'BUKRS',  'Company code',                         'FIN_COMPANY',        'COMPANY_CODE',         'As is'),
  ('T001', 'BUTXT',  'Company name',                         'FIN_COMPANY',        'COMPANY_NAME',         'As is'),
  ('T001', 'LAND1',  'Country key',                          'FIN_COMPANY',        'COUNTRY_CODE',         'As is (ISO 3166-1 alpha-2)'),
  ('T001', 'WAERS',  'Local (company code) currency',        'FIN_COMPANY',        'LOCAL_CURRENCY',       'As is (ISO 4217)'),
  -- G/L accounts
  ('SKA1', 'SAKNR',  'G/L account number',                   'FIN_GL_ACCOUNT',     'GL_ACCOUNT',           'LTRIM leading zeros'),
  ('SKA1', 'XBILK',  'Balance sheet account indicator',      'FIN_GL_ACCOUNT',     'ACCOUNT_CLASS',        '''X'' -> Balance Sheet, else Profit & Loss'),
  ('SKA1', 'KTOKS',  'G/L account group',                    'FIN_GL_ACCOUNT',     'ACCOUNT_GROUP',        'As is'),
  ('SKAT', 'TXT50',  'G/L account long text',                'FIN_GL_ACCOUNT',     'ACCOUNT_NAME',         'Language SPRAS = E'),
  -- Customers
  ('KNA1', 'KUNNR',  'Customer number',                      'FIN_CUSTOMER',       'CUSTOMER_ID',          'LTRIM leading zeros'),
  ('KNA1', 'NAME1',  'Name 1',                               'FIN_CUSTOMER',       'CUSTOMER_NAME',        'TRIM'),
  ('KNA1', 'LAND1',  'Country key',                          'FIN_CUSTOMER',       'COUNTRY_CODE',         'As is'),
  ('KNA1', 'ORT01',  'City',                                 'FIN_CUSTOMER',       'CITY',                 'INITCAP'),
  ('KNA1', 'KTOKD',  'Customer account group',               'FIN_CUSTOMER',       'CUSTOMER_TYPE',        'CPD -> One-time / consumer, else Business'),
  ('KNA1', 'BRSCH',  'Industry key',                         'FIN_CUSTOMER',       'INDUSTRY_CODE',        'As is'),
  ('KNA1', 'STCD1',  'Tax number 1 (PAN in India)',          'FIN_CUSTOMER',       'TAX_ID',               'NULLIF empty'),
  ('KNA1', 'ERDAT',  'Created on (YYYYMMDD)',                'FIN_CUSTOMER',       'CREATED_DATE',         'TRY_TO_DATE(x, ''YYYYMMDD''), 00000000 -> NULL'),
  ('KNA1', 'LOEVM',  'Central deletion flag',                'FIN_CUSTOMER',       'IS_DELETED',           '''X'' -> TRUE'),
  -- Vendors
  ('LFA1', 'LIFNR',  'Vendor number',                        'FIN_VENDOR',         'VENDOR_ID',            'LTRIM leading zeros'),
  ('LFA1', 'NAME1',  'Name 1',                               'FIN_VENDOR',         'VENDOR_NAME',          'TRIM'),
  ('LFA1', 'LAND1',  'Country key',                          'FIN_VENDOR',         'COUNTRY_CODE',         'As is'),
  ('LFA1', 'STCD3',  'Tax number 3 (GSTIN in India)',        'FIN_VENDOR',         'TAX_ID',               'NULLIF empty'),
  ('LFA1', 'SPERR',  'Central posting block',                'FIN_VENDOR',         'IS_POSTING_BLOCKED',   '''X'' -> TRUE'),
  -- Sales
  ('VBAK', 'VBELN',  'Sales document',                       'FIN_SALES_ORDER',    'SALES_ORDER_ID',       'LTRIM leading zeros'),
  ('VBAK', 'ERDAT',  'Created on',                           'FIN_SALES_ORDER',    'ORDER_DATE',           'TRY_TO_DATE(x, ''YYYYMMDD'')'),
  ('VBAK', 'AUART',  'Sales document type',                  'FIN_SALES_ORDER',    'ORDER_TYPE',           'OR -> Standard order, RE -> Returns'),
  ('VBAK', 'VTWEG',  'Distribution channel',                 'FIN_SALES_ORDER',    'CHANNEL',              '10 Direct, 20 Distributor, 30 E-commerce, 40 Retail'),
  ('VBAK', 'KUNNR',  'Sold-to party',                        'FIN_SALES_ORDER',    'CUSTOMER_ID',          'LTRIM leading zeros'),
  ('VBAK', 'NETWR',  'Net value in document currency',       'FIN_SALES_ORDER',    'NET_VALUE',            'As is'),
  ('VBAK', 'WAERK',  'Document currency',                    'FIN_SALES_ORDER',    'CURRENCY',             'As is'),
  ('VBAK', 'BUKRS_VF','Company code to be billed',           'FIN_SALES_ORDER',    'COMPANY_CODE',         'As is'),
  ('VBAK', 'GBSTK',  'Overall processing status',            'FIN_SALES_ORDER',    'PROCESSING_STATUS',    'A Open, B In process, C Completed'),
  ('VBAP', 'POSNR',  'Sales document item',                  'FIN_SALES_ORDER_LINE','LINE_NUMBER',         'TO_NUMBER'),
  ('VBAP', 'MATNR',  'Material number',                      'FIN_SALES_ORDER_LINE','PRODUCT_SKU',         'TRIM'),
  ('VBAP', 'KWMENG', 'Order quantity (sales unit)',          'FIN_SALES_ORDER_LINE','QUANTITY',            'As is'),
  ('VBAP', 'NETWR',  'Net value of item',                    'FIN_SALES_ORDER_LINE','NET_VALUE',           'As is'),
  ('VBAP', 'WERKS',  'Plant',                                'FIN_SALES_ORDER_LINE','PLANT',               'As is'),
  ('VBAP', 'ABGRU',  'Reason for rejection',                 'FIN_SALES_ORDER_LINE','IS_REJECTED',         'non-empty -> TRUE'),
  -- Purchasing
  ('EKKO', 'EBELN',  'Purchasing document',                  'FIN_PURCHASE_ORDER', 'PURCHASE_ORDER_ID',    'As is'),
  ('EKKO', 'BEDAT',  'Purchasing document date',             'FIN_PURCHASE_ORDER', 'PO_DATE',              'TRY_TO_DATE(x, ''YYYYMMDD'')'),
  ('EKKO', 'LIFNR',  'Vendor',                               'FIN_PURCHASE_ORDER', 'VENDOR_ID',            'LTRIM leading zeros'),
  ('EKKO', 'BSART',  'Purchasing document type',             'FIN_PURCHASE_ORDER', 'PO_TYPE',              'NB -> Standard PO'),
  ('EKKO', 'ZTERM',  'Terms of payment key',                 'FIN_PURCHASE_ORDER', 'PAYMENT_TERMS',        'As is'),
  ('EKPO', 'EBELP',  'Item number of purchasing document',   'FIN_PURCHASE_ORDER', 'LINE_NUMBER',          'TO_NUMBER'),
  ('EKPO', 'MENGE',  'Purchase order quantity',              'FIN_PURCHASE_ORDER', 'QUANTITY',             'As is'),
  ('EKPO', 'NETPR',  'Net price',                            'FIN_PURCHASE_ORDER', 'UNIT_PRICE',           'NETPR / PEINH'),
  ('EKPO', 'NETWR',  'Net order value',                      'FIN_PURCHASE_ORDER', 'NET_VALUE',            'As is'),
  ('EKPO', 'ELIKZ',  'Delivery completed indicator',         'FIN_PURCHASE_ORDER', 'IS_DELIVERED',         '''X'' -> TRUE'),
  ('EKPO', 'LOEKZ',  'Deletion indicator',                   'FIN_PURCHASE_ORDER', 'IS_CANCELLED',         '''L'' -> TRUE'),
  ('EKPO', 'EINDT',  'Item delivery date (EKET in SAP)',     'FIN_PURCHASE_ORDER', 'PROMISED_DATE',        'TRY_TO_DATE(x, ''YYYYMMDD'')'),
  -- Accounting documents
  ('BKPF', 'BUKRS',  'Company code',                         'FIN_GL_ENTRY',       'COMPANY_CODE',         'As is'),
  ('BKPF', 'BELNR',  'Accounting document number',           'FIN_GL_ENTRY',       'DOCUMENT_NUMBER',      'As is'),
  ('BKPF', 'GJAHR',  'Fiscal year',                          'FIN_GL_ENTRY',       'FISCAL_YEAR',          'TO_NUMBER'),
  ('BKPF', 'BLART',  'Document type',                        'FIN_GL_ENTRY',       'DOCUMENT_TYPE',        'Joined to SAP_DOCUMENT_TYPES for description'),
  ('BKPF', 'BUDAT',  'Posting date',                         'FIN_GL_ENTRY',       'POSTING_DATE',         'TRY_TO_DATE(x, ''YYYYMMDD'')'),
  ('BKPF', 'BLDAT',  'Document date',                        'FIN_GL_ENTRY',       'DOCUMENT_DATE',        'TRY_TO_DATE(x, ''YYYYMMDD'')'),
  ('BKPF', 'MONAT',  'Fiscal period',                        'FIN_GL_ENTRY',       'FISCAL_PERIOD',        'TO_NUMBER'),
  ('BKPF', 'CPUDT',  'Entry date',                           'FIN_GL_ENTRY',       'ENTERED_AT',           'CPUDT || CPUTM -> TIMESTAMP_NTZ'),
  ('BKPF', 'CPUTM',  'Entry time (HHMMSS)',                  'FIN_GL_ENTRY',       'ENTERED_AT',           'CPUDT || CPUTM -> TIMESTAMP_NTZ'),
  ('BKPF', 'USNAM',  'User name',                            'FIN_GL_ENTRY',       'ENTERED_BY',           'As is'),
  ('BKPF', 'TCODE',  'Transaction code',                     'FIN_GL_ENTRY',       'TRANSACTION_CODE',     'As is'),
  ('BKPF', 'XBLNR',  'Reference document number',           'FIN_GL_ENTRY',       'REFERENCE',            'NULLIF empty'),
  ('BKPF', 'BKTXT',  'Document header text',                 'FIN_GL_ENTRY',       'HEADER_TEXT',          'As is'),
  ('BKPF', 'WAERS',  'Document currency',                    'FIN_GL_ENTRY',       'DOCUMENT_CURRENCY',    'As is'),
  ('BKPF', 'HWAER',  'Local currency',                       'FIN_GL_ENTRY',       'LOCAL_CURRENCY',       'As is'),
  ('BSEG', 'BUZEI',  'Line item number',                     'FIN_GL_ENTRY',       'LINE_NUMBER',          'TO_NUMBER'),
  ('BSEG', 'BSCHL',  'Posting key',                          'FIN_GL_ENTRY',       'POSTING_KEY',          'Joined to SAP_POSTING_KEYS for description'),
  ('BSEG', 'KOART',  'Account type',                         'FIN_GL_ENTRY',       'ACCOUNT_TYPE',         'D Customer, K Vendor, S G/L, A Asset, M Material'),
  ('BSEG', 'SHKZG',  'Debit/credit indicator',               'FIN_GL_ENTRY',       'DEBIT_CREDIT',         'S -> Debit, H -> Credit; drives the sign of amounts'),
  ('BSEG', 'DMBTR',  'Amount in local currency (unsigned)',  'FIN_GL_ENTRY',       'AMOUNT_LOCAL',         'IFF(SHKZG = ''S'', DMBTR, -DMBTR)'),
  ('BSEG', 'WRBTR',  'Amount in document currency (unsigned)','FIN_GL_ENTRY',      'AMOUNT_DOCUMENT',      'IFF(SHKZG = ''S'', WRBTR, -WRBTR)'),
  ('BSEG', 'HKONT',  'General ledger account',               'FIN_GL_ENTRY',       'GL_ACCOUNT',           'LTRIM leading zeros'),
  ('BSEG', 'KUNNR',  'Customer number',                      'FIN_GL_ENTRY',       'CUSTOMER_ID',          'LTRIM leading zeros, NULLIF empty'),
  ('BSEG', 'LIFNR',  'Vendor number',                        'FIN_GL_ENTRY',       'VENDOR_ID',            'LTRIM leading zeros, NULLIF empty'),
  ('BSEG', 'KOSTL',  'Cost center',                          'FIN_GL_ENTRY',       'COST_CENTER',          'NULLIF empty'),
  ('BSEG', 'ZFBDT',  'Baseline date for due date calc.',     'FIN_GL_ENTRY',       'BASELINE_DATE',        'TRY_TO_DATE; 00000000 -> NULL'),
  ('BSEG', 'ZTERM',  'Terms of payment key',                 'FIN_GL_ENTRY',       'PAYMENT_TERMS',        'NULLIF empty'),
  ('BSEG', 'ZBD1T',  'Cash discount days 1 / net days',      'FIN_GL_ENTRY',       'DUE_DATE',             'BASELINE_DATE + ZBD1T days'),
  ('BSEG', 'AUGDT',  'Clearing date',                        'FIN_GL_ENTRY',       'CLEARING_DATE',        'TRY_TO_DATE; 00000000 -> NULL (open item)'),
  ('BSEG', 'AUGBL',  'Clearing document',                    'FIN_GL_ENTRY',       'CLEARING_DOCUMENT',    'NULLIF empty'),
  ('BSEG', 'EBELN',  'Purchasing document',                  'FIN_GL_ENTRY',       'PURCHASE_ORDER_ID',    'NULLIF empty'),
  ('BSEG', 'VBEL2',  'Sales document',                       'FIN_GL_ENTRY',       'SALES_ORDER_ID',       'LTRIM leading zeros, NULLIF empty'),
  ('BSEG', 'SGTXT',  'Item text',                            'FIN_GL_ENTRY',       'LINE_TEXT',            'As is')
);

------------------------------------------------------------------------------
-- Code tables used for translations
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE SAP_DOCUMENT_TYPES (BLART VARCHAR(2), DESCRIPTION VARCHAR, PROCESS VARCHAR);
INSERT INTO SAP_DOCUMENT_TYPES
SELECT $1, $2, $3 FROM (VALUES
  ('RV', 'Billing document transfer', 'Order to Cash'),
  ('DR', 'Customer invoice',          'Order to Cash'),
  ('DZ', 'Customer payment',          'Order to Cash'),
  ('RE', 'Invoice - gross (MM)',      'Procure to Pay'),
  ('KR', 'Vendor invoice',            'Procure to Pay'),
  ('KZ', 'Vendor payment',            'Procure to Pay'),
  ('SA', 'G/L account document',      'Record to Report'),
  ('AB', 'Accounting document',       'Record to Report'));

CREATE OR REPLACE TABLE SAP_POSTING_KEYS (BSCHL VARCHAR(2), DESCRIPTION VARCHAR, KOART VARCHAR(1), SHKZG VARCHAR(1));
INSERT INTO SAP_POSTING_KEYS
SELECT $1, $2, $3, $4 FROM (VALUES
  ('01', 'Invoice (customer debit)',        'D', 'S'),
  ('11', 'Credit memo (customer credit)',   'D', 'H'),
  ('15', 'Incoming payment (customer)',     'D', 'H'),
  ('25', 'Outgoing payment (vendor debit)', 'K', 'S'),
  ('31', 'Invoice (vendor credit)',         'K', 'H'),
  ('21', 'Credit memo (vendor debit)',      'K', 'S'),
  ('40', 'G/L debit',                       'S', 'S'),
  ('50', 'G/L credit',                      'S', 'H'));

SELECT CANONICAL_ENTITY, COUNT(*) AS MAPPED_FIELDS
FROM SAP_FIELD_MAPPING GROUP BY 1 ORDER BY 1;
