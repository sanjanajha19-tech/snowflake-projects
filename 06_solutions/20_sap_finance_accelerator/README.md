# 20 - SAP Finance Accelerator

## What it does
Shows how SAP ECC / S/4HANA finance data becomes analytics-ready in Snowflake, from cryptic SAP tables to standard finance reports:

1. **Raw layer (`01`)**: synthetic SAP tables with real SAP table and field names, in the shape a replication tool delivers them: `CHAR(8)` dates (`'00000000'` = empty), leading-zero keys, unsigned amounts with a debit/credit indicator (`SHKZG`).
   `T001`, `TCURR`, `SKA1`/`SKAT`, `KNA1`, `LFA1`, `VBAK`/`VBAP`, `EKKO`/`EKPO`, `BKPF`/`BSEG`. The tables are derived from `ACCEL_DB.DEMO` (customers, suppliers, products, orders and purchase orders from Jul 2025 to Sep 2026), so numbers tie back to the shared demo data. That gives a few thousand sales and purchasing documents and a few tens of thousands of FI line items: customer invoices and payments, vendor invoices and payments, opening capital, payroll and office costs. Every FI document balances.
2. **Field mapping (`02`)**: `SAP_FIELD_MAPPING` documents every SAP field used, with its meaning, its canonical entity and field, and the transformation applied. Code tables `SAP_DOCUMENT_TYPES` and `SAP_POSTING_KEYS` translate SAP codes.
3. **Canonical model (`03`)**: views with business names, typed dates, signed amounts and no leading zeros: `FIN_COMPANY`, `FIN_GL_ACCOUNT`, `FIN_CUSTOMER`, `FIN_VENDOR`, `FIN_SALES_ORDER`, `FIN_SALES_ORDER_LINE`, `FIN_PURCHASE_ORDER`, `FIN_GL_ENTRY`.
4. **Standard reports (`04`)**: `RPT_TRIAL_BALANCE` (opening, YTD debits and credits, closing balance, with prior-year P&L carried to retained earnings), `RPT_AR_OPEN_ITEMS` / `RPT_AR_AGEING`, `RPT_AP_OPEN_ITEMS` / `RPT_AP_AGEING`, and `RPT_DSO_DPO_TREND` (13 month-ends). All reports run as of `SAPFIN_PARAMS.KEY_DATE`.

Everything lives in `ACCEL_DB.SAPFIN`.

## Production note: where the raw layer comes from
In a client project, file `01` is replaced by the real SAP replica. The canonical views in `03` only need the same table and field names. Options:
- **SAP Business Data Cloud / SAP Datasphere zero-copy sharing with Snowflake**: SAP data products shared into Snowflake without copying.
- **Snowflake Openflow** connectors and SAP partner connectors (for example SNP Glue, Theobald, Qlik/Fivetran SAP connectors, AWS AppFlow) for ECC and S/4HANA tables, CDS views or ODP extractors.
- **SAP SLT or another CDC tool** landing into Snowflake.
Check client-specific items: customer Z-fields, fiscal year variants (non-calendar `GJAHR`/`MONAT`), `ACDOCA` (Universal Journal) instead of `BSEG` on S/4HANA, `BSID`/`BSAD`/`BSIK`/`BSAK` index tables, inverted `TCURR.GDATU`, and multiple clients (`MANDT`).

## Prerequisites
- `00_setup` has been run (ACCEL_ADMIN, ACCEL_WH, ACCEL_DB.DEMO).

## Run order
| # | File | Notes |
|---|---|---|
| 1 | `01_sap_raw_tables.sql` | `-- EDIT ME`: `SAP_MANDT`, exchange rates. Ends with a row count and a balance check (expect 0 rows) |
| 2 | `02_field_mapping.sql` | Mapping and code tables. Run before `03`, because `FIN_GL_ENTRY` joins the code tables |
| 3 | `03_canonical_model.sql` | `-- EDIT ME`: `SAPFIN_PARAMS` client, key date, language |
| 4 | `04_standard_reports.sql` | Report views and sample queries |

Run each file in a single worksheet session. `01` uses session variables and temporary tables.

## 5-step demo script
1. **The SAP reality.** Run `SELECT * FROM BSEG LIMIT 20;`: `SHKZG`, `DMBTR`, `HKONT = '0000140000'`, `AUGDT = '00000000'`. "This is what lands from SAP. Nobody in the business can query it."
2. **The Rosetta stone.** Run `SELECT * FROM SAP_FIELD_MAPPING WHERE SAP_TABLE = 'BSEG';`. Every field is documented with its transformation, which makes it ready for a data catalog.
3. **Canonical model.** Run `SELECT * FROM FIN_GL_ENTRY WHERE DOCUMENT_TYPE = 'RV' LIMIT 10;`: dates, signed amounts, names and due dates.
4. **Trial balance in seconds.** Run `SELECT * FROM RPT_TRIAL_BALANCE ORDER BY COMPANY_CODE, GL_ACCOUNT;`, then the check query: every company code nets to zero. Change `KEY_DATE` in `SAPFIN_PARAMS` and rerun to show period-end flexibility.
5. **Working capital.** Show `RPT_AR_AGEING` (slow payers in the over-90-day buckets) and `RPT_DSO_DPO_TREND`. "Your CFO's working-capital dashboard, live on SAP data, without a BW project."

## Client value
- Cuts the usual 8 to 12 weeks of SAP finance data modelling down to a few weeks: the mapping, canonical model and reports are a starting point that only needs client-specific fields added.
- `SAP_FIELD_MAPPING` gives auditors and data stewards field-level lineage from report to SAP field.
- Finance gets trial balance, ageing and DSO/DPO in Snowflake next to non-SAP data, ready for Cortex AI, semantic views and BI, without loading SAP BW.
