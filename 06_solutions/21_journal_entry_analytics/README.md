# 21 - Journal Entry Analytics (JE risk scoring)

For internal audit, SOX / IFC controls teams and statutory auditors who test journal entries (ISA 240 / SA 240, AS 2401 "management override of controls").

## What it does
Scores **every** journal in `ACCEL_DB.DEMO.GL_JOURNAL` (about 62,500 journals, 200,000 lines) against a configurable rule library, explains the riskiest ones with AI, and gives reviewers a Streamlit app to filter, drill down and record their conclusions.

| Rule | Category | Default logic (all parameters in `JE_RISK_RULES`) | Weight |
|---|---|---|---|
| `WEEKEND` | Timing | Posted or entered on Saturday / Sunday | 15 |
| `AFTER_HOURS` | Timing | Entered at or after 20:00 or before 07:00 | 10 |
| `ROUND_AMOUNT` | Amount | A line of 10,000 or more that is an exact multiple of 1,000 | 10 |
| `SELF_APPROVAL` | Segregation of duties | `CREATED_BY = APPROVED_BY` | 30 |
| `MANUAL_REVENUE` | Account | Manual journal touching a revenue account | 20 |
| `JUST_BELOW_THRESHOLD` | Amount | Journal total within 5% below a USD 100,000 approval limit | 20 |
| `UNUSUAL_ACCOUNT_COMBO` | Account | Debit/credit account pair used in 5 or fewer journals | 15 |
| `BENFORD_USER` | Behaviour | User's first-digit MAD more than 1.5 x the peer median (at least 200 lines) | 5 |
| `ZSCORE_USER` | Behaviour | Journal total more than 3 standard deviations from the user's mean | 20 |
| `DUPLICATE` | Integrity | Same entity, accounts and amounts as a journal posted up to 7 days earlier | 25 |

The score is the sum of weights, capped at 100. Bands: High 50 or more, Medium 25 or more, Low above 0.

**Seeded test cases.** The demo ledger has no manual revenue entries or duplicates, so `01` adds about 30 known-bad journals (IDs 990000+): quarter-end manual revenue, entries just under the approval limit, rare account pairs and re-posted duplicates. They show that each rule fires. This mirrors the audit practice of testing analytics with known exceptions. `V_JE_RULE_SUMMARY.SEEDED_CASES_FLAGGED` shows the evidence. In a client project, delete them from `V_GL_SCOPE` or keep them as a regression test.

## Prerequisites
- `00_setup` has been run (ACCEL_ADMIN, ACCEL_WH, ACCEL_AI_WH, DEMO data).
- For `03`: Cortex AI in your region, or cross-region inference enabled. Set the model in `03` (`-- EDIT ME`).

## Run order
| # | File | Notes |
|---|---|---|
| 1 | `01_setup_rules.sql` | FX rates (`-- EDIT ME`), rule table, seeded journals, population views, review table |
| 2 | `02_scoring.sql` | `SP_SCORE_JOURNALS()` builds `JE_RISK_SCORES` (score, band, rule codes and reasons per journal), Benford tables and summary views. About 1 minute on XSMALL |
| 3 | `03_ai_explanations.sql` | `AI_COMPLETE` reviewer notes for the top 50 journals into `JE_AI_EXPLANATIONS` |
| 4 | `streamlit_app.py` | Snowsight > Projects > Streamlit > + Streamlit App, location `ACCEL_DB.JE_ANALYTICS`, warehouse `ACCEL_WH` |

To tune the rules, update `JE_RISK_RULES` (for example `UPDATE JE_RISK_RULES SET PARAM_1 = 250000 WHERE RULE_CODE = 'JUST_BELOW_THRESHOLD';`) and run `CALL SP_SCORE_JOURNALS();`. To use client data, point `V_GL_SCOPE` at the client's GL extract with the same columns.

## 5-step demo script
1. **Full population, not samples.** Run `SELECT * FROM V_JE_RULE_SUMMARY;`. Every one of about 62,500 journals was tested against 10 rules in about a minute, and each rule caught its seeded test cases.
2. **Risk ranking.** Open the Streamlit app: KPIs, then High and Medium journals by month. Point out the month-end clustering and the self-approved entries.
3. **Drill-down.** Pick a top journal. Show its lines, each rule that fired with its reason (for example "Created and approved by priya.sharma", "Posted Sun, entered at 22:41"), and the preparer's posting history.
4. **AI reviewer note.** Show the `AI_COMPLETE` note: why it was flagged, questions for the preparer, and a suggested test. Then record a disposition ("Exception raised") in the review form. It is stored in `JE_REVIEW` with user and timestamp.
5. **Configurability.** Change the approval limit or a weight in `JE_RISK_RULES`, run `CALL SP_SCORE_JOURNALS()`, and refresh the app. Finish with the Benford tab: observed vs expected first digits per user.

## Client value
- Moves JE testing from sampling to 100% of the population. That is stronger evidence for management-override risk, and fewer surprises at audit.
- Rules are data, not code, so the controls team can tune them and document every run in a reproducible way.
- AI notes and in-app dispositions cut reviewer time per flagged entry from about 20 minutes to about 5. The review trail is ready for the audit file.
- The same pattern supports continuous controls monitoring: schedule `SP_SCORE_JOURNALS()` with a task after each GL load.
