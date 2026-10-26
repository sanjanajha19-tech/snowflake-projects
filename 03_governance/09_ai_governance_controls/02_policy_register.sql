/* =============================================================================
   09 AI GOVERNANCE CONTROLS | 02_policy_register.sql
   - AI_POLICY_REGISTER : the organisation's AI policies (owner, status, review)
   - APPROVED_MODELS    : model catalogue = source of truth for model access (file 03)
                          and for the governed AI_COMPLETE wrapper (file 04)
   - AI_USE_CASES       : registered use cases + risk tier
   - PII_PATTERNS       : REGEXP patterns used to screen prompts and responses
   Run as: ACCEL_ADMIN. Rerunnable (MERGE).
============================================================================= */
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS AI_GOVERNANCE;
USE SCHEMA AI_GOVERNANCE;

-- ---------------------------------------------------------------------------
-- 1. Policy register
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS AI_POLICY_REGISTER (
  POLICY_ID      VARCHAR,
  POLICY_NAME    VARCHAR,
  RISK_THEME     VARCHAR,
  STATEMENT      VARCHAR,
  OWNER          VARCHAR,
  ENFORCEMENT    VARCHAR,     -- how Snowflake enforces / evidences it
  STATUS         VARCHAR,     -- DRAFT | ACTIVE | RETIRED
  LAST_REVIEWED  DATE,
  NEXT_REVIEW    DATE
);

MERGE INTO AI_POLICY_REGISTER t
USING (
  SELECT * FROM VALUES
  ('AIP-01', 'Approved models only', 'Model risk & access',
   'Only models on the approved list may be used, per role.', 'Chief Data Officer',
   'APPROVED_MODELS + model RBAC (SNOWFLAKE."CORTEX-MODEL-ROLE-*") + wrapper check', 'ACTIVE'),
  ('AIP-02', 'No personal data in prompts', 'Privacy & data protection',
   'Prompts must not contain personal identifiers (e-mail, phone, PAN, Aadhaar, card numbers) unless the use case is approved for it.', 'DPO',
   'GOVERNED_AI_COMPLETE REGEXP screening (BLOCK / REDACT) + masking policies on source columns', 'ACTIVE'),
  ('AIP-03', 'Every AI call is attributable', 'Accountability & audit',
   'Each AI request is logged with user, role, model, use case and outcome.', 'CISO',
   'AI_REQUEST_LOG + ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY', 'ACTIVE'),
  ('AIP-04', 'Registered use cases', 'Governance & transparency',
   'Production AI use cases are registered with an owner, risk tier and human-review requirement.', 'AI Governance Board',
   'AI_USE_CASES', 'ACTIVE'),
  ('AIP-05', 'Cost guardrails', 'Cost & sustainability',
   'AI spend is monitored per user and model; budgets alert at 80 %.', 'FinOps lead',
   'V_AI_USAGE_BY_USER_MODEL + Budgets (asset 08)', 'ACTIVE'),
  ('AIP-06', 'Human review for high-risk outputs', 'Accuracy & reliability',
   'Outputs used for decisions about people or money require human review before action.', 'Business owner',
   'Use-case flag REQUIRES_HUMAN_REVIEW + process', 'ACTIVE'),
  ('AIP-07', 'Prompt injection and unsafe content', 'Security & safety',
   'Untrusted text is never executed as instructions; guardrails are enabled for user-facing apps.', 'CISO',
   'Cortex Guard (model_parameters guardrails), least-privilege roles for agents/tools', 'DRAFT')
  AS s(POLICY_ID, POLICY_NAME, RISK_THEME, STATEMENT, OWNER, ENFORCEMENT, STATUS)
) s
ON t.POLICY_ID = s.POLICY_ID
WHEN MATCHED THEN UPDATE SET t.POLICY_NAME = s.POLICY_NAME, t.RISK_THEME = s.RISK_THEME, t.STATEMENT = s.STATEMENT,
  t.OWNER = s.OWNER, t.ENFORCEMENT = s.ENFORCEMENT, t.STATUS = s.STATUS
WHEN NOT MATCHED THEN INSERT (POLICY_ID, POLICY_NAME, RISK_THEME, STATEMENT, OWNER, ENFORCEMENT, STATUS, LAST_REVIEWED, NEXT_REVIEW)
  VALUES (s.POLICY_ID, s.POLICY_NAME, s.RISK_THEME, s.STATEMENT, s.OWNER, s.ENFORCEMENT, s.STATUS,
          CURRENT_DATE(), DATEADD('month', 6, CURRENT_DATE()));

-- ---------------------------------------------------------------------------
-- 2. Approved models (EDIT ME: model names as in SHOW MODELS IN SNOWFLAKE.MODELS, lowercase)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS APPROVED_MODELS (
  MODEL_NAME               VARCHAR,
  PROVIDER                 VARCHAR,
  APPROVED_FOR_ROLES       VARCHAR,   -- comma-separated account roles that get the model role (file 03)
  MAX_DATA_CLASSIFICATION  VARCHAR,   -- highest DATA_CLASSIFICATION allowed in prompts
  USE_CASES                VARCHAR,
  STATUS                   VARCHAR,   -- APPROVED | TRIAL | BLOCKED
  APPROVED_BY              VARCHAR,
  APPROVED_ON              DATE
);

MERGE INTO APPROVED_MODELS t
USING (
  SELECT * FROM VALUES
  ('llama3.1-70b',      'Meta',       'ACCEL_ANALYST,ACCEL_DEVELOPER,ACCEL_ADMIN', 'CONFIDENTIAL', 'Summaries, classification, extraction', 'APPROVED'),
  ('llama3.3-70b',      'Meta',       'ACCEL_ANALYST,ACCEL_DEVELOPER,ACCEL_ADMIN', 'CONFIDENTIAL', 'General assistant',                      'APPROVED'),
  ('mistral-large2',    'Mistral AI', 'ACCEL_ANALYST,ACCEL_DEVELOPER,ACCEL_ADMIN', 'CONFIDENTIAL', 'Code and SQL conversion',                'APPROVED'),
  ('claude-sonnet-4-5', 'Anthropic',  'ACCEL_DEVELOPER,ACCEL_ADMIN',               'INTERNAL',     'Complex reasoning, agents',              'APPROVED'),
  ('llama3.1-8b',       'Meta',       'ACCEL_DEVELOPER,ACCEL_ADMIN',               'INTERNAL',     'Low-cost bulk tasks (trial)',            'TRIAL')
  AS s(MODEL_NAME, PROVIDER, APPROVED_FOR_ROLES, MAX_DATA_CLASSIFICATION, USE_CASES, STATUS)
) s
ON t.MODEL_NAME = s.MODEL_NAME
WHEN MATCHED THEN UPDATE SET t.PROVIDER = s.PROVIDER, t.APPROVED_FOR_ROLES = s.APPROVED_FOR_ROLES,
  t.MAX_DATA_CLASSIFICATION = s.MAX_DATA_CLASSIFICATION, t.USE_CASES = s.USE_CASES, t.STATUS = s.STATUS
WHEN NOT MATCHED THEN INSERT (MODEL_NAME, PROVIDER, APPROVED_FOR_ROLES, MAX_DATA_CLASSIFICATION, USE_CASES, STATUS, APPROVED_BY, APPROVED_ON)
  VALUES (s.MODEL_NAME, s.PROVIDER, s.APPROVED_FOR_ROLES, s.MAX_DATA_CLASSIFICATION, s.USE_CASES, s.STATUS, CURRENT_USER(), CURRENT_DATE());

-- ---------------------------------------------------------------------------
-- 3. Use-case register
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS AI_USE_CASES (
  USE_CASE               VARCHAR,
  DESCRIPTION            VARCHAR,
  BUSINESS_OWNER         VARCHAR,
  RISK_TIER              VARCHAR,     -- LOW | MEDIUM | HIGH
  ALLOWED_PII_MODE       VARCHAR,     -- BLOCK | REDACT | ALLOW
  REQUIRES_HUMAN_REVIEW  BOOLEAN,
  STATUS                 VARCHAR
);

MERGE INTO AI_USE_CASES t
USING (
  SELECT * FROM VALUES
  ('GENERAL',            'Ad-hoc questions through the governed wrapper',      'AI Governance Board', 'LOW',    'BLOCK',  FALSE, 'ACTIVE'),
  ('TICKET_SUMMARY',     'Summarise support tickets for agents',               'Head of Customer Service', 'MEDIUM', 'REDACT', FALSE, 'ACTIVE'),
  ('INVOICE_EXTRACTION', 'Extract fields from supplier invoices',              'CFO office',          'MEDIUM', 'REDACT', TRUE,  'ACTIVE'),
  ('HR_ATTRITION_NOTES', 'Summarise exit interviews',                          'CHRO office',         'HIGH',   'BLOCK',  TRUE,  'DRAFT')
  AS s(USE_CASE, DESCRIPTION, BUSINESS_OWNER, RISK_TIER, ALLOWED_PII_MODE, REQUIRES_HUMAN_REVIEW, STATUS)
) s
ON t.USE_CASE = s.USE_CASE
WHEN MATCHED THEN UPDATE SET t.DESCRIPTION = s.DESCRIPTION, t.BUSINESS_OWNER = s.BUSINESS_OWNER, t.RISK_TIER = s.RISK_TIER,
  t.ALLOWED_PII_MODE = s.ALLOWED_PII_MODE, t.REQUIRES_HUMAN_REVIEW = s.REQUIRES_HUMAN_REVIEW, t.STATUS = s.STATUS
WHEN NOT MATCHED THEN INSERT VALUES (s.USE_CASE, s.DESCRIPTION, s.BUSINESS_OWNER, s.RISK_TIER, s.ALLOWED_PII_MODE,
  s.REQUIRES_HUMAN_REVIEW, s.STATUS);

-- ---------------------------------------------------------------------------
-- 4. PII patterns (POSIX ERE as used by Snowflake REGEXP functions)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE PII_PATTERNS (
  PATTERN_NAME VARCHAR,
  REGEX        VARCHAR,
  ACTIVE       BOOLEAN,
  NOTE         VARCHAR
);
INSERT INTO PII_PATTERNS VALUES
  ('EMAIL',       '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}',          TRUE, 'E-mail address'),
  ('PHONE',       '[+]?[0-9]{1,3}[ -]?[0-9]{2,5}[ -]?[0-9]{3,5}[ -]?[0-9]{3,5}', TRUE, 'International / Indian phone numbers'),
  ('PAN',         '[A-Z]{5}[0-9]{4}[A-Z]',                                    TRUE, 'Indian PAN'),
  ('AADHAAR',     '[2-9][0-9]{3}[ -]?[0-9]{4}[ -]?[0-9]{4}',                  TRUE, 'Indian Aadhaar number (12 digits)'),
  ('CARD_NUMBER', '[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{1,4}',        TRUE, 'Payment card number (13-16 digits)'),
  ('GSTIN',       '[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]',           TRUE, 'Indian GST identification number');

GRANT SELECT ON TABLE AI_POLICY_REGISTER TO ROLE ACCEL_ANALYST;
GRANT SELECT ON TABLE APPROVED_MODELS    TO ROLE ACCEL_ANALYST;
GRANT SELECT ON TABLE AI_USE_CASES       TO ROLE ACCEL_ANALYST;
GRANT SELECT ON TABLE PII_PATTERNS       TO ROLE ACCEL_ANALYST;

SELECT POLICY_ID, POLICY_NAME, RISK_THEME, OWNER, STATUS, NEXT_REVIEW FROM AI_POLICY_REGISTER ORDER BY POLICY_ID;
SELECT * FROM APPROVED_MODELS ORDER BY STATUS, MODEL_NAME;
