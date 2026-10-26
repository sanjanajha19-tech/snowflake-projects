# 22 · Fraud & Anomaly Detection

Card-fraud detection that runs entirely in Snowflake. Explainable **rules** built with window functions are combined with **SNOWFLAKE.ML.ANOMALY_DETECTION** on each cardholder's daily spend. The output is a scored **case queue** with plain-language reasons, an analyst workflow (Open → Investigating → Confirmed fraud / False positive) and a Snowflake **ALERT** that pushes new high-risk cases for investigation.

## What it does
| Object | Purpose |
|---|---|
| `FRAUD.CARD_TRANSACTIONS` | ~200,000 synthetic card transactions (4 Apr – 30 Sep 2026) for the DEMO customers, with four injected fraud patterns: velocity burst, impossible travel, odd merchant and amount spike. `IS_FRAUD_INJECTED` is ground truth for evaluation only |
| `FRAUD.FRAUD_CONFIG` | Period, ML training cut-off (`DETECT_FROM`), ML minimum history, minimum case score (`-- EDIT ME`) |
| `FRAUD.FRAUD_RULES` | Six configurable rules with thresholds and weights. Edits are kept on rerun |
| `V_TXN_FEATURES`, `V_TXN_RULE_SCORES` | Per-transaction features relative to the cardholder's own history (1-hour velocity, implied km/h, amount ratio and z-score, first use of MCC or device), rule flags, a 0–100 rule score and reasons |
| `V_RULE_EVALUATION` | Precision and recall of each rule against the injected fraud |
| `FRAUD_SPEND_AD`, `AD_RESULTS` | Multi-series anomaly detection model (one series per high-activity cardholder), trained before `DETECT_FROM`, scored after it |
| `V_CASE_CANDIDATES` → `FRAUD_CASES` | Rules and ML combined per cardholder-day: `RISK_SCORE`, `RISK_BAND` (High / Medium), `DETECTED_BY` (Rules / ML / Rules + ML) and `REASONS`, plus workflow columns `STATUS`, `ASSIGNED_TO`, `ANALYST_NOTES`, `STATUS_UPDATED_*`, `CLOSED_AT` |
| `REFRESH_FRAUD_CASES()` | MERGEs new candidates into `FRAUD_CASES`. Analyst status and notes are kept |
| `SET_CASE_STATUS(case_id, status, note, user)` | Validated status change, written to `FRAUD_CASE_HISTORY` |
| `FRAUD_HIGH_RISK_ALERT` → `CASE_QUEUE`, `V_CASE_QUEUE` | Hourly ALERT (**created suspended**). When an open case scores at or above `CASE_CONFIG.HIGH_RISK_MIN_SCORE` (70) and is not yet queued, it calls `ENQUEUE_HIGH_RISK_CASES('ALERT')` |
| `streamlit_app.py` | Case review screen: filters, KPIs, case detail with reasons, the customer's recent transactions, status buttons and history |

## Prerequisites
- `00_setup` has been run (`ACCEL_ADMIN`, `ACCEL_WH`, `ACCEL_AI_WH`, `DEMO.CUSTOMERS`). `ACCEL_ADMIN` has `EXECUTE ALERT`.
- File 03 trains an ML model on `ACCEL_AI_WH`, which takes a few minutes.

## Run order
1. `01_synthetic_transactions.sql`: transactions and reference data (~30 s)
2. `02_features_and_rules.sql`: features, rules, rule evaluation
3. `03_ml_anomaly_detection.sql`: train and detect, writes `AD_RESULTS`
4. `04_alerts_and_cases.sql`: cases, procedures, the alert (suspended), first refresh and a manual queue run
5. Create a Streamlit app in `ACCEL_DB.FRAUD` on `ACCEL_WH` and paste `streamlit_app.py`.
6. Optional: `ALTER ALERT ACCEL_DB.FRAUD.FRAUD_HIGH_RISK_ALERT RESUME;` to start the hourly check. Suspend it after the demo to save credits.

## 5-step demo script
1. **The data and the rules.** Show the injected patterns (the last query in file 01) and `V_RULE_EVALUATION`. Each rule is a readable threshold in `FRAUD_RULES`, and you can see how much fraud it catches and how noisy it is.
2. **ML on top.** Show `AD_RESULTS` from file 03. The model learns each cardholder's own spending pattern and flags days above the expected band, with no thresholds set by hand. Point out the amount-spike days that ML catches on its own.
3. **One case queue.** Open the app. The KPIs show open cases, high-risk count and open exposure. Filter to *High* and *Rules + ML*. Each case reads like an analyst note: "Impossible travel: Mumbai to Dubai in 70 min; Card present abroad: UAE".
4. **Investigate and decide.** Open a case. Show the customer's recent transactions with the flagged rows, then click *Investigating*, add a note and click *Confirmed fraud*. Open a medium ML-only case and mark it *False positive*. Show the status history, then run `SELECT * FROM ACCEL_DB.FRAUD.FRAUD_CASE_HISTORY` to show the audit trail.
5. **Always on.** Show `FRAUD_HIGH_RISK_ALERT` (`SHOW ALERTS`), `CASE_QUEUE` and `ALERT_HISTORY`. Change a rule weight in `FRAUD_RULES`, run `CALL ENQUEUE_HIGH_RISK_CASES('MANUAL')` and show new cases arriving while earlier decisions stay in place.

## Tuning (`-- EDIT ME`)
- `FRAUD_RULES`: thresholds, weights and `IS_ACTIVE` per rule. Views pick up changes immediately.
- `FRAUD_CONFIG.CASE_MIN_SCORE` (40) sets the minimum score for a case. `CASE_CONFIG.HIGH_RISK_MIN_SCORE` (70) sets the score at which a case is queued by the alert.
- `prediction_interval` in file 03: a higher value gives fewer, stronger ML anomalies.
- Score design: rule points are the best transaction score, +10 per extra rule type, +10 for 3 or more flagged transactions. ML points are 40–60 when the day's spend is above the model's upper bound. The total is capped at 100.
- Production: replace `CARD_TRANSACTIONS` with the card authorisation feed, and remove `IS_FRAUD_INJECTED` from the evaluation views.

## Client value claim
Fraud teams get one ranked, explained queue instead of separate rule alerts and model scores. Combining transparent rules with per-customer ML typically catches 20–40% more fraud at the same alert volume, or removes a similar share of false positives at the same catch rate. Every case states why it was raised, which speeds up review and supports auditors and regulators. Data, models, alerting and the review app all run inside Snowflake, so there is no separate fraud platform or data copy, and a pilot can go live in weeks.
