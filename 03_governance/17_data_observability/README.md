# 17 · Data Observability

Watches ACCEL_DB tables for the three most common silent data failures: **stale data** (freshness), **missing or exploding data** (volume) and **unexpected schema changes**. Each run takes a snapshot history, opens de-duplicated incidents with severity, e-mails new incidents through a Snowflake alert, and feeds a Streamlit health dashboard. It is built entirely from native Snowflake objects, with no external tool.

## What it does
| File | Objects (schema `ACCEL_DB.OBSERVABILITY`) |
|---|---|
| `01_monitor_config.sql` | `MONITOR_CONFIG`: per table, `FRESHNESS_SLA_MINUTES`, `MIN_ROWS`, `MAX_ROW_CHANGE_PCT`, `CHECK_SCHEMA`, severity, owner. It is seeded with every table in `ACCEL_DB.DEMO`. `OBS_SETTINGS` holds the e-mail recipients (`-- EDIT ME`) |
| `02_snapshots_and_evaluation.sql` | `TABLE_SNAPSHOTS` (row count, bytes, last altered and column list/hash from `ACCEL_DB.INFORMATION_SCHEMA.TABLES/COLUMNS`) and `INCIDENTS`. `TAKE_SNAPSHOT()`, `EVALUATE_MONITORS()` (MISSING_TABLE, FRESHNESS, VOLUME_MIN, VOLUME_CHANGE, SCHEMA_CHANGE; auto-resolve), `SET_INCIDENT_STATUS()`. Views `V_TABLE_HEALTH`, `V_INCIDENT_SUMMARY` and `V_DDL_ACTIVITY_7D` (from `ACCOUNT_USAGE.TABLES/COLUMNS`). `TASK_OBS_EVALUATE` runs hourly and is created suspended |
| `03_notifications_and_alert.sql` | E-mail notification integration `ACCEL_OBS_EMAIL_INT`. `NOTIFY_NEW_INCIDENTS()` (`SYSTEM$SEND_EMAIL`, logs to `NOTIFICATION_LOG`). `OBS_NEW_INCIDENT_ALERT` (`CREATE ALERT`, hourly) is **suspended by default** |
| `04_demo_simulate_incidents.sql` | Builds `DEMO_ORDER_FEED`, takes a baseline, then deletes 60% of rows, adds a column and waits 70 s, so that all four incident types fire. DEMO data is not touched |
| `streamlit_app.py` | KPIs and tabs: Table health / Incidents (acknowledge and resolve) / Volume trend / DDL activity / Configuration. "Run checks now" button |

## How incidents work
- **State monitors** (MISSING_TABLE, FRESHNESS, VOLUME_MIN) keep one open incident per table while the condition holds (`LAST_SEEN_AT` is updated) and **auto-resolve** when it clears.
- **Event monitors** (VOLUME_CHANGE, SCHEMA_CHANGE) compare against the previous snapshot. They raise a new incident each time, which a person acknowledges or resolves.
- The first evaluation is the baseline, so change-based monitors need at least two snapshots.

## Prerequisites
- `00_setup` (ACCEL_ADMIN with CREATE INTEGRATION, EXECUTE TASK, EXECUTE ALERT, IMPORTED PRIVILEGES on SNOWFLAKE).
- E-mail recipients must be **users of this account with a verified e-mail address**. Set them in `OBS_SETTINGS` (`-- EDIT ME` in files 01 and 03).
- Only tables in `ACCEL_DB` that ACCEL_ADMIN can see are monitored, because INFORMATION_SCHEMA is per database. `V_DDL_ACTIVITY_7D` lags by up to about 3 hours.

## Run order
1. `01_monitor_config.sql` (review the thresholds)
2. `02_snapshots_and_evaluation.sql` (takes the baseline)
3. `03_notifications_and_alert.sql` (set recipients first)
4. `04_demo_simulate_incidents.sql` (optional demo, about 2 minutes)
5. Streamlit: Snowsight » Projects » Streamlit » + Streamlit App. Choose `ACCEL_DB.OBSERVABILITY` and warehouse `ACCEL_WH`, then paste `streamlit_app.py`.
6. To go live: `ALTER TASK ACCEL_DB.OBSERVABILITY.TASK_OBS_EVALUATE RESUME;` and `ALTER ALERT ACCEL_DB.OBSERVABILITY.OBS_NEW_INCIDENT_ALERT RESUME;`

## 5-step demo script
1. **Table health tab**: every DEMO table is green, with its row count, minutes since last change and SLA.
2. Run `04_demo_simulate_incidents.sql` (a faulty upstream load: 60% of rows lost and a new column).
3. **Incidents tab**: show the four incidents on `DEMO_ORDER_FEED`: VOLUME_CHANGE (−60%), VOLUME_MIN, SCHEMA_CHANGE (shows `DISCOUNT_CODE VARCHAR` was added) and FRESHNESS. Severity comes from config.
4. Run `CALL NOTIFY_NEW_INCIDENTS();` to show the e-mail, or resume the alert. Acknowledge one incident in the app.
5. Re-load the rows (step 6 in file 04) and click **Run checks now**. VOLUME_MIN and FRESHNESS auto-resolve. Show the **Volume trend** chart dipping and recovering.

## Client value
"Know about broken data before your users do." Freshness, volume and schema monitoring cover most data incidents that reach dashboards. Running them natively in Snowflake (tasks, alerts, e-mail) adds no extra licence and no data leaves the platform. Mean time to detect drops from days (a user complains) to under an hour.

## Notes
- Freshness uses `LAST_ALTERED`, which also changes on DDL and on some background operations. For event-time freshness (e.g. `MAX(ORDER_DATE)`), add a Data Metric Function (`SNOWFLAKE.CORE.FRESHNESS`) on top.
- `ROW_COUNT` comes from metadata and is free. No table scans are run.
- The demo tables are static, so they are configured with a 7-day freshness SLA. Tighten it for real pipelines.
- The alert and the task are separate, so evaluation can run more often than e-mail checks, or the reverse.
