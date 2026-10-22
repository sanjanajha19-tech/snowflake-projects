/* =============================================================================
   04 INGESTION FRAMEWORK | 03_ingestion_procedure.sql
   Generic metadata-driven loader: ACCEL_DB.INGEST.RUN_INGESTION(source, schedule)
   For every active config row:
     FILE / API : LIST stage -> auto-create target with INFER_SCHEMA + USING TEMPLATE
                  if missing -> COPY INTO (APPEND) or COPY INTO temp staging table
                  then MERGE / INSERT OVERWRITE (MERGE, TRUNCATE_INSERT)
     TABLE      : CREATE TABLE ... LIKE source if missing -> INSERT / MERGE / INSERT OVERWRITE
   Every feed writes one row to INGESTION_AUDIT_LOG (rows, errors, duration).
   Run as: ACCEL_ADMIN.
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS INGEST;
USE SCHEMA INGEST;

CREATE OR REPLACE PROCEDURE RUN_INGESTION(
    P_SOURCE_NAME VARCHAR DEFAULT NULL,   -- NULL = all active feeds
    P_SCHEDULE    VARCHAR DEFAULT NULL    -- NULL = any schedule label
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
COMMENT = 'Metadata-driven ingestion loop over ACCEL_DB.INGEST.INGESTION_CONFIG'
AS
$$
import time
import uuid

CONFIG_TABLE = "ACCEL_DB.INGEST.INGESTION_CONFIG"
AUDIT_TABLE = "ACCEL_DB.INGEST.INGESTION_AUDIT_LOG"
VALID_ON_ERROR = {"CONTINUE", "SKIP_FILE", "ABORT_STATEMENT"}
VALID_MODES = {"APPEND", "MERGE", "TRUNCATE_INSERT"}


def lit(value):
    """SQL string literal with escaping."""
    return "'" + str(value).replace("\\", "\\\\").replace("'", "''") + "'"


def qid(name):
    """Double-quoted identifier (exact case)."""
    return '"' + str(name).replace('"', '""') + '"'


def split_fqn(fqn):
    parts = [p.strip().strip('"') for p in fqn.split(".")]
    if len(parts) != 3 or not all(parts):
        raise ValueError("TARGET_TABLE / SOURCE_OBJECT must be DB.SCHEMA.TABLE, got: " + fqn)
    return parts[0].upper(), parts[1].upper(), parts[2].upper()


def table_exists(session, fqn):
    db, sch, tbl = split_fqn(fqn)
    sql = (f"SELECT COUNT(*) FROM {qid(db)}.INFORMATION_SCHEMA.TABLES "
           f"WHERE TABLE_SCHEMA = {lit(sch)} AND TABLE_NAME = {lit(tbl)}")
    return session.sql(sql).collect()[0][0] > 0


def table_columns(session, fqn):
    db, sch, tbl = split_fqn(fqn)
    sql = (f"SELECT COLUMN_NAME FROM {qid(db)}.INFORMATION_SCHEMA.COLUMNS "
           f"WHERE TABLE_SCHEMA = {lit(sch)} AND TABLE_NAME = {lit(tbl)} ORDER BY ORDINAL_POSITION")
    return [r[0] for r in session.sql(sql).collect()]


def fq(fqn):
    db, sch, tbl = split_fqn(fqn)
    return f"{qid(db)}.{qid(sch)}.{qid(tbl)}"


def staging_name(fqn):
    db, sch, tbl = split_fqn(fqn)
    return f"{qid(db)}.{qid(sch)}.{qid(tbl + '__STG')}"


def count_files(session, stage_path, pattern):
    sql = f"LIST {stage_path}"
    if pattern:
        sql += f" PATTERN = {lit(pattern)}"
    return len(session.sql(sql).collect())


def create_from_template(session, target, stage_path, file_format):
    sql = (f"CREATE TABLE {fq(target)} USING TEMPLATE ("
           f"SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY ORDER_ID) "
           f"FROM TABLE(INFER_SCHEMA(LOCATION => {lit(stage_path)}, FILE_FORMAT => {lit(file_format)})))")
    session.sql(sql).collect()


def run_copy(session, into, cfg, force):
    sql = (f"COPY INTO {into} FROM {cfg['STAGE_PATH']} "
           f"FILE_FORMAT = (FORMAT_NAME = {lit(cfg['FILE_FORMAT'])}) "
           f"MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE "
           f"ON_ERROR = {cfg['ON_ERROR']}")
    if cfg.get("FILE_PATTERN"):
        sql += f" PATTERN = {lit(cfg['FILE_PATTERN'])}"
    if force:
        sql += " FORCE = TRUE"
    rows = session.sql(sql).collect()
    qid_ = session.sql("SELECT LAST_QUERY_ID()").collect()[0][0]
    stats = {"files": 0, "parsed": 0, "loaded": 0, "errors": 0, "first_error": None, "failed_files": 0}
    for r in rows:
        d = {k.lower(): v for k, v in r.as_dict().items()}
        if "rows_loaded" not in d:      # "Copy executed with 0 files processed."
            continue
        stats["files"] += 1
        stats["parsed"] += int(d.get("rows_parsed") or 0)
        stats["loaded"] += int(d.get("rows_loaded") or 0)
        stats["errors"] += int(d.get("errors_seen") or 0)
        if str(d.get("status", "")).upper() != "LOADED":
            stats["failed_files"] += 1
        if d.get("first_error") and not stats["first_error"]:
            stats["first_error"] = str(d["first_error"])[:1000]
    return stats, qid_


def merge_from(session, target, source_sql, keys, dedupe_order_by):
    cols = table_columns(session, target)
    key_list = [k.strip().upper() for k in keys.split(",") if k.strip()]
    missing = [k for k in key_list if k not in cols]
    if not key_list or missing:
        raise ValueError(f"MERGE_KEYS invalid or not in target: {keys}")
    part = ", ".join(qid(k) for k in key_list)
    order = dedupe_order_by if dedupe_order_by else part
    on = " AND ".join(f"t.{qid(k)} = s.{qid(k)}" for k in key_list)
    non_keys = [c for c in cols if c not in key_list]
    col_list = ", ".join(qid(c) for c in cols)
    val_list = ", ".join(f"s.{qid(c)}" for c in cols)
    sql = (f"MERGE INTO {fq(target)} t USING ("
           f"SELECT {col_list} FROM {source_sql} "
           f"QUALIFY ROW_NUMBER() OVER (PARTITION BY {part} ORDER BY {order}) = 1) s ON {on} ")
    if non_keys:
        sets = ", ".join(f"t.{qid(c)} = s.{qid(c)}" for c in non_keys)
        sql += f"WHEN MATCHED THEN UPDATE SET {sets} "
    sql += f"WHEN NOT MATCHED THEN INSERT ({col_list}) VALUES ({val_list})"
    res = session.sql(sql).collect()[0].as_dict()
    ins = upd = 0
    for k, v in res.items():
        if "inserted" in k.lower():
            ins = int(v or 0)
        elif "updated" in k.lower():
            upd = int(v or 0)
    return ins, upd


def overwrite_from(session, target, source_sql):
    cols = table_columns(session, target)
    col_list = ", ".join(qid(c) for c in cols)
    res = session.sql(f"INSERT OVERWRITE INTO {fq(target)} ({col_list}) SELECT {col_list} FROM {source_sql}").collect()
    return int(list(res[0].as_dict().values())[0] or 0)


def append_from(session, target, source_sql):
    cols = table_columns(session, target)
    col_list = ", ".join(qid(c) for c in cols)
    res = session.sql(f"INSERT INTO {fq(target)} ({col_list}) SELECT {col_list} FROM {source_sql}").collect()
    return int(list(res[0].as_dict().values())[0] or 0)


def process_file_feed(session, cfg, out):
    stage_path, ff, target = cfg["STAGE_PATH"], cfg["FILE_FORMAT"], cfg["TARGET_TABLE"]
    if not stage_path or not stage_path.startswith("@") or not ff:
        raise ValueError("FILE/API feeds need STAGE_PATH starting with @ and FILE_FORMAT")
    if count_files(session, stage_path, cfg.get("FILE_PATTERN")) == 0:
        out["STATUS"] = "NO_FILES"
        return
    if not table_exists(session, target):
        create_from_template(session, target, stage_path, ff)
        out["TABLE_CREATED"] = True

    mode = cfg["LOAD_MODE"]
    if mode == "APPEND":
        stats, query_id = run_copy(session, fq(target), cfg, force=False)
        out["ROWS_INSERTED"] = stats["loaded"]
    else:
        stg = staging_name(target)
        session.sql(f"CREATE OR REPLACE TEMPORARY TABLE {stg} LIKE {fq(target)}").collect()
        stats, query_id = run_copy(session, stg, cfg, force=True)
        if stats["loaded"] > 0:
            if mode == "MERGE":
                out["ROWS_INSERTED"], out["ROWS_UPDATED"] = merge_from(
                    session, target, stg, cfg.get("MERGE_KEYS") or "", cfg.get("DEDUPE_ORDER_BY"))
            else:  # TRUNCATE_INSERT: atomic replace
                out["ROWS_INSERTED"] = overwrite_from(session, target, stg)
        session.sql(f"DROP TABLE IF EXISTS {stg}").collect()

    out["QUERY_ID"] = query_id
    out["FILES_PROCESSED"] = stats["files"]
    out["ROWS_PARSED"] = stats["parsed"]
    out["ROWS_LOADED"] = stats["loaded"]
    out["ERRORS_SEEN"] = stats["errors"]
    out["FIRST_ERROR"] = stats["first_error"]
    if stats["files"] == 0:
        out["STATUS"] = "NO_FILES"           # all files already loaded (load metadata)
    elif stats["errors"] > 0 or stats["failed_files"] > 0:
        out["STATUS"] = "PARTIAL"
    else:
        out["STATUS"] = "SUCCESS"


def process_table_feed(session, cfg, out):
    source, target, mode = cfg["SOURCE_OBJECT"], cfg["TARGET_TABLE"], cfg["LOAD_MODE"]
    if not source:
        raise ValueError("TABLE feeds need SOURCE_OBJECT")
    src = fq(source)
    if not table_exists(session, target):
        session.sql(f"CREATE TABLE {fq(target)} LIKE {src}").collect()
        out["TABLE_CREATED"] = True
    out["ROWS_LOADED"] = session.sql(f"SELECT COUNT(*) FROM {src}").collect()[0][0]
    if mode == "APPEND":
        out["ROWS_INSERTED"] = append_from(session, target, src)
    elif mode == "MERGE":
        out["ROWS_INSERTED"], out["ROWS_UPDATED"] = merge_from(
            session, target, src, cfg.get("MERGE_KEYS") or "", cfg.get("DEDUPE_ORDER_BY"))
    else:
        out["ROWS_INSERTED"] = overwrite_from(session, target, src)
    out["QUERY_ID"] = session.sql("SELECT LAST_QUERY_ID()").collect()[0][0]
    out["STATUS"] = "SUCCESS"


def sqlval(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return str(v)
    return lit(v)


def write_audit(session, run_id, cfg, out, t0, t1):
    values = [run_id, cfg["CONFIG_ID"], cfg["SOURCE_NAME"], cfg["SOURCE_TYPE"], cfg["LOAD_MODE"],
              cfg["TARGET_TABLE"], out["STATUS"], out["TABLE_CREATED"], out["FILES_PROCESSED"],
              out["ROWS_PARSED"], out["ROWS_LOADED"], out["ROWS_INSERTED"], out["ROWS_UPDATED"],
              out["ERRORS_SEEN"], out["FIRST_ERROR"]]
    session.sql(
        f"INSERT INTO {AUDIT_TABLE} (RUN_ID, CONFIG_ID, SOURCE_NAME, SOURCE_TYPE, LOAD_MODE, TARGET_TABLE, STATUS, "
        f"TABLE_CREATED, FILES_PROCESSED, ROWS_PARSED, ROWS_LOADED, ROWS_INSERTED, ROWS_UPDATED, ERRORS_SEEN, "
        f"FIRST_ERROR, START_TS, END_TS, DURATION_SEC, QUERY_ID) SELECT "
        + ", ".join(sqlval(v) for v in values)
        + f", TO_TIMESTAMP_LTZ({int(t0 * 1000)}, 3), TO_TIMESTAMP_LTZ({int(t1 * 1000)}, 3), "
        + f"{round(t1 - t0, 2)}, {sqlval(out['QUERY_ID'])}"
    ).collect()


def run(session, p_source_name=None, p_schedule=None):
    run_id = str(uuid.uuid4())
    where = "ACTIVE_FLAG = TRUE"
    if p_source_name:
        where += f" AND SOURCE_NAME = {lit(p_source_name)}"
    if p_schedule:
        where += f" AND SCHEDULE = {lit(p_schedule)}"
    cfgs = session.sql(f"SELECT * FROM {CONFIG_TABLE} WHERE {where} ORDER BY CONFIG_ID").collect()

    summary = {"run_id": run_id, "feeds": []}
    for row in cfgs:
        cfg = row.as_dict()
        cfg["SOURCE_TYPE"] = (cfg.get("SOURCE_TYPE") or "").upper()
        cfg["LOAD_MODE"] = (cfg.get("LOAD_MODE") or "").upper()
        cfg["ON_ERROR"] = (cfg.get("ON_ERROR") or "CONTINUE").upper()
        out = {"STATUS": "FAILED", "TABLE_CREATED": False, "FILES_PROCESSED": 0, "ROWS_PARSED": 0,
               "ROWS_LOADED": 0, "ROWS_INSERTED": 0, "ROWS_UPDATED": 0, "ERRORS_SEEN": 0,
               "FIRST_ERROR": None, "QUERY_ID": None}
        t0 = time.time()
        try:
            if cfg["LOAD_MODE"] not in VALID_MODES:
                raise ValueError("LOAD_MODE must be one of " + ", ".join(sorted(VALID_MODES)))
            if cfg["ON_ERROR"] not in VALID_ON_ERROR:
                raise ValueError("ON_ERROR must be one of " + ", ".join(sorted(VALID_ON_ERROR)))
            if cfg["SOURCE_TYPE"] in ("FILE", "API"):
                process_file_feed(session, cfg, out)
            elif cfg["SOURCE_TYPE"] == "TABLE":
                process_table_feed(session, cfg, out)
            else:
                out["STATUS"] = "SKIPPED"
                out["FIRST_ERROR"] = "Unknown SOURCE_TYPE " + str(cfg["SOURCE_TYPE"])
        except Exception as e:  # log and continue with the next feed
            out["STATUS"] = "FAILED"
            out["FIRST_ERROR"] = str(e)[:1000]
        t1 = time.time()
        write_audit(session, run_id, cfg, out, t0, t1)
        summary["feeds"].append({"source": cfg["SOURCE_NAME"], "status": out["STATUS"],
                                 "rows_loaded": out["ROWS_LOADED"], "inserted": out["ROWS_INSERTED"],
                                 "updated": out["ROWS_UPDATED"], "error": out["FIRST_ERROR"]})
    return summary
$$;

GRANT USAGE ON PROCEDURE RUN_INGESTION(VARCHAR, VARCHAR) TO ROLE ACCEL_DEVELOPER;

-- Quick check (runs all active feeds; DEMO_* feeds need 04_demo_seed_and_run.sql first)
-- CALL ACCEL_DB.INGEST.RUN_INGESTION();
