/* =============================================================================
   Asset 27 - GST Tax Data Hub
   File  03_reconciliation.sql
   Purpose
     GST.RUN_GST_RECONCILIATION()  books (PURCHASE_REGISTER) vs GSTR-2B
       Pass 1  exact key: same GSTIN + same normalised invoice number
                 -> 'Matched' if taxable and tax differences are within
                    AMOUNT_TOLERANCE_ABS_INR, else 'Mismatch-amount'
       Pass 2  fuzzy, on what is left: GSTIN equal or EDITDISTANCE <= GSTIN_EDIT_DISTANCE_MAX,
               invoice EDITDISTANCE <= INVOICE_EDIT_DISTANCE_MAX, taxable within
               PROBABLE_AMOUNT_TOL_PCT, dates within PROBABLE_DATE_WINDOW_DAYS
                 -> 'Probable match' (best candidate, one-to-one)
       Pass 3  leftovers -> 'Missing in 2B' (books only) / 'Missing in books' (2B only)
     GST.RECON_RESULTS            one row per books and/or 2B invoice
     GST.RECON_RUN_LOG            one row per run
     GST.RECON_SUMMARY            counts and values by category
     GST.ITC_AT_RISK_BY_SUPPLIER  ITC at risk and unclaimed ITC per supplier
     GST.RECON_ACCURACY_DEMO      compares results with the injected DEMO_SCENARIO
   ITC at risk (illustrative logic, confirm with your tax team):
     Missing in 2B      -> full ITC claimed in books
     Mismatch-amount    -> books tax - 2B tax (if positive)
     Probable match     -> books tax until a reviewer confirms the match
     Missing in books   -> 0 at risk; 2B tax shown as potentially unclaimed ITC
   Run as  ACCEL_ADMIN after 02. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS GST;
USE SCHEMA GST;

CREATE TABLE IF NOT EXISTS GST.RECON_RUN_LOG (
    RUN_ID          VARCHAR,
    RUN_AT          TIMESTAMP_NTZ,
    BOOKS_INVOICES  NUMBER,
    GSTR2B_INVOICES NUMBER,
    MATCHED         NUMBER,
    MISMATCH_AMOUNT NUMBER,
    PROBABLE        NUMBER,
    MISSING_IN_2B   NUMBER,
    MISSING_IN_BOOKS NUMBER,
    ITC_AT_RISK     NUMBER(18,2)
);

CREATE OR REPLACE PROCEDURE GST.RUN_GST_RECONCILIATION()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    run_id VARCHAR DEFAULT UUID_STRING();
    res_msg VARCHAR;
BEGIN
    -- normalised inputs
    CREATE OR REPLACE TEMPORARY TABLE ACCEL_DB.GST.TMP_BOOKS AS
    SELECT b.*, ACCEL_DB.GST.NORMALIZE_INVOICE_NO(b.INVOICE_NO) AS INV_NORM, UPPER(TRIM(b.SUPPLIER_GSTIN)) AS GSTIN_NORM
    FROM ACCEL_DB.GST.PURCHASE_REGISTER b;

    CREATE OR REPLACE TEMPORARY TABLE ACCEL_DB.GST.TMP_2B AS
    SELECT t.*, ACCEL_DB.GST.NORMALIZE_INVOICE_NO(t.INVOICE_NO) AS INV_NORM, UPPER(TRIM(t.SUPPLIER_GSTIN)) AS GSTIN_NORM,
           ACCEL_DB.GST.GSTIN_VALIDATION_ERROR(t.SUPPLIER_GSTIN) AS GSTIN_ERROR
    FROM ACCEL_DB.GST.GSTR2B_INVOICES t;

    -- pass 1: exact key
    CREATE OR REPLACE TEMPORARY TABLE ACCEL_DB.GST.TMP_PAIRS AS
    SELECT b.BOOKS_ID, t.GSTR2B_ID,
           IFF(ABS(b.TAXABLE_VALUE - t.TAXABLE_VALUE) <= c.TOL_ABS AND ABS(b.TOTAL_TAX - t.TOTAL_TAX) <= c.TOL_ABS,
               'Matched', 'Mismatch-amount') AS MATCH_CATEGORY,
           'Exact GSTIN + invoice no' AS MATCH_METHOD,
           0 AS GSTIN_EDIT_DISTANCE, 0 AS INVOICE_EDIT_DISTANCE
    FROM ACCEL_DB.GST.TMP_BOOKS b
    JOIN ACCEL_DB.GST.TMP_2B t ON t.GSTIN_NORM = b.GSTIN_NORM AND t.INV_NORM = b.INV_NORM
    CROSS JOIN (SELECT MAX(IFF(PARAM = 'AMOUNT_TOLERANCE_ABS_INR', VALUE, NULL)) AS TOL_ABS
                FROM ACCEL_DB.GST.RECON_CONFIG) c
    QUALIFY ROW_NUMBER() OVER (PARTITION BY b.BOOKS_ID ORDER BY ABS(b.TAXABLE_VALUE - t.TAXABLE_VALUE), t.GSTR2B_ID) = 1
        AND ROW_NUMBER() OVER (PARTITION BY t.GSTR2B_ID ORDER BY ABS(b.TAXABLE_VALUE - t.TAXABLE_VALUE), b.BOOKS_ID) = 1;

    -- pass 2: fuzzy on the remainder (best candidate per books row, then per 2B row)
    INSERT INTO ACCEL_DB.GST.TMP_PAIRS (BOOKS_ID, GSTR2B_ID, MATCH_CATEGORY, MATCH_METHOD, GSTIN_EDIT_DISTANCE, INVOICE_EDIT_DISTANCE)
    WITH cfg AS (
        SELECT MAX(IFF(PARAM = 'PROBABLE_AMOUNT_TOL_PCT',   VALUE, NULL)) AS TOL_PCT,
               MAX(IFF(PARAM = 'PROBABLE_DATE_WINDOW_DAYS', VALUE, NULL)) AS DATE_WINDOW,
               MAX(IFF(PARAM = 'INVOICE_EDIT_DISTANCE_MAX', VALUE, NULL)) AS INV_ED_MAX,
               MAX(IFF(PARAM = 'GSTIN_EDIT_DISTANCE_MAX',   VALUE, NULL)) AS GSTIN_ED_MAX
        FROM ACCEL_DB.GST.RECON_CONFIG
    ),
    ub AS (SELECT * FROM ACCEL_DB.GST.TMP_BOOKS b
           WHERE NOT EXISTS (SELECT 1 FROM ACCEL_DB.GST.TMP_PAIRS p WHERE p.BOOKS_ID = b.BOOKS_ID)),
    ut AS (SELECT * FROM ACCEL_DB.GST.TMP_2B t
           WHERE NOT EXISTS (SELECT 1 FROM ACCEL_DB.GST.TMP_PAIRS p WHERE p.GSTR2B_ID = t.GSTR2B_ID)),
    cand AS (
        SELECT ub.BOOKS_ID, ut.GSTR2B_ID,
               EDITDISTANCE(ub.GSTIN_NORM, ut.GSTIN_NORM) AS GSTIN_ED,
               EDITDISTANCE(ub.INV_NORM, ut.INV_NORM)     AS INV_ED,
               ABS(ub.TAXABLE_VALUE - ut.TAXABLE_VALUE)   AS AMT_DIFF,
               ABS(DATEDIFF('day', ub.INVOICE_DATE, ut.INVOICE_DATE)) AS DATE_DIFF
        FROM ub
        CROSS JOIN cfg
        JOIN ut
          ON SUBSTR(ub.GSTIN_NORM, 3, 5) = SUBSTR(ut.GSTIN_NORM, 3, 5)      -- block: first 5 PAN chars ...
          OR RIGHT(ub.GSTIN_NORM, 8) = RIGHT(ut.GSTIN_NORM, 8)              -- ... or last 8 chars (typo-tolerant)
        WHERE EDITDISTANCE(ub.GSTIN_NORM, ut.GSTIN_NORM) <= cfg.GSTIN_ED_MAX
          AND EDITDISTANCE(ub.INV_NORM, ut.INV_NORM)     <= cfg.INV_ED_MAX
          AND ABS(ub.TAXABLE_VALUE - ut.TAXABLE_VALUE)   <= cfg.TOL_PCT * GREATEST(ABS(ub.TAXABLE_VALUE), 1)
          AND ABS(DATEDIFF('day', ub.INVOICE_DATE, ut.INVOICE_DATE)) <= cfg.DATE_WINDOW
    ),
    best_b AS (
        SELECT * FROM cand
        QUALIFY ROW_NUMBER() OVER (PARTITION BY BOOKS_ID ORDER BY GSTIN_ED + INV_ED, AMT_DIFF, DATE_DIFF, GSTR2B_ID) = 1
    ),
    best AS (
        SELECT * FROM best_b
        QUALIFY ROW_NUMBER() OVER (PARTITION BY GSTR2B_ID ORDER BY GSTIN_ED + INV_ED, AMT_DIFF, DATE_DIFF, BOOKS_ID) = 1
    )
    SELECT BOOKS_ID, GSTR2B_ID, 'Probable match',
           'Fuzzy: GSTIN ED ' || GSTIN_ED || ', invoice ED ' || INV_ED || ', amount diff ' || ROUND(AMT_DIFF, 2)
             || ', date diff ' || DATE_DIFF || 'd',
           GSTIN_ED, INV_ED
    FROM best;

    -- assemble results (full outer join of pairs with leftovers)
    CREATE OR REPLACE TABLE ACCEL_DB.GST.RECON_RESULTS AS
    WITH all_rows AS (
        SELECT p.BOOKS_ID, p.GSTR2B_ID, p.MATCH_CATEGORY, p.MATCH_METHOD, p.GSTIN_EDIT_DISTANCE, p.INVOICE_EDIT_DISTANCE
        FROM ACCEL_DB.GST.TMP_PAIRS p
        UNION ALL
        SELECT b.BOOKS_ID, NULL, 'Missing in 2B', 'No counterpart in GSTR-2B', NULL, NULL
        FROM ACCEL_DB.GST.TMP_BOOKS b
        WHERE NOT EXISTS (SELECT 1 FROM ACCEL_DB.GST.TMP_PAIRS p WHERE p.BOOKS_ID = b.BOOKS_ID)
        UNION ALL
        SELECT NULL, t.GSTR2B_ID, 'Missing in books', 'No counterpart in purchase register', NULL, NULL
        FROM ACCEL_DB.GST.TMP_2B t
        WHERE NOT EXISTS (SELECT 1 FROM ACCEL_DB.GST.TMP_PAIRS p WHERE p.GSTR2B_ID = t.GSTR2B_ID)
    )
    SELECT NULL::VARCHAR                                              AS RUN_ID,      -- set below
           r.MATCH_CATEGORY, r.MATCH_METHOD, r.BOOKS_ID, r.GSTR2B_ID,
           COALESCE(b.SUPPLIER_ID, sm.SUPPLIER_ID)                     AS SUPPLIER_ID,
           COALESCE(b.SUPPLIER_NAME, sm.SUPPLIER_NAME, t.SUPPLIER_TRADE_NAME) AS SUPPLIER_NAME,
           b.SUPPLIER_GSTIN                                            AS GSTIN_BOOKS,
           t.SUPPLIER_GSTIN                                            AS GSTIN_2B,
           t.GSTIN_ERROR                                               AS GSTIN_2B_VALIDATION_ERROR,
           b.INVOICE_NO                                                AS INVOICE_NO_BOOKS,
           t.INVOICE_NO                                                AS INVOICE_NO_2B,
           b.INVOICE_DATE                                              AS INVOICE_DATE_BOOKS,
           t.INVOICE_DATE                                              AS INVOICE_DATE_2B,
           COALESCE(b.RETURN_PERIOD, t.RETURN_PERIOD)                  AS RETURN_PERIOD,
           b.TAXABLE_VALUE                                             AS TAXABLE_BOOKS,
           t.TAXABLE_VALUE                                             AS TAXABLE_2B,
           b.TOTAL_TAX                                                 AS TAX_BOOKS,
           t.TOTAL_TAX                                                 AS TAX_2B,
           ROUND(COALESCE(b.TAXABLE_VALUE, 0) - COALESCE(t.TAXABLE_VALUE, 0), 2) AS TAXABLE_DIFF,
           ROUND(COALESCE(b.TOTAL_TAX, 0) - COALESCE(t.TOTAL_TAX, 0), 2)         AS TAX_DIFF,
           DATEDIFF('day', b.INVOICE_DATE, t.INVOICE_DATE)             AS DATE_DIFF_DAYS,
           (b.INVOICE_DATE IS NOT NULL AND t.INVOICE_DATE IS NOT NULL
             AND b.INVOICE_DATE <> t.INVOICE_DATE)                      AS DATE_MISMATCH,
           r.GSTIN_EDIT_DISTANCE, r.INVOICE_EDIT_DISTANCE,
           COALESCE(b.ITC_CLAIMED, 0)                                  AS ITC_CLAIMED,
           ROUND(CASE r.MATCH_CATEGORY
                     WHEN 'Missing in 2B'   THEN COALESCE(b.ITC_CLAIMED, 0)
                     WHEN 'Mismatch-amount' THEN GREATEST(COALESCE(b.TOTAL_TAX, 0) - COALESCE(t.TOTAL_TAX, 0), 0)
                     WHEN 'Probable match'  THEN COALESCE(b.ITC_CLAIMED, 0)
                     ELSE 0 END, 2)                                    AS ITC_AT_RISK,
           ROUND(IFF(r.MATCH_CATEGORY = 'Missing in books', COALESCE(t.TOTAL_TAX, 0), 0), 2) AS ITC_UNCLAIMED_POTENTIAL,
           CASE r.MATCH_CATEGORY
               WHEN 'Matched'          THEN IFF(b.INVOICE_DATE <> t.INVOICE_DATE, 'Claim; align invoice date in books', 'Claim ITC')
               WHEN 'Mismatch-amount'  THEN 'Obtain corrected invoice / ask supplier to amend (credit or debit note)'
               WHEN 'Probable match'   THEN IFF(t.GSTIN_ERROR IS NOT NULL,
                                                'Confirm match; supplier GSTIN in 2B fails validation (' || t.GSTIN_ERROR || ')',
                                                'Reviewer to confirm match and correct invoice number in books')
               WHEN 'Missing in 2B'    THEN 'Follow up with supplier to file GSTR-1; consider deferring ITC'
               WHEN 'Missing in books' THEN 'Check if invoice is unrecorded; book it to claim eligible ITC'
           END                                                         AS RECOMMENDED_ACTION,
           t.DEMO_SCENARIO,
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ                          AS RECONCILED_AT
    FROM all_rows r
    LEFT JOIN ACCEL_DB.GST.TMP_BOOKS b ON b.BOOKS_ID = r.BOOKS_ID
    LEFT JOIN ACCEL_DB.GST.TMP_2B t    ON t.GSTR2B_ID = r.GSTR2B_ID
    LEFT JOIN ACCEL_DB.GST.SUPPLIER_GST_MASTER sm ON sm.GSTIN = t.GSTIN_NORM;

    UPDATE ACCEL_DB.GST.RECON_RESULTS SET RUN_ID = :run_id;

    INSERT INTO ACCEL_DB.GST.RECON_RUN_LOG
    SELECT :run_id, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
           COUNT(BOOKS_ID), COUNT(GSTR2B_ID),
           COUNT_IF(MATCH_CATEGORY = 'Matched'), COUNT_IF(MATCH_CATEGORY = 'Mismatch-amount'),
           COUNT_IF(MATCH_CATEGORY = 'Probable match'), COUNT_IF(MATCH_CATEGORY = 'Missing in 2B'),
           COUNT_IF(MATCH_CATEGORY = 'Missing in books'), SUM(ITC_AT_RISK)
    FROM ACCEL_DB.GST.RECON_RESULTS;

    SELECT 'Run ' || RUN_ID || ': matched ' || MATCHED || ', amount mismatch ' || MISMATCH_AMOUNT
           || ', probable ' || PROBABLE || ', missing in 2B ' || MISSING_IN_2B
           || ', missing in books ' || MISSING_IN_BOOKS || ', ITC at risk INR ' || ITC_AT_RISK
      INTO :res_msg
      FROM ACCEL_DB.GST.RECON_RUN_LOG WHERE RUN_ID = :run_id;
    RETURN res_msg;
END;
$$;

CALL GST.RUN_GST_RECONCILIATION();

-- -----------------------------------------------------------------------------
-- Reporting views
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW GST.RECON_SUMMARY AS
SELECT MATCH_CATEGORY,
       COUNT(*)                         AS INVOICES,
       ROUND(SUM(TAXABLE_BOOKS), 2)     AS TAXABLE_BOOKS,
       ROUND(SUM(TAXABLE_2B), 2)        AS TAXABLE_2B,
       ROUND(SUM(ITC_CLAIMED), 2)       AS ITC_CLAIMED,
       ROUND(SUM(ITC_AT_RISK), 2)       AS ITC_AT_RISK,
       ROUND(SUM(ITC_UNCLAIMED_POTENTIAL), 2) AS ITC_UNCLAIMED_POTENTIAL,
       COUNT_IF(DATE_MISMATCH)          AS WITH_DATE_DIFFERENCE
FROM GST.RECON_RESULTS
GROUP BY MATCH_CATEGORY;

CREATE OR REPLACE VIEW GST.ITC_AT_RISK_BY_SUPPLIER AS
SELECT r.SUPPLIER_ID, r.SUPPLIER_NAME,
       MAX(sm.GSTIN)                                                  AS GSTIN,
       COUNT(*)                                                       AS INVOICES,
       COUNT_IF(r.MATCH_CATEGORY = 'Matched')                         AS MATCHED,
       COUNT_IF(r.MATCH_CATEGORY = 'Mismatch-amount')                 AS MISMATCH_AMOUNT,
       COUNT_IF(r.MATCH_CATEGORY = 'Probable match')                  AS PROBABLE_MATCH,
       COUNT_IF(r.MATCH_CATEGORY = 'Missing in 2B')                   AS MISSING_IN_2B,
       COUNT_IF(r.MATCH_CATEGORY = 'Missing in books')                AS MISSING_IN_BOOKS,
       ROUND(SUM(r.ITC_CLAIMED), 2)                                   AS ITC_CLAIMED,
       ROUND(SUM(r.ITC_AT_RISK), 2)                                   AS ITC_AT_RISK,
       ROUND(SUM(r.ITC_UNCLAIMED_POTENTIAL), 2)                       AS ITC_UNCLAIMED_POTENTIAL,
       ROUND(COUNT_IF(r.MATCH_CATEGORY = 'Matched') / NULLIF(COUNT(*), 0), 3) AS MATCH_RATE,
       CASE WHEN SUM(r.ITC_AT_RISK) > 0.10 * NULLIF(SUM(r.ITC_CLAIMED), 0) THEN 'High'
            WHEN SUM(r.ITC_AT_RISK) > 0.03 * NULLIF(SUM(r.ITC_CLAIMED), 0) THEN 'Medium'
            ELSE 'Low' END                                            AS SUPPLIER_COMPLIANCE_RISK      -- EDIT ME thresholds
FROM GST.RECON_RESULTS r
LEFT JOIN GST.SUPPLIER_GST_MASTER sm ON sm.SUPPLIER_ID = r.SUPPLIER_ID
GROUP BY r.SUPPLIER_ID, r.SUPPLIER_NAME;

-- Demo only: how well did the matcher recover the injected scenarios?
CREATE OR REPLACE VIEW GST.RECON_ACCURACY_DEMO AS
SELECT COALESCE(DEMO_SCENARIO, 'MISSING_IN_2B') AS INJECTED_SCENARIO,
       MATCH_CATEGORY,
       COUNT(*) AS INVOICES
FROM GST.RECON_RESULTS
GROUP BY 1, 2;

GRANT USAGE ON SCHEMA ACCEL_DB.GST TO ROLE ACCEL_ANALYST;
GRANT USAGE ON SCHEMA ACCEL_DB.GST TO ROLE ACCEL_VIEWER;
GRANT SELECT ON ALL TABLES IN SCHEMA ACCEL_DB.GST TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ACCEL_DB.GST TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ACCEL_DB.GST TO ROLE ACCEL_VIEWER;
GRANT USAGE ON FUNCTION ACCEL_DB.GST.IS_VALID_GSTIN(VARCHAR) TO ROLE ACCEL_ANALYST;
GRANT USAGE ON FUNCTION ACCEL_DB.GST.GSTIN_VALIDATION_ERROR(VARCHAR) TO ROLE ACCEL_ANALYST;

SELECT * FROM GST.RECON_SUMMARY ORDER BY INVOICES DESC;
SELECT * FROM GST.RECON_ACCURACY_DEMO ORDER BY INJECTED_SCENARIO, INVOICES DESC;
SELECT * FROM GST.ITC_AT_RISK_BY_SUPPLIER ORDER BY ITC_AT_RISK DESC LIMIT 15;
