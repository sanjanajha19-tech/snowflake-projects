/*=============================================================================
  ASSET 12 - Document Intelligence
  File 02   : PROCESS_NEW_DOCUMENTS() procedure + DOC_PROCESSING_TASK
              1. refresh directory table, read DOCS_STREAM into DOC_FILE_QUEUE
              2. AI_PARSE_DOCUMENT (LAYOUT) -> PARSED_DOCUMENTS
              3. classify unknown files with AI_CLASSIFY
              4. AI_EXTRACT invoice fields + line-item table -> INVOICE_*
              5. AI_EXTRACT contract fields -> CONTRACTS
  Run as    : ACCEL_ADMIN (has EXECUTE TASK from 00_setup)
  Rerun     : safe (CREATE OR REPLACE)
  Cost      : AI_PARSE_DOCUMENT is billed per page, AI_EXTRACT per token.
              The task only starts the warehouse when the stream has data.
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS DOC_INTEL;
USE SCHEMA DOC_INTEL;

CREATE OR REPLACE PROCEDURE PROCESS_NEW_DOCUMENTS()
  RETURNS VARCHAR
  LANGUAGE SQL
  EXECUTE AS OWNER
  COMMENT = 'Parses and extracts newly uploaded invoices and contracts (ACCEL asset 12)'
AS
$$
DECLARE
  n_pending   NUMBER DEFAULT 0;
  n_invoices  NUMBER DEFAULT 0;
  n_contracts NUMBER DEFAULT 0;
  n_errors    NUMBER DEFAULT 0;
BEGIN
  -- 1a. Make sure the directory table (and therefore the stream) sees new uploads
  ALTER STAGE ACCEL_DB.DOC_INTEL.DOCS_STAGE REFRESH;

  -- 1b. Consume the stream into the queue (re-uploads of the same path are re-queued)
  MERGE INTO ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE q
  USING (
      SELECT RELATIVE_PATH,
             SIZE          AS FILE_SIZE,
             LAST_MODIFIED,
             CASE
               WHEN STARTSWITH(LOWER(RELATIVE_PATH), 'invoices/')  THEN 'INVOICE'
               WHEN STARTSWITH(LOWER(RELATIVE_PATH), 'contracts/') THEN 'CONTRACT'
               ELSE NULL
             END           AS DOC_TYPE
      FROM ACCEL_DB.DOC_INTEL.DOCS_STREAM
      WHERE METADATA$ACTION = 'INSERT'
        AND LOWER(RELATIVE_PATH) LIKE '%.pdf'
      QUALIFY ROW_NUMBER() OVER (PARTITION BY RELATIVE_PATH ORDER BY LAST_MODIFIED DESC) = 1
  ) s
  ON q.RELATIVE_PATH = s.RELATIVE_PATH
  WHEN MATCHED THEN UPDATE SET
       q.DOC_TYPE = s.DOC_TYPE, q.FILE_SIZE = s.FILE_SIZE, q.LAST_MODIFIED = s.LAST_MODIFIED,
       q.STATUS = 'PENDING', q.QUEUED_AT = CURRENT_TIMESTAMP(), q.PROCESSED_AT = NULL, q.ERROR_MESSAGE = NULL
  WHEN NOT MATCHED THEN INSERT (RELATIVE_PATH, DOC_TYPE, FILE_SIZE, LAST_MODIFIED, STATUS)
       VALUES (s.RELATIVE_PATH, s.DOC_TYPE, s.FILE_SIZE, s.LAST_MODIFIED, 'PENDING');

  SELECT COUNT(*) INTO :n_pending FROM ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE WHERE STATUS = 'PENDING';
  IF (n_pending = 0) THEN
    RETURN 'No pending documents';
  END IF;

  -- Remove earlier results for files being (re)processed
  DELETE FROM ACCEL_DB.DOC_INTEL.PARSED_DOCUMENTS     WHERE RELATIVE_PATH IN (SELECT RELATIVE_PATH FROM ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE WHERE STATUS = 'PENDING');
  DELETE FROM ACCEL_DB.DOC_INTEL.INVOICE_EXTRACT_RAW  WHERE RELATIVE_PATH IN (SELECT RELATIVE_PATH FROM ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE WHERE STATUS = 'PENDING');
  DELETE FROM ACCEL_DB.DOC_INTEL.INVOICE_HEADER       WHERE RELATIVE_PATH IN (SELECT RELATIVE_PATH FROM ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE WHERE STATUS = 'PENDING');
  DELETE FROM ACCEL_DB.DOC_INTEL.INVOICE_LINES        WHERE RELATIVE_PATH IN (SELECT RELATIVE_PATH FROM ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE WHERE STATUS = 'PENDING');
  DELETE FROM ACCEL_DB.DOC_INTEL.CONTRACT_EXTRACT_RAW WHERE RELATIVE_PATH IN (SELECT RELATIVE_PATH FROM ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE WHERE STATUS = 'PENDING');
  DELETE FROM ACCEL_DB.DOC_INTEL.CONTRACTS            WHERE RELATIVE_PATH IN (SELECT RELATIVE_PATH FROM ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE WHERE STATUS = 'PENDING');

  -- 2. Parse text + layout (tables come back as markdown in LAYOUT mode)
  INSERT INTO ACCEL_DB.DOC_INTEL.PARSED_DOCUMENTS (RELATIVE_PATH, DOC_TYPE, CONTENT, PARSE_RESULT)
  SELECT p.RELATIVE_PATH, p.DOC_TYPE, p.R:content::VARCHAR, p.R
  FROM (
      SELECT q.RELATIVE_PATH,
             q.DOC_TYPE,
             -- AI_PARSE_DOCUMENT returns JSON text; PARSE_JSON(TO_VARCHAR()) gives a VARIANT
             PARSE_JSON(TO_VARCHAR(AI_PARSE_DOCUMENT(
                 TO_FILE('@ACCEL_DB.DOC_INTEL.DOCS_STAGE', q.RELATIVE_PATH),
                 {'mode': 'LAYOUT'}
             ))) AS R
      FROM ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE q
      WHERE q.STATUS = 'PENDING'
  ) p;

  -- 3. Files outside invoices/ and contracts/: classify from their text
  UPDATE ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE q
     SET DOC_TYPE = UPPER(c.LABEL)
    FROM (
      SELECT RELATIVE_PATH,
             PARSE_JSON(TO_VARCHAR(AI_CLASSIFY(LEFT(CONTENT, 6000), ['invoice', 'contract', 'other']))):labels[0]::VARCHAR AS LABEL
      FROM ACCEL_DB.DOC_INTEL.PARSED_DOCUMENTS
      WHERE DOC_TYPE IS NULL AND CONTENT IS NOT NULL
    ) c
   WHERE q.RELATIVE_PATH = c.RELATIVE_PATH
     AND q.STATUS = 'PENDING';

  UPDATE ACCEL_DB.DOC_INTEL.PARSED_DOCUMENTS d
     SET DOC_TYPE = q.DOC_TYPE
    FROM ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE q
   WHERE d.RELATIVE_PATH = q.RELATIVE_PATH AND d.DOC_TYPE IS NULL;

  -- 4. Invoices: entities + line-item table in one AI_EXTRACT call
  INSERT INTO ACCEL_DB.DOC_INTEL.INVOICE_EXTRACT_RAW (RELATIVE_PATH, EXTRACT_RESULT)
  SELECT q.RELATIVE_PATH,
         PARSE_JSON(TO_VARCHAR(AI_EXTRACT(
           file => TO_FILE('@ACCEL_DB.DOC_INTEL.DOCS_STAGE', q.RELATIVE_PATH),
           responseFormat => {
             'schema': {
               'type': 'object',
               'properties': {
                 'invoice_number': {'description': 'Invoice number', 'type': 'string'},
                 'invoice_date':   {'description': 'Invoice date in YYYY-MM-DD format', 'type': 'string'},
                 'due_date':       {'description': 'Payment due date in YYYY-MM-DD format', 'type': 'string'},
                 'vendor_name':    {'description': 'Name of the company that issued the invoice (seller)', 'type': 'string'},
                 'vendor_gstin':   {'description': 'GSTIN (15 character GST number) of the seller', 'type': 'string'},
                 'buyer_name':     {'description': 'Name of the bill-to company (buyer)', 'type': 'string'},
                 'buyer_gstin':    {'description': 'GSTIN of the bill-to company (buyer)', 'type': 'string'},
                 'po_number':      {'description': 'Purchase order number referenced on the invoice', 'type': 'string'},
                 'currency':       {'description': 'Currency code, for example INR', 'type': 'string'},
                 'subtotal':       {'description': 'Subtotal before tax as a plain number', 'type': 'string'},
                 'tax_amount':     {'description': 'Total tax amount (GST, IGST or CGST plus SGST) as a plain number', 'type': 'string'},
                 'total_amount':   {'description': 'Total amount due including tax as a plain number', 'type': 'string'},
                 'line_items': {
                   'description': 'Invoice line items table',
                   'type': 'object',
                   'column_ordering': ['description', 'quantity', 'unit_price', 'line_total'],
                   'properties': {
                     'description': {'description': 'Item description', 'type': 'array'},
                     'quantity':    {'description': 'Quantity', 'type': 'array'},
                     'unit_price':  {'description': 'Unit price', 'type': 'array'},
                     'line_total':  {'description': 'Line total amount', 'type': 'array'}
                   }
                 }
               }
             }
           }
         )))
  FROM ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE q
  WHERE q.STATUS = 'PENDING' AND q.DOC_TYPE = 'INVOICE';

  INSERT INTO ACCEL_DB.DOC_INTEL.INVOICE_HEADER
    (RELATIVE_PATH, INVOICE_NO, INVOICE_DATE, DUE_DATE, VENDOR_NAME, VENDOR_GSTIN, BUYER_NAME, BUYER_GSTIN,
     PO_NUMBER, CURRENCY, SUBTOTAL, TAX_AMOUNT, TOTAL_AMOUNT, EXTRACT_ERROR)
  SELECT r.RELATIVE_PATH,
         NULLIF(TRIM(r.EXTRACT_RESULT:response:invoice_number::VARCHAR), ''),
         TRY_TO_DATE(r.EXTRACT_RESULT:response:invoice_date::VARCHAR),
         TRY_TO_DATE(r.EXTRACT_RESULT:response:due_date::VARCHAR),
         NULLIF(TRIM(r.EXTRACT_RESULT:response:vendor_name::VARCHAR), ''),
         NULLIF(UPPER(REPLACE(r.EXTRACT_RESULT:response:vendor_gstin::VARCHAR, ' ', '')), ''),
         NULLIF(TRIM(r.EXTRACT_RESULT:response:buyer_name::VARCHAR), ''),
         NULLIF(UPPER(REPLACE(r.EXTRACT_RESULT:response:buyer_gstin::VARCHAR, ' ', '')), ''),
         NULLIF(TRIM(r.EXTRACT_RESULT:response:po_number::VARCHAR), ''),
         NULLIF(TRIM(r.EXTRACT_RESULT:response:currency::VARCHAR), ''),
         TRY_TO_NUMBER(REGEXP_REPLACE(r.EXTRACT_RESULT:response:subtotal::VARCHAR,     '[^0-9.-]', ''), 18, 2),
         TRY_TO_NUMBER(REGEXP_REPLACE(r.EXTRACT_RESULT:response:tax_amount::VARCHAR,   '[^0-9.-]', ''), 18, 2),
         TRY_TO_NUMBER(REGEXP_REPLACE(r.EXTRACT_RESULT:response:total_amount::VARCHAR, '[^0-9.-]', ''), 18, 2),
         r.EXTRACT_RESULT:error::VARCHAR
  FROM ACCEL_DB.DOC_INTEL.INVOICE_EXTRACT_RAW r
  JOIN ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE q
    ON q.RELATIVE_PATH = r.RELATIVE_PATH AND q.STATUS = 'PENDING';

  INSERT INTO ACCEL_DB.DOC_INTEL.INVOICE_LINES
    (RELATIVE_PATH, INVOICE_NO, LINE_NO, DESCRIPTION, QUANTITY, UNIT_PRICE, LINE_TOTAL)
  SELECT r.RELATIVE_PATH,
         NULLIF(TRIM(r.EXTRACT_RESULT:response:invoice_number::VARCHAR), ''),
         f.INDEX + 1,
         f.VALUE::VARCHAR,
         TRY_TO_NUMBER(REGEXP_REPLACE(r.EXTRACT_RESULT:response:line_items:quantity[f.INDEX]::VARCHAR,   '[^0-9.-]', ''), 18, 4),
         TRY_TO_NUMBER(REGEXP_REPLACE(r.EXTRACT_RESULT:response:line_items:unit_price[f.INDEX]::VARCHAR, '[^0-9.-]', ''), 18, 4),
         TRY_TO_NUMBER(REGEXP_REPLACE(r.EXTRACT_RESULT:response:line_items:line_total[f.INDEX]::VARCHAR, '[^0-9.-]', ''), 18, 2)
  FROM ACCEL_DB.DOC_INTEL.INVOICE_EXTRACT_RAW r
  JOIN ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE q
    ON q.RELATIVE_PATH = r.RELATIVE_PATH AND q.STATUS = 'PENDING',
  LATERAL FLATTEN(input => r.EXTRACT_RESULT:response:line_items:description) f;

  -- 5. Contracts: key commercial terms
  INSERT INTO ACCEL_DB.DOC_INTEL.CONTRACT_EXTRACT_RAW (RELATIVE_PATH, EXTRACT_RESULT)
  SELECT q.RELATIVE_PATH,
         PARSE_JSON(TO_VARCHAR(AI_EXTRACT(
           file => TO_FILE('@ACCEL_DB.DOC_INTEL.DOCS_STAGE', q.RELATIVE_PATH),
           responseFormat => {
             'contract_number':         'What is the agreement or contract number?',
             'contract_type':           'What type of agreement is this (for example Master Services Agreement, Supply Agreement)?',
             'party_1':                 'What is the company name of the first party to the agreement? Company name only.',
             'party_2':                 'What is the company name of the second party to the agreement? Company name only.',
             'effective_date':          'What is the effective date of the agreement? Answer in YYYY-MM-DD format.',
             'term':                    'What is the term or duration of the agreement, including any renewal terms?',
             'term_months':             'How many months is the initial term? Answer with a number only.',
             'auto_renewal':            'Does the agreement renew automatically? Answer Yes or No.',
             'termination_clause':      'Summarise the termination clause in one or two sentences.',
             'termination_notice_days': 'How many days of written notice are required to terminate for convenience? Answer with a number only.',
             'liability_cap':           'What is the limitation of liability or liability cap?',
             'liability_cap_amount':    'What is the maximum liability cap amount as a plain number without currency symbols or commas?',
             'governing_law':           'Which law governs the agreement and where are disputes resolved?'
           }
         )))
  FROM ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE q
  WHERE q.STATUS = 'PENDING' AND q.DOC_TYPE = 'CONTRACT';

  INSERT INTO ACCEL_DB.DOC_INTEL.CONTRACTS
    (RELATIVE_PATH, CONTRACT_NUMBER, CONTRACT_TYPE, PARTY_1, PARTY_2, EFFECTIVE_DATE, TERM_TEXT, TERM_MONTHS,
     AUTO_RENEWAL, TERMINATION_CLAUSE, TERMINATION_NOTICE_DAYS, LIABILITY_CAP_TEXT, LIABILITY_CAP_AMOUNT,
     GOVERNING_LAW, END_DATE, EXTRACT_ERROR)
  SELECT x.RELATIVE_PATH, x.CONTRACT_NUMBER, x.CONTRACT_TYPE, x.PARTY_1, x.PARTY_2, x.EFFECTIVE_DATE,
         x.TERM_TEXT, x.TERM_MONTHS, x.AUTO_RENEWAL, x.TERMINATION_CLAUSE, x.TERMINATION_NOTICE_DAYS,
         x.LIABILITY_CAP_TEXT, x.LIABILITY_CAP_AMOUNT, x.GOVERNING_LAW,
         IFF(x.EFFECTIVE_DATE IS NOT NULL AND x.TERM_MONTHS IS NOT NULL,
             DATEADD('day', -1, DATEADD('month', x.TERM_MONTHS, x.EFFECTIVE_DATE)), NULL),
         x.EXTRACT_ERROR
  FROM (
    SELECT r.RELATIVE_PATH,
           NULLIF(TRIM(r.EXTRACT_RESULT:response:contract_number::VARCHAR), '')                      AS CONTRACT_NUMBER,
           NULLIF(TRIM(r.EXTRACT_RESULT:response:contract_type::VARCHAR), '')                        AS CONTRACT_TYPE,
           NULLIF(TRIM(r.EXTRACT_RESULT:response:party_1::VARCHAR), '')                              AS PARTY_1,
           NULLIF(TRIM(r.EXTRACT_RESULT:response:party_2::VARCHAR), '')                              AS PARTY_2,
           TRY_TO_DATE(r.EXTRACT_RESULT:response:effective_date::VARCHAR)                            AS EFFECTIVE_DATE,
           NULLIF(TRIM(r.EXTRACT_RESULT:response:term::VARCHAR), '')                                 AS TERM_TEXT,
           TRY_TO_NUMBER(REGEXP_REPLACE(r.EXTRACT_RESULT:response:term_months::VARCHAR, '[^0-9]', '')) AS TERM_MONTHS,
           NULLIF(TRIM(r.EXTRACT_RESULT:response:auto_renewal::VARCHAR), '')                         AS AUTO_RENEWAL,
           NULLIF(TRIM(r.EXTRACT_RESULT:response:termination_clause::VARCHAR), '')                   AS TERMINATION_CLAUSE,
           TRY_TO_NUMBER(REGEXP_REPLACE(r.EXTRACT_RESULT:response:termination_notice_days::VARCHAR, '[^0-9]', '')) AS TERMINATION_NOTICE_DAYS,
           NULLIF(TRIM(r.EXTRACT_RESULT:response:liability_cap::VARCHAR), '')                        AS LIABILITY_CAP_TEXT,
           TRY_TO_NUMBER(REGEXP_REPLACE(r.EXTRACT_RESULT:response:liability_cap_amount::VARCHAR, '[^0-9.]', ''), 18, 2) AS LIABILITY_CAP_AMOUNT,
           NULLIF(TRIM(r.EXTRACT_RESULT:response:governing_law::VARCHAR), '')                        AS GOVERNING_LAW,
           r.EXTRACT_RESULT:error::VARCHAR                                                           AS EXTRACT_ERROR
    FROM ACCEL_DB.DOC_INTEL.CONTRACT_EXTRACT_RAW r
    JOIN ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE q
      ON q.RELATIVE_PATH = r.RELATIVE_PATH AND q.STATUS = 'PENDING'
  ) x;

  -- 6. Close out the queue
  UPDATE ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE q
     SET STATUS = IFF(p.CONTENT IS NULL, 'ERROR', 'PROCESSED'),
         ERROR_MESSAGE = IFF(p.CONTENT IS NULL, 'AI_PARSE_DOCUMENT returned no content', NULL),
         PROCESSED_AT = CURRENT_TIMESTAMP()
    FROM ACCEL_DB.DOC_INTEL.PARSED_DOCUMENTS p
   WHERE q.RELATIVE_PATH = p.RELATIVE_PATH
     AND q.STATUS = 'PENDING';

  UPDATE ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE
     SET STATUS = 'ERROR', ERROR_MESSAGE = 'Not parsed', PROCESSED_AT = CURRENT_TIMESTAMP()
   WHERE STATUS = 'PENDING';

  SELECT COUNT_IF(DOC_TYPE = 'INVOICE' AND STATUS = 'PROCESSED'),
         COUNT_IF(DOC_TYPE = 'CONTRACT' AND STATUS = 'PROCESSED'),
         COUNT_IF(STATUS = 'ERROR')
    INTO :n_invoices, :n_contracts, :n_errors
    FROM ACCEL_DB.DOC_INTEL.DOC_FILE_QUEUE
   WHERE PROCESSED_AT >= DATEADD('minute', -60, CURRENT_TIMESTAMP());

  RETURN 'Pending: ' || n_pending || ' | invoices processed (last hour): ' || n_invoices ||
         ' | contracts processed (last hour): ' || n_contracts || ' | errors (last hour): ' || n_errors;
END;
$$;

------------------------------------------------------------------------------
-- Task: runs every 5 minutes but ONLY when the stream has new files
-- (the WHEN check does not start the warehouse).
-- Note: the stream sees files once the directory table is refreshed; run
-- ALTER STAGE DOCS_STAGE REFRESH after an upload (see 03_upload_and_run.sql).
------------------------------------------------------------------------------
CREATE OR REPLACE TASK DOC_PROCESSING_TASK
  WAREHOUSE = ACCEL_AI_WH
  SCHEDULE = '5 MINUTE'                                   -- EDIT ME
  COMMENT = 'Processes new documents in DOCS_STAGE (ACCEL asset 12)'
  WHEN SYSTEM$STREAM_HAS_DATA('ACCEL_DB.DOC_INTEL.DOCS_STREAM')
AS
  CALL ACCEL_DB.DOC_INTEL.PROCESS_NEW_DOCUMENTS();

ALTER TASK DOC_PROCESSING_TASK RESUME;

SHOW TASKS LIKE 'DOC_PROCESSING_TASK';
