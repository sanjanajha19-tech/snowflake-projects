# Code Conversion Kit (Teradata / Oracle / SQL Server to Snowflake)

## What it does
A toolkit for the code that automated conversion leaves behind:

- **Pattern library** (`PATTERN_LIBRARY`, ~55 rows): legacy construct, Snowflake equivalent, a before/after
  example and a detection regex for Teradata, Oracle and SQL Server. It covers TOP/LIMIT and WITH TIES, QUALIFY,
  NVL2, DECODE, CONNECT BY to recursive CTE, MERGE differences, date functions and formats, IDENTITY, SET/MULTISET
  tables, volatile and #temp tables to TEMPORARY, BTEQ `.EXPORT` / `.IF ERRORCODE`, macros, packages, triggers,
  BULK COLLECT, autonomous transactions, TRY/CATCH, hints, and more.
- **Legacy function UDFs** (`02_legacy_udfs.sql`): `OREPLACE`, `OTRANSLATE`, `TD_INDEX`, `TD_DAY_OF_WEEK`,
  `TD_DATE_TO_INT` / `TD_INT_TO_DATE`, `TD_EXPAND_DATES` (EXPAND ON), `ORA_INSTR` (with position and occurrence),
  `ORA_ROUND_DATE`, `LNNVL`, `ORA_SYS_GUID`, `ORA_LEVELS` (CONNECT BY LEVEL generator), `EOMONTH`, `STUFF`.
  Converted code can keep calling these, so you change less code.
- **AI-assisted converter** (`SP_CONVERT_SQL`): takes legacy SQL and its dialect, adds the matching library patterns
  to a strict prompt, calls `AI_COMPLETE`, and returns JSON with `snowflake_sql`, `changes`, `warnings` and
  `confidence`. It compiles single SELECT/DML results with `EXPLAIN` and writes everything to `CONVERSION_LOG`.
  `SP_CONVERT_QUEUE` processes a backlog in `CONVERSION_QUEUE`. `V_CONVERSION_REVIEW` is the review list.

## How it complements SnowConvert AI
SnowConvert AI is Snowflake's free, deterministic converter. It should do the bulk conversion (DDL, views, procedures,
BTEQ) and it produces an assessment report with EWIs (issues to fix by hand). This kit is for what comes after:
- **EWI and FDM clean-up**: look up the flagged construct in `PATTERN_LIBRARY` and paste the tested Snowflake form.
- **Snippets outside the code base**: report SQL, ETL-tool SQL overrides, spreadsheet macros and ad-hoc scripts that
  SnowConvert never sees can go through `SP_CONVERT_SQL` one at a time, with a log.
- **Runtime parity**: the UDFs keep semantics that SnowConvert would otherwise rewrite inline.
- **Team enablement**: the library is a shared reference for engineers who are new to Snowflake.

Treat AI output as a draft. `STATUS = 'VALIDATED'` only means it compiles. It does not mean the results are the
same, so test the results with the Data Validation Framework (`../03_data_validation_framework`).

## Prerequisites
- `00_setup` completed (ACCEL_ADMIN with `SNOWFLAKE.CORTEX_USER`).
- Cortex AI available in your region for the chosen model, or cross-region inference enabled.
- Python UDF/procedures use only the built-in `snowflake-snowpark-python` package.

## Run order
| # | File | Notes |
|---|---|---|
| 1 | `01_pattern_library.sql` | Creates schema `CODE_CONVERSION`, library and search view |
| 2 | `02_legacy_udfs.sql` | Creates UDFs; ends with smoke tests (expected values in comments) |
| 3 | `03_ai_converter.sql` | Creates log/queue, procedures, runs one demo conversion and a 4-item queue. Default model `llama3.1-70b` (`-- EDIT ME`) |

Usage:
```sql
CALL ACCEL_DB.CODE_CONVERSION.SP_CONVERT_SQL(
  $$SELECT * FROM (SELECT * FROM INV ORDER BY AMT DESC) WHERE ROWNUM <= 10$$,
  'Oracle', 'AP.TOP_INVOICES', 'claude-3-5-sonnet', TRUE);
```

## 5-step demo script
1. `SELECT * FROM PATTERN_LIBRARY WHERE SOURCE_DIALECT = 'Teradata';` shows the library and its before/after examples.
2. Run the UDF smoke test: legacy functions work unchanged in Snowflake.
3. Run the single `CALL SP_CONVERT_SQL(...)` on the Teradata snippet. Show `changes` and `warnings`, and how the PERIOD `CONTAINS` construct gets a `-- REVIEW:` note.
4. `CALL SP_CONVERT_QUEUE();` then `SELECT * FROM V_CONVERSION_REVIEW;`: a batch of BTEQ, Oracle and T-SQL with status and confidence.
5. Compare one result with the matching `PATTERN_LIBRARY` example, and explain the human review step and the validation framework hand-off.

## Client value
It cuts manual rework after SnowConvert by an estimated 30-50 % on the long tail of objects that need hands-on fixes, gives
reviewers an audit trail of every AI-assisted change, and gives the client's engineers a reusable, searchable
playbook for constructs specific to their own platform.
