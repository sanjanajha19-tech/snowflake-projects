/*=============================================================================
  ASSET 11 - Semantic KPI Library
  File 06   : KPI_CATALOG - documents every KPI: definition, formula, owner,
              grain, source semantic view + metric name
  Creates   : ACCEL_DB.KPI_LIBRARY.KPI_CATALOG, KPI_CATALOG_V
  Run as    : ACCEL_ADMIN
  Rerun     : safe (CREATE OR REPLACE TABLE + full reload)
  EDIT ME   : OWNER values - replace with the client's KPI owners
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS KPI_LIBRARY;
USE SCHEMA KPI_LIBRARY;

CREATE OR REPLACE TABLE KPI_CATALOG (
    KPI_ID          VARCHAR(20)   NOT NULL PRIMARY KEY,
    DOMAIN          VARCHAR(30)   NOT NULL,
    KPI_NAME        VARCHAR(100)  NOT NULL,
    DEFINITION      VARCHAR(1000) NOT NULL,
    FORMULA         VARCHAR(1000) NOT NULL,
    UNIT            VARCHAR(20),
    GOOD_DIRECTION  VARCHAR(10),          -- 'Up' or 'Down'
    GRAIN           VARCHAR(300),
    SEMANTIC_VIEW   VARCHAR(200),
    METRIC_NAME     VARCHAR(100),
    OWNER           VARCHAR(100),         -- EDIT ME
    CAVEATS         VARCHAR(1000),
    UPDATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Business glossary for the semantic KPI library (ACCEL asset 11)';

INSERT INTO KPI_CATALOG
  (KPI_ID, DOMAIN, KPI_NAME, DEFINITION, FORMULA, UNIT, GOOD_DIRECTION, GRAIN, SEMANTIC_VIEW, METRIC_NAME, OWNER, CAVEATS)
VALUES
  -- Finance
  ('FIN-001','Finance','Revenue','Income recognised on Revenue GL accounts','-SUM(AMOUNT) where ACCOUNT_TYPE = Revenue','Currency','Up','Journal line; slice by entity, month, cost center, account','ACCEL_DB.KPI_LIBRARY.FINANCE_SEMANTIC_VIEW','gl.revenue','CFO / Financial Controller','Ledger currency per entity; convert before consolidating'),
  ('FIN-002','Finance','COGS','Cost of goods sold posted to COGS accounts','SUM(AMOUNT) where ACCOUNT_TYPE = COGS','Currency','Down','Journal line; entity, month, cost center','ACCEL_DB.KPI_LIBRARY.FINANCE_SEMANTIC_VIEW','gl.cogs','Financial Controller',NULL),
  ('FIN-003','Finance','Gross margin','Revenue less cost of goods sold','Revenue - COGS','Currency','Up','Entity, month, cost center','ACCEL_DB.KPI_LIBRARY.FINANCE_SEMANTIC_VIEW','gl.gross_margin','CFO',NULL),
  ('FIN-004','Finance','Gross margin %','Gross margin as a share of revenue','(Revenue - COGS) / Revenue x 100','%','Up','Entity, month','ACCEL_DB.KPI_LIBRARY.FINANCE_SEMANTIC_VIEW','gl.gross_margin_pct','CFO','Not additive - recompute at each grain'),
  ('FIN-005','Finance','Operating expenses','All Opex GL postings including depreciation and amortisation','SUM(AMOUNT) where ACCOUNT_TYPE = Opex','Currency','Down','Entity, month, cost center','ACCEL_DB.KPI_LIBRARY.FINANCE_SEMANTIC_VIEW','gl.opex','FP&A Lead',NULL),
  ('FIN-006','Finance','EBITDA (proxy)','Operating profit before depreciation and amortisation','Revenue - COGS - (Opex - D&A)','Currency','Up','Entity, month','ACCEL_DB.KPI_LIBRARY.FINANCE_SEMANTIC_VIEW','gl.ebitda_proxy','CFO','Proxy: D&A identified by account name; interest/tax are not in P&L accounts of the demo'),
  ('FIN-007','Finance','EBITDA margin %','EBITDA proxy as a share of revenue','EBITDA proxy / Revenue x 100','%','Up','Entity, month','ACCEL_DB.KPI_LIBRARY.FINANCE_SEMANTIC_VIEW','gl.ebitda_margin_pct','CFO','Not additive'),
  ('FIN-008','Finance','Opex ratio %','Operating expenses relative to revenue','Opex / Revenue x 100','%','Down','Entity, month, cost center','ACCEL_DB.KPI_LIBRARY.FINANCE_SEMANTIC_VIEW','gl.opex_ratio_pct','FP&A Lead','Not additive'),
  -- Supply chain
  ('SC-001','Supply chain','OTIF %','Share of received purchase orders delivered on or before the promised date and in full','Received POs with RECEIVED_DATE <= PROMISED_DATE / received POs x 100','%','Up','Purchase order; supplier, plant, product, month','ACCEL_DB.KPI_LIBRARY.SUPPLY_CHAIN_SEMANTIC_VIEW','purchase_orders.otif_pct','Head of Procurement','In-full assumed: demo data has no received quantity'),
  ('SC-002','Supply chain','Late PO %','Share of non-cancelled POs that are late','POs (Late status OR received after promise OR open past promise) / non-cancelled POs x 100','%','Down','Purchase order; supplier, plant, month','ACCEL_DB.KPI_LIBRARY.SUPPLY_CHAIN_SEMANTIC_VIEW','purchase_orders.late_po_pct','Head of Procurement','Open-past-promise uses CURRENT_DATE'),
  ('SC-003','Supply chain','Average delivery delay (days)','Average days between promised and actual receipt','AVG(RECEIVED_DATE - PROMISED_DATE)','Days','Down','Purchase order; supplier','ACCEL_DB.KPI_LIBRARY.SUPPLY_CHAIN_SEMANTIC_VIEW','purchase_orders.avg_delivery_delay_days','Supplier Quality Manager','Negative = early'),
  ('SC-004','Supply chain','PO spend','Value of purchase orders raised','SUM(QUANTITY x UNIT_COST)','Currency','Down','Purchase order; supplier, category, month','ACCEL_DB.KPI_LIBRARY.SUPPLY_CHAIN_SEMANTIC_VIEW','purchase_orders.po_spend','Head of Procurement','Includes all statuses unless filtered'),
  ('SC-005','Supply chain','Days of supply','How many days current stock covers at recent demand','SUM(ON_HAND_QTY) / SUM(trailing 91-day avg daily demand)','Days','Balanced','Weekly snapshot x plant x product','ACCEL_DB.KPI_LIBRARY.SUPPLY_CHAIN_SEMANTIC_VIEW','inventory.days_of_supply','Supply Planning Lead','Filter to a single snapshot date'),
  ('SC-006','Supply chain','Stock-out risk %','Share of plant-product positions at or below safety stock or under 14 days of supply','AVG(IS_STOCKOUT_RISK) x 100','%','Down','Weekly snapshot x plant x product','ACCEL_DB.KPI_LIBRARY.SUPPLY_CHAIN_SEMANTIC_VIEW','inventory.stockout_risk_pct','Supply Planning Lead','14-day threshold is configurable in SC_INVENTORY_DOS'),
  -- HR
  ('HR-001','HR','Headcount','Number of active employees','COUNT(employees with STATUS = Active)','Count','Balanced','Employee; department, location, job title','ACCEL_DB.KPI_LIBRARY.HR_SEMANTIC_VIEW','employees.headcount','CHRO',NULL),
  ('HR-002','HR','Attrition rate %','Share of employees who have left','Exited employees / all employees on file x 100','%','Down','Employee; department, location, hire year','ACCEL_DB.KPI_LIBRARY.HR_SEMANTIC_VIEW','employees.attrition_rate_pct','CHRO','Cumulative: no exit date in demo. Standard = exits in period / average headcount'),
  ('HR-003','HR','Average tenure (years)','Average years of service of active employees','AVG(CURRENT_DATE - HIRE_DATE) / 365.25','Years','Up','Employee; department, location','ACCEL_DB.KPI_LIBRARY.HR_SEMANTIC_VIEW','employees.avg_tenure_years','HR Business Partner',NULL),
  ('HR-004','HR','Salary cost','Annualised salary cost of active employees','SUM(SALARY) where STATUS = Active','Currency','Down','Employee; department, location','ACCEL_DB.KPI_LIBRARY.HR_SEMANTIC_VIEW','employees.salary_cost','CHRO / CFO','Restrict to HR roles; mixed currencies by location'),
  -- Customer service
  ('CS-001','Customer service','Ticket volume','Number of support tickets created','COUNT(TICKET_ID)','Count','Down','Ticket; day/month, channel, priority, region, product','ACCEL_DB.KPI_LIBRARY.CUSTOMER_SERVICE_SEMANTIC_VIEW','tickets.ticket_count','Head of Customer Service',NULL),
  ('CS-002','Customer service','Average resolution time (hours)','Average hours from ticket creation to resolution','AVG(RESOLVED_AT - CREATED_AT) in hours, resolved tickets','Hours','Down','Ticket; channel, priority, product','ACCEL_DB.KPI_LIBRARY.CUSTOMER_SERVICE_SEMANTIC_VIEW','tickets.avg_resolution_hours','Head of Customer Service','Median also available (tickets.median_resolution_hours)'),
  ('CS-003','Customer service','Escalation rate %','Share of tickets escalated','Escalated tickets / all tickets x 100','%','Down','Ticket; channel, priority, product, region','ACCEL_DB.KPI_LIBRARY.CUSTOMER_SERVICE_SEMANTIC_VIEW','tickets.escalation_rate_pct','Head of Customer Service',NULL),
  ('CS-004','Customer service','SLA breach rate %','Share of resolved tickets resolved after their priority SLA','Resolved tickets over SLA / resolved tickets x 100','%','Down','Ticket; priority, channel','ACCEL_DB.KPI_LIBRARY.CUSTOMER_SERVICE_SEMANTIC_VIEW','tickets.sla_breach_rate_pct','Service Delivery Manager','SLA hours: Critical 8, High 24, Medium 72, Low 120');

CREATE OR REPLACE VIEW KPI_CATALOG_V
  COMMENT = 'KPI catalog for BI tools and data catalogs'
AS
SELECT DOMAIN, KPI_ID, KPI_NAME, DEFINITION, FORMULA, UNIT, GOOD_DIRECTION, GRAIN,
       SEMANTIC_VIEW, METRIC_NAME, OWNER, CAVEATS, UPDATED_AT
FROM KPI_CATALOG;

GRANT SELECT ON TABLE ACCEL_DB.KPI_LIBRARY.KPI_CATALOG  TO ROLE ACCEL_ANALYST;
GRANT SELECT ON VIEW  ACCEL_DB.KPI_LIBRARY.KPI_CATALOG_V TO ROLE ACCEL_VIEWER;

SELECT DOMAIN, COUNT(*) AS KPIS FROM KPI_CATALOG GROUP BY DOMAIN ORDER BY DOMAIN;
