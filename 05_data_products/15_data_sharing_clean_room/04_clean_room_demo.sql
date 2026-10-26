/*=============================================================================
  ACCELERATOR 15 - Data Sharing & Clean Room
  File 04 : Clean room demo walk-through (run after 03)
            Switches to ACCEL_ANALYST (the collaborating party's analyst) and
            shows what is allowed and what is blocked.
  Run as  : ACCEL_ANALYST (granted to ACCEL_ADMIN via the role hierarchy)
  Rerun   : safe (read-only).
  Note    : statements that are EXPECTED TO FAIL are commented out so that
            "Run All" completes. Uncomment them one at a time during the demo.
=============================================================================*/

USE ROLE ACCEL_ANALYST;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
USE SCHEMA CLEANROOM;

------------------------------------------------------------------------------
-- 1. BLOCKED: row-level access to the other party's list
------------------------------------------------------------------------------
-- SELECT * FROM BRAND_CUSTOMERS LIMIT 10;
--   -> fails: aggregation policy requires the query to aggregate
-- SELECT HASHED_EMAIL, COUNT(*) FROM RETAILER_CUSTOMERS GROUP BY HASHED_EMAIL;
--   -> fails: HASHED_EMAIL is projection-constrained and cannot be returned

------------------------------------------------------------------------------
-- 2. ALLOWED BUT PROTECTED: ad-hoc aggregate. Groups with fewer than 25 rows
--    are folded into one remainder row with NULL keys.
------------------------------------------------------------------------------
SELECT STORE_REGION, PREFERRED_CHANNEL, COUNT(*) AS CUSTOMERS, AVG(SPEND_12M) AS AVG_SPEND
FROM RETAILER_CUSTOMERS
GROUP BY STORE_REGION, PREFERRED_CHANNEL
ORDER BY STORE_REGION, PREFERRED_CHANNEL;

-- Try to single out one person with a tiny group: comes back in the remainder row
SELECT AGE_BAND, LOYALTY_TIER, CATEGORY_AFFINITY, COUNT(*) AS CUSTOMERS
FROM BRAND_CUSTOMERS
GROUP BY AGE_BAND, LOYALTY_TIER, CATEGORY_AFFINITY
ORDER BY CUSTOMERS;

-- The identifier can still be used to JOIN (that is the point of a clean room)
SELECT COUNT(*) AS OVERLAP
FROM BRAND_CUSTOMERS b
JOIN RETAILER_CUSTOMERS r ON r.HASHED_EMAIL = b.HASHED_EMAIL;

------------------------------------------------------------------------------
-- 3. APPROVED ANALYSES
------------------------------------------------------------------------------
SELECT * FROM V_APPROVED_OVERLAP_SUMMARY ORDER BY SORT_ORDER;

SELECT * FROM V_APPROVED_OVERLAP_BY_SEGMENT
ORDER BY LOYALTY_TIER, STORE_REGION;

SELECT * FROM V_APPROVED_OVERLAP_BY_CATEGORY_AFFINITY
ORDER BY OVERLAP_CUSTOMERS DESC;

SELECT * FROM TABLE(APPROVED_OVERLAP_FOR_REGION('North'))
ORDER BY LOYALTY_TIER, AGE_BAND;

------------------------------------------------------------------------------
-- 4. Operator view (unrestricted) for comparison
------------------------------------------------------------------------------
USE ROLE ACCEL_ADMIN;
SELECT * FROM TABLE(APPROVED_OVERLAP_FOR_REGION('North'))
ORDER BY OVERLAP_CUSTOMERS;   -- shows the small cells the analyst could not see

-- Which policies protect which objects
SELECT POLICY_NAME, POLICY_KIND, REF_ENTITY_NAME, REF_COLUMN_NAME
FROM TABLE(ACCEL_DB.INFORMATION_SCHEMA.POLICY_REFERENCES(
        REF_ENTITY_NAME   => 'ACCEL_DB.CLEANROOM.BRAND_CUSTOMERS',
        REF_ENTITY_DOMAIN => 'table'));
