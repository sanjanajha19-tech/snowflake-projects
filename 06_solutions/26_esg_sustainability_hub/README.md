# 26 · ESG & Sustainability Hub

A governed GHG inventory and ESG data hub in Snowflake. It holds emission-factor reference tables, plant activity data, Scope 1, Scope 2 (location-based) and Scope 3 (categories 1 and 4) calculations, intensity metrics, a data-quality and evidence tracker, BRSR-style (India) and generic disclosure summaries, and a dashboard.

> **Important:** this asset **supports, but does not replace, assured sustainability reporting.** Every emission factor, calorific value and FX rate is an **illustrative placeholder** marked `-- EDIT ME` and `IS_PLACEHOLDER = TRUE`. Before you use any figure internally or externally, replace them with official sources: CEA CO2 Baseline Database for India's grid, DESNZ/DEFRA conversion factors, EPA eGRID, IPCC 2006, the GLEC Framework, an EEIO model for spend-based factors, and so on. The organisational boundary, the consolidation approach and the BRSR format are management decisions, and must be confirmed with your sustainability and assurance teams.

## What it does
| Object | Purpose |
|---|---|
| `ESG.EMISSION_FACTORS` | kgCO2e per unit for: grid electricity by country, diesel, natural gas, freight per tonne-km by mode, and spend-based purchased goods per INR (one row per supplier category, plus a default). Every row carries a source note and a placeholder flag |
| `ESG.ENERGY_CONVERSION`, `ESG.FX_TO_INR`, `ESG.SETTINGS` | GJ conversions, FX rates and the PO currency |
| `ESG.PLANT_PRODUCTION`, `ESG.ACTIVITY_DATA` | Synthetic monthly data per plant for 2024–2026: kWh, diesel litres, gas m³, tonne-km by mode, and spend by supplier category (from `DEMO.PURCHASE_ORDERS`). Months after the last DEMO order are marked `Projected` |
| `ESG.EMISSIONS_DETAIL` | One row per activity, with its matched factor (country-specific → generic → default), tCO2e, scope, GHG Protocol category, method and data quality. This is the audit trail |
| `SCOPE1_EMISSIONS`, `SCOPE2_LOCATION_BASED`, `SCOPE3_CAT1_PURCHASED_GOODS`, `SCOPE3_CAT4_UPSTREAM_TRANSPORT` | Calculation views |
| `EMISSIONS_MONTHLY`, `REVENUE_MONTHLY`, `INTENSITY_MONTHLY`, `INTENSITY_ANNUAL` | tCO2e per unit produced, and per INR crore of revenue (from DEMO orders) |
| `ESG.EVIDENCE_TRACKER`, `ESG.DATA_QUALITY_SUMMARY` | Evidence status per plant, month and activity. Completeness, estimated share, month-on-month outliers and evidence gaps |
| `ESG.BRSR_P6_SUMMARY` | BRSR Principle 6-style energy and GHG indicators by Indian FY (April–March), including intensity per rupee of turnover and per unit of output |
| `ESG.GHG_DISCLOSURE_SUMMARY` | Generic calendar-year inventory by scope and category, with a methodology note |
| `streamlit_app.py` | Dashboard: KPIs, trend by scope, plant and source breakdowns, intensity, BRSR tab, data quality and evidence, factor register |

## Prerequisites
`00_setup` has been run (`ACCEL_ADMIN`, `ACCEL_WH`, `DEMO.PLANTS`, `ORDERS`, `PURCHASE_ORDERS`, `SUPPLIERS`). The asset makes no AI calls and needs no special privileges.

## Run order
1. `01_reference_factors.sql`. **Replace the placeholder values.** After you enter real values, stop rerunning this file, or keep your values in a separate script, because rerunning it resets the tables to the placeholders.
2. `02_activity_data.sql`. In production, replace it with loads from utility bills, fuel cards, a TMS and the ERP.
3. `03_ghg_calculations.sql`
4. `04_data_quality_and_disclosures.sql`
5. Create a Streamlit app in `ACCEL_DB.ESG` on `ACCEL_WH` and paste `streamlit_app.py`.

## Scope and method notes
- Scope 1 covers stationary combustion only. Mobile combustion, process emissions and fugitive refrigerants are not modelled. Add rows to `ACTIVITY_DATA` and the factors table to extend it.
- Scope 2 is location-based. Market-based Scope 2 needs supplier-specific factors and REC or PPA data, and is not calculated.
- Scope 3 covers category 1 (spend-based) and category 4 (distance-based) only. The other categories are out of scope for this demo.
- Revenue intensity uses demo order revenue attributed to the producing plant, converted with the placeholder FX table.

## 5-step demo script
1. Show `ESG.EMISSION_FACTORS`. Every factor has a source note and a placeholder flag, and the dashboard warns while placeholders remain. Edit one grid factor to show that the inventory recalculates instantly.
2. Open the dashboard and walk through the scope KPIs, the monthly trend and the plant breakdown. Filter to one plant.
3. Show intensity (kgCO2e per unit and tCO2e per INR crore). It improves about 3% a year in the synthetic data, which shows how a decarbonisation narrative is evidenced.
4. Open *Data quality & evidence*. Completeness, estimated share and open evidence items per data owner tell the assurance provider exactly where the gaps are.
5. Open the *BRSR-style (P6)* tab. The FY figures, including per-rupee-of-turnover intensity, can be traced row by row to `EMISSIONS_DETAIL`.

## Client value claim
Moving from spreadsheets to a governed, traceable GHG ledger in Snowflake typically shortens the reporting cycle from weeks to days. Each disclosed number links to its activity data, factor and evidence, which lowers the cost of limited or reasonable assurance. Emissions data sits next to finance and operations data, so intensity metrics and abatement analysis need no extra pipelines. The figures must still be reviewed and assured. They are not a substitute for a regulated filing.
