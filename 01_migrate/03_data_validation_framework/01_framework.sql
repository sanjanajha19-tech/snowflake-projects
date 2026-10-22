/*=============================================================================
  DATA VALIDATION FRAMEWORK 01 - Tables, procedures and views
  Creates: VALIDATION_CONFIG (source -> target pairs), result tables,
           SP_RUN_VALIDATION (aggregate + checksum comparison),
           SP_ROW_DIFF (sampled key-level diff for failed pairs),
           VALIDATION_SIGNOFF and summary views.
  Checks per pair: schema (missing / extra columns, type changes), row count,
           table checksum (HASH_AGG of all columns) and, per column: null count,
           distinct count, min, max, sum (numeric) and HASH_AGG checksum.
  Tables are referenced as DATABASE.SCHEMA.TABLE (views work too). The source
  side is normally the legacy data landed in Snowflake (extract, external or
  Iceberg table), so both sides are compared with the same engine.
  Run as : ACCEL_ADMIN. Rerun: safe (config, results and sign-offs are kept).
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS VALIDATION;
USE SCHEMA VALIDATION;

------------------------------------------------------------------------------
-- 1. Configuration
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS VALIDATION_CONFIG (
  PAIR_ID                NUMBER,
  PAIR_NAME              VARCHAR,
  SOURCE_TABLE           VARCHAR,              -- DB.SCHEMA.TABLE (legacy copy)
  TARGET_TABLE           VARCHAR,              -- DB.SCHEMA.TABLE (migrated)
  KEY_COLUMNS            VARCHAR,              -- comma-separated business key, used by the row diff
  EXCLUDE_COLUMNS        VARCHAR,              -- comma-separated, e.g. load timestamps / audit columns
  NUMERIC_TOLERANCE_PCT  NUMBER(9,4) DEFAULT 0, -- allowed SUM variance in %, 0 = exact
  SAMPLE_PCT             NUMBER(5,2) DEFAULT 100, -- <100 = consistent key-hash sample on both sides
  DIFF_SAMPLE_ROWS       NUMBER DEFAULT 20,    -- example rows kept per diff type
  IS_ACTIVE              BOOLEAN DEFAULT TRUE,
  DATA_OWNER             VARCHAR,
  NOTES                  VARCHAR
) COMMENT = 'Source -> target table pairs to validate';

------------------------------------------------------------------------------
-- 2. Results
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS VALIDATION_RUNS (
  RUN_ID         VARCHAR,
  RUN_TS         TIMESTAMP_LTZ,
  TRIGGERED_BY   VARCHAR,
  PAIRS          NUMBER,
  PAIRS_PASSED   NUMBER,
  PAIRS_FAILED   NUMBER,
  PAIRS_ERROR    NUMBER,
  DURATION_SEC   FLOAT
);

CREATE TABLE IF NOT EXISTS VALIDATION_PAIR_RUNS (
  RUN_ID         VARCHAR,
  RUN_TS         TIMESTAMP_LTZ,
  PAIR_ID        NUMBER,
  PAIR_NAME      VARCHAR,
  SOURCE_TABLE   VARCHAR,
  TARGET_TABLE   VARCHAR,
  SOURCE_ROWS    NUMBER,
  TARGET_ROWS    NUMBER,
  CHECKS_RUN     NUMBER,
  CHECKS_FAILED  NUMBER,
  CHECKS_WARNED  NUMBER,
  STATUS         VARCHAR,       -- PASS | FAIL | ERROR
  ERROR_MESSAGE  VARCHAR,
  DURATION_SEC   FLOAT
);

CREATE TABLE IF NOT EXISTS VALIDATION_RESULTS (
  RUN_ID         VARCHAR,
  RUN_TS         TIMESTAMP_LTZ,
  PAIR_ID        NUMBER,
  PAIR_NAME      VARCHAR,
  CHECK_TYPE     VARCHAR,       -- SCHEMA | ROW_COUNT | TABLE_CHECKSUM | NULL_COUNT | DISTINCT_COUNT | MIN | MAX | SUM | CHECKSUM | ROW_DIFF
  COLUMN_NAME    VARCHAR,
  SOURCE_VALUE   VARCHAR,
  TARGET_VALUE   VARCHAR,
  VARIANCE       FLOAT,         -- target - source (numeric checks)
  VARIANCE_PCT   FLOAT,
  STATUS         VARCHAR,       -- PASS | FAIL | WARN
  DETAIL         VARCHAR
);

CREATE TABLE IF NOT EXISTS VALIDATION_ROW_DIFFS (
  RUN_ID        VARCHAR,
  PAIR_ID       NUMBER,
  DIFF_TYPE     VARCHAR,        -- MISSING_IN_TARGET | MISSING_IN_SOURCE | VALUE_MISMATCH
  KEY_VALUES    VARIANT,
  DIFF_COLUMNS  ARRAY,
  SOURCE_ROW    VARIANT,
  TARGET_ROW    VARIANT,
  CAPTURED_AT   TIMESTAMP_LTZ
);

CREATE TABLE IF NOT EXISTS VALIDATION_SIGNOFF (
  PAIR_ID     NUMBER,
  RUN_ID      VARCHAR,
  DECISION    VARCHAR,          -- APPROVED | APPROVED_WITH_EXCEPTIONS | REJECTED
  SIGNED_BY   VARCHAR,
  COMMENTS    VARCHAR,
  SIGNED_AT   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

------------------------------------------------------------------------------
-- 3. SP_ROW_DIFF: key-level diff, sampled examples + counts
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_ROW_DIFF(
    RUN_ID      VARCHAR,
    PAIR_ID     NUMBER,
    MAX_ROWS    NUMBER DEFAULT NULL)        -- NULL = DIFF_SAMPLE_ROWS from config
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
COMMENT = 'Row-level diff on key columns for one validation pair'
AS
$$
from snowflake.snowpark.functions import col, current_timestamp
from snowflake.snowpark.types import DoubleType, LongType, StringType, StructField, StructType

SCHEMA = "ACCEL_DB.VALIDATION"
NO_HASH_TYPES = {"GEOGRAPHY", "GEOMETRY", "VECTOR"}


def qi(name):
    return '"' + name.replace('"', '""') + '"'


def lit_str(value):
    return "'" + str(value).replace("\\", "\\\\").replace("'", "''") + "'"


def split_name(full):
    parts = [p.strip() for p in (full or "").split(".")]
    if len(parts) != 3 or not all(parts):
        raise ValueError(f"Use DATABASE.SCHEMA.TABLE, got: {full}")
    return [p[1:-1].replace('""', '"') if p.startswith('"') and p.endswith('"') else p.upper() for p in parts]


def ref(full):
    return ".".join(qi(p) for p in split_name(full))


def get_columns(session, full):
    db, sch, tbl = split_name(full)
    rows = session.sql(
        f"SELECT COLUMN_NAME, DATA_TYPE FROM {qi(db)}.INFORMATION_SCHEMA.COLUMNS "
        f"WHERE TABLE_SCHEMA = {lit_str(sch)} AND TABLE_NAME = {lit_str(tbl)} ORDER BY ORDINAL_POSITION").collect()
    if not rows:
        raise ValueError(f"Table not found or not accessible: {full}")
    return [(r[0], str(r[1]).upper()) for r in rows]


def csv_list(text):
    return [x.strip().strip('"').upper() for x in (text or "").split(",") if x.strip()]


def sample_clause(keys, pct):
    if pct is None or float(pct) >= 100:
        return ""
    return f" WHERE MOD(ABS(HASH({', '.join(qi(k) for k in keys)})), 10000) < {int(float(pct) * 100)}"


def main(session, run_id, pair_id, max_rows):
    cfg = session.table(f"{SCHEMA}.VALIDATION_CONFIG").filter(col("PAIR_ID") == pair_id).collect()
    if not cfg:
        return f"Pair {pair_id} not found"
    c = cfg[0]
    src, tgt = c["SOURCE_TABLE"], c["TARGET_TABLE"]
    n = int(max_rows if max_rows is not None else (c["DIFF_SAMPLE_ROWS"] or 20))

    src_cols = dict((name.upper(), (name, typ)) for name, typ in get_columns(session, src))
    tgt_cols = dict((name.upper(), (name, typ)) for name, typ in get_columns(session, tgt))
    excluded = set(csv_list(c["EXCLUDE_COLUMNS"]))
    key_up = csv_list(c["KEY_COLUMNS"])
    if not key_up:
        return f"Pair {pair_id}: KEY_COLUMNS not configured - row diff skipped"
    missing = [k for k in key_up if k not in src_cols or k not in tgt_cols]
    if missing:
        return f"Pair {pair_id}: key column(s) {missing} not found on both sides"

    keys = [tgt_cols[k][0] for k in key_up]
    common = [u for u in tgt_cols if u in src_cols and u not in excluded]
    compare = [tgt_cols[u][0] for u in common
               if u not in key_up and tgt_cols[u][1] not in NO_HASH_TYPES and src_cols[u][1] not in NO_HASH_TYPES]
    shown = [tgt_cols[u][0] for u in common]

    kl = ", ".join(qi(k) for k in keys)
    hash_expr = f"HASH({', '.join(qi(x) for x in compare)})" if compare else "0"
    samp = sample_clause(keys, c["SAMPLE_PCT"])
    on_st = " AND ".join(f"s.{qi(k)} = t.{qi(k)}" for k in keys)
    base = f"""
WITH s AS (SELECT {kl}, {hash_expr} AS "__H", 1 AS "__P" FROM {ref(src)}{samp}),
t AS (SELECT {kl}, {hash_expr} AS "__H", 1 AS "__P" FROM {ref(tgt)}{samp}),
d AS (
  SELECT {', '.join(f's.{qi(k)} AS "__S_{i}", t.{qi(k)} AS "__T_{i}"' for i, k in enumerate(keys))},
         {', '.join(f'COALESCE(s.{qi(k)}, t.{qi(k)}) AS {qi(k)}' for k in keys)},
         CASE WHEN t."__P" IS NULL THEN 'MISSING_IN_TARGET'
              WHEN s."__P" IS NULL THEN 'MISSING_IN_SOURCE'
              WHEN s."__H" <> t."__H" THEN 'VALUE_MISMATCH' END AS DIFF_TYPE
  FROM s FULL OUTER JOIN t ON {on_st}
)"""

    counts = session.sql(base + " SELECT DIFF_TYPE, COUNT(*) AS N FROM d WHERE DIFF_TYPE IS NOT NULL GROUP BY DIFF_TYPE").collect()
    count_map = {r["DIFF_TYPE"]: int(r["N"]) for r in counts}

    session.sql(f"DELETE FROM {SCHEMA}.VALIDATION_ROW_DIFFS WHERE RUN_ID = {lit_str(run_id)} AND PAIR_ID = {int(pair_id)}").collect()
    if count_map:
        key_obj = ", ".join(f"{lit_str(k)}, x.{qi(k)}" for k in keys)
        diff_cols = ", ".join(
            f"IFF(x.DIFF_TYPE = 'VALUE_MISMATCH' AND NOT EQUAL_NULL(sr.{qi(x)}, tr.{qi(x)}), {lit_str(x)}, NULL)"
            for x in compare)
        src_obj = ", ".join(f"{lit_str(x)}, sr.{qi(x)}" for x in shown)
        tgt_obj = ", ".join(f"{lit_str(x)}, tr.{qi(x)}" for x in shown)
        on_sr = " AND ".join(f"sr.{qi(k)} = x.\"__S_{i}\"" for i, k in enumerate(keys))
        on_tr = " AND ".join(f"tr.{qi(k)} = x.\"__T_{i}\"" for i, k in enumerate(keys))
        insert_sql = f"""
INSERT INTO {SCHEMA}.VALIDATION_ROW_DIFFS
  (RUN_ID, PAIR_ID, DIFF_TYPE, KEY_VALUES, DIFF_COLUMNS, SOURCE_ROW, TARGET_ROW, CAPTURED_AT)
{base},
x AS (
  SELECT * FROM d WHERE DIFF_TYPE IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY DIFF_TYPE ORDER BY HASH({', '.join('d.' + qi(k) for k in keys)})) <= {n}
)
SELECT {lit_str(run_id)}, {int(pair_id)}, x.DIFF_TYPE,
       OBJECT_CONSTRUCT_KEEP_NULL({key_obj}),
       ARRAY_COMPACT(ARRAY_CONSTRUCT({diff_cols})),
       IFF(sr."__P" IS NULL, NULL, OBJECT_CONSTRUCT_KEEP_NULL({src_obj})),
       IFF(tr."__P" IS NULL, NULL, OBJECT_CONSTRUCT_KEEP_NULL({tgt_obj})),
       CURRENT_TIMESTAMP()
FROM x
LEFT JOIN (SELECT *, 1 AS "__P" FROM {ref(src)}) sr ON {on_sr}
LEFT JOIN (SELECT *, 1 AS "__P" FROM {ref(tgt)}) tr ON {on_tr}"""
        session.sql(insert_sql).collect()

    # Diff counts also go to VALIDATION_RESULTS (CHECK_TYPE = ROW_DIFF)
    session.sql(f"DELETE FROM {SCHEMA}.VALIDATION_RESULTS WHERE RUN_ID = {lit_str(run_id)} "
                f"AND PAIR_ID = {int(pair_id)} AND CHECK_TYPE = 'ROW_DIFF'").collect()
    rows = [(run_id, int(pair_id), c["PAIR_NAME"], "ROW_DIFF", t, None, str(count_map.get(t, 0)),
             float(count_map.get(t, 0)), None, "FAIL" if count_map.get(t, 0) else "PASS",
             f"Rows with diff type {t}; up to {n} examples in VALIDATION_ROW_DIFFS")
            for t in ("MISSING_IN_TARGET", "MISSING_IN_SOURCE", "VALUE_MISMATCH")]
    schema = StructType([
        StructField("RUN_ID", StringType()), StructField("PAIR_ID", LongType()),
        StructField("PAIR_NAME", StringType()), StructField("CHECK_TYPE", StringType()),
        StructField("COLUMN_NAME", StringType()), StructField("SOURCE_VALUE", StringType()),
        StructField("TARGET_VALUE", StringType()), StructField("VARIANCE", DoubleType()),
        StructField("VARIANCE_PCT", DoubleType()), StructField("STATUS", StringType()),
        StructField("DETAIL", StringType())])
    (session.create_dataframe(rows, schema=schema)
        .with_column("RUN_TS", current_timestamp())
        .write.mode("append").save_as_table(f"{SCHEMA}.VALIDATION_RESULTS", column_order="name"))

    total = sum(count_map.values())
    return (f"Pair {pair_id}: {total} differing keys "
            + (", ".join(f"{k}={v}" for k, v in sorted(count_map.items())) if count_map else "(none)"))
$$;

------------------------------------------------------------------------------
-- 4. SP_RUN_VALIDATION: aggregate checks for all active pairs (or one)
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_RUN_VALIDATION(
    PAIR_ID        NUMBER  DEFAULT NULL,     -- NULL = all active pairs
    AUTO_ROW_DIFF  BOOLEAN DEFAULT TRUE)     -- run SP_ROW_DIFF for failed pairs
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
COMMENT = 'Compares source/target pairs: counts, nulls, distincts, min/max, sums, HASH_AGG checksums'
AS
$$
import time
import uuid
from decimal import Decimal, InvalidOperation

from snowflake.snowpark.functions import col, current_timestamp
from snowflake.snowpark.types import DoubleType, LongType, StringType, StructField, StructType

SCHEMA = "ACCEL_DB.VALIDATION"
NUMERIC_TYPES = {"NUMBER", "DECIMAL", "NUMERIC", "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT",
                 "BYTEINT", "FLOAT", "FLOAT4", "FLOAT8", "DOUBLE", "DOUBLE PRECISION", "REAL", "FIXED"}
NO_DISTINCT_TYPES = {"VARIANT", "OBJECT", "ARRAY", "MAP", "GEOGRAPHY", "GEOMETRY", "VECTOR"}
NO_MINMAX_TYPES = NO_DISTINCT_TYPES | {"BOOLEAN", "BINARY"}
NO_HASH_TYPES = {"GEOGRAPHY", "GEOMETRY", "VECTOR"}

RESULT_FIELDS = [("RUN_ID", StringType()), ("PAIR_ID", LongType()), ("PAIR_NAME", StringType()),
                 ("CHECK_TYPE", StringType()), ("COLUMN_NAME", StringType()), ("SOURCE_VALUE", StringType()),
                 ("TARGET_VALUE", StringType()), ("VARIANCE", DoubleType()), ("VARIANCE_PCT", DoubleType()),
                 ("STATUS", StringType()), ("DETAIL", StringType())]
PAIR_FIELDS = [("RUN_ID", StringType()), ("PAIR_ID", LongType()), ("PAIR_NAME", StringType()),
               ("SOURCE_TABLE", StringType()), ("TARGET_TABLE", StringType()), ("SOURCE_ROWS", LongType()),
               ("TARGET_ROWS", LongType()), ("CHECKS_RUN", LongType()), ("CHECKS_FAILED", LongType()),
               ("CHECKS_WARNED", LongType()), ("STATUS", StringType()), ("ERROR_MESSAGE", StringType()),
               ("DURATION_SEC", DoubleType())]
RUN_FIELDS = [("RUN_ID", StringType()), ("TRIGGERED_BY", StringType()), ("PAIRS", LongType()),
              ("PAIRS_PASSED", LongType()), ("PAIRS_FAILED", LongType()), ("PAIRS_ERROR", LongType()),
              ("DURATION_SEC", DoubleType())]


def qi(name):
    return '"' + name.replace('"', '""') + '"'


def lit_str(value):
    return "'" + str(value).replace("\\", "\\\\").replace("'", "''") + "'"


def split_name(full):
    parts = [p.strip() for p in (full or "").split(".")]
    if len(parts) != 3 or not all(parts):
        raise ValueError(f"Use DATABASE.SCHEMA.TABLE, got: {full}")
    return [p[1:-1].replace('""', '"') if p.startswith('"') and p.endswith('"') else p.upper() for p in parts]


def ref(full):
    return ".".join(qi(p) for p in split_name(full))


def get_columns(session, full):
    db, sch, tbl = split_name(full)
    rows = session.sql(
        f"SELECT COLUMN_NAME, DATA_TYPE FROM {qi(db)}.INFORMATION_SCHEMA.COLUMNS "
        f"WHERE TABLE_SCHEMA = {lit_str(sch)} AND TABLE_NAME = {lit_str(tbl)} ORDER BY ORDINAL_POSITION").collect()
    if not rows:
        raise ValueError(f"Table not found or not accessible: {full}")
    return [(r[0], str(r[1]).upper()) for r in rows]


def csv_list(text):
    return [x.strip().strip('"').upper() for x in (text or "").split(",") if x.strip()]


def sample_clause(keys, pct):
    if pct is None or float(pct) >= 100 or not keys:
        return ""
    return f" WHERE MOD(ABS(HASH({', '.join(qi(k) for k in keys)})), 10000) < {int(float(pct) * 100)}"


def append(session, table, fields, rows):
    if not rows:
        return
    schema = StructType([StructField(n, t) for n, t in fields])
    (session.create_dataframe(rows, schema=schema)
        .with_column("RUN_TS", current_timestamp())
        .write.mode("append").save_as_table(f"{SCHEMA}.{table}", column_order="name"))


def to_dec(value):
    if value is None:
        return None
    try:
        return Decimal(str(value))
    except InvalidOperation:
        return None


def compare_numeric(sv, tv, tol_pct=Decimal(0)):
    s, t = to_dec(sv), to_dec(tv)
    if s is None and t is None:
        return None, None, "PASS"
    if s is None or t is None:
        return None, None, "FAIL"
    var = t - s
    pct = None if s == 0 else var / abs(s) * 100
    if var == 0 or (tol_pct > 0 and pct is not None and abs(pct) <= tol_pct):
        status = "PASS"
    else:
        status = "FAIL"
    return float(var), (None if pct is None else float(pct)), status


def as_text(value):
    return None if value is None else str(value)


def profile(session, full, cols, keys, pct):
    exprs = ["COUNT(*) AS ROW_CNT"]
    hash_cols = []
    for i, c in enumerate(cols):
        q = qi(c["name"])
        exprs.append(f"COUNT_IF({q} IS NULL) AS N{i}")
        if c["distinct"]:
            exprs.append(f"COUNT(DISTINCT {q}) AS D{i}")
        if c["minmax"]:
            exprs.append(f"MIN({q})::VARCHAR AS MN{i}")
            exprs.append(f"MAX({q})::VARCHAR AS MX{i}")
        if c["numeric"]:
            exprs.append(f"SUM({q})::VARCHAR AS S{i}")
        if c["hash"]:
            exprs.append(f"HASH_AGG({q}) AS H{i}")
            hash_cols.append(q)
    if hash_cols:
        exprs.append(f"HASH_AGG({', '.join(hash_cols)}) AS H_ALL")
    sql = f"SELECT {', '.join(exprs)} FROM {ref(full)}{sample_clause(keys, pct)}"
    return session.sql(sql).collect()[0].as_dict()


def validate_pair(session, run_id, cfg):
    pid, pname = int(cfg["PAIR_ID"]), cfg["PAIR_NAME"]
    src, tgt = cfg["SOURCE_TABLE"], cfg["TARGET_TABLE"]
    tol = to_dec(cfg["NUMERIC_TOLERANCE_PCT"]) or Decimal(0)
    results = []

    def add(check, column, sv, tv, var, pct, status, detail=None):
        results.append((run_id, pid, pname, check, column, as_text(sv), as_text(tv), var, pct, status, detail))

    src_cols = dict((n.upper(), (n, t)) for n, t in get_columns(session, src))
    tgt_cols = dict((n.upper(), (n, t)) for n, t in get_columns(session, tgt))
    excluded = set(csv_list(cfg["EXCLUDE_COLUMNS"]))
    keys = [tgt_cols[k][0] for k in csv_list(cfg["KEY_COLUMNS"]) if k in tgt_cols and k in src_cols]

    # Schema checks
    for u, (name, typ) in src_cols.items():
        if u in excluded:
            continue
        if u not in tgt_cols:
            add("SCHEMA", name, typ, None, None, None, "FAIL", "Column missing in target")
        elif tgt_cols[u][1] != typ:
            add("SCHEMA", name, typ, tgt_cols[u][1], None, None, "WARN", "Data type differs")
    for u, (name, typ) in tgt_cols.items():
        if u not in src_cols and u not in excluded:
            add("SCHEMA", name, None, typ, None, None, "WARN", "Extra column in target")

    cols = []
    for u, (name, ttyp) in tgt_cols.items():
        if u in excluded or u not in src_cols:
            continue
        styp = src_cols[u][1]
        types = {styp, ttyp}
        cols.append({
            "name": name,
            "numeric": styp in NUMERIC_TYPES and ttyp in NUMERIC_TYPES,
            "distinct": not (types & NO_DISTINCT_TYPES),
            "minmax": not (types & NO_MINMAX_TYPES),
            "hash": not (types & NO_HASH_TYPES),
        })

    sp = profile(session, src, cols, keys, cfg["SAMPLE_PCT"])
    tp = profile(session, tgt, cols, keys, cfg["SAMPLE_PCT"])

    var, pct, st = compare_numeric(sp["ROW_CNT"], tp["ROW_CNT"])
    add("ROW_COUNT", None, sp["ROW_CNT"], tp["ROW_CNT"], var, pct, st)
    if "H_ALL" in sp:
        add("TABLE_CHECKSUM", None, sp["H_ALL"], tp["H_ALL"], None, None,
            "PASS" if sp["H_ALL"] == tp["H_ALL"] else "FAIL", "HASH_AGG over all compared columns")

    for i, c in enumerate(cols):
        name = c["name"]
        var, pct, st = compare_numeric(sp[f"N{i}"], tp[f"N{i}"])
        add("NULL_COUNT", name, sp[f"N{i}"], tp[f"N{i}"], var, pct, st)
        if c["distinct"]:
            var, pct, st = compare_numeric(sp[f"D{i}"], tp[f"D{i}"])
            add("DISTINCT_COUNT", name, sp[f"D{i}"], tp[f"D{i}"], var, pct, st)
        if c["minmax"]:
            for chk, k in (("MIN", f"MN{i}"), ("MAX", f"MX{i}")):
                if c["numeric"]:
                    var, pct, st = compare_numeric(sp[k], tp[k])
                    add(chk, name, sp[k], tp[k], var, pct, st)
                else:
                    add(chk, name, sp[k], tp[k], None, None, "PASS" if sp[k] == tp[k] else "FAIL")
        if c["numeric"]:
            var, pct, st = compare_numeric(sp[f"S{i}"], tp[f"S{i}"], tol)
            add("SUM", name, sp[f"S{i}"], tp[f"S{i}"], var, pct, st,
                f"Tolerance {tol}%" if tol > 0 else None)
        if c["hash"]:
            add("CHECKSUM", name, sp[f"H{i}"], tp[f"H{i}"], None, None,
                "PASS" if sp[f"H{i}"] == tp[f"H{i}"] else "FAIL", "HASH_AGG of column")

    return results, int(sp["ROW_CNT"]), int(tp["ROW_CNT"])


def main(session, pair_id, auto_row_diff):
    t_run = time.time()
    run_id = str(uuid.uuid4())
    user = session.sql("SELECT CURRENT_USER()").collect()[0][0]

    cfg_df = session.table(f"{SCHEMA}.VALIDATION_CONFIG").filter(col("IS_ACTIVE"))
    if pair_id is not None:
        cfg_df = session.table(f"{SCHEMA}.VALIDATION_CONFIG").filter(col("PAIR_ID") == pair_id)
    pairs = cfg_df.sort(col("PAIR_ID")).collect()

    all_results, pair_rows, diff_messages = [], [], []
    passed = failed = errors = 0
    for cfg in pairs:
        t0 = time.time()
        pid = int(cfg["PAIR_ID"])
        try:
            res, s_rows, t_rows = validate_pair(session, run_id, cfg)
            n_fail = sum(1 for r in res if r[9] == "FAIL")
            n_warn = sum(1 for r in res if r[9] == "WARN")
            status = "FAIL" if n_fail else "PASS"
            all_results.extend(res)
            pair_rows.append((run_id, pid, cfg["PAIR_NAME"], cfg["SOURCE_TABLE"], cfg["TARGET_TABLE"],
                              s_rows, t_rows, len(res), n_fail, n_warn, status, None, round(time.time() - t0, 1)))
            passed += status == "PASS"
            failed += status == "FAIL"
        except Exception as exc:
            errors += 1
            pair_rows.append((run_id, pid, cfg["PAIR_NAME"], cfg["SOURCE_TABLE"], cfg["TARGET_TABLE"],
                              None, None, 0, 0, 0, "ERROR", str(exc)[:4000], round(time.time() - t0, 1)))

    append(session, "VALIDATION_RESULTS", RESULT_FIELDS, all_results)
    append(session, "VALIDATION_PAIR_RUNS", PAIR_FIELDS, pair_rows)

    if auto_row_diff:
        for p in pair_rows:
            if p[10] == "FAIL":
                try:
                    diff_messages.append(session.call(f"{SCHEMA}.SP_ROW_DIFF", run_id, p[1]))
                except Exception as exc:
                    diff_messages.append(f"Pair {p[1]}: row diff failed - {str(exc)[:300]}")

    append(session, "VALIDATION_RUNS", RUN_FIELDS,
           [(run_id, user, len(pairs), passed, failed, errors, round(time.time() - t_run, 1))])

    return {
        "run_id": run_id,
        "pairs": len(pairs),
        "passed": passed,
        "failed": failed,
        "errors": errors,
        "failed_pairs": [p[2] for p in pair_rows if p[10] != "PASS"],
        "row_diff": diff_messages,
    }
$$;

------------------------------------------------------------------------------
-- 5. Views
------------------------------------------------------------------------------
-- Latest run per pair + its latest sign-off
CREATE OR REPLACE VIEW V_LATEST_PAIR_STATUS AS
SELECT p.PAIR_ID, p.PAIR_NAME, p.SOURCE_TABLE, p.TARGET_TABLE, p.RUN_ID, p.RUN_TS,
       p.SOURCE_ROWS, p.TARGET_ROWS, p.TARGET_ROWS - p.SOURCE_ROWS AS ROW_VARIANCE,
       p.CHECKS_RUN, p.CHECKS_FAILED, p.CHECKS_WARNED, p.STATUS, p.ERROR_MESSAGE,
       s.DECISION AS SIGNOFF_DECISION, s.SIGNED_BY, s.SIGNED_AT, s.COMMENTS AS SIGNOFF_COMMENTS
FROM VALIDATION_PAIR_RUNS p
LEFT JOIN (
  SELECT * FROM VALIDATION_SIGNOFF
  QUALIFY ROW_NUMBER() OVER (PARTITION BY PAIR_ID, RUN_ID ORDER BY SIGNED_AT DESC) = 1
) s ON s.PAIR_ID = p.PAIR_ID AND s.RUN_ID = p.RUN_ID
QUALIFY ROW_NUMBER() OVER (PARTITION BY p.PAIR_ID ORDER BY p.RUN_TS DESC) = 1;

-- One row per run
CREATE OR REPLACE VIEW V_VALIDATION_SUMMARY AS
SELECT r.RUN_ID, r.RUN_TS, r.TRIGGERED_BY, r.PAIRS, r.PAIRS_PASSED, r.PAIRS_FAILED, r.PAIRS_ERROR,
       ROUND(100 * r.PAIRS_PASSED / NULLIF(r.PAIRS, 0), 1) AS PASS_RATE_PCT,
       COALESCE(SUM(p.CHECKS_RUN), 0)    AS CHECKS_RUN,
       COALESCE(SUM(p.CHECKS_FAILED), 0) AS CHECKS_FAILED,
       COALESCE(SUM(p.SOURCE_ROWS), 0)   AS SOURCE_ROWS,
       COALESCE(SUM(p.TARGET_ROWS), 0)   AS TARGET_ROWS,
       r.DURATION_SEC
FROM VALIDATION_RUNS r
LEFT JOIN VALIDATION_PAIR_RUNS p ON p.RUN_ID = r.RUN_ID
GROUP BY r.RUN_ID, r.RUN_TS, r.TRIGGERED_BY, r.PAIRS, r.PAIRS_PASSED, r.PAIRS_FAILED, r.PAIRS_ERROR, r.DURATION_SEC;

-- Failed / warned checks of the latest run per pair
CREATE OR REPLACE VIEW V_LATEST_EXCEPTIONS AS
SELECT r.PAIR_ID, r.PAIR_NAME, r.CHECK_TYPE, r.COLUMN_NAME, r.SOURCE_VALUE, r.TARGET_VALUE,
       r.VARIANCE, r.VARIANCE_PCT, r.STATUS, r.DETAIL, r.RUN_ID, r.RUN_TS
FROM VALIDATION_RESULTS r
JOIN V_LATEST_PAIR_STATUS l ON l.PAIR_ID = r.PAIR_ID AND l.RUN_ID = r.RUN_ID
WHERE r.STATUS <> 'PASS';

SHOW PROCEDURES LIKE 'SP_%' IN SCHEMA VALIDATION;
