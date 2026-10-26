# 09 · AI Governance Controls

A working AI governance layer inside Snowflake. It shows who uses which models and what that costs, keeps a policy and use-case register, restricts model access by role, puts a PII-screening and audit-logging wrapper around `AI_COMPLETE`, and keeps a controls checklist that collects its own evidence.

## What it does
| File | Objects (schema `ACCEL_DB.AI_GOVERNANCE`) |
|---|---|
| `01_ai_usage_views.sql` | `V_AI_USAGE_BY_USER_MODEL`, `V_AI_TOKENS_BY_USER_MODEL`, `V_AI_ASSISTANT_USAGE_BY_USER`, `V_AI_CREDITS_DAILY`, `V_AI_TOP_USERS_30D` (ACCOUNT_USAGE Cortex usage views) |
| `02_policy_register.sql` | `AI_POLICY_REGISTER`, `APPROVED_MODELS` (model → allowed roles), `AI_USE_CASES` (risk tier, PII mode BLOCK/REDACT/ALLOW, human review), `PII_PATTERNS` (REGEXP for e-mail, phone, PAN, Aadhaar, card, GSTIN) |
| `03_model_allowlist.sql` | **ACCOUNTADMIN.** Shows `CORTEX_MODELS_ALLOWLIST`, refreshes `SNOWFLAKE.MODELS`, grants `SNOWFLAKE."CORTEX-MODEL-ROLE-<MODEL>"` to the roles listed in `APPROVED_MODELS`, logs to `MODEL_ACCESS_GRANTS`. Setting the allowlist to `'None'` is left commented because it is a one-way step |
| `04_ai_complete_audit_wrapper.sql` | `GOVERNED_AI_COMPLETE(prompt, model, use_case)`: checks the use case and the model approval for the caller's role, screens the prompt for PII (block or redact), calls `AI_COMPLETE` (temperature 0), redacts PII in the response, and writes `AI_REQUEST_LOG`. Views `V_AI_REQUEST_SUMMARY` and `V_AI_PII_EVENTS` |
| `05_controls_checklist.sql` | `AI_CONTROLS`: 16 controls across data leakage, hallucination, bias, access, cost, auditability and model risk, each with a Snowflake control and an evidence query. `RUN_CONTROL_EVIDENCE()` writes to `CONTROL_EVIDENCE`. Views `V_CONTROL_STATUS` and `V_CONTROL_SCORECARD`. `TASK_AI_CONTROL_EVIDENCE` runs monthly and is created suspended |

## Model access: allowlist vs RBAC
- `CORTEX_MODELS_ALLOWLIST` is an account parameter (`'All'` by default, `'None'`, or a list of lowercase model names). **It is deprecated.** Since August 2026 it can no longer be changed to a new list, only to `'None'`.
- Model RBAC replaces it. Each model has an application role `SNOWFLAKE."CORTEX-MODEL-ROLE-<MODEL>"` (or `CORTEX-MODEL-ROLE-ALL`).
- A call is allowed if the role has the model through RBAC **or** the model is on the allowlist. So RBAC only restricts anything once the allowlist is `'None'`.
- Users also need the `USE AI FUNCTIONS` account privilege plus the `SNOWFLAKE.CORTEX_USER` (or `AI_FUNCTIONS_USER`) database role.

## Prerequisites
- `00_setup` (roles, `ACCEL_WH`, IMPORTED PRIVILEGES on SNOWFLAKE, CORTEX_USER).
- ACCOUNTADMIN for `03_model_allowlist.sql` only.
- Models listed in `APPROVED_MODELS` must be available in your region. Otherwise `03` reports them as `MODEL_NOT_AVAILABLE`. Change the `-- EDIT ME` list in `02`, or enable cross-region inference.
- ACCOUNT_USAGE lags by up to 3 hours. On a new account, the usage views and controls AIC-13/14 fill up over time.

## Run order
1. `01_ai_usage_views.sql`
2. `02_policy_register.sql` (edit the approved models and use cases first)
3. `03_model_allowlist.sql` (ACCOUNTADMIN; read step 5 before switching the allowlist off)
4. `04_ai_complete_audit_wrapper.sql` (runs 6 demo calls)
5. `05_controls_checklist.sql` (runs the evidence collection once)

## 5-step demo script
1. **Visibility**: `SELECT * FROM V_AI_TOP_USERS_30D` shows AI credits per user and model at the same grain as warehouse cost.
2. **Policy**: show `AI_POLICY_REGISTER`, `APPROVED_MODELS` and `AI_USE_CASES`, with each policy tied to a Snowflake enforcement point.
3. **Model control**: run `03` and show `MODEL_ACCESS_GRANTS`. Explain that the allowlist is deprecated and RBAC replaces it.
4. **Guardrail**: run demo calls (b) and (c) in `04`. The e-mail and phone under `GENERAL` are **blocked**, while the PAN and e-mail under `TICKET_SUMMARY` are **redacted** before the model sees them. Show `AI_REQUEST_LOG`: the raw PII is never stored.
5. **Assurance**: `SELECT * FROM V_CONTROL_STATUS` lists 16 controls by risk theme with PASS/FAIL and a re-runnable evidence query. Point out the failing ones (e.g. AIC-02 masking, AIC-04 human review, AIC-08 CORTEX_USER on PUBLIC) as the remediation backlog.

## Client value
"Use GenAI on governed data, with proof." Every AI request is attributable, screened for personal data and logged. Model access follows an approved list, and the auditor gets a controls checklist with evidence queries instead of a slide. This supports DPDP Act / GDPR, RBI and SEBI expectations, ISO 42001 and the EU AI Act.

## Notes
- The REGEXP patterns are deliberately broad. The `PHONE` pattern also matches other long digit runs, such as order numbers. Tune `PII_PATTERNS` for your data. For free text, consider `AI_EXTRACT` / Snowflake classification on top.
- The wrapper only governs calls that go through it. AIC-13 reconciles `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` against `AI_REQUEST_LOG` to measure how many calls bypass it. Pair it with model RBAC and least-privilege roles.
- The wrapper runs with caller's rights, so Snowflake model RBAC still applies to the caller. Callers have INSERT only on `AI_REQUEST_LOG`.
