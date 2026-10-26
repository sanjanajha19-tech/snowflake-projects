# 14 - Forecasting & ML Starter

Three ready-to-run ML patterns on the demo sales data. They use Snowflake's built-in ML functions, which need no data science code, plus a custom model in Snowpark ML with the Model Registry.

| Pattern | Technique | Output |
|---|---|---|
| 90-day revenue forecast by region | `SNOWFLAKE.ML.FORECAST` (multi-series) | `REVENUE_FORECAST`, `REVENUE_FORECAST_EVAL` (MAE, MAPE, SMAPE, MSE ... from `!SHOW_EVALUATION_METRICS`), `REVENUE_FORECAST_FEATURE_IMPORTANCE`, `REVENUE_ACTUAL_VS_FORECAST_V` |
| Daily order anomaly detection | `SNOWFLAKE.ML.ANOMALY_DETECTION` (unsupervised) | `ORDER_ANOMALIES` (actual vs expected, bounds, `IS_ANOMALY`, percentile) |
| Customer churn propensity | Snowpark Python stored procedure: sklearn pipeline + XGBoost, logged to the **Model Registry** | `CHURN_PROPENSITY_MODEL` (one version per run, with metrics), `CHURN_SCORES` (probability and risk band per customer) |

All objects are in `ACCEL_DB.ML_STARTER`.

## Prerequisites
- `00_setup` run. `ACCEL_ADMIN` owns the schema, so it can create FORECAST, ANOMALY_DETECTION and MODEL objects.
- For the churn model, Anaconda packages (`xgboost`, `scikit-learn`, `snowflake-ml-python`). If `04` fails with an Anaconda terms message, an ORGADMIN accepts them once. This is a UI step: **Admin > Billing & Terms > Anaconda > Acknowledge & Continue**.

## Run order
1. `01_revenue_forecast.sql`. Run the whole file top to bottom: each `RESULT_SCAN(LAST_QUERY_ID())` reads the `CALL` directly above it. Training takes about 1-2 minutes.
2. `02_order_anomaly_detection.sql`. Trains on all but the last 60 days and scores the last 60. Two synthetic incidents (a spike and a dip) are injected into the test window so the demo always shows hits. Set `INJECT_DEMO_ANOMALIES` to `FALSE` for real use.
3. `03_churn_features.sql`. Builds the point-in-time feature function `CUSTOMER_FEATURES(AS_OF)` (RFM, trend, returns, e-commerce share, tickets, escalations), a labelled training set (cutoff = latest date - 90 days), and a scoring set (as of the latest date).
4. `04_churn_model_procedure.sql`. Creates `TRAIN_CHURN_MODEL()`, whose code is identical to `churn_model.py`, then calls it and shows the top-risk customers.
   - Alternative: run `churn_model.py` in a **Snowflake Notebook** (packages `snowflake-ml-python`, `scikit-learn`, `xgboost`) with `print(run(get_active_session()))`, or locally (see the file's docstring).

## Visualising (UI step)
In a Snowsight worksheet run `SELECT * FROM REVENUE_ACTUAL_VS_FORECAST_V WHERE REGION = 'South' ORDER BY TS;`, open **Chart**, choose a line chart with X = `TS`, Y = `VALUE` and series = `KIND`.

## 5-step demo script
1. Show `DAILY_REVENUE_BY_REGION_V` and train the forecast with one SQL statement. No Python, no feature engineering.
2. Chart actual vs forecast for one region, then show `REVENUE_FORECAST_EVAL` (MAPE per region) to discuss forecast accuracy.
3. Run anomaly detection and show the two flagged days with expected range against actual. Mention the scheduled-task and alert pattern at the bottom of file 02.
4. Run `CALL TRAIN_CHURN_MODEL();`. Show AUC, precision and recall in the return value, then `SHOW VERSIONS IN MODEL CHURN_PROPENSITY_MODEL` (versioned and governed).
5. Show the top 25 high-risk customers, with segment, recency and ticket count, as a ready-made retention call list.

## Client value
- Forecasts and anomaly alerts in days, not months. Built-in ML functions put this in the hands of SQL analysts, with no separate ML platform.
- Churn scores land next to the customer data. They can drive CRM campaigns, Streamlit apps or agents, and are governed by Snowflake RBAC with model lineage in the Registry.
- The patterns transfer to demand planning, cash-flow forecasting, sensor and IoT anomalies, and propensity-to-buy.

## Notes and assumptions
- Revenue for forecasting = `ORDER_TOTAL` of Delivered and Shipped orders. The series are zero-filled daily per customer region.
- `CONFIG_OBJECT => {'ON_ERROR': 'SKIP'}` lets training continue if one region fails. Evaluation metrics come from the cross-validation that runs during training.
- Churn label: active in the 365 days before the cutoff, then no Delivered or Shipped order in the next 90 days (`CHURN_WINDOW_DAYS`, marked `EDIT ME`). Features use only data up to the as-of date, so there is no leakage.
- The model is an sklearn `Pipeline` (OneHotEncoder + `XGBClassifier`). The procedure scores with the in-memory pipeline and also checks in-warehouse inference via `ModelVersion.run(..., function_name="predict_proba")`. From SQL use `MODEL(ACCEL_DB.ML_STARTER.CHURN_PROPENSITY_MODEL, LAST)!PREDICT_PROBA(...)`.
- The stored procedure runs `EXECUTE AS CALLER`, so the caller's role needs CREATE MODEL and CREATE TABLE on `ML_STARTER`. `ACCEL_ADMIN` has both.
- Cost: training uses `ACCEL_AI_WH` (SMALL), and all three patterns together take a few minutes of runtime.
