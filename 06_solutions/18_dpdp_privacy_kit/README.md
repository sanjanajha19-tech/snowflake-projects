# 18 - DPDP Privacy Kit (India DPDP Act 2023 + general privacy)

> **Disclaimer:** this is a technical accelerator, not legal advice. Section references are there for orientation only. Map each control to the client's own legal interpretation of the Digital Personal Data Protection Act, 2023 and the DPDP Rules with their counsel and DPO. The same patterns support GDPR, CCPA and similar regimes.

## What it does
| DPDP theme | Control in this kit | Objects |
|---|---|---|
| Know your personal data | Discovery that combines `SYSTEM$CLASSIFY`, India-specific value patterns (PAN, GSTIN, Aadhaar, Indian mobile, UPI ID) and column-name rules, written to a personal data inventory | `PERSONAL_DATA_INVENTORY`, `V_PERSONAL_DATA_INVENTORY`, `SP_DISCOVER_PERSONAL_DATA` |
| Notice and consent (s.5-6) | A purpose register and an append-only consent register with notice version, language, channel and Consent Manager ID | `PROCESSING_PURPOSES`, `CONSENT_REGISTER`, `V_CONSENT_CURRENT`, `SP_RECORD_CONSENT` |
| Purpose limitation and legitimate use (s.4, s.7) | A row access policy that shows a principal's rows only for a legitimate use or an active consent for the role's purpose. A masking policy hides direct identifiers from roles that do not need them | `ROLE_PURPOSE_MAP`, `RAP_PURPOSE_CONSENT`, `MP_DPDP_IDENTIFIER`, `V_CUSTOMER_PERSONAL_DATA` |
| Rights of data principals (s.11-13) | Access (a JSON export of everything held), correction (whitelisted fields) and erasure (pseudonymisation across tables, keeping statutory records under a pseudonym), all with an SLA register | `SP_DSR_ACCESS`, `SP_DSR_CORRECTION`, `SP_DSR_ERASURE`, `DSR_REQUESTS`, `ERASURE_LOG`, `V_DSR_SLA` |
| Storage limitation (s.8(7)) | Configurable retention rules, a dry-run mode and a suspended monthly task | `RETENTION_RULES`, `SP_APPLY_RETENTION`, `RETENTION_RUN_LOG`, `TSK_DPDP_RETENTION_MONTHLY` |
| Accountability | An append-only audit log of every scan, consent change, request and retention run, plus a RAG scorecard | `DPDP_AUDIT_LOG`, `V_DPDP_COMPLIANCE_SCORECARD`, `V_PII_BY_TABLE`, `V_CONSENT_TREND`, `V_DSR_SUMMARY` |

Everything lives in `ACCEL_DB.DPDP`. The kit works on **zero-copy clones** of `DEMO.CUSTOMERS`, `ORDERS`, `SUPPORT_TICKETS` and `EMPLOYEES`, so erasure and retention never change the shared demo data. In a client project, point the procedures at the real systems of record.

## Prerequisites
- `00_setup` (both files).
- Enterprise Edition, for row access and masking policies.
- ACCOUNTADMIN once, in file 04, to grant `APPLY ROW ACCESS POLICY` and `APPLY MASKING POLICY` to ACCEL_ADMIN.

## Run order
| File | Purpose |
|---|---|
| `01_setup_systems_of_record.sql` | Schema, clones, `KIT_CONFIG` (salt, SLA, DPO contact: `-- EDIT ME`), audit log |
| `02_pii_discovery.sql` | Discovery procedure and scan of the DEMO and DPDP tables. Builds the consolidated inventory view |
| `03_consent_register.sql` | Purposes (`-- EDIT ME`), synthetic consent history, consent recording procedure |
| `04_purpose_based_access.sql` | Role-to-purpose map (`-- EDIT ME`), row access and masking policies, a demo for each role |
| `05_data_principal_rights.sql` | Request register and the access, correction and erasure procedures, with a demo |
| `06_retention.sql` | Retention rules (`-- EDIT ME` periods), procedure, suspended task, dry-run demo |
| `07_compliance_dashboard.sql` | Scorecard and supporting views |

Rerunning `01` resets the cloned tables. Rerun `04` afterwards so analysts lose direct table access again.

## 5-step demo script
1. **What personal data do we hold?** Run `SELECT * FROM V_PII_BY_TABLE`. `SYSTEM$CLASSIFY` finds e-mail, name and phone. The India patterns add PAN (`IN_PAN`) and GSTIN, which generic classifiers often miss. Columns found by two detectors are flagged `CORROBORATED`.
2. **Consent drives access.** In `04`, the same view returns all 5,000 customers to support (a legitimate use). Analytics sees only principals with active analytics consent, with identifiers masked. Marketing sees only marketing opt-ins, and customer 42, who withdrew in `03`, disappears.
3. **Right to access.** Run `CALL SP_DSR_ACCESS(101, 'DSR-DEMO-0001')`. One JSON document holds the profile, orders, tickets, consents, purposes, recipients and the grievance contact.
4. **Right to erasure.** Run `CALL SP_DSR_ERASURE(202, ...)`. Name, e-mail, phone, PAN and city are pseudonymised, ticket text is erased and consents are withdrawn. Orders are kept under the pseudonymous ID for tax retention. Show `ERASURE_LOG` and `DPDP_AUDIT_LOG`.
5. **Board view.** Run `CALL SP_APPLY_RETENTION(TRUE)` to show what would be anonymised. Then `SELECT * FROM V_DPDP_COMPLIANCE_SCORECARD` gives RAG status for the inventory, consent, rights, retention and access-control controls.

## Extending for a client
- Turn on continuous classification: create a `SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE` and attach it with `ALTER DATABASE ... SET CLASSIFICATION_PROFILE`. Add custom classifiers for Aadhaar, ABHA or Voter ID. Use tag-based masking so new columns are protected automatically.
- Feed `CONSENT_REGISTER` from the client's consent platform or a registered Consent Manager through Snowpipe Streaming or Openflow.
- Children's data (s.9): add a date of birth or age flag, plus a verifiable parental-consent purpose, to the same row access policy.
- Personal data breach notification: use `SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY` and `LOGIN_HISTORY` to find which principals' data was touched.

## Client value
- One place to show the Data Protection Board, auditors and the board how personal data is found, consented, restricted, served and retired. The evidence sits in auditable tables, not slides.
- Requests that took days of manual searching across systems now run in seconds. Every action is logged.
- Controls are enforced in the data platform itself, so BI tools, notebooks and AI apps inherit them.
