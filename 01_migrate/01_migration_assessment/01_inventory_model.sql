/*=============================================================================
  MIGRATION ASSESSMENT 01 - Source inventory model + scoring rules
  Creates: SRC_* inventory tables, rule tables (TYPE_RULES, SYNTAX_RULES,
           EFFORT_MODEL, COMPLEXITY_BANDS), CSV file format and internal stage.
  Run as : ACCEL_ADMIN. Rerun: safe (recreates empty inventory tables and rules).
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS MIGRATION_ASSESSMENT;
USE SCHEMA MIGRATION_ASSESSMENT;

------------------------------------------------------------------------------
-- 1. Inventory tables (column order = CSV column order in sample_data/)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE SRC_OBJECTS (
  OBJECT_ID        NUMBER,
  SOURCE_PLATFORM  VARCHAR,        -- Teradata | Oracle | SQL Server | ...
  DATABASE_NAME    VARCHAR,
  SCHEMA_NAME      VARCHAR,
  OBJECT_NAME      VARCHAR,
  FULL_NAME        VARCHAR,        -- DATABASE.SCHEMA.OBJECT (join key everywhere)
  OBJECT_TYPE      VARCHAR,        -- TABLE, VIEW, PROCEDURE, PACKAGE, FUNCTION, MACRO, BTEQ_SCRIPT, TRIGGER, SEQUENCE
  ROW_COUNT        NUMBER,
  SIZE_GB          NUMBER(12,2),
  LINES_OF_CODE    NUMBER,
  OWNER            VARCHAR,
  LAST_ALTERED     DATE,
  LAST_ACCESSED    DATE,
  BUSINESS_DOMAIN  VARCHAR
) COMMENT = 'Legacy object inventory';

CREATE OR REPLACE TABLE SRC_COLUMNS (
  FULL_NAME         VARCHAR,
  COLUMN_NAME       VARCHAR,
  ORDINAL_POSITION  NUMBER,
  DATA_TYPE         VARCHAR,       -- as reported by the source catalog, e.g. VARCHAR2(100), PERIOD(DATE)
  IS_NULLABLE       VARCHAR
) COMMENT = 'Legacy table columns';

CREATE OR REPLACE TABLE SRC_CODE (
  FULL_NAME  VARCHAR,
  CODE_TEXT  VARCHAR
) COMMENT = 'DDL / procedural code for views, procs, macros, scripts';

CREATE OR REPLACE TABLE SRC_DEPENDENCIES (
  OBJECT_FULL_NAME      VARCHAR,   -- this object ...
  DEPENDS_ON_FULL_NAME  VARCHAR    -- ... reads / calls this one
) COMMENT = 'Object lineage from the source catalog or parsed code';

CREATE OR REPLACE TABLE SRC_QUERY_LOG (
  LOG_MONTH        DATE,
  FULL_NAME        VARCHAR,
  USER_NAME        VARCHAR,
  STATEMENT_TYPE   VARCHAR,
  EXEC_COUNT       NUMBER,
  AVG_ELAPSED_SEC  NUMBER(12,1),
  TOTAL_CPU_SEC    NUMBER(14,1)
) COMMENT = 'Monthly usage summary from DBQL / AWR / ETL scheduler logs';

------------------------------------------------------------------------------
-- 2. Data type conversion rules (UPPER(DATA_TYPE) LIKE TYPE_PATTERN)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE TYPE_RULES (
  SOURCE_PLATFORM  VARCHAR,
  TYPE_PATTERN     VARCHAR,
  SNOWFLAKE_TYPE   VARCHAR,
  POINTS           NUMBER(5,2),
  NOTE             VARCHAR
);

INSERT INTO TYPE_RULES VALUES
  ('Teradata', 'BYTEINT%',                  'NUMBER(3,0)',                    1, 'No BYTEINT; confirm range checks'),
  ('Teradata', 'PERIOD(%',                  'Two columns *_BEGIN / *_END',    4, 'PERIOD type not supported; split column and rewrite BEGIN/END/CONTAINS logic'),
  ('Teradata', 'INTERVAL%',                 'NUMBER (seconds) or VARCHAR',    3, 'INTERVAL is not a column type in Snowflake'),
  ('Teradata', '%GRAPHIC%',                 'VARCHAR',                        2, 'GRAPHIC/VARGRAPHIC become UTF-8 VARCHAR; re-check lengths'),
  ('Teradata', '%CHARACTER SET UNICODE%',   'VARCHAR',                        0, 'All Snowflake strings are UTF-8'),
  ('Teradata', '%CASESPECIFIC%',            'VARCHAR (+ COLLATE if needed)',  2, 'Case-sensitivity defaults differ (Teradata NOT CASESPECIFIC vs Snowflake case-sensitive)'),
  ('Teradata', '%FORMAT %',                 'Same type; format in queries',   1, 'Column FORMAT phrase dropped; use TO_CHAR/TO_DATE'),
  ('Teradata', 'CLOB%',                     'VARCHAR',                        2, 'Check maximum lengths against VARCHAR limit'),
  ('Teradata', 'BLOB%',                     'BINARY or files in a stage',     3, 'Large binaries are better kept as staged files'),
  ('Teradata', 'JSON%',                     'VARIANT',                        1, 'Rewrite JSON extraction to : / GET_PATH / FLATTEN'),
  ('Teradata', 'XML%',                      'VARIANT (PARSE_XML)',            3, 'XML functions differ'),
  ('Teradata', 'ST_GEOMETRY%',              'GEOGRAPHY / GEOMETRY',           3, 'Spatial functions differ'),
  ('Teradata', 'TIMESTAMP%WITH TIME ZONE%', 'TIMESTAMP_TZ',                   1, 'Check session time zone handling'),
  ('Teradata', 'TIMESTAMP%',                'TIMESTAMP_NTZ',                  0, ''),
  ('Teradata', 'DECIMAL%',                  'NUMBER(p,s)',                    0, ''),
  ('Teradata', '%INT%',                     'NUMBER(38,0)',                   0, ''),
  ('Teradata', 'DATE%',                     'DATE',                           0, ''),
  ('Teradata', '%CHAR(%',                   'VARCHAR',                        0, 'CHAR padding semantics differ slightly'),
  ('Oracle',   'VARCHAR2%',                 'VARCHAR',                        0, ''),
  ('Oracle',   'NVARCHAR2%',                'VARCHAR',                        0, ''),
  ('Oracle',   'NUMBER',                    'NUMBER(38,10) or FLOAT',         2, 'Unconstrained NUMBER would become NUMBER(38,0) and lose decimals'),
  ('Oracle',   'NUMBER(%',                  'NUMBER(p,s)',                    0, ''),
  ('Oracle',   'DATE',                      'TIMESTAMP_NTZ',                  1, 'Oracle DATE holds a time part'),
  ('Oracle',   'LONG',                      'VARCHAR',                        3, 'Deprecated LONG; check length and access code'),
  ('Oracle',   'LONG RAW',                  'BINARY or files in a stage',     4, 'Deprecated LONG RAW'),
  ('Oracle',   'RAW%',                      'BINARY',                         1, ''),
  ('Oracle',   'CLOB',                      'VARCHAR',                        2, 'Check maximum lengths against VARCHAR limit'),
  ('Oracle',   'NCLOB',                     'VARCHAR',                        2, 'Check maximum lengths against VARCHAR limit'),
  ('Oracle',   'BLOB',                      'BINARY or files in a stage',     3, 'Large binaries are better kept as staged files'),
  ('Oracle',   'XMLTYPE',                   'VARIANT (PARSE_XML)',            3, 'XMLTYPE methods must be rewritten'),
  ('Oracle',   'SDO_GEOMETRY',              'GEOGRAPHY / GEOMETRY',           4, 'Oracle Spatial functions must be rewritten'),
  ('Oracle',   'ROWID',                     'Remove / surrogate key',         3, 'No ROWID in Snowflake'),
  ('Oracle',   'BFILE',                     'Stage + file URL',               4, 'External file pointers become staged files'),
  ('Oracle',   'TIMESTAMP%TIME ZONE%',      'TIMESTAMP_TZ / TIMESTAMP_LTZ',   1, ''),
  ('Oracle',   'INTERVAL%',                 'NUMBER or VARCHAR',              3, 'INTERVAL is not a column type in Snowflake'),
  ('Oracle',   '%CHAR(%',                   'VARCHAR',                        0, '');

------------------------------------------------------------------------------
-- 3. Proprietary syntax rules (REGEXP_COUNT on UPPER(CODE_TEXT), multiline)
--    Patterns use ($$ ... $$) so backslashes need no escaping.
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTAX_RULES (
  RULE_ID             VARCHAR,
  SOURCE_PLATFORM     VARCHAR,     -- Teradata | Oracle | ANY
  KEYWORD             VARCHAR,
  PATTERN             VARCHAR,
  POINTS              NUMBER(5,2),
  CATEGORY            VARCHAR,
  SNOWFLAKE_APPROACH  VARCHAR
);

INSERT INTO SYNTAX_RULES VALUES
  ('TD01','Teradata','SEL abbreviation',       $$(^|[^A-Z0-9_])SEL([^A-Z0-9_]|$)$$,                               1, 'Syntax',      'Replace SEL with SELECT'),
  ('TD02','Teradata','QUALIFY',                $$(^|[^A-Z0-9_])QUALIFY([^A-Z0-9_]|$)$$,                           1, 'Syntax',      'Supported natively; verify window semantics'),
  ('TD03','Teradata','VOLATILE TABLE',         $$VOLATILE(\s+MULTISET|\s+SET)?\s+TABLE$$,                         2, 'Temp objects','CREATE TEMPORARY TABLE'),
  ('TD04','Teradata','SET / MULTISET TABLE',   $$(^|[^A-Z0-9_])(SET|MULTISET)\s+TABLE$$,                          2, 'DDL',         'No SET-table duplicate rejection; dedupe on load (QUALIFY / DISTINCT)'),
  ('TD05','Teradata','PRIMARY INDEX',          $$PRIMARY\s+INDEX$$,                                               1, 'DDL',         'Remove; consider a clustering key only for very large tables'),
  ('TD06','Teradata','COLLECT STATISTICS',     $$COLLECT\s+STAT$$,                                                1, 'Maintenance', 'Remove; statistics are automatic'),
  ('TD07','Teradata','BTEQ commands',          $$^\s*\.(LOGON|LOGOFF|IMPORT|EXPORT|IF|GOTO|LABEL|QUIT|SET|RUN)$$, 3, 'Scripting',   'Rewrite as Snowflake Scripting procedure + task; exports via COPY INTO @stage'),
  ('TD08','Teradata','MACRO / EXEC',           $$(REPLACE|CREATE)\s+MACRO|(^|[^A-Z0-9_])EXEC\s$$,                 3, 'Procedural',  'Convert macro to stored procedure'),
  ('TD09','Teradata','MERGE',                  $$(^|[^A-Z0-9_])MERGE\s+INTO$$,                                    1, 'DML',         'Supported; check matching rules and error tables'),
  ('TD10','Teradata','PERIOD functions',       $$(^|[^A-Z0-9_])(BEGIN|END|P_INTERSECT|P_NORMALIZE|PERIOD)\s*\(|(^|[^A-Z0-9_])(CONTAINS|UNTIL_CHANGED)([^A-Z0-9_]|$)$$,
                                                                                                                  3, 'Temporal',    'Rewrite with explicit begin/end columns'),
  ('TD11','Teradata','HASHROW / HASHBUCKET',   $$HASH(ROW|BUCKET|AMP)\s*\($$,                                     3, 'Proprietary', 'Use HASH() or sequences; AMP distribution does not apply'),
  ('TD12','Teradata','FORMAT phrase',          $$\(\s*FORMAT\s+'$$,                                               2, 'Formatting',  'Use TO_CHAR / TO_DATE with a format'),
  ('TD13','Teradata','OREPLACE / OTRANSLATE / INDEX', $$(OREPLACE|OTRANSLATE)\s*\(|(^|[,(=]\s*)INDEX\s*\($$,       1, 'Functions',   'REPLACE / TRANSLATE / POSITION, or code-kit UDFs'),
  ('TD14','Teradata','ACTIVITY_COUNT / HANDLER', $$ACTIVITY_COUNT|(EXIT|CONTINUE)\s+HANDLER$$,                    3, 'Procedural',  'Use SQLROWCOUNT and EXCEPTION blocks'),
  ('TD15','Teradata','DBC dictionary / SYSEXECSQL', $$(^|[^A-Z0-9_])DBC\.$$,                                      3, 'Proprietary', 'Use EXECUTE IMMEDIATE / INFORMATION_SCHEMA'),
  ('TD16','Teradata','LOCKING modifier',       $$LOCKING\s+(ROW|TABLE)$$,                                         1, 'Syntax',      'Remove; not needed'),
  ('TD17','Teradata','DELETE ... ALL',         $$DELETE\s+FROM\s+[A-Z0-9_.]+\s+ALL$$,                             1, 'DML',         'Use TRUNCATE TABLE'),
  ('OR01','Oracle',  'CONNECT BY',             $$CONNECT\s+BY$$,                                                  3, 'Hierarchy',   'Supported for simple cases; recursive CTE recommended'),
  ('OR02','Oracle',  'NOCYCLE / ORDER SIBLINGS / CONNECT_BY_ISLEAF', $$NOCYCLE|ORDER\s+SIBLINGS|CONNECT_BY_ISLEAF$$, 3, 'Hierarchy', 'Rewrite as recursive CTE'),
  ('OR03','Oracle',  'ROWNUM',                 $$(^|[^A-Z0-9_])ROWNUM([^A-Z0-9_]|$)$$,                            2, 'Syntax',      'LIMIT / ROW_NUMBER()'),
  ('OR04','Oracle',  'ROWID',                  $$(^|[^A-Z0-9_])ROWID([^A-Z0-9_]|$)$$,                             3, 'Proprietary', 'Use a business or surrogate key'),
  ('OR05','Oracle',  '(+) outer join',         $$\(\+\)$$,                                                        2, 'Joins',       'Rewrite as ANSI LEFT/RIGHT JOIN'),
  ('OR06','Oracle',  'NVL2 / DECODE',          $$(NVL2|DECODE)\s*\($$,                                            0.5,'Functions',  'Supported natively; verify NULL handling'),
  ('OR07','Oracle',  'BULK COLLECT / FORALL',  $$BULK\s+COLLECT|(^|[^A-Z0-9_])FORALL([^A-Z0-9_]|$)$$,            4, 'Procedural',  'Replace array processing with set-based SQL'),
  ('OR08','Oracle',  'Cursor loops',           $$CURSOR\s+[A-Z0-9_]+\s+IS|FOR\s+[A-Z0-9_]+\s+IN\s+[A-Z0-9_]+\s+LOOP$$, 2, 'Procedural', 'Snowflake Scripting cursors, or set-based SQL'),
  ('OR09','Oracle',  'AUTONOMOUS_TRANSACTION', $$AUTONOMOUS_TRANSACTION$$,                                        5, 'Transactions','No autonomous transactions; redesign logging'),
  ('OR10','Oracle',  'DBMS_ / UTL_ packages',  $$(DBMS|UTL)_[A-Z_]+\.$$,                                          4, 'Packages',    'Replace with Snowflake features (stages, COPY INTO, logging, SYSTEM$ functions)'),
  ('OR11','Oracle',  'PACKAGE',                $$(CREATE|REPLACE)\s+(OR\s+REPLACE\s+)?PACKAGE$$,                  4, 'Procedural',  'Split into procedures / UDFs in one schema'),
  ('OR12','Oracle',  'TRIGGER',                $$(CREATE|REPLACE)\s+(OR\s+REPLACE\s+)?TRIGGER$$,                  6, 'Procedural',  'No triggers; streams + tasks or dynamic tables'),
  ('OR13','Oracle',  '%TYPE / %ROWTYPE',       $$%(ROW)?TYPE$$,                                                   2, 'Procedural',  'Declare explicit types'),
  ('OR14','Oracle',  'EXECUTE IMMEDIATE',      $$EXECUTE\s+IMMEDIATE$$,                                           1, 'Dynamic SQL', 'Supported in Snowflake Scripting; review DDL inside'),
  ('OR15','Oracle',  'Exception handling',     $$EXCEPTION\s+WHEN|RAISE_APPLICATION_ERROR$$,                      2, 'Procedural',  'EXCEPTION blocks and custom exceptions'),
  ('OR16','Oracle',  'SYSDATE / SYSTIMESTAMP', $$(^|[^A-Z0-9_])SYS(DATE|TIMESTAMP)([^A-Z0-9_]|$)$$,              1, 'Dates',       'CURRENT_DATE / CURRENT_TIMESTAMP; mind time zones'),
  ('OR17','Oracle',  'MERGE ... DELETE WHERE', $$DELETE\s+WHERE$$,                                                3, 'DML',         'Use WHEN MATCHED AND <cond> THEN DELETE'),
  ('OR18','Oracle',  'Sequence options',       $$CREATE\s+SEQUENCE$$,                                             1, 'DDL',         'Snowflake sequences have no CACHE/ORDER; gaps possible'),
  ('OR19','Oracle',  'MERGE',                  $$(^|[^A-Z0-9_])MERGE\s+INTO$$,                                    1, 'DML',         'Supported; check ON-clause and DELETE semantics'),
  ('OR20','Oracle',  'SYS_CONTEXT / :NEW / :OLD', $$SYS_CONTEXT|:(NEW|OLD)\.$$,                                   2, 'Procedural',  'Use CURRENT_USER(), streams METADATA$ columns'),
  ('OR21','Oracle',  'Partition DDL',          $$(TRUNCATE|DROP|EXCHANGE)\s+PARTITION$$,                          2, 'DDL',         'Micro-partitions are automatic; delete by predicate'),
  ('AN01','ANY',     'COMMIT / ROLLBACK',      $$(^|[^A-Z0-9_])(COMMIT|ROLLBACK)([^A-Z0-9_]|$)$$,                 1, 'Transactions','Review transaction scope in procedures'),
  ('AN02','ANY',     'OS file I/O',            $$FILE\s*=\s*/|FOPEN$$,                                            3, 'Integration', 'Unload with COPY INTO @stage; orchestrate outside or via tasks');

------------------------------------------------------------------------------
-- 4. Effort model (edit to your delivery benchmarks)
------------------------------------------------------------------------------
CREATE OR REPLACE TABLE EFFORT_MODEL (
  OBJECT_TYPE  VARCHAR,
  BASE_HOURS   NUMBER(6,1)     -- hours for a Low-complexity object incl. unit test
);
INSERT INTO EFFORT_MODEL VALUES
  ('TABLE', 2), ('VIEW', 3), ('SEQUENCE', 0.5), ('FUNCTION', 4), ('MACRO', 6),
  ('PROCEDURE', 10), ('PACKAGE', 16), ('BTEQ_SCRIPT', 8), ('TRIGGER', 12);

CREATE OR REPLACE TABLE COMPLEXITY_BANDS (
  BAND        VARCHAR,
  MIN_SCORE   NUMBER(6,2),     -- inclusive
  MAX_SCORE   NUMBER(6,2),     -- exclusive
  MULTIPLIER  NUMBER(4,2),
  SORT_ORDER  NUMBER
);
INSERT INTO COMPLEXITY_BANDS VALUES
  ('Low',        0,   4,    1.0, 1),
  ('Medium',     4,  10,    1.8, 2),
  ('High',      10,  20,    3.0, 3),
  ('Very High', 20, 9999,   5.0, 4);

------------------------------------------------------------------------------
-- 5. CSV loading objects (used by 03_load_from_csv.sql)
------------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT FF_INVENTORY_CSV
  TYPE = CSV
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  EMPTY_FIELD_AS_NULL = TRUE
  NULL_IF = ('')
  ENCODING = 'UTF8';

CREATE STAGE IF NOT EXISTS INVENTORY_STAGE
  FILE_FORMAT = (FORMAT_NAME = 'FF_INVENTORY_CSV')
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Upload src_*.csv inventory extracts here';

SHOW TABLES IN SCHEMA MIGRATION_ASSESSMENT;
