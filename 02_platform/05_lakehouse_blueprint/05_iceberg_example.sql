/* =============================================================================
   05 LAKEHOUSE BLUEPRINT | 05_iceberg_example.sql
   OPTIONAL - Apache Iceberg table managed by Snowflake (Snowflake catalog).
   Why: data is stored as open Parquet + Iceberg metadata in YOUR cloud bucket,
   so Spark / Trino / Databricks / Fabric can read the same gold data that
   Snowflake writes (via Snowflake Horizon Catalog / Iceberg REST, or the
   metadata files directly), with no copy.
   Everything is commented: an external volume needs a bucket and a cloud IAM
   trust relationship. Fill the -- EDIT ME values, then uncomment and run.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS GOLD;
USE SCHEMA GOLD;

-- 1) External volume (ACCOUNTADMIN: account-level object holding cloud credentials/trust)
-- USE ROLE ACCOUNTADMIN;
-- CREATE EXTERNAL VOLUME IF NOT EXISTS ACCEL_ICEBERG_VOL
--   STORAGE_LOCATIONS = (
--     (
--       NAME = 'accel-iceberg-s3'
--       STORAGE_PROVIDER = 'S3'
--       STORAGE_BASE_URL = 's3://my-company-lakehouse/iceberg/'                          -- EDIT ME
--       STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/snowflake-iceberg-role'   -- EDIT ME
--     )
--   );
-- -- Azure: STORAGE_PROVIDER = 'AZURE', STORAGE_BASE_URL = 'azure://<acct>.blob.core.windows.net/<container>/iceberg/', AZURE_TENANT_ID = '<tenant>'
-- -- GCS:   STORAGE_PROVIDER = 'GCS',   STORAGE_BASE_URL = 'gcs://<bucket>/iceberg/'
-- DESC EXTERNAL VOLUME ACCEL_ICEBERG_VOL;      -- copy the IAM user ARN / external ID into the cloud trust policy
-- SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('ACCEL_ICEBERG_VOL');
-- GRANT USAGE ON EXTERNAL VOLUME ACCEL_ICEBERG_VOL TO ROLE ACCEL_ADMIN;
-- USE ROLE ACCEL_ADMIN;

-- 2) Snowflake-managed Iceberg table (Snowflake is the catalog; full DML supported)
-- CREATE OR REPLACE ICEBERG TABLE ACCEL_DB.GOLD.FACT_SALES_ICEBERG (
--   ORDER_LINE_SK   STRING,
--   ORDER_ID        NUMBER(38,0),
--   LINE_NO         NUMBER(10,0),
--   DATE_KEY        NUMBER(8,0),
--   ORDER_DATE      DATE,
--   CUSTOMER_SK     STRING,
--   PRODUCT_SK      STRING,
--   PLANT_SK        STRING,
--   CHANNEL         STRING,
--   ORDER_STATUS    STRING,
--   CURRENCY        STRING,
--   QUANTITY        NUMBER(12,0),
--   NET_AMOUNT      NUMBER(14,2),
--   COST_AMOUNT     NUMBER(14,2),
--   MARGIN_AMOUNT   NUMBER(14,2)
-- )
--   CATALOG = 'SNOWFLAKE'
--   EXTERNAL_VOLUME = 'ACCEL_ICEBERG_VOL'       -- EDIT ME if you named the volume differently
--   BASE_LOCATION = 'gold/fact_sales/';
--
-- INSERT INTO ACCEL_DB.GOLD.FACT_SALES_ICEBERG
-- SELECT ORDER_LINE_SK, ORDER_ID, LINE_NO, DATE_KEY, ORDER_DATE, CUSTOMER_SK, PRODUCT_SK, PLANT_SK,
--        CHANNEL, ORDER_STATUS, CURRENCY, QUANTITY, NET_AMOUNT, COST_AMOUNT, MARGIN_AMOUNT
-- FROM ACCEL_DB.GOLD.FACT_SALES;
--
-- SELECT COUNT(*) FROM ACCEL_DB.GOLD.FACT_SALES_ICEBERG;
-- -- Where the metadata for external engines lives:
-- SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ACCEL_DB.GOLD.FACT_SALES_ICEBERG');

-- 3) Alternative: keep it continuously in sync as a Dynamic Iceberg Table
-- CREATE OR REPLACE DYNAMIC ICEBERG TABLE ACCEL_DB.GOLD.AGG_MONTHLY_REVENUE_ICEBERG
--   TARGET_LAG = '1 hour'
--   WAREHOUSE = ACCEL_WH
--   CATALOG = 'SNOWFLAKE'
--   EXTERNAL_VOLUME = 'ACCEL_ICEBERG_VOL'
--   BASE_LOCATION = 'gold/agg_monthly_revenue/'
-- AS
-- SELECT MONTH_START, REGION, CATEGORY, CURRENCY, ORDERS, UNITS, NET_REVENUE, COST, MARGIN
-- FROM ACCEL_DB.GOLD.AGG_MONTHLY_REVENUE_REGION_CATEGORY;

SELECT 'Iceberg example is commented out - set up an external volume first (see file header)' AS NOTE;
