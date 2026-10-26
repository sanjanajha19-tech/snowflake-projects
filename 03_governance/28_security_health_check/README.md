# 28 · Security Health Check

A repeatable security posture assessment for a Snowflake account. It runs 12 checks on authentication, privileges, network and monitoring against `SNOWFLAKE.ACCOUNT_USAGE`, writes each issue as a finding with severity and a recommended fix, and scores the account from 0 to 100 so progress can be tracked week to week.

## What it does
| File | Objects (schema `ACCEL_DB.SECURITY_HC`) |
|---|---|
| `01_security_checks.sql` | `V_USERS` (active users, normalised MFA / password / key-pair / PAT flags, `AUTH_CLASS`), `V_AUTH_INVENTORY`, `V_AUTH_METHOD_MIX_30D` (LOGIN_HISTORY), `V_PRIVILEGED_USERS` (direct holders of ACCOUNTADMIN, SECURITYADMIN, ORGADMIN, USERADMIN, SYSADMIN), `CHECK_CATALOG` (12 checks, weight, recommendation, check SQL) |
| `02_scoring_procedure.sql` | `RUN_SECURITY_HEALTH_CHECK()` → `FINDINGS` (check, severity, object, detail, recommendation), `CHECK_RESULTS` (PASS/FAIL/ERROR), `HC_RUNS` (score). `TASK_SECURITY_HEALTH_WEEKLY` is created suspended |
| `03_summary_views.sql` | `V_SECURITY_SUMMARY` (one row per check with severity counts: the checklist), `V_LATEST_FINDINGS`, `V_SECURITY_SCORE_TREND` |

## Checks
| ID | Check | Typical severity |
|---|---|---|
| SEC-01 | Human users with a password but no MFA | HIGH |
| SEC-02 | ACCOUNTADMIN holders without MFA | CRITICAL |
| SEC-03 | ACCOUNTADMIN holder count (not 2–3) and ACCOUNTADMIN as default role | HIGH / MEDIUM |
| SEC-04 | SERVICE / LEGACY_SERVICE users with passwords (should use key-pair / OAuth / workload identity) | HIGH |
| SEC-05 | Password-only logins in the last 30 days | MEDIUM |
| SEC-06 | Users inactive for 90 days, or never logged in | MEDIUM / LOW |
| SEC-07 | No network policy, none attached to the account, or `0.0.0.0/0` allowed | HIGH / MEDIUM |
| SEC-08 | Repeated failed logins per user and per IP (7 days) | HIGH / MEDIUM |
| SEC-09 | Object privileges granted to PUBLIC | HIGH / MEDIUM |
| SEC-10 | Roles other than SECURITYADMIN with MANAGE GRANTS | HIGH |
| SEC-11 | Active MFA bypass windows | MEDIUM |
| SEC-12 | Privileged role holders with no login in 90 days | MEDIUM |

**Score** = 100 × (weight of passing checks) ÷ (weight of checks that ran). A check passes when it has no findings above INFO. You can add checks by inserting a row into `CHECK_CATALOG` whose SQL returns `(severity, object_type, object_name, detail)`.

## Relationship to Trust Center
Snowflake **Trust Center** (Snowsight » Governance & security » Trust Center) is the native posture tool. Its scanner packages, such as the CIS Benchmarks package and the Threat Intelligence package, evaluate the account and flag violations. This accelerator complements it:
- the checks are transparent SQL your team can read, extend and map to internal policy IDs,
- the results are stored as tables (trend, workflow, BI) and joined with user and role context,
- it works with ACCEL_ADMIN-level access through ACCOUNT_USAGE.

Recommended approach: enable Trust Center scanners (ACCOUNTADMIN, or a role with the `SNOWFLAKE.TRUST_CENTER_ADMIN` application role) for the CIS baseline, and use this check for weekly scoring and the remediation backlog. Review both in the same security meeting.

## Prerequisites
- `00_setup` (ACCEL_ADMIN has IMPORTED PRIVILEGES on the SNOWFLAKE database, which covers USERS, GRANTS_*, LOGIN_HISTORY and NETWORK_POLICIES).
- ACCOUNT_USAGE lags by up to 2–3 hours, so users or grants created in the last few hours may not appear yet.
- To verify the **account-level** network policy attachment, run the procedure as SECURITYADMIN or ACCOUNTADMIN. Otherwise an INFO finding says the check could not read the parameter.
- Admin checks use **direct** role grants to users. Users who reach ACCOUNTADMIN through a nested role are not counted.

## Run order
1. `01_security_checks.sql`
2. `02_scoring_procedure.sql` (runs the first assessment)
3. `03_summary_views.sql`
4. Optional: `ALTER TASK ACCEL_DB.SECURITY_HC.TASK_SECURITY_HEALTH_WEEKLY RESUME;`

## 5-step demo script
1. `SELECT * FROM V_SECURITY_SUMMARY ORDER BY CHECK_ID;` shows the overall score and the pass/fail checklist.
2. `SELECT * FROM V_LATEST_FINDINGS;` puts CRITICAL and HIGH first: for each finding, who or what it is, why it matters and the exact fix.
3. `SELECT * FROM V_AUTH_INVENTORY;` and `V_AUTH_METHOD_MIX_30D` show password vs key-pair vs SSO users and how people actually sign in.
4. Fix one item live (e.g. `ALTER USER <svc_user> UNSET PASSWORD;`, or create and attach a network policy). Wait for ACCOUNT_USAGE latency or run the next day, then `CALL RUN_SECURITY_HEALTH_CHECK();` and show `V_SECURITY_SCORE_TREND` going up.
5. Open Trust Center and compare its CIS findings with this checklist: one native scanner plus one transparent, extensible scorecard.

## Client value
"A security score your CISO can track weekly, with the fix for every finding." It surfaces the highest-impact Snowflake risks (no MFA, too many admins, password-based service users, open network access, PUBLIC grants) in minutes. It also produces audit evidence (ISO 27001, SOC 2, RBI / SEBI cyber frameworks) as a by-product.

## Notes
- Severities and weights are opinions. Tune them in `CHECK_CATALOG` to match your policy.
- Findings contain user names and IPs. Restrict access to the `SECURITY_HC` schema to security roles (`-- EDIT ME` in file 03).
- Snowflake is retiring single-factor password sign-in for human users and LEGACY_SERVICE users. SEC-01, SEC-04 and SEC-05 show who will be affected.
