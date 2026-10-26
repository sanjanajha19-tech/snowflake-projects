/*=============================================================================
  ASSET 12 - Document Intelligence
  File 04   : DOC_EXCEPTIONS_V - documents that need human review
              * missing mandatory fields (invoice + contract)
              * invalid GSTIN format
              * line totals != subtotal, subtotal + tax != total
              * qty x unit price != line total
              * duplicate invoice numbers per vendor
              * contracts with uncapped / missing liability cap
  Run as    : ACCEL_ADMIN
  Rerun     : safe (CREATE OR REPLACE)
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS DOC_INTEL;
USE SCHEMA DOC_INTEL;

-- Rounding tolerance used below: 1.00 in invoice currency (EDIT ME in the two checks marked)

CREATE OR REPLACE VIEW DOC_EXCEPTIONS_V
  COMMENT = 'Invoices and contracts that fail completeness or arithmetic checks (ACCEL asset 12)'
AS
WITH line_sums AS (
    SELECT RELATIVE_PATH,
           COUNT(*)                         AS LINE_COUNT,
           SUM(LINE_TOTAL)                  AS SUM_LINE_TOTAL,
           COUNT_IF(QUANTITY IS NOT NULL AND UNIT_PRICE IS NOT NULL AND LINE_TOTAL IS NOT NULL
                    AND ABS(QUANTITY * UNIT_PRICE - LINE_TOTAL) > 1.00) AS BAD_LINE_MATH
    FROM INVOICE_LINES
    GROUP BY RELATIVE_PATH
),
inv AS (
    SELECT h.*, l.LINE_COUNT, l.SUM_LINE_TOTAL, l.BAD_LINE_MATH
    FROM INVOICE_HEADER h
    LEFT JOIN line_sums l ON l.RELATIVE_PATH = h.RELATIVE_PATH
),
invoice_checks AS (
    SELECT RELATIVE_PATH, INVOICE_NO AS DOC_REF, 'MISSING_FIELD' AS EXCEPTION_TYPE,
           'Missing: ' || ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
               IFF(INVOICE_NO   IS NULL, 'invoice number', NULL),
               IFF(INVOICE_DATE IS NULL, 'invoice date',   NULL),
               IFF(VENDOR_NAME  IS NULL, 'vendor',         NULL),
               IFF(VENDOR_GSTIN IS NULL, 'vendor GSTIN',   NULL),
               IFF(TAX_AMOUNT   IS NULL, 'tax amount',     NULL),
               IFF(TOTAL_AMOUNT IS NULL, 'total amount',   NULL),
               IFF(COALESCE(LINE_COUNT, 0) = 0, 'line items', NULL)), ', ') AS DETAIL,
           'High' AS SEVERITY
    FROM inv
    WHERE INVOICE_NO IS NULL OR INVOICE_DATE IS NULL OR VENDOR_NAME IS NULL OR VENDOR_GSTIN IS NULL
       OR TAX_AMOUNT IS NULL OR TOTAL_AMOUNT IS NULL OR COALESCE(LINE_COUNT, 0) = 0

    UNION ALL
    SELECT RELATIVE_PATH, INVOICE_NO, 'INVALID_GSTIN',
           'Vendor GSTIN "' || VENDOR_GSTIN || '" does not match the 15-character GSTIN pattern', 'Medium'
    FROM inv
    WHERE VENDOR_GSTIN IS NOT NULL
      AND NOT REGEXP_LIKE(VENDOR_GSTIN, '[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]')

    UNION ALL
    SELECT RELATIVE_PATH, INVOICE_NO, 'LINES_NE_SUBTOTAL',
           'Sum of line totals ' || TO_VARCHAR(SUM_LINE_TOTAL, '999,999,999,990.00') ||
           ' <> subtotal ' || TO_VARCHAR(SUBTOTAL, '999,999,999,990.00'), 'High'
    FROM inv
    WHERE SUBTOTAL IS NOT NULL AND SUM_LINE_TOTAL IS NOT NULL
      AND ABS(SUM_LINE_TOTAL - SUBTOTAL) > 1.00   -- EDIT ME tolerance

    UNION ALL
    SELECT RELATIVE_PATH, INVOICE_NO, 'TOTAL_MISMATCH',
           'Subtotal + tax = ' || TO_VARCHAR(SUBTOTAL + TAX_AMOUNT, '999,999,999,990.00') ||
           ' but invoice total is ' || TO_VARCHAR(TOTAL_AMOUNT, '999,999,999,990.00') ||
           ' (difference ' || TO_VARCHAR(TOTAL_AMOUNT - (SUBTOTAL + TAX_AMOUNT), '999,999,999,990.00') || ')', 'High'
    FROM inv
    WHERE SUBTOTAL IS NOT NULL AND TAX_AMOUNT IS NOT NULL AND TOTAL_AMOUNT IS NOT NULL
      AND ABS((SUBTOTAL + TAX_AMOUNT) - TOTAL_AMOUNT) > 1.00   -- EDIT ME tolerance

    UNION ALL
    SELECT RELATIVE_PATH, INVOICE_NO, 'LINE_MATH',
           BAD_LINE_MATH || ' line(s) where quantity x unit price <> line total', 'Medium'
    FROM inv
    WHERE COALESCE(BAD_LINE_MATH, 0) > 0

    UNION ALL
    SELECT RELATIVE_PATH, INVOICE_NO, 'TAX_RATE_UNUSUAL',
           'Effective tax rate ' || TO_VARCHAR(ROUND(TAX_AMOUNT / NULLIF(SUBTOTAL, 0) * 100, 2)) ||
           '% is not a standard GST slab (0, 5, 12, 18, 28)', 'Low'
    FROM inv
    WHERE SUBTOTAL > 0 AND TAX_AMOUNT IS NOT NULL
      AND ROUND(TAX_AMOUNT / SUBTOTAL * 100, 0) NOT IN (0, 5, 12, 18, 28)

    UNION ALL
    SELECT RELATIVE_PATH, INVOICE_NO, 'DUPLICATE_INVOICE',
           'Invoice number appears ' || CNT || ' times for vendor ' || VENDOR_NAME, 'High'
    FROM (SELECT RELATIVE_PATH, INVOICE_NO, VENDOR_NAME,
                 COUNT(*) OVER (PARTITION BY INVOICE_NO, VENDOR_GSTIN) AS CNT
          FROM inv WHERE INVOICE_NO IS NOT NULL)
    WHERE CNT > 1
),
contract_checks AS (
    SELECT RELATIVE_PATH, CONTRACT_NUMBER AS DOC_REF, 'MISSING_FIELD' AS EXCEPTION_TYPE,
           'Missing: ' || ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
               IFF(PARTY_1 IS NULL OR PARTY_2 IS NULL, 'parties', NULL),
               IFF(EFFECTIVE_DATE IS NULL,     'effective date',      NULL),
               IFF(TERM_TEXT IS NULL,          'term',                NULL),
               IFF(TERMINATION_CLAUSE IS NULL, 'termination clause',  NULL),
               IFF(LIABILITY_CAP_TEXT IS NULL, 'liability cap',       NULL)), ', ') AS DETAIL,
           'High' AS SEVERITY
    FROM CONTRACTS
    WHERE PARTY_1 IS NULL OR PARTY_2 IS NULL OR EFFECTIVE_DATE IS NULL OR TERM_TEXT IS NULL
       OR TERMINATION_CLAUSE IS NULL OR LIABILITY_CAP_TEXT IS NULL

    UNION ALL
    SELECT RELATIVE_PATH, CONTRACT_NUMBER, 'UNCAPPED_LIABILITY',
           'Liability clause mentions uncapped / unlimited exposure: ' || LEFT(LIABILITY_CAP_TEXT, 200), 'Medium'
    FROM CONTRACTS
    WHERE LIABILITY_CAP_TEXT ILIKE ANY ('%uncapped%', '%unlimited%')

    UNION ALL
    SELECT RELATIVE_PATH, CONTRACT_NUMBER, 'EXPIRING_SOON',
           'Contract ends on ' || TO_VARCHAR(END_DATE) || ' (within 120 days)', 'Low'
    FROM CONTRACTS
    WHERE END_DATE BETWEEN CURRENT_DATE() AND DATEADD('day', 120, CURRENT_DATE())
)
SELECT 'INVOICE' AS DOC_TYPE, * FROM invoice_checks
UNION ALL
SELECT 'CONTRACT', * FROM contract_checks
UNION ALL
SELECT DOC_TYPE, RELATIVE_PATH, NULL, 'PROCESSING_ERROR', COALESCE(ERROR_MESSAGE, 'Unknown error'), 'High'
FROM DOC_FILE_QUEUE WHERE STATUS = 'ERROR';

GRANT SELECT ON VIEW ACCEL_DB.DOC_INTEL.DOC_EXCEPTIONS_V TO ROLE ACCEL_ANALYST;

SELECT * FROM DOC_EXCEPTIONS_V
ORDER BY CASE SEVERITY WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END, DOC_TYPE, RELATIVE_PATH;
