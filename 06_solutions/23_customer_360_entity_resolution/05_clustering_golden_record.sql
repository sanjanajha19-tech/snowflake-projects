/* =============================================================================
   Asset 23 - Customer 360 & Entity Resolution
   File  05_clustering_golden_record.sql
   Purpose
     1. C360.BUILD_CUSTOMER_CLUSTERS - connected components over accepted
        matches (FINAL_DECISION = 'MATCH') using iterative min-label propagation
        in Snowflake Scripting. Writes C360.CUSTOMER_XREF (record -> GOLDEN_ID).
     2. C360.GOLDEN_CUSTOMER - survivorship rules per attribute.
   Run as  ACCEL_ADMIN after 03 (and optionally 04). Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS C360;
USE SCHEMA C360;

-- -----------------------------------------------------------------------------
-- 1. Connected components
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE C360.BUILD_CUSTOMER_CLUSTERS(MAX_ITERATIONS INTEGER)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    changed_rows INTEGER DEFAULT 1;
    iter         INTEGER DEFAULT 0;
    clusters     INTEGER DEFAULT 0;
BEGIN
    -- undirected edge list of accepted matches
    CREATE OR REPLACE TEMPORARY TABLE ACCEL_DB.C360.TMP_CC_EDGES AS
    SELECT RECORD_KEY_A AS SRC, RECORD_KEY_B AS DST FROM ACCEL_DB.C360.MATCH_PAIRS_FINAL WHERE FINAL_DECISION = 'MATCH'
    UNION
    SELECT RECORD_KEY_B, RECORD_KEY_A FROM ACCEL_DB.C360.MATCH_PAIRS_FINAL WHERE FINAL_DECISION = 'MATCH';

    -- every record starts as its own component
    CREATE OR REPLACE TEMPORARY TABLE ACCEL_DB.C360.TMP_CC_LABELS AS
    SELECT RECORD_KEY, RECORD_KEY AS CLUSTER_KEY FROM ACCEL_DB.C360.CUSTOMER_RECORDS;

    -- propagate the smallest label across edges until nothing changes
    WHILE (changed_rows > 0 AND iter < MAX_ITERATIONS) DO
        CREATE OR REPLACE TEMPORARY TABLE ACCEL_DB.C360.TMP_CC_NEXT AS
        SELECT l.RECORD_KEY,
               LEAST(l.CLUSTER_KEY, COALESCE(MIN(n.CLUSTER_KEY), l.CLUSTER_KEY)) AS CLUSTER_KEY
        FROM ACCEL_DB.C360.TMP_CC_LABELS l
        LEFT JOIN ACCEL_DB.C360.TMP_CC_EDGES e  ON e.SRC = l.RECORD_KEY
        LEFT JOIN ACCEL_DB.C360.TMP_CC_LABELS n ON n.RECORD_KEY = e.DST
        GROUP BY l.RECORD_KEY, l.CLUSTER_KEY;

        SELECT COUNT(*) INTO :changed_rows
        FROM ACCEL_DB.C360.TMP_CC_NEXT x
        JOIN ACCEL_DB.C360.TMP_CC_LABELS l ON l.RECORD_KEY = x.RECORD_KEY
        WHERE x.CLUSTER_KEY <> l.CLUSTER_KEY;

        CREATE OR REPLACE TEMPORARY TABLE ACCEL_DB.C360.TMP_CC_LABELS AS
        SELECT * FROM ACCEL_DB.C360.TMP_CC_NEXT;

        iter := iter + 1;
    END WHILE;

    CREATE OR REPLACE TABLE ACCEL_DB.C360.CUSTOMER_XREF AS
    SELECT 'GC-' || UPPER(LEFT(SHA2(l.CLUSTER_KEY, 256), 12)) AS GOLDEN_ID,
           r.RECORD_KEY, r.SOURCE_SYSTEM, r.SOURCE_ID, r.ERP_CUSTOMER_ID,
           l.CLUSTER_KEY,
           COUNT(*) OVER (PARTITION BY l.CLUSTER_KEY) AS CLUSTER_SIZE,
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS CLUSTERED_AT
    FROM ACCEL_DB.C360.TMP_CC_LABELS l
    JOIN ACCEL_DB.C360.CUSTOMER_RECORDS r ON r.RECORD_KEY = l.RECORD_KEY;

    SELECT COUNT(DISTINCT GOLDEN_ID) INTO :clusters FROM ACCEL_DB.C360.CUSTOMER_XREF;

    RETURN 'Converged after ' || iter || ' iterations (last change count ' || changed_rows || '); '
           || clusters || ' golden customers';
END;
$$;

CALL C360.BUILD_CUSTOMER_CLUSTERS(50);

-- -----------------------------------------------------------------------------
-- 2. Survivorship rules -> GOLDEN_CUSTOMER
--    name      : ERP > CRM > ECOM, then most recently updated
--    email     : most recently updated valid email (any source)
--    phone     : ERP > CRM > ECOM
--    PAN       : valid PAN, ERP > CRM > ECOM
--    segment / industry / region / credit limit : ERP only
--    city      : most recent
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE C360.GOLDEN_CUSTOMER AS
SELECT
    x.GOLDEN_ID,
    (ARRAY_AGG(r.RAW_NAME)  WITHIN GROUP (ORDER BY r.SOURCE_PRIORITY, r.LAST_UPDATED_AT DESC))[0]::VARCHAR AS CUSTOMER_NAME,
    (ARRAY_AGG(r.NAME_STD)  WITHIN GROUP (ORDER BY r.SOURCE_PRIORITY, r.LAST_UPDATED_AT DESC))[0]::VARCHAR AS CUSTOMER_NAME_STD,
    (ARRAY_AGG(r.EMAIL_STD) WITHIN GROUP (ORDER BY r.LAST_UPDATED_AT DESC, r.SOURCE_PRIORITY))[0]::VARCHAR AS EMAIL,
    (ARRAY_AGG(r.PHONE_STD) WITHIN GROUP (ORDER BY r.SOURCE_PRIORITY, r.LAST_UPDATED_AT DESC))[0]::VARCHAR AS PHONE,
    (ARRAY_AGG(r.PAN_STD)   WITHIN GROUP (ORDER BY r.SOURCE_PRIORITY, r.LAST_UPDATED_AT DESC))[0]::VARCHAR AS PAN_NUMBER,
    (ARRAY_AGG(r.RAW_CITY)  WITHIN GROUP (ORDER BY r.LAST_UPDATED_AT DESC, r.SOURCE_PRIORITY))[0]::VARCHAR AS CITY,
    (ARRAY_AGG(r.RAW_COUNTRY) WITHIN GROUP (ORDER BY r.SOURCE_PRIORITY))[0]::VARCHAR                       AS COUNTRY,
    (ARRAY_AGG(IFF(r.SOURCE_SYSTEM = 'ERP', r.SEGMENT, NULL))
         WITHIN GROUP (ORDER BY r.LAST_UPDATED_AT DESC))[0]::VARCHAR                                       AS SEGMENT,
    (ARRAY_AGG(r.INDUSTRY)  WITHIN GROUP (ORDER BY r.LAST_UPDATED_AT DESC))[0]::VARCHAR                    AS INDUSTRY,
    (ARRAY_AGG(r.REGION)    WITHIN GROUP (ORDER BY r.LAST_UPDATED_AT DESC))[0]::VARCHAR                    AS REGION,
    MAX(r.CREDIT_LIMIT)                                                                                    AS CREDIT_LIMIT,
    MIN(r.ERP_CUSTOMER_ID)                                                                                 AS PRIMARY_ERP_CUSTOMER_ID,
    ARRAY_AGG(DISTINCT r.ERP_CUSTOMER_ID)                                                                  AS ERP_CUSTOMER_IDS,
    ARRAY_AGG(DISTINCT r.SOURCE_SYSTEM)                                                                    AS SOURCE_SYSTEMS,
    COUNT(DISTINCT r.SOURCE_SYSTEM)                                                                        AS SOURCE_COUNT,
    COUNT(*)                                                                                               AS RECORD_COUNT,
    SUM(r.ECOM_LIFETIME_ORDERS)                                                                            AS ECOM_LIFETIME_ORDERS,
    SUM(r.ECOM_LIFETIME_SPEND_INR)                                                                         AS ECOM_LIFETIME_SPEND_INR,
    MAX(r.ECOM_LAST_ORDER_DATE)                                                                            AS ECOM_LAST_ORDER_DATE,
    MAX(r.ACCOUNT_OWNER)                                                                                   AS CRM_ACCOUNT_OWNER,
    MAX(r.LAST_UPDATED_AT)                                                                                 AS LAST_UPDATED_AT,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ                                                                     AS BUILT_AT
FROM C360.CUSTOMER_XREF x
JOIN C360.CUSTOMER_RECORDS r ON r.RECORD_KEY = x.RECORD_KEY
GROUP BY x.GOLDEN_ID;

-- Results: how much did entity resolution consolidate?
SELECT (SELECT COUNT(*) FROM C360.CUSTOMER_RECORDS)                         AS SOURCE_RECORDS,
       (SELECT COUNT(*) FROM C360.GOLDEN_CUSTOMER)                          AS GOLDEN_CUSTOMERS,
       (SELECT COUNT(*) FROM C360.GOLDEN_CUSTOMER WHERE SOURCE_COUNT = 3)   AS IN_ALL_3_SOURCES,
       (SELECT COUNT(*) FROM C360.GOLDEN_CUSTOMER WHERE RECORD_COUNT > SOURCE_COUNT) AS WITH_IN_SOURCE_DUPLICATES,
       (SELECT COUNT(*) FROM C360.GOLDEN_CUSTOMER WHERE ARRAY_SIZE(ERP_CUSTOMER_IDS) = 0) AS ECOM_OR_CRM_ONLY;

-- Accuracy check (possible only because the data is synthetic: every CRM/ECOM
-- record derived from ERP customer N carries N inside its source id).
WITH truth AS (
    SELECT RECORD_KEY, GOLDEN_ID,
           CASE SOURCE_SYSTEM
               WHEN 'ERP'  THEN TRY_TO_NUMBER(SOURCE_ID)
               WHEN 'CRM'  THEN TRY_TO_NUMBER(REPLACE(REPLACE(SOURCE_ID, 'CRM-', ''), '-D', ''))
               WHEN 'ECOM' THEN IFF(STARTSWITH(SOURCE_ID, 'EC-G'), NULL, TRY_TO_NUMBER(REPLACE(SOURCE_ID, 'EC-', '')))
           END AS TRUE_CUSTOMER_ID
    FROM C360.CUSTOMER_XREF
),
per_golden AS (
    SELECT GOLDEN_ID, COUNT(DISTINCT TRUE_CUSTOMER_ID) AS N_TRUE FROM truth GROUP BY GOLDEN_ID
),
per_true AS (
    SELECT TRUE_CUSTOMER_ID, COUNT(DISTINCT GOLDEN_ID) AS N_GOLDEN FROM truth
    WHERE TRUE_CUSTOMER_ID IS NOT NULL GROUP BY TRUE_CUSTOMER_ID
)
SELECT (SELECT COUNT(*) FROM per_true)                       AS TRUE_ENTITIES_WITH_ERP_ORIGIN,
       (SELECT COUNT_IF(N_GOLDEN = 1) FROM per_true)         AS FULLY_RESOLVED_ENTITIES,
       (SELECT COUNT_IF(N_GOLDEN > 1) FROM per_true)         AS UNDER_MERGED_ENTITIES,
       (SELECT COUNT_IF(N_TRUE > 1) FROM per_golden)         AS OVER_MERGED_GOLDEN_IDS;
