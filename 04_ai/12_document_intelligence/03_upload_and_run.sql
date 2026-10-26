/*=============================================================================
  ASSET 12 - Document Intelligence
  File 03   : Upload sample documents, process them, inspect results
  Run as    : ACCEL_ADMIN
  Rerun     : safe

  STEP A - UPLOAD (UI step, do this first)
    Snowsight > Data > Databases > ACCEL_DB > DOC_INTEL > Stages > DOCS_STAGE
    > "+ Files" (top right):
      * select the 3 PDFs in sample_docs/invoices/   and set the path to: invoices
      * select the 2 PDFs in sample_docs/contracts/  and set the path to: contracts
    Or with Snow CLI / SnowSQL from the sample_docs folder:
      PUT file://invoices/*.pdf  @ACCEL_DB.DOC_INTEL.DOCS_STAGE/invoices/  AUTO_COMPRESS = FALSE;
      PUT file://contracts/*.pdf @ACCEL_DB.DOC_INTEL.DOCS_STAGE/contracts/ AUTO_COMPRESS = FALSE;
    (AUTO_COMPRESS = FALSE matters: AI functions cannot read .gz files.)

  STEP B - run this file top to bottom.
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_AI_WH;        -- document AI work runs on the AI warehouse
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS DOC_INTEL;
USE SCHEMA DOC_INTEL;

-- 1. Refresh the directory table so the stream sees the uploads
ALTER STAGE DOCS_STAGE REFRESH;

SELECT RELATIVE_PATH, SIZE, LAST_MODIFIED FROM DIRECTORY(@DOCS_STAGE) ORDER BY RELATIVE_PATH;
SELECT SYSTEM$STREAM_HAS_DATA('ACCEL_DB.DOC_INTEL.DOCS_STREAM') AS STREAM_HAS_NEW_FILES;

-- 2. Process now (the task would also pick them up within 5 minutes)
CALL PROCESS_NEW_DOCUMENTS();

-- Optional backfill: re-queue every PDF already on the stage (e.g. files that
-- were uploaded before the stream existed), then process again.
-- MERGE INTO DOC_FILE_QUEUE q
-- USING (SELECT RELATIVE_PATH, SIZE, LAST_MODIFIED,
--               CASE WHEN STARTSWITH(LOWER(RELATIVE_PATH), 'invoices/')  THEN 'INVOICE'
--                    WHEN STARTSWITH(LOWER(RELATIVE_PATH), 'contracts/') THEN 'CONTRACT' END AS DOC_TYPE
--        FROM DIRECTORY(@DOCS_STAGE) WHERE LOWER(RELATIVE_PATH) LIKE '%.pdf') s
-- ON q.RELATIVE_PATH = s.RELATIVE_PATH
-- WHEN MATCHED THEN UPDATE SET q.STATUS = 'PENDING', q.DOC_TYPE = s.DOC_TYPE
-- WHEN NOT MATCHED THEN INSERT (RELATIVE_PATH, DOC_TYPE, FILE_SIZE, LAST_MODIFIED, STATUS)
--   VALUES (s.RELATIVE_PATH, s.DOC_TYPE, s.SIZE, s.LAST_MODIFIED, 'PENDING');
-- CALL PROCESS_NEW_DOCUMENTS();

-- 3. Inspect results
SELECT RELATIVE_PATH, DOC_TYPE, STATUS, PROCESSED_AT, ERROR_MESSAGE FROM DOC_FILE_QUEUE ORDER BY RELATIVE_PATH;

SELECT RELATIVE_PATH, DOC_TYPE, LEFT(CONTENT, 500) AS CONTENT_PREVIEW FROM PARSED_DOCUMENTS ORDER BY RELATIVE_PATH;

SELECT INVOICE_NO, INVOICE_DATE, VENDOR_NAME, VENDOR_GSTIN, PO_NUMBER, SUBTOTAL, TAX_AMOUNT, TOTAL_AMOUNT
FROM INVOICE_HEADER ORDER BY INVOICE_DATE;

SELECT INVOICE_NO, LINE_NO, DESCRIPTION, QUANTITY, UNIT_PRICE, LINE_TOTAL
FROM INVOICE_LINES ORDER BY INVOICE_NO, LINE_NO;

SELECT CONTRACT_NUMBER, CONTRACT_TYPE, PARTY_1, PARTY_2, EFFECTIVE_DATE, TERM_MONTHS, END_DATE,
       TERMINATION_NOTICE_DAYS, LIABILITY_CAP_AMOUNT, TERMINATION_CLAUSE, LIABILITY_CAP_TEXT
FROM CONTRACTS ORDER BY EFFECTIVE_DATE;

-- Raw AI_EXTRACT output (useful when tuning questions)
SELECT RELATIVE_PATH, EXTRACT_RESULT FROM INVOICE_EXTRACT_RAW;

-- Task history
SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, RETURN_VALUE, ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'DOC_PROCESSING_TASK'))
ORDER BY SCHEDULED_TIME DESC
LIMIT 10;

-- After the demo you can stop the task:
-- ALTER TASK DOC_PROCESSING_TASK SUSPEND;
