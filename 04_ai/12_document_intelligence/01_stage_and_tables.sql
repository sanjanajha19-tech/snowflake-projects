/*=============================================================================
  ASSET 12 - Document Intelligence (invoices + contracts)
  File 01   : Stage, stream on the directory table, target tables
  Creates   : ACCEL_DB.DOC_INTEL.DOCS_STAGE (SNOWFLAKE_SSE, directory table)
              DOCS_STREAM, DOC_FILE_QUEUE, PARSED_DOCUMENTS,
              INVOICE_EXTRACT_RAW, INVOICE_HEADER, INVOICE_LINES,
              CONTRACT_EXTRACT_RAW, CONTRACTS
  Run as    : ACCEL_ADMIN
  Rerun     : stage + stream are IF NOT EXISTS (so uploaded files and the
              stream offset survive); tables are IF NOT EXISTS.
              To start clean: DROP SCHEMA ACCEL_DB.DOC_INTEL; then rerun.
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS DOC_INTEL COMMENT = 'Asset 12: document intelligence (AI_PARSE_DOCUMENT / AI_EXTRACT)';
USE SCHEMA DOC_INTEL;

------------------------------------------------------------------------------
-- 1. Internal stage. AI document functions need server-side encryption
--    (SNOWFLAKE_SSE); the directory table lists files for the stream.
------------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS DOCS_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Upload invoices to invoices/ and contracts to contracts/ (PDF)';

------------------------------------------------------------------------------
-- 2. Stream on the directory table - captures newly added / changed files
--    (after ALTER STAGE ... REFRESH or an upload that refreshes the directory)
------------------------------------------------------------------------------
CREATE STREAM IF NOT EXISTS DOCS_STREAM ON STAGE DOCS_STAGE
  COMMENT = 'New files landing in DOCS_STAGE';

------------------------------------------------------------------------------
-- 3. Processing queue + outputs
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DOC_FILE_QUEUE (
    RELATIVE_PATH   VARCHAR       NOT NULL PRIMARY KEY,
    DOC_TYPE        VARCHAR(20),               -- INVOICE / CONTRACT / OTHER
    FILE_SIZE       NUMBER,
    LAST_MODIFIED   TIMESTAMP_TZ,
    STATUS          VARCHAR(20)   NOT NULL,    -- PENDING / PROCESSED / ERROR
    QUEUED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PROCESSED_AT    TIMESTAMP_NTZ,
    ERROR_MESSAGE   VARCHAR
);

CREATE TABLE IF NOT EXISTS PARSED_DOCUMENTS (
    RELATIVE_PATH   VARCHAR       NOT NULL,
    DOC_TYPE        VARCHAR(20),
    CONTENT         VARCHAR,                   -- full text/markdown (LAYOUT mode)
    PARSE_RESULT    VARIANT,                   -- raw AI_PARSE_DOCUMENT output
    PARSED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS INVOICE_EXTRACT_RAW (
    RELATIVE_PATH   VARCHAR       NOT NULL,
    EXTRACT_RESULT  VARIANT,                   -- raw AI_EXTRACT output {response, error}
    EXTRACTED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS INVOICE_HEADER (
    RELATIVE_PATH   VARCHAR       NOT NULL,
    INVOICE_NO      VARCHAR,
    INVOICE_DATE    DATE,
    DUE_DATE        DATE,
    VENDOR_NAME     VARCHAR,
    VENDOR_GSTIN    VARCHAR,
    BUYER_NAME      VARCHAR,
    BUYER_GSTIN     VARCHAR,
    PO_NUMBER       VARCHAR,
    CURRENCY        VARCHAR,
    SUBTOTAL        NUMBER(18,2),
    TAX_AMOUNT      NUMBER(18,2),
    TOTAL_AMOUNT    NUMBER(18,2),
    EXTRACT_ERROR   VARCHAR,
    EXTRACTED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS INVOICE_LINES (
    RELATIVE_PATH   VARCHAR       NOT NULL,
    INVOICE_NO      VARCHAR,
    LINE_NO         NUMBER,
    DESCRIPTION     VARCHAR,
    QUANTITY        NUMBER(18,4),
    UNIT_PRICE      NUMBER(18,4),
    LINE_TOTAL      NUMBER(18,2)
);

CREATE TABLE IF NOT EXISTS CONTRACT_EXTRACT_RAW (
    RELATIVE_PATH   VARCHAR       NOT NULL,
    EXTRACT_RESULT  VARIANT,
    EXTRACTED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS CONTRACTS (
    RELATIVE_PATH            VARCHAR NOT NULL,
    CONTRACT_NUMBER          VARCHAR,
    CONTRACT_TYPE            VARCHAR,
    PARTY_1                  VARCHAR,
    PARTY_2                  VARCHAR,
    EFFECTIVE_DATE           DATE,
    TERM_TEXT                VARCHAR,
    TERM_MONTHS              NUMBER,
    AUTO_RENEWAL             VARCHAR,
    TERMINATION_CLAUSE       VARCHAR,
    TERMINATION_NOTICE_DAYS  NUMBER,
    LIABILITY_CAP_TEXT       VARCHAR,
    LIABILITY_CAP_AMOUNT     NUMBER(18,2),
    GOVERNING_LAW            VARCHAR,
    END_DATE                 DATE,
    EXTRACT_ERROR            VARCHAR,
    EXTRACTED_AT             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

GRANT USAGE ON SCHEMA ACCEL_DB.DOC_INTEL TO ROLE ACCEL_ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA ACCEL_DB.DOC_INTEL TO ROLE ACCEL_ANALYST;

SHOW STAGES LIKE 'DOCS_STAGE';
SHOW STREAMS LIKE 'DOCS_STREAM';
