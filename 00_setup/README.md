# 00_setup - Account foundation and shared demo data

## What it does
Creates the common foundation every accelerator relies on:

| Object | Name |
|---|---|
| Roles | `ACCEL_ADMIN` > `ACCEL_DEVELOPER` > `ACCEL_ANALYST` > `ACCEL_VIEWER` (ACCEL_ADMIN is granted to SYSADMIN and to you) |
| Warehouses | `ACCEL_WH` (XSMALL), `ACCEL_AI_WH` (SMALL), both auto-suspend 60 s |
| Resource monitor | `ACCEL_RM` - monthly quota, notify at 75 % / 90 %, suspend at 100 % |
| Database | `ACCEL_DB` with schemas `DEMO` and `COMMON` |
| AI access | `SNOWFLAKE.CORTEX_USER` for all four roles |
| Usage data | `IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE` for ACCEL_ADMIN |
| Account privileges (ACCEL_ADMIN) | CREATE DATABASE / WAREHOUSE / INTEGRATION / SHARE / APPLICATION PACKAGE / APPLICATION; EXECUTE TASK / MANAGED TASK / ALERT / MANAGED ALERT / DATA METRIC FUNCTION |

`02_demo_data.sql` then builds 11 synthetic, deterministic tables in `ACCEL_DB.DEMO`
(Jan 2024 - Sep 2026) that all other accelerators use.

## Prerequisites
- Snowflake Enterprise edition (or higher) account.
- A user with `ACCOUNTADMIN` for `01_account_setup.sql` and `99_teardown.sql`.
- Cortex AI functions available in your region, or cross-region inference enabled
  (see the commented `CORTEX_ENABLED_CROSS_REGION` line in `01_account_setup.sql`).

## Run order
1. `01_account_setup.sql` - as ACCOUNTADMIN. Review the `-- EDIT ME` lines first
   (installing user - defaults to you; monthly credit quota; optional extra users).
2. `02_demo_data.sql` - as ACCEL_ADMIN. Takes 1-3 minutes on XSMALL. Ends with a row-count
   check, integrity checks (all zeros expected) and a South-region preview.
3. `99_teardown.sql` - only when you want to remove everything. Set `confirm` to `'YES'` inside the script.

## Demo data at a glance
| Table | Rows | Story built in |
|---|---|---|
| CUSTOMERS | 5,000 | 4 segments, 5 regions, 6 countries; fake PAN/email/phone for PII demos |
| PRODUCTS | 200 | 5 categories; low PRODUCT_IDs are best-sellers |
| SUPPLIERS | 50 | 6 High-risk suppliers with poor on-time delivery |
| PLANTS | 8 | India, USA, UK, Germany, Japan, Singapore |
| ORDERS / ORDER_LINES | 100,000 / ~250,000 | ~30 % YoY growth, Q4 peak, weekend dip, E-commerce growth, **South region dip in 2026-Q2**; ORDER_TOTAL = SUM(NET_AMOUNT) |
| PURCHASE_ORDERS | 20,000 | Late deliveries concentrated in High-risk suppliers, worse in 2026 |
| INVENTORY_SNAPSHOTS | 230,400 | Weekly; Houston plant (3) stocks out on a few SKUs from Aug 2026 |
| GL_JOURNAL | ~200,000 | Balanced journals in local currency; Manual anomalies: weekend/late-night postings, round amounts, creator = approver (~0.5 %), ~25 very large adjustments, month-end clustering |
| EMPLOYEES | 500 | CEO > 8 department heads > 56 managers > staff; 8 % exited |
| SUPPORT_TICKETS | 2,000 | 8 topics (delivery, billing, defect, praise, install, refund, access, warranty) |

Orders are invoiced in USD; GL amounts are in each entity's local currency (INR, USD, GBP, EUR).

## 5-step demo script
1. Show `SHOW GRANTS TO ROLE ACCEL_ADMIN` and the role hierarchy: least privilege from day one.
2. Show `ACCEL_RM` in Admin > Cost Management: spend is capped before any demo runs.
3. Run the row-count query at the end of `02_demo_data.sql` - 800k+ realistic rows in about 2 minutes.
4. Run the South-region preview - "here is a business problem the AI and BI accelerators will find".
5. Query `GL_JOURNAL WHERE CREATED_BY = APPROVED_BY AND SOURCE = 'Manual'` - the audit and anomaly accelerators start here.

## Client value
A governed, cost-capped Snowflake sandbox with realistic cross-domain data is ready in under
10 minutes, so every later accelerator demo runs on the client's own account instead of slides.

## Notes
- Future grants are defined at database level. Do not add schema-level future grants in
  ACCEL_DB, because schema-level future grants override database-level ones for that schema.
- Streamlit apps are owned by the creating role; grant `USAGE ON STREAMLIT` to ACCEL_VIEWER per app if viewers need them.
