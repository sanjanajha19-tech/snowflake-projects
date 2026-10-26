# Data Health Checker

The Data Health Checker profiles one table you choose. It reports:

- row and column counts
- null rate per column
- approximate distinct values per column
- minimum and maximum values
- an estimate of duplicate rows
- a 0 to 100 health score

## Getting started
1. After installing, open the app. You can also grant access from the app's **Security** tab: under **Table to profile**, choose any table. The app gets `SELECT` on that table only.
2. Click **Run profile now**.
3. Review the column profile, null-rate chart and score trend. Every run is kept, so you can track quality over time.

To bind the table with SQL instead:
```sql
CALL <app_name>.CORE.REGISTER_SINGLE_REFERENCE(
  'consumer_table', 'ADD',
  SYSTEM$REFERENCE('TABLE', 'MY_DB.MY_SCHEMA.MY_TABLE', 'PERSISTENT', 'SELECT'));
CALL <app_name>.CORE.PROFILE_TABLE();
SELECT * FROM <app_name>.CORE.LATEST_COLUMN_PROFILE;
```

## Privacy
Your data never leaves your account. The app stores only aggregate statistics, in its own `DATA` schema. It does not request any account-level privileges.
