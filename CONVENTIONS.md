# Conventions (every script follows these)

## Objects created by `00_setup`
| Object | Name | Notes |
|---|---|---|
| Admin role | `ACCEL_ADMIN` | Owns everything below; granted to SYSADMIN and to the installing user |
| Developer role | `ACCEL_DEVELOPER` | Create objects in ACCEL_DB schemas |
| Analyst role | `ACCEL_ANALYST` | Read GOLD/SEMANTIC/demo data, use Cortex |
| Viewer role | `ACCEL_VIEWER` | Read-only on demo outputs |
| Warehouse | `ACCEL_WH` | XSMALL, AUTO_SUSPEND = 60, AUTO_RESUME |
| Warehouse | `ACCEL_AI_WH` | SMALL, AUTO_SUSPEND = 60 (Cortex Search, ML, Document AI) |
| Database | `ACCEL_DB` | All accelerators live here |
| Schema | `ACCEL_DB.DEMO` | Shared synthetic demo data (below) |
| Schema | `ACCEL_DB.COMMON` | Shared utilities |
| Resource monitor | `ACCEL_RM` | Monthly credit quota on both warehouses |

All roles get `SNOWFLAKE.CORTEX_USER`. ACCOUNT_USAGE access is granted to ACCEL_ADMIN via `IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE`.

## Script header (every .sql file)
```sql
USE ROLE ACCEL_ADMIN;            -- or ACCOUNTADMIN where the step needs it (say why in a comment)
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS <ASSET_SCHEMA>;
USE SCHEMA <ASSET_SCHEMA>;
```
- Every asset gets its own schema (e.g. `FINOPS`, `VALIDATION`, `C360`).
- Idempotent: `CREATE OR REPLACE` / `IF NOT EXISTS`, so a file can be rerun.
- Values a user must change are marked `-- EDIT ME`.
- Files numbered in run order: `01_...sql`, `02_...sql`. Streamlit apps are `streamlit_app.py`.
- Each asset folder has a `README.md`: what it does, prerequisites, run order, a 5-step demo script, and the client value claim.

## Shared demo data: `ACCEL_DB.DEMO` (built by `00_setup/02_demo_data.sql`)
Synthetic, deterministic, covers Jan 2024 – Sep 2026.

| Table | Columns |
|---|---|
| CUSTOMERS (5,000) | CUSTOMER_ID NUMBER, CUSTOMER_NAME, SEGMENT ('Enterprise','Mid-Market','SMB','Consumer'), INDUSTRY, REGION ('North','South','East','West','Central'), COUNTRY ('India','USA','UK','Germany','Japan','Singapore'), CITY, EMAIL, PHONE, PAN_NUMBER, CREATED_DATE DATE, CREDIT_LIMIT NUMBER(12,2) |
| PRODUCTS (200) | PRODUCT_ID, SKU, PRODUCT_NAME, CATEGORY, SUB_CATEGORY, BRAND, UNIT_COST NUMBER(10,2), LIST_PRICE NUMBER(10,2), LAUNCH_DATE DATE |
| SUPPLIERS (50) | SUPPLIER_ID, SUPPLIER_NAME, COUNTRY, CATEGORY, RISK_RATING ('Low','Medium','High'), ON_TIME_DELIVERY_PCT NUMBER(5,2), GSTIN |
| PLANTS (8) | PLANT_ID, PLANT_NAME, CITY, COUNTRY, CAPACITY_UNITS_PER_DAY |
| ORDERS (100,000) | ORDER_ID, ORDER_DATE DATE, CUSTOMER_ID, PLANT_ID, CHANNEL ('Direct','Distributor','E-commerce','Retail'), STATUS ('Delivered','Shipped','Cancelled','Returned'), CURRENCY, ORDER_TOTAL NUMBER(14,2) |
| ORDER_LINES (~250,000) | ORDER_ID, LINE_NO, PRODUCT_ID, QUANTITY, UNIT_PRICE NUMBER(10,2), DISCOUNT_PCT NUMBER(5,2), NET_AMOUNT NUMBER(14,2) |
| PURCHASE_ORDERS (20,000) | PO_ID, PO_DATE, SUPPLIER_ID, PLANT_ID, PRODUCT_ID, QUANTITY, UNIT_COST, PROMISED_DATE, RECEIVED_DATE (NULL if open), STATUS ('Open','Received','Late','Cancelled') |
| INVENTORY_SNAPSHOTS (weekly) | SNAPSHOT_DATE, PLANT_ID, PRODUCT_ID, ON_HAND_QTY, REORDER_POINT, SAFETY_STOCK |
| GL_JOURNAL (~200,000 lines) | JOURNAL_ID, LINE_NO, POSTING_DATE DATE, ENTRY_TIMESTAMP TIMESTAMP_NTZ, ENTITY ('IN01','US01','UK01','DE01'), ACCOUNT_CODE, ACCOUNT_NAME, ACCOUNT_TYPE ('Revenue','COGS','Opex','Asset','Liability','Equity'), COST_CENTER, AMOUNT NUMBER(16,2) (debit +, credit −), CURRENCY, DESCRIPTION, CREATED_BY, APPROVED_BY, SOURCE ('AP','AR','Manual','Payroll','FA') |
| EMPLOYEES (500) | EMPLOYEE_ID, FULL_NAME, EMAIL, DEPARTMENT, JOB_TITLE, LOCATION, HIRE_DATE, SALARY NUMBER(12,2), MANAGER_ID, STATUS ('Active','Exited') |
| SUPPORT_TICKETS (2,000) | TICKET_ID, CREATED_AT TIMESTAMP_NTZ, CUSTOMER_ID, PRODUCT_ID, CHANNEL ('Email','Phone','Chat','Web'), SUBJECT, BODY (2–4 realistic sentences), PRIORITY ('Low','Medium','High','Critical'), STATUS ('Open','Resolved','Escalated'), RESOLVED_AT |

Assets may create extra synthetic tables in their own schema when they need data the core model lacks.

## Snowflake feature names to use (2026)
AI SQL functions: `AI_COMPLETE`, `AI_CLASSIFY`, `AI_EXTRACT`, `AI_SENTIMENT`, `AI_SUMMARIZE_AGG`, `AI_AGG`, `AI_FILTER`, `AI_TRANSLATE`, `AI_PARSE_DOCUMENT`, `AI_EMBED`, `AI_SIMILARITY`. Semantic views (`CREATE SEMANTIC VIEW`), Cortex Search (`CREATE CORTEX SEARCH SERVICE`), Cortex Agents (`CREATE AGENT ... FROM SPECIFICATION`), Snowflake ML functions (`SNOWFLAKE.ML.FORECAST`, `SNOWFLAKE.ML.ANOMALY_DETECTION`), Dynamic Tables, Data Metric Functions, Budgets (`SNOWFLAKE.CORE.BUDGET`), Streamlit in Snowflake.
Check exact syntax against docs.snowflake.com before using any of these.
