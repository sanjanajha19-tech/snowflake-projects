/*=============================================================================
  ASSET 13 - Enterprise Knowledge Assistant (RAG)
  File 01   : Knowledge base - policy/SOP stage, chunk table, seed content,
              ingestion procedure (AI_PARSE_DOCUMENT + SPLIT_TEXT_RECURSIVE_CHARACTER)
  Creates   : ACCEL_DB.KNOWLEDGE.POLICY_DOCS_STAGE, DOC_CHUNKS,
              INGEST_POLICY_DOCS()
  Run as    : ACCEL_ADMIN
  Rerun     : safe - seed rows are deleted and re-inserted; uploaded chunks kept
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS KNOWLEDGE COMMENT = 'Asset 13: enterprise knowledge assistant (RAG)';
USE SCHEMA KNOWLEDGE;

------------------------------------------------------------------------------
-- 1. Stage for policy / SOP PDFs (server-side encryption is required by
--    AI_PARSE_DOCUMENT; directory table lists the files)
------------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS POLICY_DOCS_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Upload policy and SOP PDFs here, then CALL INGEST_POLICY_DOCS()';

------------------------------------------------------------------------------
-- 2. Chunk table (the Cortex Search corpus)
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DOC_CHUNKS (
    CHUNK_ID     VARCHAR       NOT NULL PRIMARY KEY,
    DOC_NAME     VARCHAR       NOT NULL,   -- file path or seed document key
    DOC_TITLE    VARCHAR,
    CATEGORY     VARCHAR,                  -- Travel / IT Security / Leave / Procurement / ...
    SOURCE       VARCHAR       NOT NULL,   -- SEED or UPLOAD
    CHUNK_INDEX  NUMBER,
    CHUNK_TEXT   VARCHAR       NOT NULL,
    LOADED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CHANGE_TRACKING = TRUE
COMMENT = 'Chunked policy text for Cortex Search (ACCEL asset 13)';

------------------------------------------------------------------------------
-- 3. Seed content: 16 synthetic policy chunks so the demo works without uploads
------------------------------------------------------------------------------
DELETE FROM DOC_CHUNKS WHERE SOURCE = 'SEED';

INSERT INTO DOC_CHUNKS (CHUNK_ID, DOC_NAME, DOC_TITLE, CATEGORY, SOURCE, CHUNK_INDEX, CHUNK_TEXT)
VALUES
  ('SEED-TRV-01','seed/travel_policy','Global Travel and Expense Policy v4.2','Travel','SEED',1,
   'Travel and Expense Policy - Section 1 Booking. All business travel must be booked through the corporate travel portal at least 14 days before departure for international trips and 7 days for domestic trips. Bookings made outside the portal are not reimbursed unless the traveller obtains written approval from their cost center manager. Economy class is the default for all flights under 6 hours.'),
  ('SEED-TRV-02','seed/travel_policy','Global Travel and Expense Policy v4.2','Travel','SEED',2,
   'Travel and Expense Policy - Section 2 Air and rail class. Premium economy may be booked for flights between 6 and 10 hours. Business class is permitted for flights longer than 10 hours or overnight flights for Director level and above, with VP approval. Rail travel in first class is allowed for journeys over 3 hours. Upgrades using personal loyalty points are allowed at no cost to the company.'),
  ('SEED-TRV-03','seed/travel_policy','Global Travel and Expense Policy v4.2','Travel','SEED',3,
   'Travel and Expense Policy - Section 3 Hotels and per diem. Hotel nightly caps: India metro cities INR 9,000; other Indian cities INR 6,000; USA USD 250; UK GBP 180; Germany EUR 170; Japan JPY 25,000; Singapore SGD 300. The daily meal per diem is INR 2,500 in India and USD 75 equivalent elsewhere. Alcohol is not reimbursable except at approved client entertainment events.'),
  ('SEED-TRV-04','seed/travel_policy','Global Travel and Expense Policy v4.2','Travel','SEED',4,
   'Travel and Expense Policy - Section 4 Expense claims. Expense claims must be submitted in the expense system within 30 days of the trip end date with itemised receipts for every expense above INR 500 or USD 10. Claims submitted after 60 days are rejected. Corporate card statements must be reconciled monthly. Personal expenses charged to the corporate card must be repaid within 15 days.'),
  ('SEED-ITS-01','seed/it_security_policy','Information Security Policy v7.0','IT Security','SEED',1,
   'Information Security Policy - Passwords and MFA. Passwords must be at least 14 characters and must not be reused across the last 10 passwords. Multi-factor authentication is mandatory for email, VPN, Snowflake, the ERP and all SaaS applications that support single sign-on. Sharing credentials or MFA devices is a disciplinary offence. Service accounts must use key-pair authentication and be registered with the IT Security team.'),
  ('SEED-ITS-02','seed/it_security_policy','Information Security Policy v7.0','IT Security','SEED',2,
   'Information Security Policy - Data classification. Company data is classified as Public, Internal, Confidential or Restricted. Customer PII, PAN numbers, salaries and unreleased financial results are Restricted. Restricted data must not be stored on personal devices, shared by email outside the company, or uploaded to public AI tools. Use only approved AI tools that run inside the company data platform.'),
  ('SEED-ITS-03','seed/it_security_policy','Information Security Policy v7.0','IT Security','SEED',3,
   'Information Security Policy - Incident reporting. Suspected phishing emails must be reported using the Report Phishing button in the mail client. Lost or stolen laptops and phones must be reported to the IT Service Desk within 1 hour so that the device can be remotely wiped. Any suspected data breach must be reported to the Security Operations Centre immediately; do not attempt to investigate on your own.'),
  ('SEED-ITS-04','seed/it_security_policy','Information Security Policy v7.0','IT Security','SEED',4,
   'Information Security Policy - Access reviews and remote work. Managers must review their team access to Confidential and Restricted systems every quarter. Access is removed within 24 hours of an employee exit. When working remotely, employees must use the company VPN on public networks, lock their screen when away, and must not allow family members to use company devices.'),
  ('SEED-LV-01','seed/leave_policy','Leave and Time Off Policy v3.1','Leave','SEED',1,
   'Leave Policy - Annual leave. Full-time employees receive 24 days of paid annual leave per calendar year, accrued monthly at 2 days per month. Up to 10 unused days can be carried forward to the next year and must be used by 31 March. Leave encashment is available only at exit, for a maximum of 30 days. Annual leave requests must be submitted in the HR portal at least 5 working days in advance.'),
  ('SEED-LV-02','seed/leave_policy','Leave and Time Off Policy v3.1','Leave','SEED',2,
   'Leave Policy - Sick leave. Employees receive 12 days of paid sick leave per year, which cannot be carried forward. A medical certificate is required for sick leave longer than 2 consecutive days. Employees should inform their manager before the start of the working day. Extended illness beyond the sick leave balance is handled through the short-term disability benefit after HR review.'),
  ('SEED-LV-03','seed/leave_policy','Leave and Time Off Policy v3.1','Leave','SEED',3,
   'Leave Policy - Parental leave. Birthing parents receive 26 weeks of fully paid maternity leave. Non-birthing parents receive 4 weeks of fully paid paternity or partner leave, to be taken within 6 months of the birth or adoption. Adoptive parents of a child under 3 months receive the same entitlements. Employees may request a phased return to work of up to 8 weeks at reduced hours.'),
  ('SEED-LV-04','seed/leave_policy','Leave and Time Off Policy v3.1','Leave','SEED',4,
   'Leave Policy - Public holidays and work from anywhere. Each location publishes 10 to 12 public holidays per year in the HR portal. Employees may work from anywhere within their country of employment for up to 20 working days per year with manager approval. Working from another country requires approval from HR and Tax at least 30 days in advance because of tax and immigration rules.'),
  ('SEED-PRC-01','seed/procurement_policy','Procurement and Purchasing Policy v5.0','Procurement','SEED',1,
   'Procurement Policy - Approval thresholds. Purchases up to INR 1,00,000 (USD 1,200) can be approved by the cost center manager. Purchases between INR 1,00,000 and INR 25,00,000 require approval by the department head and Procurement. Purchases above INR 25,00,000 (USD 30,000) require CFO approval. Splitting a purchase into smaller orders to stay under a threshold is prohibited.'),
  ('SEED-PRC-02','seed/procurement_policy','Procurement and Purchasing Policy v5.0','Procurement','SEED',2,
   'Procurement Policy - Competitive quotes. At least three written quotations are required for any purchase above INR 5,00,000. A formal RFP is required above INR 50,00,000 or for any multi-year contract. Single-source purchases must be justified in writing and approved by the Head of Procurement. All new suppliers must complete onboarding including GSTIN, PAN, bank verification and a risk assessment.'),
  ('SEED-PRC-03','seed/procurement_policy','Procurement and Purchasing Policy v5.0','Procurement','SEED',3,
   'Procurement Policy - Purchase orders and invoices. No goods or services may be ordered without an approved purchase order (no PO, no pay). Invoices must quote the PO number and are paid only after a three-way match between the PO, the goods receipt and the invoice. Price or quantity variances above 2 percent are blocked for review by Accounts Payable. Standard payment terms are 45 days from invoice receipt.'),
  ('SEED-PRC-04','seed/procurement_policy','Procurement and Purchasing Policy v5.0','Procurement','SEED',4,
   'Procurement Policy - Supplier conduct and gifts. Employees may not accept gifts or hospitality from suppliers worth more than INR 5,000 or USD 60 per occasion, and all gifts must be recorded in the gifts register. Conflicts of interest with a supplier must be declared to Compliance before taking part in a sourcing decision. Suppliers rated High risk require an annual performance and compliance review.');

------------------------------------------------------------------------------
-- 4. Ingestion procedure for uploaded PDFs:
--    parse (LAYOUT -> markdown) -> classify category -> split into chunks
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE INGEST_POLICY_DOCS()
  RETURNS VARCHAR
  LANGUAGE SQL
  EXECUTE AS OWNER
  COMMENT = 'Parses and chunks new PDFs from POLICY_DOCS_STAGE into DOC_CHUNKS'
AS
$$
DECLARE
  n_chunks NUMBER DEFAULT 0;
BEGIN
  ALTER STAGE ACCEL_DB.KNOWLEDGE.POLICY_DOCS_STAGE REFRESH;

  INSERT INTO ACCEL_DB.KNOWLEDGE.DOC_CHUNKS
    (CHUNK_ID, DOC_NAME, DOC_TITLE, CATEGORY, SOURCE, CHUNK_INDEX, CHUNK_TEXT)
  SELECT
      p.RELATIVE_PATH || '#' || LPAD(TO_VARCHAR(c.INDEX + 1), 4, '0')            AS CHUNK_ID,
      p.RELATIVE_PATH                                                            AS DOC_NAME,
      INITCAP(REPLACE(REPLACE(REGEXP_REPLACE(p.RELATIVE_PATH, '^.*/|\\.pdf$', ''), '_', ' '), '-', ' ')) AS DOC_TITLE,
      p.CATEGORY,
      'UPLOAD'                                                                   AS SOURCE,
      c.INDEX + 1                                                                AS CHUNK_INDEX,
      c.VALUE::VARCHAR                                                           AS CHUNK_TEXT
  FROM (
      SELECT d.RELATIVE_PATH,
             d.CONTENT,
             PARSE_JSON(TO_VARCHAR(AI_CLASSIFY(
                 LEFT(d.CONTENT, 4000),
                 ['Travel', 'IT Security', 'Leave', 'Procurement', 'HR', 'Finance', 'Operations', 'Other']
             ))):labels[0]::VARCHAR AS CATEGORY
      FROM (
          SELECT f.RELATIVE_PATH,
                 PARSE_JSON(TO_VARCHAR(AI_PARSE_DOCUMENT(
                     TO_FILE('@ACCEL_DB.KNOWLEDGE.POLICY_DOCS_STAGE', f.RELATIVE_PATH),
                     {'mode': 'LAYOUT'}
                 ))):content::VARCHAR AS CONTENT
          FROM DIRECTORY(@ACCEL_DB.KNOWLEDGE.POLICY_DOCS_STAGE) f
          WHERE LOWER(f.RELATIVE_PATH) LIKE '%.pdf'
            AND f.RELATIVE_PATH NOT IN (SELECT DISTINCT DOC_NAME FROM ACCEL_DB.KNOWLEDGE.DOC_CHUNKS WHERE SOURCE = 'UPLOAD')
      ) d
      WHERE d.CONTENT IS NOT NULL
  ) p,
  LATERAL FLATTEN(input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
      p.CONTENT,
      'markdown',
      1500,     -- EDIT ME: chunk size (characters)
      200       -- EDIT ME: overlap (characters)
  )) c;

  n_chunks := SQLROWCOUNT;
  RETURN 'Inserted ' || n_chunks || ' chunks from new PDFs';
END;
$$;

-- Ingest any PDFs already uploaded (returns "Inserted 0 chunks" if none)
CALL INGEST_POLICY_DOCS();

GRANT USAGE ON SCHEMA ACCEL_DB.KNOWLEDGE TO ROLE ACCEL_ANALYST;
GRANT SELECT ON TABLE ACCEL_DB.KNOWLEDGE.DOC_CHUNKS TO ROLE ACCEL_ANALYST;

SELECT SOURCE, CATEGORY, COUNT(*) AS CHUNKS FROM DOC_CHUNKS GROUP BY 1, 2 ORDER BY 1, 2;
