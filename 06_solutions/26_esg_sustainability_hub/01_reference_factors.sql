/* =============================================================================
   Asset 26 - ESG & Sustainability Hub
   File  01_reference_factors.sql
   Purpose
     Reference data for GHG calculations.

     !!!  ALL FACTOR VALUES BELOW ARE ILLUSTRATIVE PLACEHOLDERS  !!!
     They are rough orders of magnitude so that the demo produces plausible
     numbers. They are NOT authoritative and must be replaced with values from
     the official source your reporting framework requires, for example:
       * Grid electricity: national authority factors (India: CEA CO2 Baseline
         Database; UK: DESNZ/DEFRA conversion factors; US: EPA eGRID; others:
         IEA or the national grid operator)
       * Fuels: IPCC 2006 Guidelines / DEFRA conversion factors / national inventory
       * Freight: DEFRA freighting-goods factors, GLEC Framework
       * Spend-based (Scope 3 cat. 1): an EEIO model (e.g. US EPA USEEIO, EXIOBASE)
         converted to INR and adjusted for inflation
     Record the source, version and year in SOURCE_REFERENCE when you replace a value
     and set IS_PLACEHOLDER = FALSE.

   Run as  ACCEL_ADMIN. Rerunnable (CREATE OR REPLACE resets the tables to the
     placeholders - after you have entered real values, comment out the
     CREATE OR REPLACE / INSERT statements or maintain them in a separate script).
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS ESG;
USE SCHEMA ESG;

-- -----------------------------------------------------------------------------
-- Emission factors (kg CO2e per activity unit)                           -- EDIT ME
-- COUNTRY = '*' means "applies to any country without a specific row".
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ESG.EMISSION_FACTORS (
    ACTIVITY_TYPE     VARCHAR,       -- ELECTRICITY / DIESEL / NATURAL_GAS / FREIGHT / PURCHASED_GOODS
    SUB_TYPE          VARCHAR,       -- GRID / STATIONARY / ROAD / RAIL / SEA / AIR / <supplier category> / DEFAULT
    COUNTRY           VARCHAR,
    UNIT              VARCHAR,       -- kWh / litre / m3 / tonne-km / INR
    KG_CO2E_PER_UNIT  NUMBER(18,8),
    SOURCE_REFERENCE  VARCHAR,
    IS_PLACEHOLDER    BOOLEAN,
    UPDATED_BY        VARCHAR,
    UPDATED_AT        TIMESTAMP_NTZ
);

INSERT INTO ESG.EMISSION_FACTORS
SELECT ACTIVITY_TYPE, SUB_TYPE, COUNTRY, UNIT, KG, 'PLACEHOLDER - replace with official value: ' || HINT,
       TRUE, CURRENT_USER(), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM VALUES
  -- Scope 2 - grid electricity, location-based                                       -- EDIT ME
  ('ELECTRICITY', 'GRID', 'India',     'kWh', 0.72,  'CEA CO2 Baseline Database (latest version)'),
  ('ELECTRICITY', 'GRID', 'USA',       'kWh', 0.38,  'EPA eGRID subregion factor'),
  ('ELECTRICITY', 'GRID', 'UK',        'kWh', 0.21,  'DESNZ/DEFRA GHG conversion factors'),
  ('ELECTRICITY', 'GRID', 'Germany',   'kWh', 0.38,  'UBA / IEA national factor'),
  ('ELECTRICITY', 'GRID', 'Japan',     'kWh', 0.46,  'Ministry of the Environment / utility factor'),
  ('ELECTRICITY', 'GRID', 'Singapore', 'kWh', 0.41,  'EMA Singapore grid emission factor'),
  ('ELECTRICITY', 'GRID', '*',         'kWh', 0.45,  'IEA country factor'),
  -- Scope 1 - fuels                                                                  -- EDIT ME
  ('DIESEL',      'STATIONARY', '*',   'litre', 2.68, 'IPCC 2006 / DEFRA diesel (100% mineral) factor'),
  ('NATURAL_GAS', 'STATIONARY', '*',   'm3',    2.02, 'IPCC 2006 / DEFRA natural gas factor'),
  -- Scope 3 category 4 - upstream transportation (distance-based)                   -- EDIT ME
  ('FREIGHT', 'ROAD', '*', 'tonne-km', 0.105,  'DEFRA HGV average laden / GLEC road factor'),
  ('FREIGHT', 'RAIL', '*', 'tonne-km', 0.028,  'DEFRA freight train / GLEC rail factor'),
  ('FREIGHT', 'SEA',  '*', 'tonne-km', 0.016,  'DEFRA container ship average / GLEC sea factor'),
  ('FREIGHT', 'AIR',  '*', 'tonne-km', 0.600,  'DEFRA air freight / GLEC air factor'),
  -- Scope 3 category 1 - purchased goods & services (spend-based, per INR)           -- EDIT ME
  ('PURCHASED_GOODS', 'DEFAULT', '*', 'INR', 0.0060, 'EEIO model (e.g. USEEIO/EXIOBASE) converted to INR')
  AS v(ACTIVITY_TYPE, SUB_TYPE, COUNTRY, UNIT, KG, HINT);

-- One spend-based placeholder per supplier category in DEMO.SUPPLIERS, so every
-- category is visible for editing. They start at the DEFAULT value.        -- EDIT ME
INSERT INTO ESG.EMISSION_FACTORS
SELECT DISTINCT 'PURCHASED_GOODS', s.CATEGORY, '*', 'INR', 0.0060,
       'PLACEHOLDER - replace with EEIO sector factor mapped to supplier category "' || s.CATEGORY || '"',
       TRUE, CURRENT_USER(), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM ACCEL_DB.DEMO.SUPPLIERS s
WHERE s.CATEGORY IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Energy conversion (GJ per activity unit) for energy disclosures         -- EDIT ME
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ESG.ENERGY_CONVERSION (
    ACTIVITY_TYPE    VARCHAR,
    UNIT             VARCHAR,
    GJ_PER_UNIT      NUMBER(18,8),
    SOURCE_REFERENCE VARCHAR,
    IS_PLACEHOLDER   BOOLEAN
);
INSERT INTO ESG.ENERGY_CONVERSION VALUES
  ('ELECTRICITY', 'kWh',   0.0036,  'Exact physical conversion (1 kWh = 3.6 MJ)', FALSE),
  ('DIESEL',      'litre', 0.0386,  'PLACEHOLDER - net calorific value from IPCC/national source', TRUE),   -- EDIT ME
  ('NATURAL_GAS', 'm3',    0.0378,  'PLACEHOLDER - calorific value from gas supplier invoices', TRUE);    -- EDIT ME

-- -----------------------------------------------------------------------------
-- FX to INR for revenue / spend intensity                                 -- EDIT ME
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ESG.FX_TO_INR (CURRENCY VARCHAR, INR_PER_UNIT NUMBER(12,4), NOTE VARCHAR);
INSERT INTO ESG.FX_TO_INR VALUES
  ('INR', 1,     'base'),
  ('USD', 83.0,  'PLACEHOLDER - use period-average rate'),
  ('GBP', 105.0, 'PLACEHOLDER - use period-average rate'),
  ('EUR', 90.0,  'PLACEHOLDER - use period-average rate'),
  ('JPY', 0.56,  'PLACEHOLDER - use period-average rate'),
  ('SGD', 62.0,  'PLACEHOLDER - use period-average rate');

-- Settings                                                                 -- EDIT ME
CREATE OR REPLACE TABLE ESG.SETTINGS (PARAM VARCHAR, VALUE VARCHAR, NOTE VARCHAR);
INSERT INTO ESG.SETTINGS VALUES
  ('PO_CURRENCY', 'USD', 'Currency of DEMO.PURCHASE_ORDERS.UNIT_COST (same USD price scale as DEMO orders); looked up in FX_TO_INR'),   -- EDIT ME
  ('REPORTING_ENTITY', 'Demo Manufacturing Ltd', 'Name printed on disclosure summaries');

SELECT ACTIVITY_TYPE, SUB_TYPE, COUNTRY, UNIT, KG_CO2E_PER_UNIT, IS_PLACEHOLDER, SOURCE_REFERENCE
FROM ESG.EMISSION_FACTORS ORDER BY 1, 2, 3;
