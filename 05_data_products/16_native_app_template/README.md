# 16 - Native App Template: "Data Health Checker"

This is a complete Snowflake Native App project. Consultants can rename it and extend it into a client product or a Marketplace listing. The app:

- asks the consumer for **one table**, through a manifest *reference*, so the consumer grants only `SELECT` on that table
- profiles the table with a Python stored procedure: row count, nulls, approximate distinct values, min and max, estimated duplicate rows and a health score
- stores the results inside the app and shows them in a **Streamlit** UI

## Project layout
```
16_native_app_template/
├── snowflake.yml               Snowflake CLI project (definition_version 2)
├── deploy_manual.sql           Worksheet-only deployment (no CLI) - GENERATED
├── build_deploy_manual.py      Regenerates deploy_manual.sql after you edit ./app
└── app/
    ├── manifest.yml            manifest_version 2, reference "consumer_table"
    ├── setup_script.sql        app role, DATA schema (state), CORE versioned schema (code), Streamlit
    ├── README.md               shown to consumers on install
    └── streamlit/app.py        UI
```

## Design choices
| Topic | Choice |
|---|---|
| Consumer data access | A reference (`consumer_table`, `SELECT`, single-valued) with a `register_callback`. This is the documented least-privilege pattern, and the consumer binds the table in the app's **Security** tab. |
| State and code | Results go in schema `DATA` (`CREATE ... IF NOT EXISTS`), so they survive upgrades. Code goes in `CORE`, a `CREATE OR ALTER VERSIONED SCHEMA`, so it is replaced cleanly on upgrade. |
| Privileges | No account-level privileges are requested. Manifest v2 lets you add automated `privileges:` grants later if the app needs them. |
| Language | A Python 3.11 procedure that uses only `snowflake-snowpark-python` from the Snowflake Anaconda channel. |

## Prerequisites
- `00_setup` has been run (ACCEL_ADMIN, ACCEL_WH, and DEMO data to profile).
- ACCOUNTADMIN once, to grant `CREATE APPLICATION PACKAGE` and `CREATE APPLICATION` to ACCEL_ADMIN. `deploy_manual.sql` does this for you. On the CLI path, run those two grants first.

## Run order
**Option 1: Snowflake CLI**, from this folder:
```bash
snow app run -c <connection>          # creates DATA_HEALTH_CHECKER_PKG, uploads files, installs DATA_HEALTH_CHECKER_APP
snow sql -c <connection> -q "CALL DATA_HEALTH_CHECKER_APP.CORE.REGISTER_SINGLE_REFERENCE('consumer_table','ADD', SYSTEM\$REFERENCE('TABLE','ACCEL_DB.DEMO.CUSTOMERS','PERSISTENT','SELECT'))"
snow app open -c <connection>
snow app version create V1_0 -c <connection>   # when ready to release
snow app teardown -c <connection>              # clean up
```

**Option 2: Snowsight worksheet only.** Paste `deploy_manual.sql` and run all. It:
1. creates the package and stage
2. uploads the app files: an anonymous Python procedure writes the base64 copies embedded in the script, because `PUT` is not available in worksheets
3. installs the app in dev mode, or upgrades it if it is already installed
4. binds `ACCEL_DB.DEMO.CUSTOMERS` and runs a profile
5. optionally creates version `V1_0` and the default release directive. Set `create_version = TRUE`. The script detects whether the package has release channels, then uses either `REGISTER VERSION` with `MODIFY RELEASE CHANNEL DEFAULT ...` or `ADD VERSION` with `SET DEFAULT RELEASE DIRECTIVE`.

After you edit anything in `app/`, run `python3 build_deploy_manual.py` to refresh `deploy_manual.sql`.

## 5-step demo script
1. **The package.** Show `manifest.yml`: one reference, no account privileges. Explain that the provider's code runs in the consumer's account and the data never leaves it.
2. **Install.** Run `deploy_manual.sql`, or `snow app run`. In Snowsight go to *Data Products → Apps → DATA_HEALTH_CHECKER_APP* and show the Security tab, where you grant the table.
3. **Profile.** Open the app and click **Run profile now**. Walk through the health score, the null-rate chart, and the issues flagged, such as `HIGH_NULLS`, `CONSTANT_VALUE` and `ID_NOT_UNIQUE`.
4. **Upgrade.** Change something in `app/streamlit/app.py`, for example the title. Rerun `snow app run`, or regenerate and rerun `deploy_manual.sql`. The upgrade keeps the earlier runs, because state lives in `DATA`.
5. **Release.** Set `create_version = TRUE` and rerun step 5. Show `SHOW VERSIONS`, then explain the Marketplace path below.

## Publishing on the Snowflake Marketplace
1. **Become a provider.** An ORGADMIN or ACCOUNTADMIN accepts the Provider and Consumer Terms in *Snowsight → Data Products → Provider Studio*. For public listings, also create a provider profile.
2. **Release a version.** Create `V1_0`, which is step 5 of `deploy_manual.sql` or `snow app version create`. Then set the default release directive. If you use release channels, also test through the `QA` and `ALPHA` channels.
3. **Security scan.** Run `ALTER APPLICATION PACKAGE DATA_HEALTH_CHECKER_PKG SET DISTRIBUTION = EXTERNAL;`. Every version and patch then goes through the automated security review. Wait until `SHOW VERSIONS IN APPLICATION PACKAGE ...` shows `review_status = APPROVED`.
4. **Create the listing.** In *Provider Studio → Listings → Create listing*, choose *Snowflake Marketplace* (public) or *Specified consumers* (private), attach the application package, then add the title, description, usage examples, regions and pricing. Paid listings need a pricing plan and billing setup. Public listings go to Snowflake for listing approval.
5. **Operate.** Watch installs and usage in Provider Studio. Ship fixes with `ADD PATCH FOR VERSION` and new releases by moving the release directive, which upgrades consumers automatically. Set up event sharing if you need consumer telemetry.

## Client value
- The data never leaves the customer's account. That makes software vendors easier to approve with security teams.
- The template gives you working packaging, references, versioning and a UI, which saves 2 to 4 weeks of first-app setup.
- Monetise IP such as data-quality rules, industry models or AI workflows through the Marketplace, with Snowflake handling distribution and billing.
