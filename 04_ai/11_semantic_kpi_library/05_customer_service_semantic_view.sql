/*=============================================================================
  ASSET 11 - Semantic KPI Library
  File 05   : CUSTOMER_SERVICE_SEMANTIC_VIEW
  KPIs      : ticket volume, open tickets, avg / median resolution hours,
              escalation rate %, SLA breach rate %
  Run as    : ACCEL_ADMIN
  Rerun     : safe (CREATE OR REPLACE ... COPY GRANTS)
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS KPI_LIBRARY;
USE SCHEMA KPI_LIBRARY;

CREATE OR REPLACE SEMANTIC VIEW CUSTOMER_SERVICE_SEMANTIC_VIEW
  TABLES (
    tickets AS ACCEL_DB.KPI_LIBRARY.CS_TICKETS_V
      PRIMARY KEY (ticket_id)
      WITH SYNONYMS ('cases', 'support tickets', 'complaints', 'incidents')
      COMMENT = 'Support tickets with resolution time, escalation and SLA flags',
    customers AS ACCEL_DB.DEMO.CUSTOMERS
      PRIMARY KEY (customer_id)
      WITH SYNONYMS ('clients', 'accounts')
      COMMENT = 'Customer master (only non-PII attributes are exposed)',
    products AS ACCEL_DB.DEMO.PRODUCTS
      PRIMARY KEY (product_id)
      COMMENT = 'Product master'
  )
  RELATIONSHIPS (
    tickets_to_customers AS tickets (customer_id) REFERENCES customers,
    tickets_to_products  AS tickets (product_id)  REFERENCES products
  )
  FACTS (
    tickets.resolution_hours AS resolution_hours
      COMMENT = 'Hours from creation to resolution (NULL if unresolved)',
    tickets.is_resolved AS is_resolved
      COMMENT = '1 when the ticket has a resolved timestamp',
    tickets.is_escalated AS is_escalated
      COMMENT = '1 when status is Escalated',
    tickets.is_open AS is_open
      COMMENT = '1 when status is Open',
    tickets.is_sla_breached AS is_sla_breached
      COMMENT = '1 when resolved after the priority SLA (Critical 8h, High 24h, Medium 72h, Low 120h)'
  )
  DIMENSIONS (
    tickets.created_date AS created_date
      WITH SYNONYMS = ('date', 'opened date')
      COMMENT = 'Date the ticket was created',
    tickets.created_month AS created_month
      WITH SYNONYMS = ('month')
      COMMENT = 'First day of the creation month',
    tickets.created_year AS YEAR(created_date)
      COMMENT = 'Year the ticket was created',
    tickets.ticket_channel AS ticket_channel
      WITH SYNONYMS = ('contact channel', 'channel')
      COMMENT = 'Email, Phone, Chat or Web',
    tickets.priority AS priority
      WITH SYNONYMS = ('severity')
      COMMENT = 'Low, Medium, High, Critical',
    tickets.ticket_status AS ticket_status
      WITH SYNONYMS = ('status')
      COMMENT = 'Open, Resolved, Escalated',
    customers.customer_segment AS segment
      COMMENT = 'Customer segment',
    customers.customer_region AS region
      WITH SYNONYMS = ('region')
      COMMENT = 'Customer sales region',
    customers.customer_country AS country
      COMMENT = 'Customer country',
    products.product_name AS product_name
      COMMENT = 'Product name',
    products.product_category AS category
      WITH SYNONYMS = ('product line')
      COMMENT = 'Product category'
  )
  METRICS (
    tickets.ticket_count AS COUNT(ticket_id)
      WITH SYNONYMS = ('ticket volume', 'number of tickets', 'contacts')
      COMMENT = 'Number of tickets created',
    tickets.open_tickets AS SUM(tickets.is_open)
      WITH SYNONYMS = ('backlog')
      COMMENT = 'Tickets currently open',
    tickets.avg_resolution_hours AS AVG(tickets.resolution_hours)
      WITH SYNONYMS = ('resolution time', 'MTTR', 'time to resolve')
      COMMENT = 'Average hours to resolve (resolved tickets only)',
    tickets.median_resolution_hours AS MEDIAN(tickets.resolution_hours)
      COMMENT = 'Median hours to resolve (resolved tickets only)',
    tickets.escalation_rate_pct AS SUM(tickets.is_escalated) / NULLIF(COUNT(ticket_id), 0) * 100
      WITH SYNONYMS = ('escalation rate', 'escalations %')
      COMMENT = 'Escalated tickets / all tickets x 100',
    tickets.sla_breach_rate_pct AS SUM(tickets.is_sla_breached) / NULLIF(SUM(tickets.is_resolved), 0) * 100
      WITH SYNONYMS = ('SLA breach', 'SLA miss rate')
      COMMENT = 'Resolved tickets that breached SLA / resolved tickets x 100'
  )
  COMMENT = 'Customer service KPI library: volume, resolution time, escalation, SLA (ACCEL asset 11)'
  COPY GRANTS;

GRANT SELECT ON SEMANTIC VIEW ACCEL_DB.KPI_LIBRARY.CUSTOMER_SERVICE_SEMANTIC_VIEW TO ROLE ACCEL_ANALYST;

SELECT * FROM SEMANTIC_VIEW(
    CUSTOMER_SERVICE_SEMANTIC_VIEW
    DIMENSIONS tickets.priority
    METRICS tickets.ticket_count, tickets.avg_resolution_hours, tickets.escalation_rate_pct, tickets.sla_breach_rate_pct
  )
ORDER BY ticket_count DESC;
