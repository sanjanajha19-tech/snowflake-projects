/* =============================================================================
   Asset 27 - GST Tax Data Hub (India GST ITC reconciliation demo)
   File  01_config_and_udfs.sql
   Purpose
     GST.RECON_CONFIG       - matching tolerances (-- EDIT ME)
     GST.GST_RATES          - ILLUSTRATIVE GST rates by product category (-- EDIT ME)
     GST.STATE_CODES        - GST state codes (used for intra/inter-state split)
     GST.PLANT_GST_STATE    - state code for each DEMO plant (-- EDIT ME)
     UDFs
       GST.GSTIN_CHECK_CHAR(first14)      Python - check character, base-36 Luhn-style
                                           algorithm (factor 1/2 alternating,
                                           quotient + remainder per position)
       GST.GSTIN_VALIDATION_ERROR(gstin)  Python - NULL if valid, else reason:
                                           NULL / LENGTH_NOT_15 / FORMAT / STATE_CODE / CHECK_DIGIT
       GST.IS_VALID_GSTIN(gstin)          SQL wrapper -> BOOLEAN
       GST.NORMALIZE_INVOICE_NO(inv)      Python - upper-case, separators removed,
                                           leading zeros dropped in each number group
     Test cases at the end - every row must show PASS.

   DISCLAIMER  Tax rates, rules and tolerances here are illustrative for a demo.
     They are not tax advice. Confirm current rates (HSN/SAC-wise), place-of-supply
     rules and ITC eligibility with your tax team and the GST portal / CBIC notifications.
   Run as  ACCEL_ADMIN. Rerunnable.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS GST;
USE SCHEMA GST;

-- -----------------------------------------------------------------------------
-- Configuration                                                        -- EDIT ME
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE GST.RECON_CONFIG (PARAM VARCHAR, VALUE NUMBER(14,4), NOTE VARCHAR);
INSERT INTO GST.RECON_CONFIG VALUES
  ('AMOUNT_TOLERANCE_ABS_INR',   10,    'Exact match: max |difference| in taxable value and in total tax (INR)'),   -- EDIT ME
  ('PROBABLE_AMOUNT_TOL_PCT',    0.02,  'Probable match: max relative difference in taxable value'),                -- EDIT ME
  ('PROBABLE_DATE_WINDOW_DAYS',  30,    'Probable match: max difference in invoice dates'),                         -- EDIT ME
  ('INVOICE_EDIT_DISTANCE_MAX',  2,     'Probable match: max EDITDISTANCE between normalised invoice numbers'),      -- EDIT ME
  ('GSTIN_EDIT_DISTANCE_MAX',    2,     'Probable match: max EDITDISTANCE between GSTINs (typos)'),                  -- EDIT ME
  ('BOOKS_FROM_DATE_YYYYMMDD',   20250401, 'First invoice date included in the demo purchase register (FY2025-26)'); -- EDIT ME

-- ILLUSTRATIVE rates only - real rates are HSN/SAC-specific.           -- EDIT ME
CREATE OR REPLACE TABLE GST.GST_RATES (PRODUCT_CATEGORY VARCHAR, GST_RATE NUMBER(5,4), NOTE VARCHAR);
INSERT INTO GST.GST_RATES VALUES ('DEFAULT', 0.18, 'ILLUSTRATIVE - replace with HSN-wise rate');
INSERT INTO GST.GST_RATES
SELECT DISTINCT p.CATEGORY,
       0.18,                                                               -- EDIT ME
       'ILLUSTRATIVE - replace with HSN-wise rate for category "' || p.CATEGORY || '"'
FROM ACCEL_DB.DEMO.PRODUCTS p
WHERE p.CATEGORY IS NOT NULL;

-- GST state / UT codes (first two characters of a GSTIN)
CREATE OR REPLACE TABLE GST.STATE_CODES (STATE_CODE VARCHAR(2), STATE_NAME VARCHAR);
INSERT INTO GST.STATE_CODES VALUES
  ('01','Jammu and Kashmir'),('02','Himachal Pradesh'),('03','Punjab'),('04','Chandigarh'),('05','Uttarakhand'),
  ('06','Haryana'),('07','Delhi'),('08','Rajasthan'),('09','Uttar Pradesh'),('10','Bihar'),('11','Sikkim'),
  ('12','Arunachal Pradesh'),('13','Nagaland'),('14','Manipur'),('15','Mizoram'),('16','Tripura'),('17','Meghalaya'),
  ('18','Assam'),('19','West Bengal'),('20','Jharkhand'),('21','Odisha'),('22','Chhattisgarh'),('23','Madhya Pradesh'),
  ('24','Gujarat'),('25','Daman and Diu'),('26','Dadra and Nagar Haveli and Daman and Diu'),('27','Maharashtra'),
  ('28','Andhra Pradesh (old)'),('29','Karnataka'),('30','Goa'),('31','Lakshadweep'),('32','Kerala'),('33','Tamil Nadu'),
  ('34','Puducherry'),('35','Andaman and Nicobar Islands'),('36','Telangana'),('37','Andhra Pradesh'),('38','Ladakh'),
  ('97','Other Territory'),('99','Centre Jurisdiction');

-- Registration state of each receiving plant.                          -- EDIT ME
-- Mapped from city where recognisable; everything else (incl. non-India plants
-- in the demo data) defaults to Maharashtra (27) so the demo has a buyer GSTIN state.
CREATE OR REPLACE TABLE GST.PLANT_GST_STATE AS
SELECT p.PLANT_ID, p.PLANT_NAME, p.CITY, p.COUNTRY,
       CASE UPPER(p.CITY)
           WHEN 'MUMBAI' THEN '27' WHEN 'PUNE' THEN '27' WHEN 'NAGPUR' THEN '27' WHEN 'NASHIK' THEN '27'
           WHEN 'BENGALURU' THEN '29' WHEN 'BANGALORE' THEN '29' WHEN 'MYSURU' THEN '29'
           WHEN 'CHENNAI' THEN '33' WHEN 'COIMBATORE' THEN '33' WHEN 'HOSUR' THEN '33'
           WHEN 'DELHI' THEN '07' WHEN 'NEW DELHI' THEN '07'
           WHEN 'GURUGRAM' THEN '06' WHEN 'GURGAON' THEN '06' WHEN 'MANESAR' THEN '06'
           WHEN 'NOIDA' THEN '09' WHEN 'LUCKNOW' THEN '09'
           WHEN 'HYDERABAD' THEN '36' WHEN 'KOLKATA' THEN '19' WHEN 'AHMEDABAD' THEN '24' WHEN 'VADODARA' THEN '24'
           WHEN 'SURAT' THEN '24' WHEN 'JAIPUR' THEN '08' WHEN 'KOCHI' THEN '32' WHEN 'BHUBANESWAR' THEN '21'
           ELSE '27'
       END AS STATE_CODE
FROM ACCEL_DB.DEMO.PLANTS p;

-- -----------------------------------------------------------------------------
-- UDFs
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION GST.GSTIN_CHECK_CHAR(FIRST14 VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'check_char'
COMMENT = 'GSTIN check character for the first 14 characters (base-36 checksum)'
AS
$$
_CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"


def check_char(first14):
    if first14 is None:
        return None
    s = str(first14).strip().upper()
    if len(s) < 14 or any(c not in _CHARSET for c in s[:14]):
        return None
    total = 0
    for i, c in enumerate(s[:14]):
        # odd positions (1st, 3rd, ...) weight 1, even positions weight 2
        product = _CHARSET.index(c) * (1 if i % 2 == 0 else 2)
        total += product // 36 + product % 36
    return _CHARSET[(36 - total % 36) % 36]
$$;

CREATE OR REPLACE FUNCTION GST.GSTIN_VALIDATION_ERROR(GSTIN VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'validation_error'
COMMENT = 'NULL when the GSTIN is valid, otherwise NULL / LENGTH_NOT_15 / FORMAT / STATE_CODE / CHECK_DIGIT'
AS
$$
import re

_CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
# 2-digit state code, 10-char PAN (5 letters, 4 digits, 1 letter), entity number, 'Z', check char
_PATTERN = re.compile(r"^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$")
_STATE_CODES = {"%02d" % i for i in range(1, 39)} | {"97", "99"}


def _check_char(first14):
    total = 0
    for i, c in enumerate(first14):
        product = _CHARSET.index(c) * (1 if i % 2 == 0 else 2)
        total += product // 36 + product % 36
    return _CHARSET[(36 - total % 36) % 36]


def validation_error(gstin):
    if gstin is None:
        return "NULL"
    s = str(gstin).strip().upper()
    if len(s) != 15:
        return "LENGTH_NOT_15"
    if not _PATTERN.match(s):
        return "FORMAT"
    if s[:2] not in _STATE_CODES:
        return "STATE_CODE"
    if _check_char(s[:14]) != s[14]:
        return "CHECK_DIGIT"
    return None
$$;

CREATE OR REPLACE FUNCTION GST.IS_VALID_GSTIN(GSTIN VARCHAR)
RETURNS BOOLEAN
AS
$$
    ACCEL_DB.GST.GSTIN_VALIDATION_ERROR(GSTIN) IS NULL
$$;

CREATE OR REPLACE FUNCTION GST.NORMALIZE_INVOICE_NO(INVOICE_NO VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'normalize'
COMMENT = 'INV/2025/000123, inv-2025-123 and INV 2025 0123 all become INV2025123'
AS
$$
import re

_TOKEN = re.compile(r"[A-Z]+|[0-9]+")


def normalize(invoice_no):
    if invoice_no is None:
        return None
    tokens = _TOKEN.findall(str(invoice_no).upper())
    out = "".join(t if t.isalpha() else str(int(t)) for t in tokens)
    return out or None
$$;

-- -----------------------------------------------------------------------------
-- Test cases (all rows must show PASS)
-- 27AAPFU0939F1ZV and 29AAGCB7383J1Z4 are publicly cited sample GSTINs whose
-- check digit is consistent with the algorithm.
-- -----------------------------------------------------------------------------
SELECT TEST_CASE, INPUT, EXPECTED, ACTUAL, IFF(EQUAL_NULL(EXPECTED, ACTUAL), 'PASS', 'FAIL') AS RESULT
FROM (
    SELECT 'valid sample 1'          AS TEST_CASE, '27AAPFU0939F1ZV' AS INPUT, 'VALID' AS EXPECTED,
           COALESCE(GST.GSTIN_VALIDATION_ERROR('27AAPFU0939F1ZV'), 'VALID') AS ACTUAL
    UNION ALL SELECT 'valid sample 2', '29AAGCB7383J1Z4', 'VALID', COALESCE(GST.GSTIN_VALIDATION_ERROR('29AAGCB7383J1Z4'), 'VALID')
    UNION ALL SELECT 'lower case + spaces', ' 27aapfu0939f1zv ', 'VALID', COALESCE(GST.GSTIN_VALIDATION_ERROR(' 27aapfu0939f1zv '), 'VALID')
    UNION ALL SELECT 'wrong check digit', '27AAPFU0939F1ZA', 'CHECK_DIGIT', GST.GSTIN_VALIDATION_ERROR('27AAPFU0939F1ZA')
    UNION ALL SELECT 'PAN typo (U->V)', '27AAPFV0939F1ZV', 'CHECK_DIGIT', GST.GSTIN_VALIDATION_ERROR('27AAPFV0939F1ZV')
    UNION ALL SELECT 'too short', '27AAPFU0939F1Z', 'LENGTH_NOT_15', GST.GSTIN_VALIDATION_ERROR('27AAPFU0939F1Z')
    UNION ALL SELECT '14th char not Z', '27AAPFU0939F1XV', 'FORMAT', GST.GSTIN_VALIDATION_ERROR('27AAPFU0939F1XV')
    UNION ALL SELECT 'state code 40', '40AAPFU0939F1ZV', 'STATE_CODE', GST.GSTIN_VALIDATION_ERROR('40AAPFU0939F1ZV')
    UNION ALL SELECT 'null input', NULL, 'NULL', GST.GSTIN_VALIDATION_ERROR(NULL)
    UNION ALL SELECT 'check char calc', '27AAPFU0939F1Z', 'V', GST.GSTIN_CHECK_CHAR('27AAPFU0939F1Z')
    UNION ALL SELECT 'is_valid true', '29AAGCB7383J1Z4', 'TRUE', UPPER(GST.IS_VALID_GSTIN('29AAGCB7383J1Z4')::VARCHAR)
    UNION ALL SELECT 'is_valid false', '29AAGCB7383J1Z5', 'FALSE', UPPER(GST.IS_VALID_GSTIN('29AAGCB7383J1Z5')::VARCHAR)
    UNION ALL SELECT 'invoice normalise 1', 'INV/2025/000123', 'INV2025123', GST.NORMALIZE_INVOICE_NO('INV/2025/000123')
    UNION ALL SELECT 'invoice normalise 2', 'inv-2025-123', 'INV2025123', GST.NORMALIZE_INVOICE_NO('inv-2025-123')
)
ORDER BY RESULT, TEST_CASE;
