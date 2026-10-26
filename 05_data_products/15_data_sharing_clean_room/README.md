# 15 - Data Sharing & Lightweight Clean Room

Two data-collaboration patterns on one Snowflake Enterprise account:

1. **Secure Data Sharing** - publish an aggregated sales data product (monthly sales by region / country / category) through secure views and a `SHARE`, with per-consumer row entitlements and an optional reader account for partners who have no Snowflake account.
2. **Lightweight clean room** - two parties (a brand and a retailer) match customer lists on salted, hashed e-mails. Aggregation and projection policies stop either side from seeing individual rows or identifiers. Only approved aggregate analyses are exposed.

> **Production note:** this clean room is a teaching and demo pattern built from core governance features. For real multi-party collaboration across accounts, use **Snowflake Data Clean Rooms**, the managed Native App from the Snowflake Marketplace. It adds templates, cross-account provider and consumer flows, differential privacy options, activation and a UI for business users. Use this asset to explain the mechanics, then position the managed product.

## Prerequisites
- `00_setup` has been run (ACCEL_ADMIN, ACCEL_WH, ACCEL_DB.DEMO data).
- Enterprise Edition or higher. Aggregation and projection policies need it.
- ACCOUNTADMIN for three one-off grants: `CREATE SHARE`, `APPLY AGGREGATION POLICY` and `APPLY PROJECTION POLICY` on the account. File 02 also needs it, to create a reader account.

## Run order
| File | What it does | Role |
|---|---|---|
| `01_secure_share.sql` | Aggregated table, entitlement table, two secure views, `ACCEL_SALES_SHARE`, optional consumer accounts | ACCOUNTADMIN (1 grant), then ACCEL_ADMIN |
| `02_reader_account_optional.sql` | Creates a managed READER account and adds it to the share. Skipped unless `create_reader = TRUE` | ACCOUNTADMIN |
| `03_clean_room_setup.sql` | Brand and retailer tables with hashed e-mails, aggregation policy (min group size 25), projection policy on `HASHED_EMAIL`, approved secure views and a secure UDTF | ACCOUNTADMIN (2 grants), then ACCEL_ADMIN |
| `04_clean_room_demo.sql` | Walk-through as ACCEL_ANALYST: blocked queries, protected aggregates and approved analyses | ACCEL_ANALYST |

### `-- EDIT ME` values
- `01`: minimum customers per published cell (`CALL SP_REFRESH_SALES_AGG(5)`), consumer account locators in `CONSUMER_ENTITLEMENTS`, and the consumer accounts in `SHARE_CONFIG` (`'NONE'` skips this step).
- `02`: `create_reader`, admin user name and password.
- `03`: the hashing salt `CR_SALT` and `MIN_GROUP_SIZE`.

## Objects
- `ACCEL_DB.SHARING`: `SALES_MONTHLY_AGG`, `SP_REFRESH_SALES_AGG`, `CONSUMER_ENTITLEMENTS`, `SHARE_CONFIG`, `V_SALES_BY_REGION_CATEGORY_MONTH` (secure), `V_SALES_ENTITLED` (secure, filtered on `CURRENT_ACCOUNT()`), share `ACCEL_SALES_SHARE`.
- `ACCEL_DB.CLEANROOM`: `BRAND_CUSTOMERS`, `RETAILER_CUSTOMERS`, `CR_AGG_POLICY`, `CR_HASH_PROJ_POLICY`, `V_APPROVED_OVERLAP_SUMMARY`, `V_APPROVED_OVERLAP_BY_SEGMENT`, `V_APPROVED_OVERLAP_BY_CATEGORY_AFFINITY`, `APPROVED_OVERLAP_FOR_REGION(region)`.

## How the clean room works
| Control | Mechanism | Effect for ACCEL_ANALYST |
|---|---|---|
| Pseudonymous join key | `SHA2(salt \|\| lower(trim(email)), 256)` | The parties match without exchanging raw e-mails. |
| Aggregation policy | `AGGREGATION_CONSTRAINT(MIN_GROUP_SIZE => 25)` | `SELECT *` fails. Groups under 25 rows fold into a remainder row with NULL keys. |
| Projection policy | `PROJECTION_CONSTRAINT(ALLOW => false)` on `HASHED_EMAIL` | The hash can be joined on and filtered on, but never returned. |
| Approved analyses | Secure views and a secure UDTF | The logic is hidden, and only aggregate outputs are exposed. |

ACCEL_ADMIN (the clean-room operator) is exempt so it can load and check data. The demo compares the two views.

In this single-account demo, `03` hashes both lists from the same DEMO customers, so the true overlap is known: `CUSTOMER_ID mod 10` in 3 to 6, about 2,000 people. That lets you show that the overlap count is right.

## 5-step demo script
1. **The data product.** In `01`, show `V_SALES_BY_REGION_CATEGORY_MONTH`: aggregated, cells under 5 customers suppressed, refreshed by a procedure. Run `SHOW GRANTS TO SHARE ACCEL_SALES_SHARE`. The point: no copies and no ETL, and the consumer queries live data.
2. **One share, many consumers.** Run the `SIMULATED_DATA_SHARING_CONSUMER` block. The same secure view returns only the North and West regions for consumer 1. To onboard a partner without a Snowflake account, show `02`.
3. **The clean-room problem.** Open `03`. The brand and the retailer each want to know their shared customers, but neither may hand over customer lists. Show the salted hashing, then the two policies.
4. **Try to break it.** In `04` as ACCEL_ANALYST, uncomment `SELECT * FROM BRAND_CUSTOMERS` and it fails. Uncomment the `HASHED_EMAIL` projection and it fails. Then run the fine-grained `GROUP BY`, where the small cells collapse into a NULL remainder row.
5. **Approved insight.** Run `V_APPROVED_OVERLAP_SUMMARY` (about 2,000 overlapping customers and their spend) and `APPROVED_OVERLAP_FOR_REGION('North')`. Close with Snowflake Data Clean Rooms as the managed, cross-account production path.

## Client value
- Partners get governed data in minutes instead of weeks of SFTP and file pipelines. The provider keeps one copy and one set of access rules.
- Per-consumer entitlements in one share keep operating cost flat as the partner count grows.
- The clean room lets two companies measure audience overlap and joint campaign reach while the hashed identifiers never leave the governance policies.
- This supports DPDP, GDPR and contractual data-minimisation obligations.
