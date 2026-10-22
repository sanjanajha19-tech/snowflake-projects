# Migration Assessment (Teradata / Oracle to Snowflake)

## What it does
Turns a legacy warehouse inventory into a scored, sequenced migration plan inside Snowflake:

- **Inventory model** (`SRC_OBJECTS`, `SRC_COLUMNS`, `SRC_CODE`, `SRC_DEPENDENCIES`, `SRC_QUERY_LOG`), loaded from CSV through an internal stage, or from the bundled sample (41 objects: a Teradata EDW plus an Oracle finance DW).
- **Rule-based scoring** (`SP_RUN_ASSESSMENT`): data types that need conversion (`TYPE_RULES`), 40 proprietary-syntax regex rules (`SYNTAX_RULES`: BTEQ, PERIOD, QUALIFY, MERGE, CONNECT BY, ROWNUM, NVL2/DECODE, BULK COLLECT, triggers, DBMS_ packages, ...), code size, data volume and dependencies. The result is a **Low / Medium / High / Very High** band, an effort estimate in hours, and a recommendation.
- **Wave planning**: objects are grouped by their longest upstream dependency chain, so each wave only depends on earlier ones. Objects with no recent usage go to **Wave 0 - Retire**.
- **AI insights (optional)**: `AI_COMPLETE` summarises each proc, view or script (purpose, conversion risks, Snowflake approach).
- **Streamlit dashboard**: KPIs, complexity mix, effort by wave, wave plan with team-size calculator, and object drill-down with score breakdown, rule hits, column mapping, dependencies, AI insight and source code.

## Prerequisites
- `00_setup` completed (role `ACCEL_ADMIN`, warehouse `ACCEL_WH`, database `ACCEL_DB`).
- For step 05: Cortex AI available in your region, or cross-region inference enabled.

## Run order
| # | File | Notes |
|---|---|---|
| 1 | `01_inventory_model.sql` | Tables, rules, effort model, file format, stage |
| 2 | `02_sample_inventory.sql` | Loads the sample inventory with INSERTs, so no upload is needed |
| 2b | `03_load_from_csv.sql` | *Instead of 2:* upload your own `src_*.csv` to `@INVENTORY_STAGE`, then run |
| 3 | `04_scoring.sql` | Creates views and the procedure, runs `CALL SP_RUN_ASSESSMENT()` |
| 4 | `05_ai_code_insights.sql` | Optional. Set `AI_MODEL` (`-- EDIT ME`) |
| 5 | `streamlit_app.py` | Snowsight > Projects > Streamlit > + Streamlit App, location `ACCEL_DB.MIGRATION_ASSESSMENT`, warehouse `ACCEL_WH` |

`sample_data/` holds the same inventory as CSV files. They are a template for real extracts
(for example from Teradata `DBC.TablesV`/`DBC.ColumnsV`/DBQL, or Oracle `ALL_OBJECTS`/`ALL_TAB_COLUMNS`/`ALL_SOURCE`/`ALL_DEPENDENCIES`/AWR).
Keep the header row and column order.

## Tuning
- `EFFORT_MODEL`: base hours per object type for a Low-complexity object.
- `COMPLEXITY_BANDS`: score thresholds and effort multipliers.
- `TYPE_RULES` / `SYNTAX_RULES`: add patterns for other platforms (SQL Server, Netezza, ...). Patterns are POSIX regular expressions applied to `UPPER(CODE_TEXT)`.
Rerun `CALL SP_RUN_ASSESSMENT();` after any change.

## 5-step demo script
1. Run `SELECT * FROM V_WAVE_PLAN ORDER BY MIGRATION_WAVE;` to show 41 objects turned into a 5-wave plan with person-days.
2. Open the Streamlit app: KPIs and complexity mix. "Most of the estate is Low/Medium. The risk is concentrated in a few objects."
3. Drill into `FINDW.GL.PKG_PERIOD_CLOSE`: the score breakdown shows autonomous transactions, BULK COLLECT, UTL_FILE. Explain why it is Very High.
4. Show the Wave 0 retire candidates (unused for 6+ months). "We are not migrating what nobody uses."
5. Run `05_ai_code_insights.sql` and show the AI purpose and risk summary next to the rule-based band for `BTEQ_LOAD_CUSTOMER`.

## Client value
A defensible, data-driven migration estimate and wave plan in days instead of weeks of spreadsheet work.
It typically cuts 10-20 % of scope through retire candidates, and it gives the SnowConvert and engineering
team a prioritised backlog with the specific constructs to watch per object.
