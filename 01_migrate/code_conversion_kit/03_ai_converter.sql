/*=============================================================================
  CODE CONVERSION KIT 03 - AI-assisted SQL converter
  SP_CONVERT_SQL(legacy_sql, source_dialect [, object_name, model, validate])
    1. finds matching PATTERN_LIBRARY rows and adds them to a strict prompt
    2. calls AI_COMPLETE, expects JSON {snowflake_sql, changes, warnings, confidence}
    3. optionally compiles the result with EXPLAIN (single SELECT/DML only)
    4. logs everything to CONVERSION_LOG and returns the result as VARIANT
  SP_CONVERT_QUEUE() converts every PENDING row in CONVERSION_QUEUE.
  Run as : ACCEL_ADMIN (needs SNOWFLAKE.CORTEX_USER). Rerun: safe.
  Every AI conversion must be reviewed by an engineer before use.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS CODE_CONVERSION;
USE SCHEMA CODE_CONVERSION;

------------------------------------------------------------------------------
-- 1. Log + queue tables
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CONVERSION_LOG (
  RUN_ID              VARCHAR,
  RUN_TS              TIMESTAMP_LTZ,
  SOURCE_DIALECT      VARCHAR,
  OBJECT_NAME         VARCHAR,
  MODEL               VARCHAR,
  LEGACY_SQL          VARCHAR,
  SNOWFLAKE_SQL       VARCHAR,
  CHANGES             VARIANT,
  WARNINGS            VARIANT,
  CONFIDENCE          VARCHAR,
  PATTERNS_USED       VARCHAR,
  STATUS              VARCHAR,     -- VALIDATED | NEEDS_REVIEW | NOT_VALIDATED | PARSE_ERROR | AI_ERROR
  VALIDATION_MESSAGE  VARCHAR,
  RAW_RESPONSE        VARCHAR,
  CALLED_BY           VARCHAR
);

CREATE TABLE IF NOT EXISTS CONVERSION_QUEUE (
  QUEUE_ID        NUMBER AUTOINCREMENT START 1 INCREMENT 1,
  SOURCE_DIALECT  VARCHAR,
  OBJECT_NAME     VARCHAR,
  LEGACY_SQL      VARCHAR,
  STATUS          VARCHAR DEFAULT 'PENDING',
  LAST_RUN_ID     VARCHAR
);

------------------------------------------------------------------------------
-- 2. Single-statement converter
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_CONVERT_SQL(
    LEGACY_SQL     VARCHAR,
    SOURCE_DIALECT VARCHAR,                          -- 'Teradata' | 'Oracle' | 'SQL Server'
    OBJECT_NAME    VARCHAR DEFAULT NULL,
    MODEL          VARCHAR DEFAULT 'llama3.1-70b',   -- EDIT ME: any AI_COMPLETE model available in your region
    VALIDATE       BOOLEAN DEFAULT TRUE)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
COMMENT = 'AI-assisted legacy SQL -> Snowflake SQL conversion with pattern hints and logging'
AS
$$
import json
import re
import uuid

from snowflake.snowpark.functions import call_function, col, current_timestamp, current_user, lit, parse_json
from snowflake.snowpark.types import StringType, StructField, StructType

LOG_TABLE = "ACCEL_DB.CODE_CONVERSION.CONVERSION_LOG"
PATTERN_TABLE = "ACCEL_DB.CODE_CONVERSION.PATTERN_LIBRARY"
MAX_HINTS = 15

PROMPT = """You are an expert SQL migration engineer converting {dialect} SQL to Snowflake SQL.
Follow these rules strictly:
1. Reply with ONLY one JSON object. No markdown fences, no text before or after it.
2. JSON keys:
   "snowflake_sql": complete, runnable Snowflake SQL (string),
   "changes": array of objects {{"original": "...", "converted": "...", "reason": "..."}},
   "warnings": array of strings for anything a human must review,
   "confidence": "High" | "Medium" | "Low".
3. Keep business logic, table names, column names, aliases, filters and ordering exactly the same.
   Never invent tables, columns or functions.
4. Use only documented Snowflake syntax: ANSI joins, QUALIFY, LIMIT, TEMPORARY tables,
   MERGE, Snowflake Scripting (BEGIN ... EXCEPTION ... END) for procedural code.
5. Remove physical-design or tuning clauses that do not apply (PRIMARY INDEX, COLLECT STATISTICS,
   FALLBACK, optimizer hints, NOLOCK, TABLESPACE) and list each removal in "changes".
6. If something cannot be converted reliably, write the closest equivalent, add a "-- REVIEW:" comment
   in the SQL and add a warning.

Known {dialect} -> Snowflake patterns that apply to this code:
{hints}

{dialect} SQL to convert:
<<<
{legacy_sql}
>>>"""


def _matching_hints(session, dialect, legacy_sql):
    rows = (session.table(PATTERN_TABLE)
            .filter(col("SOURCE_DIALECT") == dialect)
            .select("PATTERN_ID", "LEGACY_PATTERN", "SNOWFLAKE_EQUIVALENT", "NOTES", "DETECT_REGEX")
            .collect())
    text = legacy_sql.upper()
    hits = []
    for r in rows:
        try:
            if r["DETECT_REGEX"] and re.search(r["DETECT_REGEX"], text, re.MULTILINE):
                hits.append(r)
        except re.error:
            continue
    return hits[:MAX_HINTS]


def _extract_json(raw):
    if raw is None:
        return None
    text = raw.strip()
    # AI_COMPLETE may return a JSON-encoded string; unwrap it once
    if text.startswith('"') and text.endswith('"'):
        try:
            text = json.loads(text)
        except ValueError:
            pass
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        return json.loads(text[start:end + 1])
    except ValueError:
        return None


def _validate(session, sql_text):
    stmt = sql_text.strip().rstrip(";").strip()
    without_comments = re.sub(r"--[^\n]*", "", stmt).strip()
    if ";" in without_comments:
        return "NOT_VALIDATED", "Multiple statements - compile manually"
    if not re.match(r"^(SELECT|WITH|INSERT|UPDATE|DELETE|MERGE)\b", without_comments, re.IGNORECASE):
        return "NOT_VALIDATED", "Only single SELECT / DML statements are compiled automatically"
    try:
        session.sql("EXPLAIN USING TEXT " + stmt).collect()
        return "VALIDATED", "Compiled successfully with EXPLAIN"
    except Exception as exc:  # missing objects are the most common reason
        return "NEEDS_REVIEW", str(exc)[:2000]


def main(session, legacy_sql, source_dialect, object_name, model, validate):
    run_id = str(uuid.uuid4())
    dialect = (source_dialect or "").strip()
    model = (model or "llama3.1-70b").strip()
    hints = _matching_hints(session, dialect, legacy_sql or "")
    hint_text = "\n".join(
        f"- [{h['PATTERN_ID']}] {h['LEGACY_PATTERN']} -> {h['SNOWFLAKE_EQUIVALENT']}. {h['NOTES'] or ''}".strip()
        for h in hints) or "- (no library pattern matched)"
    prompt = PROMPT.format(dialect=dialect, hints=hint_text, legacy_sql=legacy_sql)

    raw, parsed = None, None
    status, message = "AI_ERROR", None
    try:
        df = session.create_dataframe([[prompt]], schema=["P"])
        raw = df.select(call_function("AI_COMPLETE", lit(model), col("P")).alias("R")).collect()[0]["R"]
        parsed = _extract_json(raw)
        status = "PARSE_ERROR" if parsed is None else "NOT_VALIDATED"
        message = "Model reply was not valid JSON" if parsed is None else None
    except Exception as exc:
        message = str(exc)[:2000]

    sf_sql = (parsed or {}).get("snowflake_sql")
    changes = (parsed or {}).get("changes", [])
    warnings = (parsed or {}).get("warnings", [])
    confidence = (parsed or {}).get("confidence")
    if parsed is not None and sf_sql and validate:
        status, message = _validate(session, sf_sql)

    schema = StructType([StructField(n, StringType()) for n in
                         ["RUN_ID", "SOURCE_DIALECT", "OBJECT_NAME", "MODEL", "LEGACY_SQL", "SNOWFLAKE_SQL",
                          "CHANGES_J", "WARNINGS_J", "CONFIDENCE", "PATTERNS_USED", "STATUS",
                          "VALIDATION_MESSAGE", "RAW_RESPONSE"]])
    row = [run_id, dialect, object_name, model, legacy_sql, sf_sql, json.dumps(changes), json.dumps(warnings),
           confidence, ",".join(h["PATTERN_ID"] for h in hints), status, message,
           None if raw is None else str(raw)]
    (session.create_dataframe([row], schema=schema)
        .select(col("RUN_ID"), current_timestamp().alias("RUN_TS"), col("SOURCE_DIALECT"), col("OBJECT_NAME"),
                col("MODEL"), col("LEGACY_SQL"), col("SNOWFLAKE_SQL"),
                parse_json(col("CHANGES_J")).alias("CHANGES"), parse_json(col("WARNINGS_J")).alias("WARNINGS"),
                col("CONFIDENCE"), col("PATTERNS_USED"), col("STATUS"), col("VALIDATION_MESSAGE"),
                col("RAW_RESPONSE"), current_user().alias("CALLED_BY"))
        .write.mode("append").save_as_table(LOG_TABLE, column_order="name"))

    return {
        "run_id": run_id,
        "status": status,
        "confidence": confidence,
        "snowflake_sql": sf_sql,
        "changes": changes,
        "warnings": warnings,
        "patterns_used": [h["PATTERN_ID"] for h in hints],
        "validation_message": message,
    }
$$;

------------------------------------------------------------------------------
-- 3. Batch converter for CONVERSION_QUEUE
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_CONVERT_QUEUE(
    MODEL     VARCHAR DEFAULT 'llama3.1-70b',   -- EDIT ME
    MAX_ITEMS NUMBER  DEFAULT 50)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
COMMENT = 'Converts PENDING rows of CONVERSION_QUEUE via SP_CONVERT_SQL'
AS
$$
import json

from snowflake.snowpark.functions import col


def main(session, model, max_items):
    queue = "ACCEL_DB.CODE_CONVERSION.CONVERSION_QUEUE"
    rows = (session.table(queue).filter(col("STATUS") == "PENDING")
            .sort(col("QUEUE_ID")).limit(int(max_items)).collect())
    summary = {}
    for r in rows:
        result = session.call("ACCEL_DB.CODE_CONVERSION.SP_CONVERT_SQL",
                              r["LEGACY_SQL"], r["SOURCE_DIALECT"], r["OBJECT_NAME"], model, True)
        result = json.loads(result) if isinstance(result, str) else result
        status = result.get("status", "AI_ERROR")
        summary[status] = summary.get(status, 0) + 1
        session.table(queue).update(
            {"STATUS": "DONE" if status in ("VALIDATED", "NOT_VALIDATED", "NEEDS_REVIEW") else "FAILED",
             "LAST_RUN_ID": result.get("run_id")},
            col("QUEUE_ID") == r["QUEUE_ID"])
    return f"Processed {len(rows)} item(s): " + ", ".join(f"{k}={v}" for k, v in sorted(summary.items()))
$$;

------------------------------------------------------------------------------
-- 4. Review view
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_CONVERSION_REVIEW AS
SELECT RUN_TS, OBJECT_NAME, SOURCE_DIALECT, MODEL, STATUS, CONFIDENCE, PATTERNS_USED,
       ARRAY_SIZE(CHANGES)  AS N_CHANGES,
       ARRAY_SIZE(WARNINGS) AS N_WARNINGS,
       LEGACY_SQL, SNOWFLAKE_SQL, WARNINGS, VALIDATION_MESSAGE, RUN_ID
FROM CONVERSION_LOG;

------------------------------------------------------------------------------
-- 5. Demo
------------------------------------------------------------------------------
-- Single conversion
CALL SP_CONVERT_SQL(
  $$SEL TOP 10 c.CUST_ID, c.CUST_NAME, ZEROIFNULL(SUM(f.ORDER_AMT)) AS REVENUE
FROM CORE.ORDER_FACT f
JOIN CORE.CUSTOMER_DIM c ON c.CUSTOMER_KEY = f.CUSTOMER_KEY
WHERE f.ORDER_DATE >= DATE - 90
  AND c.VALID_PERIOD CONTAINS CURRENT_DATE
GROUP BY 1, 2
ORDER BY 3 DESC;$$,
  'Teradata',
  'EDW_PROD.MART.V_TOP_CUSTOMERS_90D');

-- Batch: queue sample snippets (skipped if they are already queued)
INSERT INTO CONVERSION_QUEUE (SOURCE_DIALECT, OBJECT_NAME, LEGACY_SQL)
SELECT v.DIALECT, v.NAME, v.CODE
FROM (
  SELECT 'Teradata' AS DIALECT, 'ETL.LOAD_CUST_VT' AS NAME,
         $$CREATE VOLATILE TABLE VT_CUST AS (
  SEL CUST_ID, CUST_NAME FROM STG.STG_CUSTOMER
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CUST_ID ORDER BY LOAD_TS DESC) = 1
) WITH DATA PRIMARY INDEX (CUST_ID) ON COMMIT PRESERVE ROWS;
UPDATE CORE.CUSTOMER_DIM FROM VT_CUST v SET CUST_NAME = v.CUST_NAME WHERE CORE.CUSTOMER_DIM.CUST_ID = v.CUST_ID;
COLLECT STATISTICS ON CORE.CUSTOMER_DIM COLUMN (CUST_ID);$$ AS CODE
  UNION ALL
  SELECT 'Oracle', 'GL.V_ACCOUNT_TREE',
         $$SELECT ACCOUNT_ID, LPAD(' ', 2 * (LEVEL - 1)) || ACCOUNT_NAME AS TREE, SYS_CONNECT_BY_PATH(ACCOUNT_CODE, '/') AS PATH
FROM GL.GL_ACCOUNTS
START WITH PARENT_ACCOUNT_ID IS NULL
CONNECT BY NOCYCLE PRIOR ACCOUNT_ID = PARENT_ACCOUNT_ID
ORDER SIBLINGS BY ACCOUNT_CODE$$
  UNION ALL
  SELECT 'Oracle', 'AP.TOP_OPEN_INVOICES',
         $$SELECT * FROM (
  SELECT s.SUPPLIER_NAME, i.INVOICE_NUM, NVL2(i.PAID_DATE, 'PAID', 'OPEN') AS STATE,
         TRUNC(SYSDATE) - TRUNC(i.INVOICE_DATE) AS DAYS_OPEN
  FROM AP.AP_INVOICES i, AP.AP_SUPPLIERS s
  WHERE i.SUPPLIER_ID = s.SUPPLIER_ID (+)
  ORDER BY i.INVOICE_AMOUNT DESC
) WHERE ROWNUM <= 20$$
  UNION ALL
  SELECT 'SQL Server', 'dbo.usp_daily_sales',
         $$DECLARE @d DATE = DATEADD(DAY, -1, GETDATE());
SELECT TOP 100 o.StoreId, ISNULL(SUM(o.Total), 0) AS Revenue, CONVERT(VARCHAR(8), @d, 112) AS DayKey
INTO #daily
FROM dbo.Orders o WITH (NOLOCK)
WHERE o.OrderDate = @d
GROUP BY o.StoreId
ORDER BY Revenue DESC;$$
) v
WHERE NOT EXISTS (SELECT 1 FROM CONVERSION_QUEUE q WHERE q.OBJECT_NAME = v.NAME);

-- Optional: queue code from the migration assessment inventory (if that asset is installed)
-- INSERT INTO CONVERSION_QUEUE (SOURCE_DIALECT, OBJECT_NAME, LEGACY_SQL)
-- SELECT o.SOURCE_PLATFORM, o.FULL_NAME, c.CODE_TEXT
-- FROM ACCEL_DB.MIGRATION_ASSESSMENT.SRC_CODE c
-- JOIN ACCEL_DB.MIGRATION_ASSESSMENT.SRC_OBJECTS o ON o.FULL_NAME = c.FULL_NAME
-- WHERE o.OBJECT_TYPE IN ('VIEW', 'PROCEDURE', 'MACRO');

CALL SP_CONVERT_QUEUE();

SELECT * FROM V_CONVERSION_REVIEW ORDER BY RUN_TS DESC;
