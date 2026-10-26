"""
ASSET 14 - Churn propensity model (Snowpark + snowflake-ml-python)

What it does
  1. Reads ACCEL_DB.ML_STARTER.CHURN_TRAINING_SET (built by 03_churn_features.sql)
  2. Trains an sklearn Pipeline (one-hot encode categoricals + XGBoost classifier)
     on an 80/20 stratified split; computes AUC, precision, recall, F1
  3. Logs the pipeline to the Snowflake Model Registry as CHURN_PROPENSITY_MODEL
     (new version per run) with metrics
  4. Scores CHURN_SCORING_SET and writes ACCEL_DB.ML_STARTER.CHURN_SCORES
     (probability, risk band) - scored with the in-memory pipeline, and also
     demonstrates in-warehouse inference with ModelVersion.run()

Three ways to run it
  a) Stored procedure (easiest): run 04_churn_model_procedure.sql, which embeds
     this exact code, then CALL ACCEL_DB.ML_STARTER.TRAIN_CHURN_MODEL();
  b) Snowflake Notebook: create a notebook in ACCEL_DB.ML_STARTER (warehouse
     runtime), add packages snowflake-ml-python, scikit-learn, xgboost, paste
     this file into a cell and run:  print(run(get_active_session()))
  c) Locally: pip install "snowflake-snowpark-python" "snowflake-ml-python" \
     scikit-learn xgboost pandas, set the SNOWFLAKE_* environment variables
     (account, user, password or authenticator) and run  python3 churn_model.py
"""

import datetime
import os

import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.metrics import f1_score, precision_score, recall_score, roc_auc_score
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder
from xgboost import XGBClassifier

DATABASE = "ACCEL_DB"
SCHEMA = "ML_STARTER"
MODEL_NAME = "CHURN_PROPENSITY_MODEL"
TRAINING_TABLE = f"{DATABASE}.{SCHEMA}.CHURN_TRAINING_SET"
SCORING_TABLE = f"{DATABASE}.{SCHEMA}.CHURN_SCORING_SET"
OUTPUT_TABLE = "CHURN_SCORES"

CATEGORICAL = ["SEGMENT", "REGION", "COUNTRY"]
NUMERIC = [
    "TENURE_DAYS", "RECENCY_DAYS", "FREQUENCY_365D", "MONETARY_365D", "AVG_ORDER_VALUE_365D",
    "ORDERS_90D", "ORDERS_PRIOR_90D", "ORDER_TREND_RATIO", "RETURN_RATE_365D",
    "ECOMMERCE_SHARE_365D", "TICKETS_180D", "ESCALATED_180D", "CREDIT_LIMIT",
]
LABEL = "CHURNED"
HIGH_RISK = 0.6     # EDIT ME: risk band thresholds
MEDIUM_RISK = 0.3


def _prepare(df):
    """Make dtypes model-friendly (Snowflake NUMBER can arrive as object/Decimal)."""
    out = df.copy()
    for col in NUMERIC:
        out[col] = pd.to_numeric(out[col], errors="coerce").astype("float64")
    for col in CATEGORICAL:
        out[col] = out[col].astype(str)
    return out


def _build_pipeline(scale_pos_weight):
    preprocess = ColumnTransformer(
        transformers=[
            ("cat", OneHotEncoder(handle_unknown="ignore"), CATEGORICAL),
            ("num", "passthrough", NUMERIC),
        ]
    )
    model = XGBClassifier(
        n_estimators=300,
        max_depth=4,
        learning_rate=0.05,
        subsample=0.9,
        colsample_bytree=0.9,
        eval_metric="auc",
        scale_pos_weight=scale_pos_weight,
        random_state=42,
        n_jobs=1,
    )
    return Pipeline(steps=[("preprocess", preprocess), ("model", model)])


def run(session):
    """Train, evaluate, register and score. Returns a short text summary."""
    from snowflake.ml.registry import Registry

    # 1. Data
    train_pdf = _prepare(session.table(TRAINING_TABLE).to_pandas())
    if train_pdf[LABEL].nunique() < 2:
        return "Training set has a single class - adjust the churn window in 03_churn_features.sql"
    X = train_pdf[CATEGORICAL + NUMERIC]
    y = train_pdf[LABEL].astype(int)
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, stratify=y, random_state=42
    )

    # 2. Train + evaluate
    positives = max(int(y_train.sum()), 1)
    negatives = max(int((y_train == 0).sum()), 1)
    pipeline = _build_pipeline(scale_pos_weight=negatives / positives)
    pipeline.fit(X_train, y_train)

    proba = pipeline.predict_proba(X_test)[:, 1]
    pred = (proba >= 0.5).astype(int)
    metrics = {
        "auc": round(float(roc_auc_score(y_test, proba)), 4),
        "precision": round(float(precision_score(y_test, pred, zero_division=0)), 4),
        "recall": round(float(recall_score(y_test, pred, zero_division=0)), 4),
        "f1": round(float(f1_score(y_test, pred, zero_division=0)), 4),
        "train_rows": int(len(X_train)),
        "test_rows": int(len(X_test)),
        "churn_rate": round(float(y.mean()), 4),
    }

    # Feature importance (top 10) for the summary
    feature_names = list(pipeline.named_steps["preprocess"].get_feature_names_out())
    importances = pipeline.named_steps["model"].feature_importances_
    top = sorted(zip(feature_names, importances), key=lambda t: t[1], reverse=True)[:10]
    metrics["top_features"] = {name: round(float(val), 4) for name, val in top}

    # 3. Register (new version each run, e.g. V_20261002_143015)
    version_name = "V_" + datetime.datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    registry = Registry(session=session, database_name=DATABASE, schema_name=SCHEMA)
    model_version = registry.log_model(
        pipeline,
        model_name=MODEL_NAME,
        version_name=version_name,
        sample_input_data=X_train.head(100),
        conda_dependencies=["scikit-learn", "xgboost"],
        target_platforms=["WAREHOUSE"],
        metrics=metrics,
        comment="Churn propensity (90-day) - RFM + service features, XGBoost. ACCEL asset 14",
    )

    # 4. Score current customers and save
    score_pdf = _prepare(session.table(SCORING_TABLE).to_pandas())
    score_proba = pipeline.predict_proba(score_pdf[CATEGORICAL + NUMERIC])[:, 1]
    out = pd.DataFrame({
        "CUSTOMER_ID": score_pdf["CUSTOMER_ID"].astype("int64"),
        "AS_OF_DATE": pd.to_datetime(score_pdf["AS_OF_DATE"]).dt.date,
        "CHURN_PROBABILITY": score_proba.round(4),
    })
    out["RISK_BAND"] = pd.cut(
        out["CHURN_PROBABILITY"],
        bins=[-0.01, MEDIUM_RISK, HIGH_RISK, 1.01],
        labels=["Low", "Medium", "High"],
    ).astype(str)
    out["MODEL_NAME"] = MODEL_NAME
    out["MODEL_VERSION"] = version_name
    out["SCORED_AT"] = datetime.datetime.utcnow()
    session.write_pandas(
        out, OUTPUT_TABLE, database=DATABASE, schema=SCHEMA,
        auto_create_table=True, overwrite=True, quote_identifiers=False,
    )

    # In-warehouse inference through the registry (same model, runs as a
    # Snowflake function on the warehouse). Shown on 5 rows as an example.
    registry_check = "ok"
    try:
        sample_df = session.table(SCORING_TABLE).select(*(CATEGORICAL + NUMERIC)).limit(5)
        model_version.run(sample_df, function_name="predict_proba").collect()
    except Exception as exc:  # inference demo must not fail the training run
        registry_check = f"skipped ({type(exc).__name__}: {exc})"

    high = int((out["RISK_BAND"] == "High").sum())
    return (
        f"Model {MODEL_NAME} {version_name} registered in {DATABASE}.{SCHEMA}. "
        f"AUC={metrics['auc']} precision={metrics['precision']} recall={metrics['recall']} "
        f"F1={metrics['f1']}. Scored {len(out)} customers into {OUTPUT_TABLE} "
        f"({high} high risk). Registry inference check: {registry_check}. "
        f"Top features: {', '.join(list(metrics['top_features'])[:5])}"
    )


def main(session):
    """Stored procedure handler (see 04_churn_model_procedure.sql)."""
    return run(session)


if __name__ == "__main__":
    from snowflake.snowpark import Session

    connection = {
        "account": os.environ["SNOWFLAKE_ACCOUNT"],
        "user": os.environ["SNOWFLAKE_USER"],
        "role": os.environ.get("SNOWFLAKE_ROLE", "ACCEL_ADMIN"),
        "warehouse": os.environ.get("SNOWFLAKE_WAREHOUSE", "ACCEL_AI_WH"),
        "database": DATABASE,
        "schema": SCHEMA,
    }
    if os.environ.get("SNOWFLAKE_PASSWORD"):
        connection["password"] = os.environ["SNOWFLAKE_PASSWORD"]
    if os.environ.get("SNOWFLAKE_AUTHENTICATOR"):
        connection["authenticator"] = os.environ["SNOWFLAKE_AUTHENTICATOR"]
    local_session = Session.builder.configs(connection).create()
    try:
        print(run(local_session))
    finally:
        local_session.close()
