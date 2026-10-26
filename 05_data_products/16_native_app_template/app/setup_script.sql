-- =============================================================================
-- Data Health Checker - Native App setup script
-- Runs inside the consumer account at install and at every upgrade.
-- Must be idempotent: IF NOT EXISTS for state, OR REPLACE for code.
-- =============================================================================

-- 1. Application role granted to the consumer's roles
CREATE APPLICATION ROLE IF NOT EXISTS APP_PUBLIC;

-- 2. Stateful schema: results survive upgrades (NOT versioned)
CREATE SCHEMA IF NOT EXISTS DATA;
GRANT USAGE ON SCHEMA DATA TO APPLICATION ROLE APP_PUBLIC;

CREATE TABLE IF NOT EXISTS DATA.PROFILE_RUNS (
    RUN_ID              VARCHAR,
    RUN_TS              TIMESTAMP_NTZ,
    ROW_COUNT           NUMBER,
    COLUMN_COUNT        NUMBER,
    DUPLICATE_ROWS_EST  NUMBER,
    AVG_NULL_PCT        NUMBER(6,2),
    COLUMNS_WITH_ISSUES NUMBER,
    HEALTH_SCORE        NUMBER(5,1)
);

CREATE TABLE IF NOT EXISTS DATA.COLUMN_PROFILES (
    RUN_ID          VARCHAR,
    ORDINAL         NUMBER,
    COLUMN_NAME     VARCHAR,
    DATA_TYPE       VARCHAR,
    NULL_COUNT      NUMBER,
    NULL_PCT        NUMBER(6,2),
    DISTINCT_EST    NUMBER,
    DISTINCT_PCT    NUMBER(6,2),
    MIN_VALUE       VARCHAR,
    MAX_VALUE       VARCHAR,
    ISSUES          VARCHAR
);

GRANT SELECT ON TABLE DATA.PROFILE_RUNS    TO APPLICATION ROLE APP_PUBLIC;
GRANT SELECT ON TABLE DATA.COLUMN_PROFILES TO APPLICATION ROLE APP_PUBLIC;

-- 3. Versioned schema: code objects, replaced atomically on upgrade
CREATE OR ALTER VERSIONED SCHEMA CORE;
GRANT USAGE ON SCHEMA CORE TO APPLICATION ROLE APP_PUBLIC;

-- 3a. Reference callback (called when the consumer binds / unbinds the table)
CREATE OR REPLACE PROCEDURE CORE.REGISTER_SINGLE_REFERENCE(REF_NAME STRING, OPERATION STRING, REF_OR_ALIAS STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    CASE (OPERATION)
        WHEN 'ADD' THEN
            SELECT SYSTEM$SET_REFERENCE(:REF_NAME, :REF_OR_ALIAS);
        WHEN 'REMOVE' THEN
            SELECT SYSTEM$REMOVE_REFERENCE(:REF_NAME);
        WHEN 'CLEAR' THEN
            SELECT SYSTEM$REMOVE_REFERENCE(:REF_NAME);
        ELSE
            RETURN 'Unknown operation: ' || OPERATION;
    END CASE;
    RETURN 'Operation ' || OPERATION || ' succeeded';
END;
$$;

GRANT USAGE ON PROCEDURE CORE.REGISTER_SINGLE_REFERENCE(STRING, STRING, STRING)
    TO APPLICATION ROLE APP_PUBLIC;

-- 3b. Profiler: reads the bound table through reference('consumer_table')
CREATE OR REPLACE PROCEDURE CORE.PROFILE_TABLE()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import uuid

from snowflake.snowpark.types import (
    StructType, StructField, StringType, LongType, DoubleType
)

REF = "reference('consumer_table')"
MAX_COLUMNS = 200
NO_MINMAX_TYPES = {"VariantType", "ArrayType", "MapType", "GeographyType",
                   "GeometryType", "BinaryType", "VectorType", "StructType"}


def run(session):
    fields = session.sql(f"SELECT * FROM {REF} LIMIT 0").schema.fields[:MAX_COLUMNS]
    if not fields:
        return {"status": "error", "message": "Bound table has no columns."}

    exprs = ["COUNT(*) AS ROW_CNT", "APPROX_COUNT_DISTINCT(HASH(*)) AS DISTINCT_ROWS"]
    for i, f in enumerate(fields):
        col = f.name
        tname = type(f.datatype).__name__
        exprs.append(f"COUNT_IF({col} IS NULL) AS N_{i}")
        if tname in NO_MINMAX_TYPES:
            exprs.append(f"NULL AS D_{i}")
            exprs.append(f"NULL AS MN_{i}")
            exprs.append(f"NULL AS MX_{i}")
        else:
            exprs.append(f"APPROX_COUNT_DISTINCT({col}) AS D_{i}")
            exprs.append(f"LEFT(TO_VARCHAR(MIN({col})), 100) AS MN_{i}")
            exprs.append(f"LEFT(TO_VARCHAR(MAX({col})), 100) AS MX_{i}")

    row = session.sql(f"SELECT {', '.join(exprs)} FROM {REF}").collect()[0].as_dict()
    total = int(row["ROW_CNT"] or 0)
    dup_est = max(total - int(row["DISTINCT_ROWS"] or 0), 0)

    run_id = str(uuid.uuid4())
    col_rows = []
    issue_cols = 0
    null_pcts = []
    for i, f in enumerate(fields):
        nulls = int(row[f"N_{i}"] or 0)
        distinct = row[f"D_{i}"]
        distinct = int(distinct) if distinct is not None else None
        null_pct = round(100.0 * nulls / total, 2) if total else 0.0
        distinct_pct = round(100.0 * distinct / total, 2) if (total and distinct is not None) else None
        null_pcts.append(null_pct)

        issues = []
        if total and nulls == total:
            issues.append("EMPTY_COLUMN")
        elif null_pct >= 50:
            issues.append("HIGH_NULLS")
        elif null_pct >= 10:
            issues.append("SOME_NULLS")
        if distinct is not None and total > 1 and distinct == 1:
            issues.append("CONSTANT_VALUE")
        name_up = f.name.strip('"').upper()
        if (name_up.endswith("_ID") or name_up == "ID") and distinct_pct is not None and distinct_pct < 98:
            issues.append("ID_NOT_UNIQUE")
        if issues:
            issue_cols += 1

        col_rows.append([
            run_id, i + 1, f.name.strip('"'), type(f.datatype).__name__.replace("Type", "").upper(),
            nulls, null_pct, distinct, distinct_pct,
            row[f"MN_{i}"], row[f"MX_{i}"], ", ".join(issues) if issues else None,
        ])

    avg_null = round(sum(null_pcts) / len(null_pcts), 2)
    dup_pct = 100.0 * dup_est / total if total else 0.0
    score = 100.0
    score -= min(40.0, avg_null * 0.8)
    score -= min(30.0, 30.0 * issue_cols / len(fields))
    score -= min(30.0, dup_pct)
    score = round(max(score, 0.0), 1)

    schema = StructType([
        StructField("RUN_ID", StringType()), StructField("ORDINAL", LongType()),
        StructField("COLUMN_NAME", StringType()), StructField("DATA_TYPE", StringType()),
        StructField("NULL_COUNT", LongType()), StructField("NULL_PCT", DoubleType()),
        StructField("DISTINCT_EST", LongType()), StructField("DISTINCT_PCT", DoubleType()),
        StructField("MIN_VALUE", StringType()), StructField("MAX_VALUE", StringType()),
        StructField("ISSUES", StringType()),
    ])
    session.create_dataframe(col_rows, schema=schema).write.mode("append").save_as_table("DATA.COLUMN_PROFILES")

    session.sql(
        "INSERT INTO DATA.PROFILE_RUNS (RUN_ID, RUN_TS, ROW_COUNT, COLUMN_COUNT, DUPLICATE_ROWS_EST, "
        "AVG_NULL_PCT, COLUMNS_WITH_ISSUES, HEALTH_SCORE) "
        "SELECT ?, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, ?, ?, ?, ?, ?, ?",
        params=[run_id, total, len(fields), dup_est, avg_null, issue_cols, score],
    ).collect()

    return {
        "status": "ok", "run_id": run_id, "rows": total, "columns": len(fields),
        "duplicate_rows_est": dup_est, "avg_null_pct": avg_null,
        "columns_with_issues": issue_cols, "health_score": score,
    }
$$;

GRANT USAGE ON PROCEDURE CORE.PROFILE_TABLE() TO APPLICATION ROLE APP_PUBLIC;

-- 3c. Convenience view over the latest run
CREATE OR REPLACE VIEW CORE.LATEST_COLUMN_PROFILE AS
SELECT c.*
FROM DATA.COLUMN_PROFILES c
WHERE c.RUN_ID = (SELECT RUN_ID FROM DATA.PROFILE_RUNS ORDER BY RUN_TS DESC LIMIT 1);

GRANT SELECT ON VIEW CORE.LATEST_COLUMN_PROFILE TO APPLICATION ROLE APP_PUBLIC;

-- 4. Streamlit UI (files live under /streamlit in the version stage)
CREATE OR REPLACE STREAMLIT CORE.DATA_HEALTH_UI
    FROM '/streamlit/'
    MAIN_FILE = 'app.py';

GRANT USAGE ON STREAMLIT CORE.DATA_HEALTH_UI TO APPLICATION ROLE APP_PUBLIC;
