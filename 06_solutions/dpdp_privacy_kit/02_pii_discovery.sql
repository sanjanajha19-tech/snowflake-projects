/*=============================================================================
  ACCELERATOR 18 - DPDP Privacy Kit
  File 02 : Personal data discovery -> PERSONAL_DATA_INVENTORY
            Combines three detectors per column:
              1. SYSTEM$CLASSIFY (Snowflake sensitive data classification)
              2. Value patterns for India-specific identifiers that generic
                 classifiers may miss (PAN, GSTIN, Aadhaar, Indian mobile, UPI ID)
                 plus e-mail
              3. Column-name rules (names, addresses, salary, DOB ...)
  Creates : PERSONAL_DATA_INVENTORY, SP_DISCOVER_PERSONAL_DATA(ARRAY),
            V_PERSONAL_DATA_INVENTORY (one consolidated row per column)
  Run as  : ACCEL_ADMIN (owns the scanned tables)
  Rerun   : safe - each scan replaces the rows for the scanned tables.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS DPDP;
USE SCHEMA DPDP;

CREATE TABLE IF NOT EXISTS PERSONAL_DATA_INVENTORY (
    SCAN_ID            VARCHAR,
    SCAN_TS            TIMESTAMP_NTZ,
    DATABASE_NAME      VARCHAR,
    SCHEMA_NAME        VARCHAR,
    TABLE_NAME         VARCHAR,
    COLUMN_NAME        VARCHAR,
    DATA_TYPE          VARCHAR,
    DETECTION_METHOD   VARCHAR,   -- SYSTEM$CLASSIFY | VALUE_PATTERN | COLUMN_NAME_RULE
    SEMANTIC_CATEGORY  VARCHAR,   -- e.g. EMAIL, NAME, PHONE_NUMBER, IN_PAN, IN_AADHAAR
    PRIVACY_CATEGORY   VARCHAR,   -- IDENTIFIER | QUASI_IDENTIFIER | SENSITIVE
    CONFIDENCE         VARCHAR,   -- HIGH | MEDIUM | LOW or a match rate
    MATCH_RATE         FLOAT,     -- share of sampled non-null values matching the pattern
    DETAILS            VARIANT
) COMMENT = 'DPDP kit: raw detector output, one row per column per detector';

CREATE OR REPLACE PROCEDURE SP_DISCOVER_PERSONAL_DATA(TABLE_NAMES ARRAY)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
import json
import re
import uuid
from datetime import datetime

from snowflake.snowpark.types import StructType, StructField, StringType, FloatType

SAMPLE_ROWS = 500
MIN_MATCH_RATE = 0.6

# India-specific and generic value patterns (full-string match on trimmed upper-case values)
PATTERNS = {
    "IN_PAN":        (r"^[A-Z]{5}[0-9]{4}[A-Z]$", "IDENTIFIER"),
    "IN_GSTIN":      (r"^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$", "IDENTIFIER"),
    "IN_AADHAAR":    (r"^[2-9][0-9]{3}\s?[0-9]{4}\s?[0-9]{4}$", "IDENTIFIER"),
    "IN_MOBILE":     (r"^(\+?91[\s-]?)?0?[6-9][0-9]{4}[\s-]?[0-9]{5}$", "IDENTIFIER"),
    "PHONE_NUMBER":  (r"^\+?[0-9][0-9\s().-]{7,18}[0-9]$", "IDENTIFIER"),
    "EMAIL":         (r"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$", "IDENTIFIER"),
    "IN_UPI_ID":     (r"^[A-Z0-9._-]{2,}@[A-Z]{2,}$", "IDENTIFIER"),
}

# Column-name rules: (regex on column name, semantic category, privacy category)
NAME_RULES = [
    (r"^(FULL_|FIRST_|LAST_|MIDDLE_|CUSTOMER_|EMPLOYEE_|CONTACT_|PERSON_)?NAME$", "NAME", "IDENTIFIER"),
    (r"EMAIL", "EMAIL", "IDENTIFIER"),
    (r"PHONE|MOBILE", "PHONE_NUMBER", "IDENTIFIER"),
    (r"PAN(_NUMBER|_NO)?$", "IN_PAN", "IDENTIFIER"),
    (r"AADHAAR|AADHAR|UIDAI", "IN_AADHAAR", "IDENTIFIER"),
    (r"GSTIN", "IN_GSTIN", "QUASI_IDENTIFIER"),
    (r"ADDRESS|STREET|PINCODE|PIN_CODE|ZIP", "STREET_ADDRESS", "QUASI_IDENTIFIER"),
    (r"(^|_)CITY$", "CITY", "QUASI_IDENTIFIER"),
    (r"DOB|BIRTH", "DATE_OF_BIRTH", "QUASI_IDENTIFIER"),
    (r"SALARY|INCOME|CREDIT_LIMIT", "FINANCIAL_INFO", "SENSITIVE"),
    (r"GENDER|RELIGION|CASTE|HEALTH|MEDICAL", "SPECIAL_CATEGORY", "SENSITIVE"),
    (r"(^|_)BODY$|NOTES|COMMENTS|FREE_TEXT", "FREE_TEXT_MAY_CONTAIN_PII", "QUASI_IDENTIFIER"),
]


def _classify(session, fq_name):
    """Run SYSTEM$CLASSIFY and return {column: (semantic, privacy, confidence, raw)}."""
    out = {}
    raw = session.sql(f"CALL SYSTEM$CLASSIFY('{fq_name}', {{'auto_tag': false}})").collect()[0][0]
    res = raw if isinstance(raw, dict) else json.loads(raw)
    cols = res.get("classification_result", res) if isinstance(res, dict) else {}
    for col, info in cols.items():
        if not isinstance(info, dict):
            continue
        rec = info.get("recommendation") or info
        sem = rec.get("semantic_category")
        priv = rec.get("privacy_category")
        conf = rec.get("confidence")
        if conf is None and isinstance(info.get("extra_info"), dict):
            conf = info["extra_info"].get("probability")
        if sem or priv:
            out[col] = (sem, priv, None if conf is None else str(conf), info)
    return out


def run(session, table_names):
    scan_id = str(uuid.uuid4())
    scan_ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    rows = []
    summary = {"scan_id": scan_id, "tables": {}}

    for fq in table_names:
        fq = str(fq).upper()
        db, sch, tbl = fq.split(".")
        fields = session.sql(f"SELECT * FROM {fq} LIMIT 0").schema.fields
        types = {f.name.strip('"'): type(f.datatype).__name__.replace("Type", "").upper() for f in fields}
        found = 0

        # 1. SYSTEM$CLASSIFY
        try:
            for col, (sem, priv, conf, info) in _classify(session, fq).items():
                rows.append([scan_id, scan_ts, db, sch, tbl, col, types.get(col), "SYSTEM$CLASSIFY",
                             sem, priv, conf, None, json.dumps(info, default=str)])
                found += 1
        except Exception as exc:  # keep scanning other detectors / tables
            rows.append([scan_id, scan_ts, db, sch, tbl, None, None, "SYSTEM$CLASSIFY_ERROR",
                         None, None, None, None, json.dumps({"error": str(exc)[:1000]})])

        # 2. Value patterns on a sample of string columns
        str_cols = [f.name for f in fields if type(f.datatype).__name__ == "StringType"]
        if str_cols:
            sample = session.sql(
                f"SELECT {', '.join(str_cols)} FROM {fq} SAMPLE ({SAMPLE_ROWS} ROWS)"
            ).collect()
            for idx, col in enumerate(str_cols):
                values = [str(r[idx]).strip().upper() for r in sample if r[idx] is not None and str(r[idx]).strip()]
                if not values:
                    continue
                for cat, (pattern, priv) in PATTERNS.items():
                    rx = re.compile(pattern)
                    rate = sum(1 for v in values if rx.match(v)) / len(values)
                    if rate >= MIN_MATCH_RATE:
                        rows.append([scan_id, scan_ts, db, sch, tbl, col.strip('"'), types.get(col.strip('"')),
                                     "VALUE_PATTERN", cat, priv, "HIGH" if rate >= 0.9 else "MEDIUM",
                                     round(rate, 4), json.dumps({"sampled_values": len(values), "pattern": pattern})])
                        found += 1
                        break   # first (most specific) matching pattern wins

        # 3. Column-name rules
        for f in fields:
            name = f.name.strip('"').upper()
            for pattern, sem, priv in NAME_RULES:
                if re.search(pattern, name):
                    rows.append([scan_id, scan_ts, db, sch, tbl, name, types.get(f.name.strip('"')),
                                 "COLUMN_NAME_RULE", sem, priv, "LOW", None,
                                 json.dumps({"rule": pattern})])
                    found += 1
                    break

        session.sql(
            "DELETE FROM ACCEL_DB.DPDP.PERSONAL_DATA_INVENTORY "
            "WHERE DATABASE_NAME = ? AND SCHEMA_NAME = ? AND TABLE_NAME = ?",
            params=[db, sch, tbl],
        ).collect()
        summary["tables"][fq] = found

    if rows:
        schema = StructType([
            StructField("SCAN_ID", StringType()), StructField("SCAN_TS", StringType()),
            StructField("DATABASE_NAME", StringType()), StructField("SCHEMA_NAME", StringType()),
            StructField("TABLE_NAME", StringType()), StructField("COLUMN_NAME", StringType()),
            StructField("DATA_TYPE", StringType()), StructField("DETECTION_METHOD", StringType()),
            StructField("SEMANTIC_CATEGORY", StringType()), StructField("PRIVACY_CATEGORY", StringType()),
            StructField("CONFIDENCE", StringType()), StructField("MATCH_RATE", FloatType()),
            StructField("DETAILS_JSON", StringType()),
        ])
        session.create_dataframe(rows, schema=schema).create_or_replace_temp_view("TMP_PII_SCAN")
        session.sql(
            "INSERT INTO ACCEL_DB.DPDP.PERSONAL_DATA_INVENTORY "
            "SELECT SCAN_ID, TO_TIMESTAMP_NTZ(SCAN_TS), DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, COLUMN_NAME, "
            "DATA_TYPE, DETECTION_METHOD, SEMANTIC_CATEGORY, PRIVACY_CATEGORY, CONFIDENCE, MATCH_RATE, "
            "PARSE_JSON(DETAILS_JSON) FROM TMP_PII_SCAN"
        ).collect()

    session.sql(
        "INSERT INTO ACCEL_DB.DPDP.DPDP_AUDIT_LOG (EVENT_TYPE, ACTOR_USER, DETAILS) "
        "SELECT 'PII_SCAN', CURRENT_USER(), PARSE_JSON(?)",
        params=[json.dumps(summary)],
    ).collect()
    summary["detector_rows"] = len(rows)
    return summary
$$;

------------------------------------------------------------------------------
-- Run the scan: DEMO source tables + the DPDP systems of record
------------------------------------------------------------------------------
CALL SP_DISCOVER_PERSONAL_DATA(ARRAY_CONSTRUCT(
    'ACCEL_DB.DEMO.CUSTOMERS',
    'ACCEL_DB.DEMO.EMPLOYEES',
    'ACCEL_DB.DEMO.SUPPLIERS',
    'ACCEL_DB.DEMO.SUPPORT_TICKETS',
    'ACCEL_DB.DEMO.ORDERS',
    'ACCEL_DB.DPDP.CUSTOMERS',
    'ACCEL_DB.DPDP.SUPPORT_TICKETS'
));   -- EDIT ME: add client tables (fully qualified)

------------------------------------------------------------------------------
-- Consolidated inventory: one row per column, best evidence first
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_PERSONAL_DATA_INVENTORY
  COMMENT = 'DPDP kit: consolidated personal data inventory (record of personal data assets)'
AS
WITH methods AS (
    SELECT DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, COLUMN_NAME,
           ARRAY_AGG(DISTINCT DETECTION_METHOD) AS DETECTED_BY
    FROM ACCEL_DB.DPDP.PERSONAL_DATA_INVENTORY
    WHERE COLUMN_NAME IS NOT NULL
    GROUP BY DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, COLUMN_NAME
),
ranked AS (
    SELECT i.*,
           m.DETECTED_BY,
           ROW_NUMBER() OVER (
               PARTITION BY i.DATABASE_NAME, i.SCHEMA_NAME, i.TABLE_NAME, i.COLUMN_NAME
               ORDER BY CASE i.DETECTION_METHOD
                            WHEN 'VALUE_PATTERN'    THEN IFF(STARTSWITH(i.SEMANTIC_CATEGORY, 'IN_'), 1, 3)
                            WHEN 'SYSTEM$CLASSIFY'  THEN 2
                            ELSE 4 END) AS RN
    FROM ACCEL_DB.DPDP.PERSONAL_DATA_INVENTORY i
    JOIN methods m
      ON  m.DATABASE_NAME = i.DATABASE_NAME AND m.SCHEMA_NAME = i.SCHEMA_NAME
      AND m.TABLE_NAME = i.TABLE_NAME AND m.COLUMN_NAME = i.COLUMN_NAME
    WHERE i.COLUMN_NAME IS NOT NULL
)
SELECT DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, COLUMN_NAME, DATA_TYPE,
       SEMANTIC_CATEGORY,
       PRIVACY_CATEGORY,
       CASE
           WHEN SEMANTIC_CATEGORY IN ('IN_AADHAAR', 'IN_PAN', 'SPECIAL_CATEGORY', 'FINANCIAL_INFO') THEN 'HIGH'
           WHEN PRIVACY_CATEGORY = 'IDENTIFIER' THEN 'HIGH'
           WHEN PRIVACY_CATEGORY IN ('QUASI_IDENTIFIER', 'SENSITIVE') THEN 'MEDIUM'
           ELSE 'LOW'
       END AS RISK_LEVEL,
       DETECTED_BY,
       ARRAY_SIZE(DETECTED_BY) >= 2 AS CORROBORATED,
       CONFIDENCE,
       SCAN_TS AS LAST_SCANNED_AT
FROM ranked
WHERE RN = 1;

SELECT TABLE_NAME, COLUMN_NAME, SEMANTIC_CATEGORY, PRIVACY_CATEGORY, RISK_LEVEL, DETECTED_BY
FROM V_PERSONAL_DATA_INVENTORY
ORDER BY DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, RISK_LEVEL, COLUMN_NAME;

SELECT * FROM PERSONAL_DATA_INVENTORY WHERE DETECTION_METHOD = 'SYSTEM$CLASSIFY_ERROR';  -- should be empty
