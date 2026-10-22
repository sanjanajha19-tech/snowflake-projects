/* =============================================================================
   04 INGESTION FRAMEWORK | 06_external_stage_templates.sql
   TEMPLATES ONLY - everything below is commented out. Uncomment the block for
   your cloud, fill in the -- EDIT ME values, and run it.
   Storage integrations need ACCOUNTADMIN (or a role with CREATE INTEGRATION)
   because they are account-level objects that hold cloud trust settings.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS INGEST;
USE SCHEMA INGEST;

/* ---------------------------------------------------------------------------
   A. AMAZON S3
--------------------------------------------------------------------------- */
-- USE ROLE ACCOUNTADMIN;   -- integrations are account-level objects
-- CREATE STORAGE INTEGRATION IF NOT EXISTS ACCEL_S3_INT
--   TYPE = EXTERNAL_STAGE
--   STORAGE_PROVIDER = 'S3'
--   ENABLED = TRUE
--   STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/snowflake-accel-role'   -- EDIT ME
--   STORAGE_ALLOWED_LOCATIONS = ('s3://my-company-landing/accel/');               -- EDIT ME
-- GRANT USAGE ON INTEGRATION ACCEL_S3_INT TO ROLE ACCEL_ADMIN;
-- DESC INTEGRATION ACCEL_S3_INT;   -- copy STORAGE_AWS_IAM_USER_ARN + STORAGE_AWS_EXTERNAL_ID into the IAM role trust policy
--
-- USE ROLE ACCEL_ADMIN;
-- CREATE STAGE IF NOT EXISTS ACCEL_DB.INGEST.LANDING_S3
--   STORAGE_INTEGRATION = ACCEL_S3_INT
--   URL = 's3://my-company-landing/accel/'                                        -- EDIT ME
--   DIRECTORY = (ENABLE = TRUE);
--
-- -- Event-driven Snowpipe (S3 -> SQS). After creating, run SHOW PIPES and point the
-- -- bucket's event notification at the pipe's notification_channel (SQS ARN).
-- CREATE OR REPLACE PIPE ACCEL_DB.INGEST.PIPE_ORDERS_S3
--   AUTO_INGEST = TRUE
-- AS
-- COPY INTO ACCEL_DB.INGEST.RAW_ORDERS_PIPE (ORDER_ID, ORDER_DATE, CUSTOMER_ID, PLANT_ID, CHANNEL, STATUS,
--                                            CURRENCY, ORDER_TOTAL, _FILE_NAME, _FILE_ROW, _LOADED_AT)
-- FROM (SELECT $1:ORDER_ID::NUMBER, $1:ORDER_DATE::DATE, $1:CUSTOMER_ID::NUMBER, $1:PLANT_ID::NUMBER,
--              $1:CHANNEL::VARCHAR, $1:STATUS::VARCHAR, $1:CURRENCY::VARCHAR, $1:ORDER_TOTAL::NUMBER(14,2),
--              METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME
--       FROM @ACCEL_DB.INGEST.LANDING_S3/orders/)
-- FILE_FORMAT = (FORMAT_NAME = 'ACCEL_DB.INGEST.FF_JSON');
-- SHOW PIPES LIKE 'PIPE_ORDERS_S3' IN SCHEMA ACCEL_DB.INGEST;

/* ---------------------------------------------------------------------------
   B. AZURE BLOB / ADLS GEN2
--------------------------------------------------------------------------- */
-- USE ROLE ACCOUNTADMIN;
-- CREATE STORAGE INTEGRATION IF NOT EXISTS ACCEL_AZURE_INT
--   TYPE = EXTERNAL_STAGE
--   STORAGE_PROVIDER = 'AZURE'
--   ENABLED = TRUE
--   AZURE_TENANT_ID = '00000000-0000-0000-0000-000000000000'                      -- EDIT ME
--   STORAGE_ALLOWED_LOCATIONS = ('azure://myaccount.blob.core.windows.net/landing/accel/');  -- EDIT ME
-- GRANT USAGE ON INTEGRATION ACCEL_AZURE_INT TO ROLE ACCEL_ADMIN;
-- DESC INTEGRATION ACCEL_AZURE_INT;   -- open AZURE_CONSENT_URL, then grant the app Storage Blob Data Reader
--
-- -- Auto-ingest on Azure needs an Event Grid -> Storage Queue notification integration:
-- CREATE NOTIFICATION INTEGRATION IF NOT EXISTS ACCEL_AZURE_EVENTS_INT
--   ENABLED = TRUE
--   TYPE = QUEUE
--   NOTIFICATION_PROVIDER = AZURE_STORAGE_QUEUE
--   AZURE_STORAGE_QUEUE_PRIMARY_URI = 'https://myaccount.queue.core.windows.net/snowpipe-queue'  -- EDIT ME
--   AZURE_TENANT_ID = '00000000-0000-0000-0000-000000000000';                     -- EDIT ME
-- GRANT USAGE ON INTEGRATION ACCEL_AZURE_EVENTS_INT TO ROLE ACCEL_ADMIN;
--
-- USE ROLE ACCEL_ADMIN;
-- CREATE STAGE IF NOT EXISTS ACCEL_DB.INGEST.LANDING_AZURE
--   STORAGE_INTEGRATION = ACCEL_AZURE_INT
--   URL = 'azure://myaccount.blob.core.windows.net/landing/accel/'                -- EDIT ME
--   DIRECTORY = (ENABLE = TRUE);
-- CREATE OR REPLACE PIPE ACCEL_DB.INGEST.PIPE_ORDERS_AZURE
--   AUTO_INGEST = TRUE
--   INTEGRATION = 'ACCEL_AZURE_EVENTS_INT'
-- AS
-- COPY INTO ACCEL_DB.INGEST.RAW_ORDERS_PIPE (ORDER_ID, ORDER_DATE, CUSTOMER_ID, PLANT_ID, CHANNEL, STATUS,
--                                            CURRENCY, ORDER_TOTAL, _FILE_NAME, _FILE_ROW, _LOADED_AT)
-- FROM (SELECT $1:ORDER_ID::NUMBER, $1:ORDER_DATE::DATE, $1:CUSTOMER_ID::NUMBER, $1:PLANT_ID::NUMBER,
--              $1:CHANNEL::VARCHAR, $1:STATUS::VARCHAR, $1:CURRENCY::VARCHAR, $1:ORDER_TOTAL::NUMBER(14,2),
--              METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME
--       FROM @ACCEL_DB.INGEST.LANDING_AZURE/orders/)
-- FILE_FORMAT = (FORMAT_NAME = 'ACCEL_DB.INGEST.FF_JSON');

/* ---------------------------------------------------------------------------
   C. GOOGLE CLOUD STORAGE
--------------------------------------------------------------------------- */
-- USE ROLE ACCOUNTADMIN;
-- CREATE STORAGE INTEGRATION IF NOT EXISTS ACCEL_GCS_INT
--   TYPE = EXTERNAL_STAGE
--   STORAGE_PROVIDER = 'GCS'
--   ENABLED = TRUE
--   STORAGE_ALLOWED_LOCATIONS = ('gcs://my-company-landing/accel/');              -- EDIT ME
-- GRANT USAGE ON INTEGRATION ACCEL_GCS_INT TO ROLE ACCEL_ADMIN;
-- DESC INTEGRATION ACCEL_GCS_INT;   -- grant STORAGE_GCP_SERVICE_ACCOUNT access to the bucket
--
-- -- Auto-ingest on GCS needs a Pub/Sub notification integration:
-- CREATE NOTIFICATION INTEGRATION IF NOT EXISTS ACCEL_GCS_EVENTS_INT
--   TYPE = QUEUE
--   NOTIFICATION_PROVIDER = GCP_PUBSUB
--   ENABLED = TRUE
--   GCP_PUBSUB_SUBSCRIPTION_NAME = 'projects/my-project/subscriptions/snowpipe-sub';  -- EDIT ME
-- GRANT USAGE ON INTEGRATION ACCEL_GCS_EVENTS_INT TO ROLE ACCEL_ADMIN;
--
-- USE ROLE ACCEL_ADMIN;
-- CREATE STAGE IF NOT EXISTS ACCEL_DB.INGEST.LANDING_GCS
--   STORAGE_INTEGRATION = ACCEL_GCS_INT
--   URL = 'gcs://my-company-landing/accel/'                                       -- EDIT ME
--   DIRECTORY = (ENABLE = TRUE);
-- CREATE OR REPLACE PIPE ACCEL_DB.INGEST.PIPE_ORDERS_GCS
--   AUTO_INGEST = TRUE
--   INTEGRATION = 'ACCEL_GCS_EVENTS_INT'
-- AS
-- COPY INTO ACCEL_DB.INGEST.RAW_ORDERS_PIPE (ORDER_ID, ORDER_DATE, CUSTOMER_ID, PLANT_ID, CHANNEL, STATUS,
--                                            CURRENCY, ORDER_TOTAL, _FILE_NAME, _FILE_ROW, _LOADED_AT)
-- FROM (SELECT $1:ORDER_ID::NUMBER, $1:ORDER_DATE::DATE, $1:CUSTOMER_ID::NUMBER, $1:PLANT_ID::NUMBER,
--              $1:CHANNEL::VARCHAR, $1:STATUS::VARCHAR, $1:CURRENCY::VARCHAR, $1:ORDER_TOTAL::NUMBER(14,2),
--              METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME
--       FROM @ACCEL_DB.INGEST.LANDING_GCS/orders/)
-- FILE_FORMAT = (FORMAT_NAME = 'ACCEL_DB.INGEST.FF_JSON');

/* ---------------------------------------------------------------------------
   D. Point the framework at an external stage: just change STAGE_PATH.
--------------------------------------------------------------------------- */
-- UPDATE ACCEL_DB.INGEST.INGESTION_CONFIG
--    SET STAGE_PATH = '@ACCEL_DB.INGEST.LANDING_S3/customers/', UPDATED_AT = CURRENT_TIMESTAMP()
--  WHERE SOURCE_NAME = 'DEMO_CUSTOMERS_CSV';

SELECT 'Templates only - uncomment the block for your cloud' AS NOTE;
