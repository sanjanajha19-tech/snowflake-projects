/*=============================================================================
  MIGRATION ASSESSMENT 03 (optional) - Load inventory from CSV files
  Use this instead of 02_sample_inventory.sql when you have a real extract.
  1. Upload the five files (same layout as sample_data/*.csv):
       src_objects.csv, src_columns.csv, src_code.csv,
       src_dependencies.csv, src_query_log.csv
     Snowsight: Data > Databases > ACCEL_DB > MIGRATION_ASSESSMENT > Stages >
                INVENTORY_STAGE > "+ Files"
     SnowSQL  : PUT file:///path/sample_data/src_*.csv @ACCEL_DB.MIGRATION_ASSESSMENT.INVENTORY_STAGE AUTO_COMPRESS=FALSE;
  2. Run this script. If src_objects.csv is not on the stage, nothing is changed.
  Run as : ACCEL_ADMIN. Rerun: safe (truncate + reload).
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS MIGRATION_ASSESSMENT;
USE SCHEMA MIGRATION_ASSESSMENT;

ALTER STAGE INVENTORY_STAGE REFRESH;      -- refresh directory table after upload
LIST @INVENTORY_STAGE;

EXECUTE IMMEDIATE $$
DECLARE
  n_files INTEGER DEFAULT 0;
BEGIN
  SELECT COUNT(*) INTO :n_files
  FROM DIRECTORY(@INVENTORY_STAGE)
  WHERE RELATIVE_PATH ILIKE '%src_objects%.csv%';

  IF (n_files = 0) THEN
    RETURN 'No src_objects*.csv on @INVENTORY_STAGE - upload files first. Existing data left unchanged.';
  END IF;

  TRUNCATE TABLE SRC_OBJECTS;
  TRUNCATE TABLE SRC_COLUMNS;
  TRUNCATE TABLE SRC_CODE;
  TRUNCATE TABLE SRC_DEPENDENCIES;
  TRUNCATE TABLE SRC_QUERY_LOG;

  COPY INTO SRC_OBJECTS      FROM @INVENTORY_STAGE PATTERN = '.*src_objects.*[.]csv.*'
    FILE_FORMAT = (FORMAT_NAME = 'FF_INVENTORY_CSV') ON_ERROR = 'ABORT_STATEMENT';
  COPY INTO SRC_COLUMNS      FROM @INVENTORY_STAGE PATTERN = '.*src_columns.*[.]csv.*'
    FILE_FORMAT = (FORMAT_NAME = 'FF_INVENTORY_CSV') ON_ERROR = 'ABORT_STATEMENT';
  COPY INTO SRC_CODE         FROM @INVENTORY_STAGE PATTERN = '.*src_code.*[.]csv.*'
    FILE_FORMAT = (FORMAT_NAME = 'FF_INVENTORY_CSV') ON_ERROR = 'ABORT_STATEMENT';
  COPY INTO SRC_DEPENDENCIES FROM @INVENTORY_STAGE PATTERN = '.*src_dependencies.*[.]csv.*'
    FILE_FORMAT = (FORMAT_NAME = 'FF_INVENTORY_CSV') ON_ERROR = 'ABORT_STATEMENT';
  COPY INTO SRC_QUERY_LOG    FROM @INVENTORY_STAGE PATTERN = '.*src_query_log.*[.]csv.*'
    FILE_FORMAT = (FORMAT_NAME = 'FF_INVENTORY_CSV') ON_ERROR = 'ABORT_STATEMENT';

  RETURN 'Inventory reloaded from @INVENTORY_STAGE. Run 04_scoring.sql next.';
END;
$$;

SELECT 'SRC_OBJECTS' AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM SRC_OBJECTS
UNION ALL SELECT 'SRC_COLUMNS', COUNT(*) FROM SRC_COLUMNS
UNION ALL SELECT 'SRC_CODE', COUNT(*) FROM SRC_CODE
UNION ALL SELECT 'SRC_DEPENDENCIES', COUNT(*) FROM SRC_DEPENDENCIES
UNION ALL SELECT 'SRC_QUERY_LOG', COUNT(*) FROM SRC_QUERY_LOG;
