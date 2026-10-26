/*=============================================================================
  ASSET 10 - Talk to your Data Agent
  File 04   : Cortex Agent SALES_INSIGHTS_AGENT
              Tools: Cortex Analyst (SALES_SEMANTIC_VIEW) + Cortex Search
              (SUPPORT_TICKET_SEARCH) so it can answer "what happened" from
              numbers and "why" from customer voice.
  Creates   : ACCEL_DB.SEMANTIC.SALES_INSIGHTS_AGENT
  Run as    : ACCEL_ADMIN
  Rerun     : safe (CREATE OR REPLACE ... COPY GRANTS)
  Requires  : 02_sales_semantic_view.sql, 03_ticket_search_service.sql
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS SEMANTIC;
USE SCHEMA SEMANTIC;

-- EDIT ME: models.orchestration below. 'auto' lets Snowflake pick the best
-- available model; or name one available in your region, e.g. claude-sonnet-4-5.
-- EDIT ME: warehouse under execution_environment.
CREATE OR REPLACE AGENT SALES_INSIGHTS_AGENT
  COPY GRANTS
  COMMENT = 'ACCEL asset 10: sales analytics + customer-voice agent'
  PROFILE = '{"display_name": "Sales Insights Agent", "color": "blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    budget:
      seconds: 60
      tokens: 16000

  instructions:
    response: "You are a sales analyst for the commercial leadership team. Be concise. Lead with the answer and the key number, then give 2-4 bullet points of drivers. Always state the time period used. Format money with thousands separators and 2 decimals, and percentages with 1 decimal. If you used support tickets, cite ticket IDs."
    orchestration: "Use SalesAnalyst for any question about revenue, margin, orders, units, average order value, customers, products, regions, channels or time trends. Use TicketSearch for questions about complaints, customer issues, quality problems, delivery problems or the reasons behind a change. For 'why' questions, first quantify the change with SalesAnalyst (break it down by region, segment, channel and category), then use TicketSearch to look for customer issues in the same region, product category and period, and combine both into one explanation. The data covers January 2024 to September 2026; interpret 'last quarter' relative to the latest data."
    sample_questions:
      - question: "Why did South region revenue drop in Q2 2026?"
      - question: "What were revenue, gross margin % and AOV by region in 2026?"
      - question: "Which product categories grew fastest year over year?"
      - question: "Show monthly revenue trend for the E-commerce channel"
      - question: "What are customers complaining about most for our top category?"

  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "SalesAnalyst"
        description: "Answers quantitative questions about sales: revenue, COGS, gross margin, margin %, order count, average order value, units, discounts and cancellation rate, by date, region, country, segment, industry, channel, product, category and brand. Data source: ACCEL_DB.SEMANTIC.SALES_SEMANTIC_VIEW."
    - tool_spec:
        type: "cortex_search"
        name: "TicketSearch"
        description: "Searches customer support tickets (subject and body) to find complaints, issues and qualitative reasons. Each result has ticket ID, priority, status, channel, product category and created date."

  tool_resources:
    SalesAnalyst:
      semantic_view: "ACCEL_DB.SEMANTIC.SALES_SEMANTIC_VIEW"
      execution_environment:
        type: "warehouse"
        warehouse: "ACCEL_WH"
    TicketSearch:
      search_service: "ACCEL_DB.KNOWLEDGE.SUPPORT_TICKET_SEARCH"
      max_results: "5"
      id_column: "TICKET_ID"
      title_column: "SUBJECT"
  $$;

-- Let analysts use the agent (they already have SELECT on the semantic view
-- and USAGE on the search service from files 02 and 03)
GRANT USAGE ON AGENT ACCEL_DB.SEMANTIC.SALES_INSIGHTS_AGENT TO ROLE ACCEL_ANALYST;

SHOW AGENTS IN SCHEMA ACCEL_DB.SEMANTIC;
DESCRIBE AGENT ACCEL_DB.SEMANTIC.SALES_INSIGHTS_AGENT;
