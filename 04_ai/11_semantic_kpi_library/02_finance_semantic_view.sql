/*=============================================================================
  ASSET 11 - Semantic KPI Library
  File 02   : FINANCE_SEMANTIC_VIEW (P&L KPIs from the general ledger)
  KPIs      : revenue, COGS, gross margin, gross margin %, opex, D&A,
              EBITDA proxy, EBITDA margin %  - by entity / month / cost center
  Run as    : ACCEL_ADMIN
  Rerun     : safe (CREATE OR REPLACE ... COPY GRANTS)
  Note      : Amounts are in each entity's ledger currency. Compare entities
              by %, or add FX conversion before consolidating.
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS KPI_LIBRARY;
USE SCHEMA KPI_LIBRARY;

CREATE OR REPLACE SEMANTIC VIEW FINANCE_SEMANTIC_VIEW
  TABLES (
    gl AS ACCEL_DB.KPI_LIBRARY.FIN_GL_PNL_V
      PRIMARY KEY (journal_id, line_no)
      WITH SYNONYMS ('general ledger', 'P&L', 'profit and loss', 'journal')
      COMMENT = 'P&L journal lines (Revenue, COGS, Opex) with sign-normalised amounts'
  )
  FACTS (
    gl.revenue_amt AS revenue_amt
      COMMENT = 'Revenue amount (credit converted to positive)',
    gl.cogs_amt AS cogs_amt
      COMMENT = 'Cost of goods sold amount',
    gl.opex_amt AS opex_amt
      COMMENT = 'Operating expense amount, including depreciation and amortisation',
    gl.da_amt AS da_amt
      COMMENT = 'Depreciation and amortisation amount (subset of opex)'
  )
  DIMENSIONS (
    gl.posting_date AS posting_date
      WITH SYNONYMS = ('date', 'accounting date')
      COMMENT = 'GL posting date',
    gl.fiscal_month AS fiscal_month
      WITH SYNONYMS = ('month', 'period')
      COMMENT = 'First day of the posting month',
    gl.fiscal_year AS YEAR(posting_date)
      WITH SYNONYMS = ('year', 'FY')
      COMMENT = 'Calendar year of posting (fiscal year = calendar year in demo)',
    gl.fiscal_quarter AS YEAR(posting_date) || '-Q' || QUARTER(posting_date)
      WITH SYNONYMS = ('quarter')
      COMMENT = 'Year and quarter, for example 2026-Q2',
    gl.entity AS entity
      WITH SYNONYMS = ('legal entity', 'company code', 'business unit')
      COMMENT = 'Legal entity: IN01 India, US01 USA, UK01 UK, DE01 Germany',
    gl.cost_center AS cost_center
      WITH SYNONYMS = ('department', 'CC')
      COMMENT = 'Cost center',
    gl.account_code AS account_code
      COMMENT = 'GL account code',
    gl.account_name AS account_name
      WITH SYNONYMS = ('GL account', 'account')
      COMMENT = 'GL account name',
    gl.account_type AS account_type
      COMMENT = 'Account type: Revenue, COGS or Opex',
    gl.source AS source
      WITH SYNONYMS = ('subledger', 'source system')
      COMMENT = 'Source sub-ledger: AP, AR, Manual, Payroll, FA',
    gl.currency AS currency
      COMMENT = 'Ledger currency of the entity'
  )
  METRICS (
    gl.revenue AS SUM(gl.revenue_amt)
      WITH SYNONYMS = ('sales', 'turnover', 'top line', 'income')
      COMMENT = 'Revenue = -SUM(amount) on Revenue accounts',
    gl.cogs AS SUM(gl.cogs_amt)
      WITH SYNONYMS = ('cost of sales', 'cost of goods sold')
      COMMENT = 'COGS = SUM(amount) on COGS accounts',
    gl.gross_margin AS SUM(gl.revenue_amt) - SUM(gl.cogs_amt)
      WITH SYNONYMS = ('gross profit', 'GM')
      COMMENT = 'Revenue minus COGS',
    gl.gross_margin_pct AS (SUM(gl.revenue_amt) - SUM(gl.cogs_amt)) / NULLIF(SUM(gl.revenue_amt), 0) * 100
      WITH SYNONYMS = ('GM%', 'gross margin percent')
      COMMENT = 'Gross margin as % of revenue',
    gl.opex AS SUM(gl.opex_amt)
      WITH SYNONYMS = ('operating expenses', 'SG&A', 'overheads')
      COMMENT = 'Operating expenses including D&A',
    gl.depreciation_amortisation AS SUM(gl.da_amt)
      WITH SYNONYMS = ('D&A', 'depreciation')
      COMMENT = 'Depreciation and amortisation',
    gl.ebitda_proxy AS SUM(gl.revenue_amt) - SUM(gl.cogs_amt) - (SUM(gl.opex_amt) - SUM(gl.da_amt))
      WITH SYNONYMS = ('EBITDA', 'operating profit before D&A')
      COMMENT = 'EBITDA proxy = revenue - COGS - (opex excluding D&A). Excludes interest and tax by construction (not in P&L accounts)',
    gl.ebitda_margin_pct AS (SUM(gl.revenue_amt) - SUM(gl.cogs_amt) - (SUM(gl.opex_amt) - SUM(gl.da_amt))) / NULLIF(SUM(gl.revenue_amt), 0) * 100
      WITH SYNONYMS = ('EBITDA margin')
      COMMENT = 'EBITDA proxy as % of revenue',
    gl.opex_ratio_pct AS SUM(gl.opex_amt) / NULLIF(SUM(gl.revenue_amt), 0) * 100
      WITH SYNONYMS = ('opex to revenue', 'cost ratio')
      COMMENT = 'Opex as % of revenue',
    gl.journal_line_count AS COUNT(journal_id)
      COMMENT = 'Number of P&L journal lines'
  )
  COMMENT = 'Finance KPI library: P&L from GL_JOURNAL by entity, month and cost center (ACCEL asset 11)'
  AI_SQL_GENERATION 'Amounts are in each entity ledger currency; when the user asks for a total across entities, show the result per entity unless they explicitly ask to add currencies together. Round money to 2 decimals and percentages to 1 decimal.'
  COPY GRANTS;

GRANT SELECT ON SEMANTIC VIEW ACCEL_DB.KPI_LIBRARY.FINANCE_SEMANTIC_VIEW TO ROLE ACCEL_ANALYST;

SELECT * FROM SEMANTIC_VIEW(
    FINANCE_SEMANTIC_VIEW
    DIMENSIONS gl.entity, gl.fiscal_year
    METRICS gl.revenue, gl.gross_margin_pct, gl.ebitda_proxy, gl.ebitda_margin_pct
  )
ORDER BY entity, fiscal_year;
