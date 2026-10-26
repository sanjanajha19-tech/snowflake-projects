# 27 · GST Tax Data Hub (India ITC reconciliation)

Reconciles a purchase register (the books) against a GSTR-2B-style statement of supplier-filed invoices. It validates GSTINs with the published check-digit algorithm, matches invoices exactly and fuzzily, assigns a result category to every invoice, quantifies **Input Tax Credit (ITC) at risk** by supplier, and provides a Streamlit workbench for the tax team.

> **Disclaimer:** GST rates, the intra-state or inter-state logic, the ITC-at-risk rules and the tolerances in this asset are **illustrative**, for a demo on synthetic data. They are not tax advice. Rates are HSN/SAC-specific and change by notification, and ITC eligibility depends on Section 16 conditions, Rule 36(4) and current CBIC guidance. Confirm everything with your tax advisors before you rely on it.

## What it does
| Object | Purpose |
|---|---|
| `GST.RECON_CONFIG` | Absolute amount tolerance, probable-match % tolerance, date window, and edit-distance limits for invoice and GSTIN (`-- EDIT ME`) |
| `GST.GST_RATES`, `GST.STATE_CODES`, `GST.PLANT_GST_STATE` | Illustrative rate per product category, GST state codes, and each plant's registration state |
| `GST.GSTIN_CHECK_CHAR`, `GST.GSTIN_VALIDATION_ERROR` (Python UDFs), `GST.IS_VALID_GSTIN` (SQL) | Checks format (regex), state code (01–38, 97, 99) and check digit (base-36: weights alternate 1 and 2, each product adds quotient + remainder, check = (36 − sum mod 36) mod 36). Includes test cases |
| `GST.NORMALIZE_INVOICE_NO` (Python UDF) | `INV/2025/000123` = `inv-2025-123` = `INV2025123` |
| `GST.SUPPLIER_GST_MASTER` | Uses `DEMO.SUPPLIERS.GSTIN` where it is valid. Otherwise it synthesises a structurally valid GSTIN |
| `GST.PURCHASE_REGISTER` | One invoice per received PO from FY2025-26 onwards: taxable value, rate, and IGST or CGST+SGST |
| `GST.GSTR2B_INVOICES` | Supplier-filed invoices with injected mismatches: missing invoices, small and large value differences, GSTIN typos, date differences, invoice-number format changes and typos, and extra invoices not in the books. `DEMO_SCENARIO` records the injection |
| `GST.RUN_GST_RECONCILIATION()` → `GST.RECON_RESULTS` | Pass 1 matches exactly on GSTIN and normalised invoice number, then checks amounts against the tolerance. Pass 2 matches fuzzily: `EDITDISTANCE` on GSTIN and invoice number, plus amount % and date window, one-to-one. Pass 3 handles the leftovers |
| Categories | **Matched**, **Mismatch-amount**, **Probable match**, **Missing in 2B**, **Missing in books**, plus a date-mismatch flag and a recommended action |
| `GST.RECON_SUMMARY`, `GST.ITC_AT_RISK_BY_SUPPLIER`, `GST.RECON_ACCURACY_DEMO`, `GST.RECON_RUN_LOG` | Reporting and audit |
| `streamlit_app.py` | Workbench: KPIs, category mix, ITC at risk by period and by supplier, an exception work queue with CSV export, a GSTIN validator, and a re-run button |

## Demo data assumptions
- PO amounts in `DEMO.PURCHASE_ORDERS` are treated as INR, and every demo supplier (including the non-Indian ones) is treated as a domestic GST-registered supplier so the demo has enough volume. Real imports of goods are not in GSTR-2B as B2B invoices (they come through ICEGATE / IMPG).
- The GSTINs in `DEMO.SUPPLIERS` have a random check character, so most fail validation and are replaced by a synthesised valid GSTIN. `GSTIN_SOURCE` in `SUPPLIER_GST_MASTER` shows which ones.

## Prerequisites
`00_setup` has been run (`ACCEL_ADMIN`, `ACCEL_WH`, `DEMO.PURCHASE_ORDERS`, `SUPPLIERS`, `PRODUCTS`, `PLANTS`). The Python UDFs use only the Python standard library, so no Anaconda package terms need to be accepted.

## Run order
1. `01_config_and_udfs.sql`. Check that every test row shows **PASS**.
2. `02_synthetic_registers.sql`
3. `03_reconciliation.sql`
4. Create a Streamlit app in `ACCEL_DB.GST` on `ACCEL_WH` and paste `streamlit_app.py`.

To reconcile real data, load your purchase register and GSTR-2B JSON or Excel into tables with the same columns as `PURCHASE_REGISTER` and `GSTR2B_INVOICES`, then `CALL GST.RUN_GST_RECONCILIATION();`.

## ITC-at-risk logic (illustrative)
| Category | ITC at risk |
|---|---|
| Matched | 0 |
| Mismatch-amount | Books tax − 2B tax, when positive |
| Probable match | Books tax, until a reviewer confirms the match |
| Missing in 2B | Full ITC claimed in books |
| Missing in books | 0. The 2B tax is reported as *potentially unclaimed ITC* |

## 5-step demo script
1. Run the test block in `01`. The GSTIN check digit catches a one-character typo that a format regex alone would miss.
2. Show `GST.RECON_SUMMARY`. Thousands of invoices are categorised in seconds, and the ITC at risk is shown in rupees.
3. In the workbench, open *Probable match*. A typo'd invoice number and a GSTIN that fails its check digit are still paired, with an edit-distance explanation that a reviewer can confirm.
4. Open *Missing in 2B*, sorted by ITC at risk, and download the CSV as the supplier follow-up list. Show *ITC at risk by supplier* to identify non-compliant suppliers.
5. Show `GST.RECON_ACCURACY_DEMO`. Each injected scenario lands in the expected category, so the matcher can be tested. Change a tolerance in `RECON_CONFIG`, re-run, and compare.

## Client value claim
Monthly ITC reconciliation drops from days of spreadsheet matching to minutes. Rupees at risk become visible before GSTR-3B is filed, typically cutting reconciliation effort by 70–90% and recovering credit that would otherwise lapse. The full audit trail of match method, tolerance and recommended action stays in Snowflake.
