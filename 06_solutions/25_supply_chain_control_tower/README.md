# 25 · Supply Chain Control Tower

One governed view of supplier performance, inventory health, stockout risk and the customer and revenue impact of late purchase orders. It includes an exception queue and a Snowflake **ALERT** for critical stockouts.

## What it does
| Object | Purpose |
|---|---|
| `SCT.CONFIG` / `CONFIG_V` | Horizon, demand window, thresholds and OTIF target (`-- EDIT ME`). The as-of date is the latest inventory snapshot |
| `SCT.PO_RECEIPTS` | Received quantity per PO. **Synthetic in-full signal**: about 8% of receipts are short-shipped, because DEMO has no received-quantity column. Replace it with GRN data |
| `SCT.SUPPLIER_SCORECARD` | On-time %, in-full %, OTIF %, average delay, open late POs, spend and a computed 0–100 risk score and rating, compared with the master-data rating |
| `SCT.DEMAND_WEEKLY`, `SCT.DEMAND_FORECAST` | Weekly demand per plant-product from customer orders, and a trailing 8-week average forecast |
| `SCT.INVENTORY_POSITION` | Latest on-hand, reorder point, safety stock and **days of supply** |
| `SCT.STOCKOUT_RISK` | Projected on-hand at the horizon (on-hand + inbound POs due − forecast demand). Overdue POs are conservatively excluded. Also gives shortfall, **revenue at risk** and a risk level (CRITICAL, HIGH, MEDIUM, OK) |
| `SCT.LATE_PURCHASE_ORDERS`, `SCT.OPEN_CUSTOMER_ORDERS`, `SCT.LATE_PO_IMPACT` | Each late PO with the open customer orders, customers and revenue exposed at the same plant-product, plus a recommended action |
| `SCT.REVENUE_AT_RISK_BY_PLANT` | Plant roll-up |
| `SCT.REFRESH_EXCEPTIONS()` → `SCT.EXCEPTIONS` | Exception queue: stockout risk, late POs, supplier OTIF below target and excess stock. Owner and status set by planners are kept, and exceptions that clear are resolved automatically |
| `SCT.CRITICAL_STOCKOUT_ALERT` (ALERT) → `SCT.ALERT_LOG` | Runs daily. If any plant-product is CRITICAL, it refreshes the queue and logs the event. Optional email via `SYSTEM$SEND_EMAIL` |
| `streamlit_app.py` | Control-tower dashboard with plant, category, product and risk filters |

## Prerequisites
- `00_setup` has been run (`ACCEL_ADMIN`, `ACCEL_WH`, `DEMO.PURCHASE_ORDERS`, `INVENTORY_SNAPSHOTS`, `SUPPLIERS`, `PLANTS`, `ORDERS`, `ORDER_LINES`, `PRODUCTS`).
- File 03 needs `EXECUTE ALERT` for `ACCEL_ADMIN` (granted by `00_setup`).
- Email notification is optional. It needs a notification integration (see the comments in 03).

## Run order
1. `01_config_and_core_views.sql`
2. `02_impact_views.sql`
3. `03_exceptions_and_alert.sql`
4. Create a Streamlit app in `ACCEL_DB.SCT` on `ACCEL_WH` and paste `streamlit_app.py`.

## Assumptions (`-- EDIT ME`)
- **Open customer orders**: DEMO order statuses have no "Open" status, so orders with `STATUS = 'Shipped'` placed in the last `OPEN_ORDER_DAYS` count as open. Change this in `SCT.OPEN_CUSTOMER_ORDERS`.
- **Revenue at risk** is the shortfall quantity × the average net selling price over the demand window, or the list price if there are no sales. Amounts are in mixed order currencies as stored in DEMO. Add FX conversion for production use.
- **Forecast**: a trailing average is a deliberately simple baseline. Swap `SCT.DEMAND_FORECAST` for `SNOWFLAKE.ML.FORECAST` output with the same columns.
- All dates are relative to the latest snapshot, not today, so the demo works on static data.

## 5-step demo script
1. Open the dashboard. The KPI row shows critical SKUs, revenue at risk, late POs and weighted supplier OTIF.
2. Filter to one plant. Show the risk mix, then drill into a CRITICAL plant-product's inventory history against its reorder point and safety stock.
3. Open *Late POs and customer impact*. Each late PO is linked to the customer orders and revenue it puts at risk, with a recommended action (expedite, chase or monitor).
4. Show the supplier scorecard: OTIF against average delay, bubble size by spend, and the computed rating compared with the master-data rating. Point out the suppliers whose master rating is out of date.
5. Show the exception queue and `SCT.ALERT_LOG`. The ALERT runs daily inside Snowflake, so the team needs no extra scheduler or BI refresh.

## Client value claim
Planners stop reconciling spreadsheets and start working from a ranked exception queue. Typical outcomes are a 20–30% reduction in stockout-driven lost sales, 5–10 pts better supplier OTIF through fact-based reviews, and lower excess inventory. All of this runs on data already in Snowflake, with alerting and no additional tooling.
