/*=============================================================================
  ACCELERATOR 21 - Journal Entry Analytics (JE risk scoring)
  File 01 : Schema, configurable rule table, seeded control test cases,
            journal population view
  Creates : schema ACCEL_DB.JE_ANALYTICS
            - FX_RATES              local currency units per USD
            - JE_RISK_RULES         configurable rules: weight, parameters, on/off
            - JE_SEEDED_JOURNALS    ~40 known-bad journals added to the demo
                                    population, to prove each rule fires
            - V_GL_SCOPE            population tested = DEMO.GL_JOURNAL + seeded
            - V_JE_HEADER           one row per journal
            - JE_REVIEW             reviewer disposition per journal
  Run as  : ACCEL_ADMIN
  Rerun   : safe. Rule settings you changed are kept (MERGE inserts missing
            rules only). Seeded journals are rebuilt.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS JE_ANALYTICS COMMENT = 'Accelerator 21: journal entry risk analytics';
USE SCHEMA JE_ANALYTICS;

------------------------------------------------------------------------------
-- 1. FX rates (used to compare amounts across entities in USD)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE FX_RATES (
    CURRENCY       VARCHAR,
    UNITS_PER_USD  NUMBER(12,5)
) COMMENT = 'Local currency units per 1 USD';
INSERT INTO FX_RATES VALUES
    ('USD', 1.00000), ('INR', 83.00000), ('GBP', 0.79000), ('EUR', 0.92000);   -- EDIT ME: closing rates

------------------------------------------------------------------------------
-- 2. Rule table. Change WEIGHT / PARAM_* / IS_ACTIVE and rerun 02 (CALL SP_SCORE_JOURNALS()).
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS JE_RISK_RULES (
    RULE_CODE    VARCHAR,
    RULE_NAME    VARCHAR,
    CATEGORY     VARCHAR,      -- Timing | Amount | Segregation of duties | Account | Behaviour | Integrity
    DESCRIPTION  VARCHAR,
    WEIGHT       NUMBER,       -- points added to the journal risk score (score capped at 100)
    PARAM_1      FLOAT,
    PARAM_2      FLOAT,
    PARAM_TEXT   VARCHAR,
    PARAM_NOTES  VARCHAR,
    IS_ACTIVE    BOOLEAN
) COMMENT = 'Configurable journal entry risk rules';

MERGE INTO JE_RISK_RULES t
USING (
    SELECT $1 AS RULE_CODE, $2 AS RULE_NAME, $3 AS CATEGORY, $4 AS DESCRIPTION, $5 AS WEIGHT,
           $6 AS PARAM_1, $7 AS PARAM_2, $8 AS PARAM_TEXT, $9 AS PARAM_NOTES
    FROM VALUES
    ('WEEKEND',             'Weekend posting',            'Timing',
     'Posting date or entry timestamp falls on a Saturday or Sunday',
     15, NULL, NULL, NULL, '-'),
    ('AFTER_HOURS',         'After-hours entry',          'Timing',
     'Entered at or after PARAM_1 hour or before PARAM_2 hour (24h clock)',
     10, 20, 7, NULL, 'PARAM_1 = start hour of after-hours, PARAM_2 = end hour'),
    ('ROUND_AMOUNT',        'Round amount',               'Amount',
     'A line of at least PARAM_1 (local currency) that is an exact multiple of PARAM_2',
     10, 10000, 1000, NULL, 'PARAM_1 = minimum line amount, PARAM_2 = rounding multiple'),
    ('SELF_APPROVAL',       'Self-approved entry',        'Segregation of duties',
     'CREATED_BY equals APPROVED_BY',
     30, NULL, NULL, NULL, '-'),
    ('MANUAL_REVENUE',      'Manual entry to revenue',    'Account',
     'Journal from SOURCE = PARAM_TEXT that touches a Revenue account',
     20, NULL, NULL, 'Manual', 'PARAM_TEXT = source system treated as manual'),
    ('JUST_BELOW_THRESHOLD','Just below approval limit',  'Amount',
     'Journal total (USD) between PARAM_1 x (1 - PARAM_2) and PARAM_1 - suggests splitting / limit avoidance',
     20, 100000, 0.05, NULL, 'PARAM_1 = approval limit in USD, PARAM_2 = band below the limit (0.05 = 5%)'),
    ('UNUSUAL_ACCOUNT_COMBO','Unusual account combination','Account',
     'Debit / credit account pair used in at most PARAM_1 journals in the whole population',
     15, 5, NULL, NULL, 'PARAM_1 = maximum occurrences for a pair to count as rare'),
    ('BENFORD_USER',        'Benford deviation by user',  'Behaviour',
     'User''s first-digit distribution deviates from Benford: MAD greater than PARAM_1 x median MAD of all users, with at least PARAM_2 lines',
     5, 1.5, 200, NULL, 'PARAM_1 = multiple of the peer median MAD, PARAM_2 = minimum lines per user'),
    ('ZSCORE_USER',         'Unusual amount for user',    'Behaviour',
     'Journal total (USD) more than PARAM_1 standard deviations from the user''s mean, users with at least PARAM_2 journals',
     20, 3, 20, NULL, 'PARAM_1 = z-score threshold, PARAM_2 = minimum journals per user'),
    ('DUPLICATE',           'Possible duplicate',         'Integrity',
     'Same entity, accounts and line amounts as another journal posted up to PARAM_1 days earlier',
     25, 7, NULL, NULL, 'PARAM_1 = look-back window in days')
) s
ON t.RULE_CODE = s.RULE_CODE
WHEN NOT MATCHED THEN INSERT
    (RULE_CODE, RULE_NAME, CATEGORY, DESCRIPTION, WEIGHT, PARAM_1, PARAM_2, PARAM_TEXT, PARAM_NOTES, IS_ACTIVE)
VALUES
    (s.RULE_CODE, s.RULE_NAME, s.CATEGORY, s.DESCRIPTION, s.WEIGHT, s.PARAM_1, s.PARAM_2, s.PARAM_TEXT, s.PARAM_NOTES, TRUE);

------------------------------------------------------------------------------
-- 3. Seeded control test cases (journal IDs 990000+).
--    Auditors seed known exceptions to prove that every rule works. The DEMO
--    ledger has no manual revenue postings or duplicates, so they are added here.
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE JE_SEEDED_JOURNALS LIKE ACCEL_DB.DEMO.GL_JOURNAL;
ALTER TABLE JE_SEEDED_JOURNALS SET COMMENT = 'Seeded journals that must be flagged (control test cases)';

-- 3a. Two-line scenarios: manual revenue, just-below-threshold, unusual account pairs
INSERT INTO JE_SEEDED_JOURNALS
WITH sc AS (
    SELECT $1 AS JOURNAL_ID, $2::DATE AS POSTING_DATE, $3 AS ENTRY_SECS, $4 AS ENTITY,
           $5 AS DR_ACC, $6 AS DR_NAME, $7 AS DR_TYPE, $8 AS CR_ACC, $9 AS CR_NAME, $10 AS CR_TYPE,
           $11 AS AMOUNT_USD, $12 AS CREATED_BY, $13 AS APPROVED_BY, $14 AS DESCRIPTION
    FROM VALUES
    -- Manual revenue at quarter-end (Dr Receivables / Cr Revenue)
    (990001, '2025-03-31', 66600, 'US01', '1100','Accounts Receivable','Asset', '4000','Product Revenue','Revenue', 48000.00, 'john.carter',  'controller.us',      'Revenue adjustment - customer side letter'),
    (990002, '2025-06-30', 67500, 'IN01', '1100','Accounts Receivable','Asset', '4000','Product Revenue','Revenue', 52500.00, 'rahul.mehta',  'controller.in',      'Q1 revenue true-up'),
    (990003, '2025-09-30', 68400, 'US01', '1100','Accounts Receivable','Asset', '4100','Service Revenue','Revenue', 61250.00, 'john.carter',  'finance.manager.us', 'Services revenue accrual'),
    (990004, '2025-12-31', 64800, 'UK01', '1100','Accounts Receivable','Asset', '4000','Product Revenue','Revenue', 39900.00, 'emma.wilson',  'controller.uk',      'Year-end revenue adjustment'),
    (990005, '2025-12-31', 70200, 'IN01', '1100','Accounts Receivable','Asset', '4000','Product Revenue','Revenue', 87000.00, 'rahul.mehta',  'rahul.mehta',        'Revenue recognised on bill-and-hold'),
    (990006, '2026-03-31', 66000, 'DE01', '1100','Accounts Receivable','Asset', '4000','Product Revenue','Revenue', 45500.00, 'lukas.weber',  'controller.de',      'Q4 revenue true-up'),
    (990007, '2026-03-31', 69000, 'US01', '1100','Accounts Receivable','Asset', '4100','Service Revenue','Revenue', 74300.00, 'john.carter',  'controller.us',      'Revenue adjustment - milestone billing'),
    (990008, '2026-06-30', 67800, 'IN01', '1100','Accounts Receivable','Asset', '4000','Product Revenue','Revenue', 58800.00, 'priya.sharma', 'controller.in',      'Quarter-end revenue adjustment'),
    (990009, '2026-06-30', 71000, 'UK01', '1100','Accounts Receivable','Asset', '4100','Service Revenue','Revenue', 42750.00, 'emma.wilson',  'finance.manager.uk', 'Unbilled revenue'),
    (990010, '2026-09-30', 68900, 'US01', '1100','Accounts Receivable','Asset', '4000','Product Revenue','Revenue', 95000.00, 'john.carter',  'john.carter',        'Revenue adjustment per sales VP'),
    -- Just below a USD 100,000 approval limit (Dr Professional fees / Cr Accruals)
    (990101, '2025-02-14', 41000, 'US01', '6600','Professional Fees','Opex', '2100','Accrued Liabilities','Liability', 99500.00, 'mei.tan',     'controller.us',      'Consulting accrual'),
    (990102, '2025-05-16', 43000, 'US01', '6600','Professional Fees','Opex', '2100','Accrued Liabilities','Liability', 98750.00, 'mei.tan',     'controller.us',      'Consulting accrual'),
    (990103, '2025-08-15', 39000, 'IN01', '6600','Professional Fees','Opex', '2100','Accrued Liabilities','Liability', 97900.00, 'anita.iyer',  'controller.in',      'Advisory fees accrual'),
    (990104, '2025-11-14', 45000, 'UK01', '6300','Marketing','Opex',         '2100','Accrued Liabilities','Liability', 99200.00, 'emma.wilson', 'controller.uk',      'Campaign accrual'),
    (990105, '2026-02-13', 42000, 'DE01', '6500','IT & Software','Opex',     '2100','Accrued Liabilities','Liability', 96400.00, 'lukas.weber', 'controller.de',      'Licence accrual'),
    (990106, '2026-05-15', 40000, 'US01', '6600','Professional Fees','Opex', '2100','Accrued Liabilities','Liability', 99900.00, 'mei.tan',     'finance.manager.us', 'Consulting accrual'),
    (990107, '2026-08-14', 44000, 'IN01', '6600','Professional Fees','Opex', '2100','Accrued Liabilities','Liability', 98100.00, 'anita.iyer',  'controller.in',      'Advisory fees accrual'),
    -- Unusual account pairs
    (990301, '2025-10-11', 79000, 'IN01', '3000','Share Capital','Equity',   '1000','Cash at Bank','Asset',          25000.00, 'kenji.sato',  'controller.in',      'Misc payment'),
    (990302, '2026-01-24', 80500, 'US01', '1510','Fixed Assets - IT Equipment','Asset', '4200','Freight Income','Revenue', 18000.00, 'kenji.sato', 'kenji.sato', 'Reclass'),
    (990303, '2026-04-18', 82000, 'UK01', '6400','Travel','Opex',            '1200','Inventory','Asset',             12500.00, 'mei.tan',     'controller.uk',      'Stock write-off to travel'),
    (990304, '2026-07-04', 77000, 'DE01', '1300','Prepaid Expenses','Asset', '4000','Product Revenue','Revenue',     22000.00, 'lukas.weber', 'controller.de',      'Prepayment release')
),
lines AS (
    SELECT sc.*, 1 AS LINE_NO, DR_ACC AS ACC, DR_NAME AS ACC_NAME, DR_TYPE AS ACC_TYPE,  1 AS SIGN FROM sc
    UNION ALL
    SELECT sc.*, 2 AS LINE_NO, CR_ACC, CR_NAME, CR_TYPE, -1 FROM sc
)
SELECT l.JOURNAL_ID,
       l.LINE_NO,
       l.POSTING_DATE,
       DATEADD(SECOND, l.ENTRY_SECS, l.POSTING_DATE::TIMESTAMP_NTZ),
       l.ENTITY,
       l.ACC,
       l.ACC_NAME,
       l.ACC_TYPE,
       IFF(l.ACC_TYPE IN ('Revenue', 'COGS', 'Opex'), 'CC400-FINANCE', 'CC000-CORPORATE'),
       (l.SIGN * ROUND(l.AMOUNT_USD * fx.UNITS_PER_USD, 2))::NUMBER(16,2),
       fx.CURRENCY,
       l.DESCRIPTION,
       l.CREATED_BY,
       l.APPROVED_BY,
       'Manual'
FROM lines l
JOIN FX_RATES fx
  ON fx.CURRENCY = DECODE(l.ENTITY, 'IN01', 'INR', 'US01', 'USD', 'UK01', 'GBP', 'EUR');

-- 3b. Duplicates: re-post 8 existing manual journals (pseudo-randomly picked,
--     deterministic) two days later with the same lines
INSERT INTO JE_SEEDED_JOURNALS
WITH candidates AS (
    SELECT JOURNAL_ID
    FROM ACCEL_DB.DEMO.GL_JOURNAL
    WHERE SOURCE = 'Manual'
      AND POSTING_DATE BETWEEN '2025-01-01' AND '2026-09-20'
      AND DAYOFWEEKISO(POSTING_DATE) BETWEEN 1 AND 3
      AND CREATED_BY <> APPROVED_BY
    GROUP BY JOURNAL_ID
),
picks AS (
    SELECT JOURNAL_ID,
           ROW_NUMBER() OVER (ORDER BY MOD(ABS(HASH(JOURNAL_ID, 'dup')), 100000), JOURNAL_ID) AS K
    FROM candidates
)
SELECT 990200 + p.K,
       g.LINE_NO,
       DATEADD(DAY, 2, g.POSTING_DATE),
       DATEADD(DAY, 2, g.ENTRY_TIMESTAMP),
       g.ENTITY, g.ACCOUNT_CODE, g.ACCOUNT_NAME, g.ACCOUNT_TYPE, g.COST_CENTER, g.AMOUNT, g.CURRENCY,
       g.DESCRIPTION, g.CREATED_BY, g.APPROVED_BY, g.SOURCE
FROM picks p
JOIN ACCEL_DB.DEMO.GL_JOURNAL g ON g.JOURNAL_ID = p.JOURNAL_ID
WHERE p.K <= 8;

------------------------------------------------------------------------------
-- 4. Population under test
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_GL_SCOPE
  COMMENT = 'Journal lines tested: DEMO.GL_JOURNAL plus seeded control test cases'
AS
SELECT JOURNAL_ID, LINE_NO, POSTING_DATE, ENTRY_TIMESTAMP, ENTITY, ACCOUNT_CODE, ACCOUNT_NAME, ACCOUNT_TYPE,
       COST_CENTER, AMOUNT, CURRENCY, DESCRIPTION, CREATED_BY, APPROVED_BY, SOURCE, 'Ledger' AS ORIGIN
FROM ACCEL_DB.DEMO.GL_JOURNAL
UNION ALL
SELECT JOURNAL_ID, LINE_NO, POSTING_DATE, ENTRY_TIMESTAMP, ENTITY, ACCOUNT_CODE, ACCOUNT_NAME, ACCOUNT_TYPE,
       COST_CENTER, AMOUNT, CURRENCY, DESCRIPTION, CREATED_BY, APPROVED_BY, SOURCE, 'Seeded test case'
FROM ACCEL_DB.JE_ANALYTICS.JE_SEEDED_JOURNALS;

CREATE OR REPLACE VIEW V_JE_HEADER
  COMMENT = 'One row per journal with totals in local currency and USD'
AS
SELECT g.JOURNAL_ID,
       ANY_VALUE(g.ENTITY)                                       AS ENTITY,
       MIN(g.POSTING_DATE)                                       AS POSTING_DATE,
       MIN(g.ENTRY_TIMESTAMP)                                    AS ENTRY_TIMESTAMP,
       ANY_VALUE(g.CREATED_BY)                                   AS CREATED_BY,
       ANY_VALUE(g.APPROVED_BY)                                  AS APPROVED_BY,
       ANY_VALUE(g.SOURCE)                                       AS SOURCE,
       ANY_VALUE(g.CURRENCY)                                     AS CURRENCY,
       ANY_VALUE(g.DESCRIPTION)                                  AS DESCRIPTION,
       ANY_VALUE(g.ORIGIN)                                       AS ORIGIN,
       COUNT(*)                                                  AS N_LINES,
       SUM(IFF(g.AMOUNT > 0, g.AMOUNT, 0))                       AS TOTAL_DEBIT,
       ROUND(SUM(IFF(g.AMOUNT > 0, g.AMOUNT, 0)) / MAX(COALESCE(fx.UNITS_PER_USD, 1)), 2) AS TOTAL_DEBIT_USD,
       BOOLOR_AGG(g.ACCOUNT_TYPE = 'Revenue')                    AS HAS_REVENUE_LINE,
       HASH(LISTAGG(g.ACCOUNT_CODE || ':' || TO_VARCHAR(g.AMOUNT), '|')
              WITHIN GROUP (ORDER BY g.ACCOUNT_CODE, g.AMOUNT))  AS LINE_SIGNATURE
FROM ACCEL_DB.JE_ANALYTICS.V_GL_SCOPE g
LEFT JOIN ACCEL_DB.JE_ANALYTICS.FX_RATES fx ON fx.CURRENCY = g.CURRENCY
GROUP BY g.JOURNAL_ID;

------------------------------------------------------------------------------
-- 5. Reviewer disposition (written by the Streamlit app)
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS JE_REVIEW (
    JOURNAL_ID   NUMBER,
    STATUS       VARCHAR,        -- Open | Explained | Exception raised | Closed
    REVIEWER     VARCHAR,
    NOTES        VARCHAR,
    UPDATED_AT   TIMESTAMP_NTZ
) COMMENT = 'Reviewer disposition per flagged journal';

------------------------------------------------------------------------------
-- 6. Check
------------------------------------------------------------------------------
SELECT ORIGIN, COUNT(DISTINCT JOURNAL_ID) AS JOURNALS, COUNT(*) AS LINES
FROM V_GL_SCOPE GROUP BY ORIGIN;

-- Every seeded journal must balance (expect 0 rows)
SELECT JOURNAL_ID, SUM(AMOUNT) AS IMBALANCE
FROM JE_SEEDED_JOURNALS GROUP BY JOURNAL_ID HAVING SUM(AMOUNT) <> 0;

SELECT RULE_CODE, RULE_NAME, WEIGHT, PARAM_1, PARAM_2, PARAM_TEXT, IS_ACTIVE FROM JE_RISK_RULES ORDER BY WEIGHT DESC;
