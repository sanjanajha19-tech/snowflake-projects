/* =============================================================================
   04 INGESTION FRAMEWORK | 02_ingestion_config.sql
   Seeds the config table with demo feeds. MERGE makes it rerunnable.
   - DEMO_*   : files generated from ACCEL_DB.DEMO in 04_demo_seed_and_run.sql
                (works without uploading anything)
   - UPLOAD_* : files you PUT from sample_data/ (optional)
   - *_TABLE  : table-to-table feeds (no files at all)
   Run as: ACCEL_ADMIN.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS INGEST;
USE SCHEMA INGEST;

MERGE INTO INGESTION_CONFIG t
USING (
  SELECT * FROM VALUES
  -- SOURCE_NAME, SOURCE_TYPE, STAGE_PATH, FILE_PATTERN, FILE_FORMAT, SOURCE_OBJECT, TARGET_TABLE, LOAD_MODE, MERGE_KEYS, DEDUPE_ORDER_BY, ON_ERROR, SCHEDULE, ACTIVE_FLAG, OWNER_EMAIL, DESCRIPTION
  ('DEMO_CUSTOMERS_CSV',  'FILE',  '@ACCEL_DB.INGEST.LANDING/demo/customers/', '.*[.]csv.*',     'ACCEL_DB.INGEST.FF_CSV',     NULL, 'ACCEL_DB.INGEST.RAW_CUSTOMERS',   'MERGE',           'CUSTOMER_ID', NULL, 'CONTINUE', 'DAILY', TRUE,  'data.team@example.com', 'Customer master extract (CSV) upserted on CUSTOMER_ID'),
  ('DEMO_ORDERS_JSON',    'FILE',  '@ACCEL_DB.INGEST.LANDING/demo/orders/',    '.*[.]json.*',    'ACCEL_DB.INGEST.FF_JSON',    NULL, 'ACCEL_DB.INGEST.RAW_ORDERS',      'APPEND',          NULL,          NULL, 'CONTINUE', 'DAILY', TRUE,  'data.team@example.com', 'Order events (JSON) appended'),
  ('DEMO_PRODUCTS_PARQUET','FILE', '@ACCEL_DB.INGEST.LANDING/demo/products/',  '.*[.]parquet.*', 'ACCEL_DB.INGEST.FF_PARQUET', NULL, 'ACCEL_DB.INGEST.RAW_PRODUCTS',    'TRUNCATE_INSERT', NULL,          NULL, 'CONTINUE', 'DAILY', TRUE,  'data.team@example.com', 'Product catalogue snapshot (Parquet) fully replaced'),
  ('DEMO_SUPPLIERS_TABLE','TABLE', NULL, NULL, NULL, 'ACCEL_DB.DEMO.SUPPLIERS', 'ACCEL_DB.INGEST.RAW_SUPPLIERS',   'MERGE',           'SUPPLIER_ID', NULL, 'CONTINUE', 'DAILY', TRUE,  'data.team@example.com', 'Supplier master copied table-to-table'),
  ('DEMO_PLANTS_TABLE',   'TABLE', NULL, NULL, NULL, 'ACCEL_DB.DEMO.PLANTS',    'ACCEL_DB.INGEST.RAW_PLANTS',      'TRUNCATE_INSERT', NULL,          NULL, 'CONTINUE', 'DAILY', TRUE,  'data.team@example.com', 'Plant reference data copied table-to-table'),
  ('UPLOAD_CUSTOMERS_DELTA_CSV','FILE','@ACCEL_DB.INGEST.LANDING/upload/customers/', '.*[.]csv.*', 'ACCEL_DB.INGEST.FF_CSV', NULL, 'ACCEL_DB.INGEST.RAW_CUSTOMERS', 'MERGE', 'CUSTOMER_ID', NULL, 'CONTINUE', 'ADHOC', TRUE, 'data.team@example.com', 'sample_data/customers_delta.csv: 5 updates + 5 new customers'),
  ('UPLOAD_ORDERS_FEED_JSON',   'FILE','@ACCEL_DB.INGEST.LANDING/upload/orders/',    '.*[.]json.*','ACCEL_DB.INGEST.FF_JSON', NULL, 'ACCEL_DB.INGEST.RAW_ORDERS_FEED', 'APPEND', NULL, NULL, 'CONTINUE', 'ADHOC', TRUE, 'data.team@example.com', 'sample_data/orders_feed.json: new-table auto-creation via INFER_SCHEMA'),
  -- API feeds: an extractor (Openflow, External Access function, partner tool) lands JSON
  -- in the stage path; the framework then loads it exactly like a FILE feed.
  ('CRM_API_ACCOUNTS',    'API',   '@ACCEL_DB.INGEST.LANDING/api/crm_accounts/', '.*[.]json.*', 'ACCEL_DB.INGEST.FF_JSON', NULL, 'ACCEL_DB.INGEST.RAW_CRM_ACCOUNTS', 'MERGE', 'ACCOUNT_ID', NULL, 'CONTINUE', 'HOURLY', FALSE, 'crm.owner@example.com', 'Template: activate once an extractor lands files')
  AS s(SOURCE_NAME, SOURCE_TYPE, STAGE_PATH, FILE_PATTERN, FILE_FORMAT, SOURCE_OBJECT, TARGET_TABLE, LOAD_MODE, MERGE_KEYS, DEDUPE_ORDER_BY, ON_ERROR, SCHEDULE, ACTIVE_FLAG, OWNER_EMAIL, DESCRIPTION)
) s
ON t.SOURCE_NAME = s.SOURCE_NAME
WHEN MATCHED THEN UPDATE SET
  t.SOURCE_TYPE = s.SOURCE_TYPE, t.STAGE_PATH = s.STAGE_PATH, t.FILE_PATTERN = s.FILE_PATTERN,
  t.FILE_FORMAT = s.FILE_FORMAT, t.SOURCE_OBJECT = s.SOURCE_OBJECT, t.TARGET_TABLE = s.TARGET_TABLE,
  t.LOAD_MODE = s.LOAD_MODE, t.MERGE_KEYS = s.MERGE_KEYS, t.DEDUPE_ORDER_BY = s.DEDUPE_ORDER_BY,
  t.ON_ERROR = s.ON_ERROR, t.SCHEDULE = s.SCHEDULE, t.ACTIVE_FLAG = s.ACTIVE_FLAG,
  t.OWNER_EMAIL = s.OWNER_EMAIL, t.DESCRIPTION = s.DESCRIPTION, t.UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
  (SOURCE_NAME, SOURCE_TYPE, STAGE_PATH, FILE_PATTERN, FILE_FORMAT, SOURCE_OBJECT, TARGET_TABLE, LOAD_MODE,
   MERGE_KEYS, DEDUPE_ORDER_BY, ON_ERROR, SCHEDULE, ACTIVE_FLAG, OWNER_EMAIL, DESCRIPTION)
VALUES
  (s.SOURCE_NAME, s.SOURCE_TYPE, s.STAGE_PATH, s.FILE_PATTERN, s.FILE_FORMAT, s.SOURCE_OBJECT, s.TARGET_TABLE, s.LOAD_MODE,
   s.MERGE_KEYS, s.DEDUPE_ORDER_BY, s.ON_ERROR, s.SCHEDULE, s.ACTIVE_FLAG, s.OWNER_EMAIL, s.DESCRIPTION);

SELECT CONFIG_ID, SOURCE_NAME, SOURCE_TYPE, LOAD_MODE, TARGET_TABLE, SCHEDULE, ACTIVE_FLAG
FROM INGESTION_CONFIG ORDER BY CONFIG_ID;

-- To onboard a new feed: insert one row (no code change). Example:
-- INSERT INTO ACCEL_DB.INGEST.INGESTION_CONFIG
--   (SOURCE_NAME, SOURCE_TYPE, STAGE_PATH, FILE_PATTERN, FILE_FORMAT, TARGET_TABLE, LOAD_MODE, MERGE_KEYS, SCHEDULE)
-- VALUES ('ERP_INVOICES_CSV', 'FILE', '@ACCEL_DB.INGEST.LANDING/erp/invoices/', '.*[.]csv.*',
--         'ACCEL_DB.INGEST.FF_CSV', 'ACCEL_DB.INGEST.RAW_INVOICES', 'MERGE', 'INVOICE_ID', 'DAILY');
