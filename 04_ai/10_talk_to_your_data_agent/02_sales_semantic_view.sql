/*=============================================================================
  ASSET 10 - Talk to your Data Agent
  File 02   : Semantic view SALES_SEMANTIC_VIEW (used by Cortex Analyst + Agent)
  Creates   : ACCEL_DB.SEMANTIC.SALES_SEMANTIC_VIEW
  Run as    : ACCEL_ADMIN
  Rerun     : safe (CREATE OR REPLACE ... COPY GRANTS)
  Requires  : 01_sales_model_views.sql
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SEMANTIC;
USE SCHEMA SEMANTIC;

CREATE OR REPLACE SEMANTIC VIEW SALES_SEMANTIC_VIEW
  TABLES (
    orders AS ACCEL_DB.SEMANTIC.SALES_ORDERS_V
      PRIMARY KEY (order_id)
      WITH SYNONYMS ('sales orders', 'transactions', 'bookings')
      COMMENT = 'One row per sales order with channel, status and order date',
    order_lines AS ACCEL_DB.SEMANTIC.SALES_ORDER_LINES_V
      PRIMARY KEY (order_id, line_no)
      WITH SYNONYMS ('order items', 'line items', 'sales lines')
      COMMENT = 'One row per order line with net revenue, cost of goods sold and units',
    customers AS ACCEL_DB.SEMANTIC.SALES_CUSTOMERS_V
      PRIMARY KEY (customer_id)
      WITH SYNONYMS ('clients', 'accounts', 'buyers')
      COMMENT = 'Customer master: segment, industry, region, country, city',
    products AS ACCEL_DB.SEMANTIC.SALES_PRODUCTS_V
      PRIMARY KEY (product_id)
      WITH SYNONYMS ('items', 'SKUs', 'catalog')
      COMMENT = 'Product master: category, sub-category, brand, cost and list price'
  )
  RELATIONSHIPS (
    order_lines_to_orders    AS order_lines (order_id)    REFERENCES orders,
    orders_to_customers      AS orders (customer_id)      REFERENCES customers,
    order_lines_to_products  AS order_lines (product_id)  REFERENCES products
  )
  FACTS (
    order_lines.line_revenue AS line_revenue
      WITH SYNONYMS = ('net sales amount', 'line sales')
      COMMENT = 'Net line amount after discount; zero for cancelled or returned orders',
    order_lines.line_cogs AS line_cogs
      WITH SYNONYMS = ('line cost', 'cost of goods sold')
      COMMENT = 'Quantity x product unit cost; zero for cancelled or returned orders',
    order_lines.line_gross_margin AS line_revenue - line_cogs
      COMMENT = 'Line revenue minus line COGS',
    order_lines.units_sold AS units_sold
      WITH SYNONYMS = ('quantity sold', 'volume')
      COMMENT = 'Units on the line; zero for cancelled or returned orders',
    order_lines.discount_amount AS discount_amount
      COMMENT = 'Gross discount given on the line',
    order_lines.unit_price AS unit_price
      COMMENT = 'Selling price per unit before discount',
    orders.order_total AS order_total
      COMMENT = 'Order header total as booked (all statuses)',
    orders.revenue_order_flag AS IFF(is_revenue_order, 1, 0)
      COMMENT = '1 when the order is Delivered or Shipped, else 0'
  )
  DIMENSIONS (
    orders.order_id AS order_id
      COMMENT = 'Unique order identifier',
    orders.order_date AS order_date
      WITH SYNONYMS = ('date', 'sale date', 'booking date')
      COMMENT = 'Date the order was placed',
    orders.order_year AS YEAR(order_date)
      WITH SYNONYMS = ('year', 'fiscal year')
      COMMENT = 'Calendar year of the order date',
    orders.order_quarter AS 'Q' || QUARTER(order_date)
      WITH SYNONYMS = ('quarter')
      COMMENT = 'Calendar quarter label Q1-Q4 of the order date',
    orders.order_year_quarter AS YEAR(order_date) || '-Q' || QUARTER(order_date)
      COMMENT = 'Year and quarter, for example 2026-Q2',
    orders.order_month AS DATE_TRUNC('MONTH', order_date)
      WITH SYNONYMS = ('month')
      COMMENT = 'First day of the order month',
    orders.channel AS channel
      WITH SYNONYMS = ('sales channel', 'route to market')
      COMMENT = 'Sales channel: Direct, Distributor, E-commerce, Retail',
    orders.order_status AS order_status
      WITH SYNONYMS = ('status')
      COMMENT = 'Order status: Delivered, Shipped, Cancelled, Returned',
    orders.currency AS currency
      COMMENT = 'Order currency code',
    customers.customer_name AS customer_name
      WITH SYNONYMS = ('client name', 'account name')
      COMMENT = 'Customer legal name',
    customers.segment AS segment
      WITH SYNONYMS = ('customer segment', 'tier')
      COMMENT = 'Customer segment: Enterprise, Mid-Market, SMB, Consumer',
    customers.industry AS industry
      WITH SYNONYMS = ('vertical', 'sector')
      COMMENT = 'Customer industry',
    customers.region AS region
      WITH SYNONYMS = ('sales region', 'territory', 'zone')
      COMMENT = 'Sales region: North, South, East, West, Central',
    customers.country AS country
      COMMENT = 'Customer country',
    customers.city AS city
      COMMENT = 'Customer city',
    products.product_name AS product_name
      WITH SYNONYMS = ('product', 'item name')
      COMMENT = 'Product name',
    products.sku AS sku
      COMMENT = 'Stock keeping unit code',
    products.category AS category
      WITH SYNONYMS = ('product category', 'product line')
      COMMENT = 'Product category',
    products.sub_category AS sub_category
      COMMENT = 'Product sub-category',
    products.brand AS brand
      COMMENT = 'Product brand'
  )
  METRICS (
    order_lines.revenue AS SUM(order_lines.line_revenue)
      WITH SYNONYMS = ('sales', 'net sales', 'turnover', 'top line')
      COMMENT = 'Net revenue after discounts, excluding cancelled and returned orders',
    order_lines.cogs AS SUM(order_lines.line_cogs)
      WITH SYNONYMS = ('cost of sales', 'cost of goods sold')
      COMMENT = 'Cost of goods sold for revenue lines',
    order_lines.gross_margin AS SUM(order_lines.line_gross_margin)
      WITH SYNONYMS = ('gross profit', 'GM')
      COMMENT = 'Revenue minus COGS',
    order_lines.gross_margin_pct AS
      SUM(order_lines.line_gross_margin) / NULLIF(SUM(order_lines.line_revenue), 0) * 100
      WITH SYNONYMS = ('margin %', 'margin percent', 'GM%')
      COMMENT = 'Gross margin as a percentage of revenue',
    order_lines.units AS SUM(order_lines.units_sold)
      WITH SYNONYMS = ('units sold', 'quantity', 'volume')
      COMMENT = 'Units sold, excluding cancelled and returned orders',
    order_lines.total_discount AS SUM(order_lines.discount_amount)
      COMMENT = 'Total discount given',
    orders.order_count AS COUNT(order_id)
      WITH SYNONYMS = ('number of orders', 'orders placed')
      COMMENT = 'Number of orders placed, all statuses',
    orders.revenue_order_count AS SUM(orders.revenue_order_flag)
      WITH SYNONYMS = ('fulfilled orders', 'billable orders')
      COMMENT = 'Number of Delivered or Shipped orders',
    orders.cancellation_rate_pct AS
      (1 - SUM(orders.revenue_order_flag) / NULLIF(COUNT(order_id), 0)) * 100
      COMMENT = 'Share of orders that were cancelled or returned, in percent',
    customers.customer_count AS COUNT(customer_id)
      WITH SYNONYMS = ('number of customers')
      COMMENT = 'Number of customers',
    average_order_value AS order_lines.revenue / NULLIF(orders.revenue_order_count, 0)
      WITH SYNONYMS = ('AOV', 'average basket', 'average ticket size')
      COMMENT = 'Revenue divided by Delivered or Shipped orders'
  )
  COMMENT = 'Sales model for Cortex Analyst: orders, order lines, customers, products (ACCEL asset 10)'
  AI_SQL_GENERATION 'Revenue always means the revenue metric (net of discounts, excluding cancelled and returned orders). When the user says last quarter or last month, compute it relative to the latest order_date in the data, not the current date. Round money to 2 decimals and percentages to 1 decimal. When explaining a change between periods, break it down by region, segment, channel and category.'
  AI_VERIFIED_QUERIES (
    orders_by_channel_2025 AS (
      QUESTION 'How many orders did we get per channel in 2025?'
      VERIFIED_AT 1790000000
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = accel_admin)'
      SQL 'SELECT o.channel, COUNT(o.order_id) AS order_count FROM orders AS o WHERE o.order_year = 2025 GROUP BY o.channel ORDER BY order_count DESC'
    ),
    overall_gross_margin AS (
      QUESTION 'What is our overall revenue, COGS and gross margin percentage?'
      VERIFIED_AT 1790000000
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = accel_admin)'
      SQL 'SELECT SUM(l.line_revenue) AS revenue, SUM(l.line_cogs) AS cogs, SUM(l.line_revenue - l.line_cogs) / NULLIF(SUM(l.line_revenue), 0) * 100 AS gross_margin_pct FROM order_lines AS l'
    )
  )
  COPY GRANTS;

-- Analysts / viewers can query it (SELECT on the semantic view is enough;
-- base-table SELECT is not needed to query a semantic view)
GRANT SELECT ON SEMANTIC VIEW ACCEL_DB.SEMANTIC.SALES_SEMANTIC_VIEW TO ROLE ACCEL_ANALYST;

------------------------------------------------------------------------------
-- Smoke tests (SQL query of a semantic view)
------------------------------------------------------------------------------
SHOW SEMANTIC VIEWS IN SCHEMA ACCEL_DB.SEMANTIC;
DESCRIBE SEMANTIC VIEW SALES_SEMANTIC_VIEW;

SELECT * FROM SEMANTIC_VIEW(
    SALES_SEMANTIC_VIEW
    DIMENSIONS customers.region, orders.order_year_quarter
    METRICS order_lines.revenue, order_lines.gross_margin_pct, average_order_value
    WHERE orders.order_year = 2026
  )
ORDER BY region, order_year_quarter;
