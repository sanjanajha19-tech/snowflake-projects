/*=============================================================================
  ASSET 11 - Semantic KPI Library
  File 03   : SUPPLY_CHAIN_SEMANTIC_VIEW
  KPIs      : OTIF %, late PO %, avg delivery delay, lead time, PO spend,
              days of supply, stock-out risk %, below-safety-stock %
  Run as    : ACCEL_ADMIN
  Rerun     : safe (CREATE OR REPLACE ... COPY GRANTS)
  Requires  : 01_kpi_base_views.sql
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS KPI_LIBRARY;
USE SCHEMA KPI_LIBRARY;

CREATE OR REPLACE SEMANTIC VIEW SUPPLY_CHAIN_SEMANTIC_VIEW
  TABLES (
    purchase_orders AS ACCEL_DB.KPI_LIBRARY.SC_PURCHASE_ORDERS_V
      PRIMARY KEY (po_id)
      WITH SYNONYMS ('POs', 'purchasing', 'procurement orders')
      COMMENT = 'Purchase orders with on-time, late and OTIF flags',
    inventory AS ACCEL_DB.KPI_LIBRARY.SC_INVENTORY_DOS
      PRIMARY KEY (snapshot_date, plant_id, product_id)
      WITH SYNONYMS ('stock', 'inventory snapshots', 'on hand')
      COMMENT = 'Weekly inventory snapshots with days of supply and stock-out risk',
    suppliers AS ACCEL_DB.DEMO.SUPPLIERS
      PRIMARY KEY (supplier_id)
      WITH SYNONYMS ('vendors')
      COMMENT = 'Supplier master',
    plants AS ACCEL_DB.DEMO.PLANTS
      PRIMARY KEY (plant_id)
      WITH SYNONYMS ('factories', 'sites', 'warehouses')
      COMMENT = 'Plants / sites',
    products AS ACCEL_DB.DEMO.PRODUCTS
      PRIMARY KEY (product_id)
      WITH SYNONYMS ('materials', 'items', 'SKUs')
      COMMENT = 'Product master'
  )
  RELATIONSHIPS (
    po_to_supplier      AS purchase_orders (supplier_id) REFERENCES suppliers,
    po_to_plant         AS purchase_orders (plant_id)    REFERENCES plants,
    po_to_product       AS purchase_orders (product_id)  REFERENCES products,
    inventory_to_plant  AS inventory (plant_id)          REFERENCES plants,
    inventory_to_product AS inventory (product_id)       REFERENCES products
  )
  FACTS (
    purchase_orders.po_value AS po_value
      COMMENT = 'PO quantity x unit cost',
    purchase_orders.po_quantity AS quantity
      COMMENT = 'Ordered quantity',
    purchase_orders.is_active_po AS is_active_po
      COMMENT = '1 when PO is not cancelled',
    purchase_orders.is_delivered AS is_delivered
      COMMENT = '1 when PO is received (not cancelled)',
    purchase_orders.is_otif AS is_otif
      COMMENT = '1 when received on or before promised date (in full assumed)',
    purchase_orders.is_late AS is_late
      COMMENT = '1 when received late, flagged Late, or open past promised date',
    purchase_orders.delivery_delay_days AS delivery_delay_days
      COMMENT = 'Received date minus promised date in days (negative = early)',
    purchase_orders.lead_time_days AS lead_time_days
      COMMENT = 'Received date minus PO date in days',
    inventory.on_hand_qty AS on_hand_qty
      COMMENT = 'Units on hand at snapshot',
    inventory.avg_daily_demand AS avg_daily_demand
      COMMENT = 'Trailing 91-day average daily units ordered from the plant',
    inventory.is_stockout_risk AS is_stockout_risk
      COMMENT = '1 when at/below safety stock or under 14 days of supply',
    inventory.is_below_safety_stock AS is_below_safety_stock
      COMMENT = '1 when on hand <= safety stock'
  )
  DIMENSIONS (
    purchase_orders.po_date AS po_date
      WITH SYNONYMS = ('order date', 'PO date')
      COMMENT = 'Date the PO was raised',
    purchase_orders.po_month AS po_month
      COMMENT = 'First day of the PO month',
    purchase_orders.po_year AS YEAR(po_date)
      COMMENT = 'Year of the PO date',
    purchase_orders.promised_date AS promised_date
      WITH SYNONYMS = ('due date', 'expected date')
      COMMENT = 'Supplier promised delivery date',
    purchase_orders.po_status AS po_status
      COMMENT = 'PO status: Open, Received, Late, Cancelled',
    inventory.snapshot_date AS snapshot_date
      WITH SYNONYMS = ('stock date', 'week')
      COMMENT = 'Weekly inventory snapshot date',
    inventory.is_latest_snapshot AS is_latest_snapshot
      WITH SYNONYMS = ('current', 'latest', 'today')
      COMMENT = 'TRUE for the most recent snapshot; use it for current stock questions',
    suppliers.supplier_name AS supplier_name
      WITH SYNONYMS = ('vendor', 'vendor name')
      COMMENT = 'Supplier name',
    suppliers.supplier_country AS country
      COMMENT = 'Supplier country',
    suppliers.supplier_category AS category
      COMMENT = 'Supplier category',
    suppliers.supplier_risk_rating AS risk_rating
      WITH SYNONYMS = ('vendor risk')
      COMMENT = 'Supplier risk rating: Low, Medium, High',
    plants.plant_name AS plant_name
      WITH SYNONYMS = ('site', 'factory')
      COMMENT = 'Plant name',
    plants.plant_city AS city
      COMMENT = 'Plant city',
    plants.plant_country AS country
      COMMENT = 'Plant country',
    products.product_name AS product_name
      COMMENT = 'Product name',
    products.product_category AS category
      WITH SYNONYMS = ('material group')
      COMMENT = 'Product category',
    products.sku AS sku
      COMMENT = 'SKU code'
  )
  METRICS (
    purchase_orders.po_count AS COUNT(po_id)
      WITH SYNONYMS = ('number of POs')
      COMMENT = 'Number of purchase orders, all statuses',
    purchase_orders.po_spend AS SUM(purchase_orders.po_value)
      WITH SYNONYMS = ('spend', 'purchase value')
      COMMENT = 'Total PO value, all statuses; filter po_status to exclude Cancelled',
    purchase_orders.otif_pct AS SUM(purchase_orders.is_otif) / NULLIF(SUM(purchase_orders.is_delivered), 0) * 100
      WITH SYNONYMS = ('OTIF', 'on time in full', 'on-time delivery %')
      COMMENT = 'Received POs delivered on/before promised date / received POs (in full assumed)',
    purchase_orders.late_po_pct AS SUM(purchase_orders.is_late) / NULLIF(SUM(purchase_orders.is_active_po), 0) * 100
      WITH SYNONYMS = ('late PO %', 'late deliveries %')
      COMMENT = 'Late POs / non-cancelled POs',
    purchase_orders.avg_delivery_delay_days AS AVG(purchase_orders.delivery_delay_days)
      COMMENT = 'Average days late (negative = early) for received POs',
    purchase_orders.avg_lead_time_days AS AVG(purchase_orders.lead_time_days)
      WITH SYNONYMS = ('lead time')
      COMMENT = 'Average PO-to-receipt days',
    inventory.total_on_hand AS SUM(inventory.on_hand_qty)
      WITH SYNONYMS = ('stock on hand', 'inventory units')
      COMMENT = 'Units on hand (filter to one snapshot date to avoid summing weeks)',
    inventory.days_of_supply AS SUM(inventory.on_hand_qty) / NULLIF(SUM(inventory.avg_daily_demand), 0)
      WITH SYNONYMS = ('DOS', 'days of cover', 'inventory cover')
      COMMENT = 'Units on hand / average daily demand (filter to one snapshot)',
    inventory.stockout_risk_pct AS AVG(inventory.is_stockout_risk) * 100
      WITH SYNONYMS = ('stock-out risk', 'OOS risk')
      COMMENT = 'Share of plant-product positions at stock-out risk',
    inventory.below_safety_stock_pct AS AVG(inventory.is_below_safety_stock) * 100
      COMMENT = 'Share of plant-product positions at or below safety stock'
  )
  COMMENT = 'Supply chain KPI library: OTIF, late POs, days of supply, stock-out risk (ACCEL asset 11)'
  AI_SQL_GENERATION 'For inventory questions without an explicit date, filter inventory.is_latest_snapshot = TRUE. Never sum on hand quantity across multiple snapshot dates. Percentages round to 1 decimal.'
  COPY GRANTS;

GRANT SELECT ON SEMANTIC VIEW ACCEL_DB.KPI_LIBRARY.SUPPLY_CHAIN_SEMANTIC_VIEW TO ROLE ACCEL_ANALYST;

SELECT * FROM SEMANTIC_VIEW(
    SUPPLY_CHAIN_SEMANTIC_VIEW
    DIMENSIONS suppliers.supplier_risk_rating
    METRICS purchase_orders.po_count, purchase_orders.otif_pct, purchase_orders.late_po_pct
  )
ORDER BY supplier_risk_rating;

SELECT * FROM SEMANTIC_VIEW(
    SUPPLY_CHAIN_SEMANTIC_VIEW
    DIMENSIONS plants.plant_name
    METRICS inventory.days_of_supply, inventory.stockout_risk_pct
    WHERE inventory.is_latest_snapshot = TRUE
  )
ORDER BY stockout_risk_pct DESC;
