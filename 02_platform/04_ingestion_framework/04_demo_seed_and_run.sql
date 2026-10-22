/* =============================================================================
   04 INGESTION FRAMEWORK | 04_demo_seed_and_run.sql
   Demo without uploading anything: unloads ACCEL_DB.DEMO tables to the
   internal stage as CSV, JSON and Parquet, then runs the framework.
   Optional: upload sample_data/ files (instructions at the bottom).
   Run as: ACCEL_ADMIN.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS INGEST;
USE SCHEMA INGEST;

-- ---------------------------------------------------------------------------
-- 1. Generate "source system" files from DEMO tables (rerunnable: folders are cleared first)
-- ---------------------------------------------------------------------------
REMOVE @LANDING/demo/customers/;
COPY INTO @LANDING/demo/customers/customers_
  FROM (SELECT CUSTOMER_ID, CUSTOMER_NAME, SEGMENT, INDUSTRY, REGION, COUNTRY, CITY,
               EMAIL, PHONE, PAN_NUMBER, CREATED_DATE, CREDIT_LIMIT
        FROM ACCEL_DB.DEMO.CUSTOMERS)
  FILE_FORMAT = (TYPE = CSV COMPRESSION = NONE FIELD_OPTIONALLY_ENCLOSED_BY = '"')
  HEADER = TRUE
  OVERWRITE = TRUE;

REMOVE @LANDING/demo/orders/;
COPY INTO @LANDING/demo/orders/orders_
  FROM (SELECT OBJECT_CONSTRUCT(*) FROM ACCEL_DB.DEMO.ORDERS WHERE ORDER_ID <= 5000)
  FILE_FORMAT = (TYPE = JSON COMPRESSION = GZIP)
  OVERWRITE = TRUE;

REMOVE @LANDING/demo/products/;
COPY INTO @LANDING/demo/products/products_
  FROM (SELECT * FROM ACCEL_DB.DEMO.PRODUCTS)
  FILE_FORMAT = (TYPE = PARQUET)
  HEADER = TRUE
  OVERWRITE = TRUE;

LIST @LANDING/demo/;

-- Peek at a staged file before loading (schema-on-read)
SELECT * FROM TABLE(INFER_SCHEMA(LOCATION => '@ACCEL_DB.INGEST.LANDING/demo/customers/',
                                 FILE_FORMAT => 'ACCEL_DB.INGEST.FF_CSV'));

-- ---------------------------------------------------------------------------
-- 2. Run every active feed. Targets that don't exist are created from the files
--    (INFER_SCHEMA + USING TEMPLATE) or from the source table (LIKE).
-- ---------------------------------------------------------------------------
CALL ACCEL_DB.INGEST.RUN_INGESTION();

SELECT SOURCE_NAME, STATUS, TABLE_CREATED, FILES_PROCESSED, ROWS_LOADED, ROWS_INSERTED,
       ROWS_UPDATED, ERRORS_SEEN, FIRST_ERROR, DURATION_SEC
FROM INGESTION_AUDIT_LOG
ORDER BY START_TS DESC
LIMIT 20;

SELECT 'RAW_CUSTOMERS' AS T, COUNT(*) AS N FROM ACCEL_DB.INGEST.RAW_CUSTOMERS
UNION ALL SELECT 'RAW_ORDERS',    COUNT(*) FROM ACCEL_DB.INGEST.RAW_ORDERS
UNION ALL SELECT 'RAW_PRODUCTS',  COUNT(*) FROM ACCEL_DB.INGEST.RAW_PRODUCTS
UNION ALL SELECT 'RAW_SUPPLIERS', COUNT(*) FROM ACCEL_DB.INGEST.RAW_SUPPLIERS
UNION ALL SELECT 'RAW_PLANTS',    COUNT(*) FROM ACCEL_DB.INGEST.RAW_PLANTS;

-- ---------------------------------------------------------------------------
-- 3. Rerun to show idempotency: APPEND feeds report NO_FILES (COPY load metadata
--    skips files already loaded); MERGE/TRUNCATE_INSERT feeds update in place.
-- ---------------------------------------------------------------------------
CALL ACCEL_DB.INGEST.RUN_INGESTION();
SELECT SOURCE_NAME, STATUS, ROWS_LOADED, ROWS_INSERTED, ROWS_UPDATED
FROM ACCEL_DB.INGEST.V_INGESTION_LATEST ORDER BY SOURCE_NAME;

-- ---------------------------------------------------------------------------
-- 4. OPTIONAL: upload the files in sample_data/
--    a) Snowsight: Data > Add Data > Load files into a Stage > ACCEL_DB.INGEST.LANDING,
--       path 'upload/customers' for customers_delta.csv and 'upload/orders' for orders_feed.json
--    b) Snowflake CLI:
--       snow stage copy sample_data/customers_delta.csv @ACCEL_DB.INGEST.LANDING/upload/customers/ -c <connection>
--       snow stage copy sample_data/orders_feed.json    @ACCEL_DB.INGEST.LANDING/upload/orders/    -c <connection>
--    c) SnowSQL / any driver session:
--       PUT file:///path/to/sample_data/customers_delta.csv @ACCEL_DB.INGEST.LANDING/upload/customers/ AUTO_COMPRESS = TRUE;
--       PUT file:///path/to/sample_data/orders_feed.json    @ACCEL_DB.INGEST.LANDING/upload/orders/    AUTO_COMPRESS = TRUE;
--    Then:
-- CALL ACCEL_DB.INGEST.RUN_INGESTION('UPLOAD_CUSTOMERS_DELTA_CSV');   -- 5 updated + 5 inserted
-- CALL ACCEL_DB.INGEST.RUN_INGESTION('UPLOAD_ORDERS_FEED_JSON');      -- creates RAW_ORDERS_FEED from the JSON
-- SELECT * FROM ACCEL_DB.INGEST.RAW_CUSTOMERS WHERE CUSTOMER_ID IN (1,2,3,4,5,5001,5002,5003,5004,5005) ORDER BY 1;
-- ---------------------------------------------------------------------------
