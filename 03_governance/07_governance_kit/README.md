# 07 · Governance Kit (RBAC, tags, masking, row access, classification, DQ)

A ready-to-run Snowflake Horizon governance baseline on the shared demo data. It covers who can see what, which data is sensitive, how it is protected and whether it is fit for use. A coverage score shows how much of the estate is governed.

## What it does
| File | Content |
|---|---|
| `01_role_hierarchy.sql` | Functional roles (`FR_SALES_ANALYST`, `FR_FINANCE_ANALYST`, `FR_HR_ANALYST`, `FR_DATA_STEWARD`) built on top of access roles. The access roles are **database roles** in ACCEL_DB (`AR_*_READ`). Everything rolls up to SYSADMIN. ACCEL_ADMIN gets `APPLY TAG / MASKING POLICY / ROW ACCESS POLICY`, `CLASSIFICATION_ADMIN` and the DMF roles |
| `02_tag_library.sql` | Tags with controlled vocabularies (`ALLOWED_VALUES`): `PII_TYPE`, `DATA_CLASSIFICATION`, `DATA_OWNER`, `DOMAIN`, plus a `TAG_LIBRARY` reference table |
| `03_auto_classification.sql` | Classification profile (`SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE`, auto-tag) and `SYSTEM$CLASSIFY` on CUSTOMERS / EMPLOYEES / SUPPLIERS. Optional schema-level automatic classification |
| `04_apply_tags.sql` | Object tags on all 11 DEMO tables. Column tags on EMAIL, PHONE, PAN_NUMBER, FULL_NAME, SALARY, GSTIN. Also creates the `SAFE_EXEC` helper |
| `05_data_metric_functions.sql` | System DMFs `NULL_COUNT`, `DUPLICATE_COUNT`, `ROW_COUNT`, `FRESHNESS` and the custom DMFs `INVALID_EMAIL_COUNT`, `NEGATIVE_AMOUNT_COUNT`, scheduled on CUSTOMERS / ORDERS / ORDER_LINES / GL_JOURNAL |
| `06_masking_and_row_access.sql` | **Tag-based masking**: `MASK_PII_STRING` (EMAIL `*****@domain`, PHONE last 4, PAN `XXXXX1234X`, NAME first letter, others fully hidden) and `MASK_PII_NUMBER` (SALARY → NULL), both attached to the `PII_TYPE` tag. Clear values only when `ACCEL_ADMIN` is in the session. **Row access policy** `RAP_REGION` on `CUSTOMERS.REGION`, driven by the `REGION_ACCESS_MAP` table |
| `07_governance_coverage.sql` | `REFRESH_GOVERNANCE_COVERAGE()` snapshots real-time tag, policy and DMF references. `V_GOVERNANCE_COVERAGE` gives a 0–100 score per table, `V_GOVERNANCE_GAPS` gives fix statements, and `V_GOVERNANCE_COVERAGE_ACCOUNT` is an account-wide view over ACCOUNT_USAGE |
| `08_role_switch_test.sql` | Runs the same queries as ACCEL_ADMIN, FR_SALES_ANALYST, FR_FINANCE_ANALYST, FR_HR_ANALYST and ACCEL_ANALYST, with expected results |

## Prerequisites
- `00_setup` run. Enterprise edition or higher (masking, row access, classification and DMFs all need it).
- ACCOUNTADMIN is used in file 01 (account-level APPLY privileges, SNOWFLAKE database/application roles) and file 03 (classification privileges). File 08 uses SECURITYADMIN to grant the FR roles to you.

## Run order
`01` → `02` → `03` → `04` → `05` → `06` → `07` → `08`. Run classification (03) **before** masking (06) so the classifier samples clear values. Every file can be rerun.

## 5-step demo script
1. **Classify**: run file 03 and show the `SEMANTIC_CATEGORY` / `PRIVACY_CATEGORY` system tags Snowflake found on CUSTOMERS and EMPLOYEES without any rules being written.
2. **Tag once, protect everywhere**: show the `PII_TYPE` tag and its two policies. Tag a new column live (`ALTER TABLE … MODIFY COLUMN … SET TAG ACCEL_DB.GOVERNANCE.PII_TYPE = 'EMAIL'`) and it is masked immediately.
3. **Role switch**: run file 08. The sales analyst sees only North and West, with masked e-mail, phone and PAN. The HR analyst sees initials and NULL salaries. ACCEL_ADMIN sees clear data.
4. **Entitlements as data**: insert a row into `REGION_ACCESS_MAP` and rerun test 2. Access changes without any DDL.
5. **Prove it**: show `V_GOVERNANCE_COVERAGE` (score per table), `V_GOVERNANCE_GAPS` (fix statements) and the DMF results (`SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS`).

## Client value
"Policy-driven data protection that scales with tags, not with tables." One tag-based policy set protects every current and future PII column. Entitlements live in a table that the business can audit. The coverage score turns "are we compliant?" into a number, typically reducing manual access reviews and audit preparation by more than 50%, with a clear path to DPDP Act / GDPR evidence.

## Notes
- **Impact on other accelerators.** Masking and the row access policy apply to `ACCEL_DB.DEMO`. ACCEL_ADMIN (and SYSADMIN/ACCOUNTADMIN, which inherit it) still see clear values. ACCEL_ANALYST / ACCEL_DEVELOPER / ACCEL_VIEWER keep all rows, through the `'*'` mapping, but see masked PII. Use the remove statements at the bottom of file 06 to undo.
- `IS_ROLE_IN_SESSION` respects the role hierarchy **and secondary roles**. File 08 runs `USE SECONDARY ROLES NONE` so the test is meaningful.
- A tag can carry one masking policy per data type. That is why there is one STRING and one NUMBER policy that branch on the tag value, read with `SYSTEM$GET_TAG_ON_CURRENT_COLUMN`.
- DMF results and ACCOUNT_USAGE tag/policy views lag by minutes to hours. The coverage procedure uses real-time `INFORMATION_SCHEMA` table functions instead.
- DMF schedules (`60 MINUTE`) run serverless and consume credits. Switch to a daily CRON or `TRIGGER_ON_CHANGES` after the demo.
