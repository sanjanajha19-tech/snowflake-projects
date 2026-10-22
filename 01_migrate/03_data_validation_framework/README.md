# Data Validation Framework (source vs target reconciliation)

## What it does
Proves that migrated tables match their legacy source and records who signed each one off.

- **Config-driven** (`VALIDATION_CONFIG`): one row per source to target table pair, with key columns, columns to exclude,
  a SUM tolerance and an optional consistent key-hash sample for very large tables.
- **`SP_RUN_VALIDATION`** (Snowpark Python): for every active pair it compares
  - schema: missing or extra columns, data type changes
  - row count and a table-level `HASH_AGG` checksum
  - per column: null count, distinct count, min, max, sum (numeric) and a `HASH_AGG` checksum.

  It writes PASS / FAIL / WARN and the variance (absolute and %) to `VALIDATION_RESULTS`, and pair status to `VALIDATION_PAIR_RUNS`.
- **`SP_ROW_DIFF`**: runs automatically for failed pairs. It joins both sides on the key columns, counts
  `MISSING_IN_TARGET`, `MISSING_IN_SOURCE` and `VALUE_MISMATCH`, and stores sample rows with the differing column names and both row images.
- **Views**: `V_LATEST_PAIR_STATUS`, `V_LATEST_EXCEPTIONS`, `V_VALIDATION_SUMMARY`.
- **Task** `TSK_NIGHTLY_VALIDATION` (created suspended) for repeated runs during parallel running.
- **Streamlit sign-off app**: KPIs, pair status, exceptions chart, drill-down with row diffs, sign-off form
  (approving a failed pair requires a comment) and audit trail in `VALIDATION_SIGNOFF`.

Both sides are compared inside Snowflake. Land the legacy extract (or connect it as an external or Iceberg table) and
point `SOURCE_TABLE` at it. Names must be `DATABASE.SCHEMA.TABLE`; views work too.

## Prerequisites
- `00_setup` completed (`02_demo_data.sql` for the demo).
- ACCEL_ADMIN has `EXECUTE TASK` (granted in `00_setup`) to resume the task.

## Run order
| # | File | Notes |
|---|---|---|
| 1 | `01_framework.sql` | Schema `VALIDATION`, tables, procedures, views |
| 2 | `02_demo_setup.sql` | Copies DEMO ORDERS / ORDER_LINES / CUSTOMERS to `SOURCE_SIM`, plants defects, registers 3 pairs |
| 3 | `03_run_and_schedule.sql` | Runs validation, shows results, creates the suspended nightly task (`-- EDIT ME` schedule) |
| 4 | `streamlit_app.py` | Snowsight > Projects > Streamlit > + Streamlit App, location `ACCEL_DB.VALIDATION`, warehouse `ACCEL_WH` |

Expected demo result: **Customers PASS**. **Orders FAIL**: +3 rows, SUM(ORDER_TOTAL) variance of 0.05 plus the 3
missing orders, and checksum and STATUS-column differences. **Order lines FAIL**: -2 rows and a DISCOUNT_PCT null-count variance.
The row diff names the exact keys: for example, `MISSING_IN_TARGET` for ORDER_ID 1900001-1900003 and `VALUE_MISMATCH` on `ORDER_TOTAL` / `STATUS`.

## Tuning
- `NUMERIC_TOLERANCE_PCT`: accept small float or rounding variances on SUM (for example 0.001).
- `EXCLUDE_COLUMNS`: load timestamps, surrogate keys and audit columns that differ by design.
- `SAMPLE_PCT` < 100 filters both sides with `MOD(ABS(HASH(keys)), 10000)`, so the same keys are sampled on each side.
- Exact `COUNT(DISTINCT)` is used. For multi-billion-row tables, consider sampling or run pairs individually
  (`CALL SP_RUN_VALIDATION(<pair_id>)`) on a larger warehouse.

## 5-step demo script
1. Show `VALIDATION_CONFIG`: "Adding a table to the reconciliation is one row, not new code."
2. `CALL SP_RUN_VALIDATION();` reconciles ~355k rows across 3 pairs in seconds, with about 120 checks.
3. Open the Streamlit app: KPIs show 1 of 3 pairs passing. The exceptions chart shows where.
4. Drill into *Orders*: SUM variance, then the row diff with the 3 dropped orders and the 0.01 rounding rows, with source and target values side by side.
5. Record a sign-off: approve *Customers*. Try to approve *Orders* without a comment (it is blocked), then add the explanation. Show the audit trail.

## Client value
It replaces spreadsheet reconciliations with a repeatable, auditable test suite. Teams can run it every night during
parallel running, find defects down to the row and column, and get a defensible business sign-off for cut-over.
It typically saves several weeks of testing effort for each migration wave.
