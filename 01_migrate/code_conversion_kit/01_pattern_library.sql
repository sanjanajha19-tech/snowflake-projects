/*=============================================================================
  CODE CONVERSION KIT 01 - SQL pattern library (legacy -> Snowflake)
  Creates: PATTERN_LIBRARY (Teradata, Oracle, SQL Server patterns with
           examples) and V_PATTERN_SEARCH. The AI converter (03) injects
           matching rows into its prompt as conversion hints.
  DETECT_REGEX is matched against UPPER(sql) (POSIX / Python compatible).
  Run as : ACCEL_ADMIN. Rerun: safe.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS CODE_CONVERSION;
USE SCHEMA CODE_CONVERSION;

CREATE OR REPLACE TABLE PATTERN_LIBRARY (
  PATTERN_ID            VARCHAR,
  SOURCE_DIALECT        VARCHAR,     -- Teradata | Oracle | SQL Server
  CATEGORY              VARCHAR,
  LEGACY_PATTERN        VARCHAR,
  SNOWFLAKE_EQUIVALENT  VARCHAR,
  LEGACY_EXAMPLE        VARCHAR,
  SNOWFLAKE_EXAMPLE     VARCHAR,
  NOTES                 VARCHAR,
  DETECT_REGEX          VARCHAR
);

-- Teradata ------------------------------------------------------------------
INSERT INTO PATTERN_LIBRARY VALUES
('TD-01','Teradata','Syntax','SEL / INS / DEL abbreviations','SELECT / INSERT / DELETE',
 $$SEL CUST_ID FROM CUSTOMER;$$,
 $$SELECT CUST_ID FROM CUSTOMER;$$,
 'Pure keyword replacement.', $$(^|[^A-Z0-9_])(SEL|INS|DEL)\s$$),
('TD-02','Teradata','Row limiting','TOP n [WITH TIES]','TOP n or LIMIT n; WITH TIES -> QUALIFY RANK()',
 $$SEL TOP 10 WITH TIES CUST_ID, REVENUE FROM SALES ORDER BY REVENUE DESC;$$,
 $$SELECT CUST_ID, REVENUE FROM SALES
QUALIFY RANK() OVER (ORDER BY REVENUE DESC) <= 10
ORDER BY REVENUE DESC;$$,
 'Snowflake supports TOP n and LIMIT n but not WITH TIES.', $$TOP\s+[0-9]+\s+WITH\s+TIES$$),
('TD-03','Teradata','Window filter','QUALIFY','QUALIFY (native)',
 $$SEL * FROM STG QUALIFY ROW_NUMBER() OVER (PARTITION BY ID ORDER BY TS DESC) = 1;$$,
 $$SELECT * FROM STG QUALIFY ROW_NUMBER() OVER (PARTITION BY ID ORDER BY TS DESC) = 1;$$,
 'Supported as-is. Teradata allows ordinal positions in some window clauses; Snowflake requires expressions.', $$QUALIFY$$),
('TD-04','Teradata','Temp tables','CREATE VOLATILE TABLE ... ON COMMIT PRESERVE ROWS','CREATE TEMPORARY TABLE ... AS SELECT',
 $$CREATE VOLATILE TABLE VT AS (SEL * FROM STG) WITH DATA PRIMARY INDEX (ID) ON COMMIT PRESERVE ROWS;$$,
 $$CREATE OR REPLACE TEMPORARY TABLE VT AS SELECT * FROM STG;$$,
 'Temporary tables live for the session. Drop WITH DATA, PRIMARY INDEX and ON COMMIT clauses.', $$VOLATILE$$),
('TD-05','Teradata','DDL','SET table (rejects duplicate rows)','Regular table + explicit de-duplication on load',
 $$CREATE SET TABLE CORE.CUST (ID INTEGER, NAME VARCHAR(100)) PRIMARY INDEX (ID);
INSERT INTO CORE.CUST SEL ID, NAME FROM STG.CUST;$$,
 $$CREATE OR REPLACE TABLE CORE.CUST (ID NUMBER, NAME VARCHAR(100));
INSERT INTO CORE.CUST SELECT DISTINCT ID, NAME FROM STG.CUST;$$,
 'Snowflake never rejects duplicate rows silently; make de-duplication explicit (DISTINCT, QUALIFY or MERGE).', $$(^|[^A-Z0-9_])SET\s+TABLE$$),
('TD-06','Teradata','DDL','MULTISET, PRIMARY INDEX, PARTITION BY RANGE_N, FALLBACK','Remove; optional CLUSTER BY for very large tables',
 $$CREATE MULTISET TABLE F, NO FALLBACK (D DATE, AMT DECIMAL(18,2)) PRIMARY INDEX (D) PARTITION BY RANGE_N(D BETWEEN DATE '2020-01-01' AND DATE '2030-12-31' EACH INTERVAL '1' MONTH);$$,
 $$CREATE OR REPLACE TABLE F (D DATE, AMT NUMBER(18,2)) CLUSTER BY (D);$$,
 'Micro-partitioning is automatic. Add CLUSTER BY only for multi-TB tables with selective filters.', $$MULTISET|PRIMARY\s+INDEX|RANGE_N|FALLBACK$$),
('TD-07','Teradata','Maintenance','COLLECT STATISTICS','Remove',
 $$COLLECT STATISTICS ON CORE.CUST COLUMN (ID);$$,
 $$-- removed: statistics are maintained automatically$$,
 'No equivalent needed.', $$COLLECT\s+STAT$$),
('TD-08','Teradata','Temporal','PERIOD(DATE) columns, BEGIN/END, CONTAINS','Two DATE columns and BETWEEN logic',
 $$SEL * FROM CUSTOMER_DIM WHERE VALID_PERIOD CONTAINS CURRENT_DATE;$$,
 $$SELECT * FROM CUSTOMER_DIM
WHERE CURRENT_DATE >= VALID_FROM AND CURRENT_DATE < VALID_TO;$$,
 'Split PERIOD into *_FROM / *_TO during data migration. PERIOD end is exclusive.', $$PERIOD\s*\(|CONTAINS|BEGIN\s*\(|END\s*\($$),
('TD-09','Teradata','Dates','CAST(x AS DATE FORMAT ''YYYYMMDD'')','TO_DATE(x, ''YYYYMMDD'')',
 $$SEL CAST(LOAD_DT_TXT AS DATE FORMAT 'YYYYMMDD') FROM STG;$$,
 $$SELECT TO_DATE(LOAD_DT_TXT, 'YYYYMMDD') FROM STG;$$,
 'Output formatting (FORMAT on a column) becomes TO_CHAR(col, fmt).', $$FORMAT\s+'$$),
('TD-10','Teradata','Dates','DATE literal / DATE - n / integer dates','CURRENT_DATE - n, DATEADD, kit UDFs TD_DATE_TO_INT / TD_INT_TO_DATE',
 $$SEL * FROM SALES WHERE SALES_DT = DATE - 1;$$,
 $$SELECT * FROM SALES WHERE SALES_DT = DATEADD(DAY, -1, CURRENT_DATE);$$,
 'Bare DATE means CURRENT_DATE in Teradata.', $$(^|[^A-Z0-9_'])DATE\s*[-+]\s*[0-9]$$),
('TD-11','Teradata','Scripting','BTEQ .EXPORT REPORT FILE','COPY INTO @stage, then GET or external stage',
 $$.EXPORT REPORT FILE = /data/out/sales.txt
SEL * FROM MART.SALES_DAILY_AGG;
.EXPORT RESET$$,
 $$COPY INTO @EXPORT_STAGE/sales/sales_
FROM (SELECT * FROM MART.SALES_DAILY_AGG)
FILE_FORMAT = (TYPE = CSV COMPRESSION = NONE) HEADER = TRUE OVERWRITE = TRUE;$$,
 'Download with GET (SnowSQL) or write to an external stage (S3/ADLS/GCS).', $$\.EXPORT$$),
('TD-12','Teradata','Scripting','BTEQ .IF ERRORCODE / .GOTO / .QUIT','Snowflake Scripting block with EXCEPTION',
 $$INSERT INTO T SEL * FROM S;
.IF ERRORCODE <> 0 THEN .GOTO ERR
.QUIT 0
.LABEL ERR
.QUIT 8$$,
 $$BEGIN
  INSERT INTO T SELECT * FROM S;
  RETURN 'OK';
EXCEPTION
  WHEN OTHER THEN
    RETURN 'FAILED: ' || SQLERRM;
END;$$,
 'Anonymous block (runs directly in Snowsight); wrap in a stored procedure plus TASK for scheduling.', $$\.IF\s+ERRORCODE|\.GOTO|\.QUIT$$),
('TD-13','Teradata','Procedural','MACRO + EXEC','Stored procedure + CALL',
 $$REPLACE MACRO M_LOAD (P_DATE DATE) AS (DELETE FROM AGG WHERE D = :P_DATE; INSERT INTO AGG SEL ...;);
EXEC M_LOAD(DATE '2026-01-01');$$,
 $$CREATE OR REPLACE PROCEDURE M_LOAD(P_DATE DATE) RETURNS VARCHAR LANGUAGE SQL AS
BEGIN
  DELETE FROM AGG WHERE D = :P_DATE;
  INSERT INTO AGG SELECT ...;
  RETURN 'done';
END;
CALL M_LOAD('2026-01-01');$$,
 'Inside Snowflake Scripting, prefix variables with : in SQL statements.', $$MACRO|(^|[^A-Z0-9_])EXEC\s$$),
('TD-14','Teradata','Functions','OREPLACE / OTRANSLATE / INDEX','REPLACE / TRANSLATE / POSITION (or kit UDFs)',
 $$SEL OREPLACE(NAME, 'LTD', 'LIMITED'), INDEX(NAME, 'CO') FROM C;$$,
 $$SELECT REPLACE(NAME, 'LTD', 'LIMITED'), POSITION('CO', NAME) FROM C;$$,
 'POSITION argument order is (search, string).', $$OREPLACE|OTRANSLATE|(^|[,(=]\s*)INDEX\s*\($$),
('TD-15','Teradata','Functions','ZEROIFNULL / NULLIFZERO','Native ZEROIFNULL / NULLIFZERO',
 $$SEL ZEROIFNULL(AMT) FROM T;$$,
 $$SELECT ZEROIFNULL(AMT) FROM T;$$,
 'Supported as-is.', $$ZEROIFNULL|NULLIFZERO$$),
('TD-16','Teradata','Proprietary','HASHROW / HASHBUCKET / HASHAMP','HASH() or a SEQUENCE for surrogate keys',
 $$SEL HASHBUCKET(HASHROW(CUST_ID)) AS CUSTOMER_KEY FROM STG;$$,
 $$SELECT HASH(CUST_ID) AS CUSTOMER_KEY FROM STG;$$,
 'HASH() returns a signed 64-bit value; use a sequence if keys must be small positive integers.', $$HASH(ROW|BUCKET|AMP)$$),
('TD-17','Teradata','DML','UPDATE target FROM source SET ...','UPDATE target SET ... FROM source WHERE ...',
 $$UPDATE T FROM STG S SET AMT = S.AMT WHERE T.ID = S.ID;$$,
 $$UPDATE T SET AMT = S.AMT FROM STG S WHERE T.ID = S.ID;$$,
 'FROM clause moves after SET.', $$UPDATE\s+[A-Z0-9_.]+(\s+[A-Z0-9_]+)?\s+FROM$$),
('TD-18','Teradata','DML','MERGE (primary-index matching, error tables)','MERGE INTO (native)',
 $$MERGE INTO F USING S ON F.ID = S.ID WHEN MATCHED THEN UPDATE SET AMT = S.AMT WHEN NOT MATCHED THEN INSERT VALUES (S.ID, S.AMT) LOGGING ERRORS;$$,
 $$MERGE INTO F USING S ON F.ID = S.ID
WHEN MATCHED THEN UPDATE SET AMT = S.AMT
WHEN NOT MATCHED THEN INSERT (ID, AMT) VALUES (S.ID, S.AMT);$$,
 'Remove LOGGING ERRORS. Duplicate source keys make Snowflake MERGE fail (ERROR_ON_NONDETERMINISTIC_MERGE); de-duplicate the source first.', $$MERGE\s+INTO$$),
('TD-19','Teradata','DML','DELETE FROM t ALL','TRUNCATE TABLE t',
 $$DELETE FROM MART.CUSTOMER_360 ALL;$$,
 $$TRUNCATE TABLE MART.CUSTOMER_360;$$,
 'TRUNCATE also resets load metadata used by COPY.', $$DELETE\s+FROM\s+[A-Z0-9_.]+\s+ALL$$),
('TD-20','Teradata','DDL','GENERATED ALWAYS AS IDENTITY','IDENTITY / AUTOINCREMENT column or SEQUENCE',
 $$CREATE TABLE D (ID INTEGER GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1), NAME VARCHAR(50));$$,
 $$CREATE OR REPLACE TABLE D (ID NUMBER IDENTITY(1,1) ORDER, NAME VARCHAR(50));$$,
 'Values can have gaps. Use ORDER if consumers rely on increasing values.', $$GENERATED\s+(ALWAYS|BY\s+DEFAULT)\s+AS\s+IDENTITY$$),
('TD-21','Teradata','Session','LOCKING ROW FOR ACCESS','Remove',
 $$LOCKING ROW FOR ACCESS SEL * FROM F;$$,
 $$SELECT * FROM F;$$,
 'Readers never block writers in Snowflake.', $$LOCKING\s+(ROW|TABLE)$$);

-- Oracle --------------------------------------------------------------------
INSERT INTO PATTERN_LIBRARY VALUES
('OR-01','Oracle','Row limiting','ROWNUM','LIMIT / QUALIFY ROW_NUMBER()',
 $$SELECT * FROM (SELECT * FROM INV ORDER BY AMT DESC) WHERE ROWNUM <= 10;$$,
 $$SELECT * FROM INV ORDER BY AMT DESC LIMIT 10;$$,
 'For per-group limits use QUALIFY ROW_NUMBER() OVER (PARTITION BY ...) <= n.', $$ROWNUM$$),
('OR-02','Oracle','Functions','NVL2(expr, not_null_val, null_val)','NVL2 (native)',
 $$SELECT NVL2(TAX_ID, 'Y', 'N') FROM SUPPLIERS;$$,
 $$SELECT NVL2(TAX_ID, 'Y', 'N') FROM SUPPLIERS;$$,
 'Supported as-is. Note: Oracle treats empty string as NULL; Snowflake does not.', $$NVL2\s*\($$),
('OR-03','Oracle','Functions','DECODE(expr, s1, r1, ..., default)','DECODE (native) or CASE',
 $$SELECT DECODE(STATUS, 'O', 'Open', 'C', 'Closed', 'Other') FROM GL_PERIODS;$$,
 $$SELECT DECODE(STATUS, 'O', 'Open', 'C', 'Closed', 'Other') FROM GL_PERIODS;$$,
 'Supported, including NULL = NULL matching. CASE is clearer for complex logic.', $$DECODE\s*\($$),
('OR-04','Oracle','Hierarchy','CONNECT BY PRIOR ... START WITH','Recursive CTE (CONNECT BY also supported for simple cases)',
 $$SELECT ACCOUNT_ID, PARENT_ID, LEVEL
FROM GL_ACCOUNTS
START WITH PARENT_ID IS NULL
CONNECT BY PRIOR ACCOUNT_ID = PARENT_ID;$$,
 $$WITH RECURSIVE tree (ACCOUNT_ID, PARENT_ID, LVL, PATH) AS (
  SELECT ACCOUNT_ID, PARENT_ID, 1, '/' || ACCOUNT_ID::VARCHAR
  FROM GL_ACCOUNTS WHERE PARENT_ID IS NULL
  UNION ALL
  SELECT a.ACCOUNT_ID, a.PARENT_ID, t.LVL + 1, t.PATH || '/' || a.ACCOUNT_ID::VARCHAR
  FROM GL_ACCOUNTS a JOIN tree t ON a.PARENT_ID = t.ACCOUNT_ID
)
SELECT * FROM tree;$$,
 'NOCYCLE, ORDER SIBLINGS BY and CONNECT_BY_ISLEAF need the recursive CTE form; build PATH for SYS_CONNECT_BY_PATH.', $$CONNECT\s+BY$$),
('OR-05','Oracle','Joins','(+) outer join','ANSI LEFT / RIGHT JOIN',
 $$SELECT * FROM A, B WHERE A.ID = B.ID (+);$$,
 $$SELECT * FROM A LEFT JOIN B ON A.ID = B.ID;$$,
 'Move all (+) predicates of the same table into the ON clause.', $$\(\+\)$$),
('OR-06','Oracle','Dates','SYSDATE / SYSTIMESTAMP','CURRENT_TIMESTAMP() / CURRENT_DATE',
 $$SELECT TRUNC(SYSDATE) - 1 FROM DUAL;$$,
 $$SELECT DATEADD(DAY, -1, CURRENT_DATE);$$,
 'Snowflake SYSDATE() returns UTC and needs parentheses; CURRENT_TIMESTAMP uses the session time zone.', $$SYSDATE|SYSTIMESTAMP$$),
('OR-07','Oracle','Data types','DATE with time part','TIMESTAMP_NTZ (or DATE if time is always midnight)',
 $$CREATE TABLE T (CREATED DATE);$$,
 $$CREATE OR REPLACE TABLE T (CREATED TIMESTAMP_NTZ);$$,
 'TRUNC(date) becomes DATE_TRUNC(''DAY'', ts) or ts::DATE.', $$(^|[^A-Z0-9_])DATE([^A-Z0-9_(']|$)$$),
('OR-08','Oracle','DML','MERGE ... UPDATE ... DELETE WHERE','Separate WHEN MATCHED AND ... THEN DELETE clause',
 $$MERGE INTO T USING S ON (T.ID = S.ID)
WHEN MATCHED THEN UPDATE SET T.AMT = S.AMT DELETE WHERE S.AMT = 0
WHEN NOT MATCHED THEN INSERT (ID, AMT) VALUES (S.ID, S.AMT);$$,
 $$MERGE INTO T USING S ON T.ID = S.ID
WHEN MATCHED AND S.AMT = 0 THEN DELETE
WHEN MATCHED THEN UPDATE SET T.AMT = S.AMT
WHEN NOT MATCHED THEN INSERT (ID, AMT) VALUES (S.ID, S.AMT);$$,
 'Oracle evaluates DELETE WHERE after the update; check edge cases.', $$DELETE\s+WHERE$$),
('OR-09','Oracle','Sequences','seq.NEXTVAL / seq.CURRVAL','seq.NEXTVAL; no CURRVAL',
 $$INSERT INTO T (ID) VALUES (SEQ_T.NEXTVAL); SELECT SEQ_T.CURRVAL FROM DUAL;$$,
 $$INSERT INTO T (ID) SELECT SEQ_T.NEXTVAL;$$,
 'Snowflake has no CURRVAL; capture the value in a variable or use an IDENTITY column.', $$CURRVAL|NEXTVAL$$),
('OR-10','Oracle','Temp tables','GLOBAL TEMPORARY TABLE','CREATE TEMPORARY TABLE (session) or TRANSIENT TABLE',
 $$CREATE GLOBAL TEMPORARY TABLE GTT_X (ID NUMBER) ON COMMIT PRESERVE ROWS;$$,
 $$CREATE OR REPLACE TEMPORARY TABLE GTT_X (ID NUMBER);$$,
 'Snowflake temporary table definitions are session-scoped; create them inside the procedure.', $$GLOBAL\s+TEMPORARY$$),
('OR-11','Oracle','Procedural','Cursor FOR loop','Snowflake Scripting FOR ... IN cursor DO (or set-based SQL)',
 $$FOR r IN (SELECT ID FROM T) LOOP
  UPDATE X SET FLAG = 1 WHERE ID = r.ID;
END LOOP;$$,
 $$UPDATE X SET FLAG = 1 WHERE ID IN (SELECT ID FROM T);$$,
 'Row-by-row loops are slow everywhere; rewrite set-based first.', $$FOR\s+[A-Z0-9_]+\s+IN\s*\($$),
('OR-12','Oracle','Procedural','BULK COLLECT / FORALL','INSERT ... SELECT',
 $$SELECT * BULK COLLECT INTO v FROM T; FORALL i IN 1..v.COUNT INSERT INTO H VALUES v(i);$$,
 $$INSERT INTO H SELECT * FROM T;$$,
 'Array processing has no equivalent and is not needed.', $$BULK\s+COLLECT|FORALL$$),
('OR-13','Oracle','Procedural','Triggers','Stream + task (or dynamic table)',
 $$CREATE TRIGGER TRG AFTER UPDATE ON EMP FOR EACH ROW BEGIN INSERT INTO EMP_AUD VALUES (:OLD.ID, SYSDATE); END;$$,
 $$CREATE OR REPLACE STREAM EMP_STRM ON TABLE EMP;
CREATE OR REPLACE TASK EMP_AUDIT_TASK WAREHOUSE = ACCEL_WH SCHEDULE = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('EMP_STRM')
AS INSERT INTO EMP_AUD SELECT ID, CURRENT_TIMESTAMP() FROM EMP_STRM WHERE METADATA$ACTION = 'DELETE' AND METADATA$ISUPDATE;$$,
 'Audit is near-real-time (task schedule), not synchronous.', $$TRIGGER$$),
('OR-14','Oracle','Procedural','PACKAGE / PACKAGE BODY','One schema per package; procedures and UDFs inside',
 $$CREATE PACKAGE BODY PKG_CLOSE AS PROCEDURE CLOSE_PERIOD(p VARCHAR2) IS ... END; END;$$,
 $$CREATE SCHEMA IF NOT EXISTS PKG_CLOSE;
CREATE OR REPLACE PROCEDURE PKG_CLOSE.CLOSE_PERIOD(P VARCHAR) RETURNS VARCHAR LANGUAGE SQL AS
BEGIN
  RETURN 'closed ' || :P;
END;$$,
 'Package variables become procedure arguments or a config table.', $$PACKAGE$$),
('OR-15','Oracle','Functions','LISTAGG ... ON OVERFLOW TRUNCATE','LISTAGG (no overflow clause)',
 $$SELECT LISTAGG(NAME, ',' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY NAME) FROM T;$$,
 $$SELECT LISTAGG(NAME, ',') WITHIN GROUP (ORDER BY NAME) FROM T;$$,
 'Snowflake LISTAGG result can be up to the VARCHAR maximum.', $$ON\s+OVERFLOW$$),
('OR-16','Oracle','Set ops','MINUS / FROM DUAL','MINUS (native) / SELECT without FROM',
 $$SELECT 1 FROM DUAL; SELECT ID FROM A MINUS SELECT ID FROM B;$$,
 $$SELECT 1; SELECT ID FROM A MINUS SELECT ID FROM B;$$,
 'MINUS and EXCEPT are both supported.', $$DUAL|MINUS$$),
('OR-17','Oracle','Hints','/*+ PARALLEL / INDEX / APPEND */ hints','Remove',
 $$SELECT /*+ PARALLEL(T, 8) */ * FROM T;$$,
 $$SELECT * FROM T;$$,
 'Scale with warehouse size instead.', $$/\*\+$$),
('OR-18','Oracle','Procedural','ROWID-based de-duplication','QUALIFY ROW_NUMBER() / INSERT OVERWRITE',
 $$DELETE FROM T WHERE ROWID NOT IN (SELECT MIN(ROWID) FROM T GROUP BY KEY_COL);$$,
 $$INSERT OVERWRITE INTO T
SELECT * FROM T QUALIFY ROW_NUMBER() OVER (PARTITION BY KEY_COL ORDER BY KEY_COL) = 1;$$,
 'There is no ROWID; choose a deterministic ORDER BY.', $$ROWID$$),
('OR-19','Oracle','Procedural','PRAGMA AUTONOMOUS_TRANSACTION logging','Log after the transaction or in a separate CALL',
 $$PROCEDURE LOG_MSG(m VARCHAR2) IS PRAGMA AUTONOMOUS_TRANSACTION; BEGIN INSERT INTO LOG VALUES (m); COMMIT; END;$$,
 $$-- Write log rows in an EXCEPTION handler or after ROLLBACK so they persist
BEGIN
  BEGIN TRANSACTION;
  INSERT INTO T SELECT * FROM S;
  COMMIT;
EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    INSERT INTO LOG VALUES ('failed: ' || SQLERRM);
    RAISE;
END;$$,
 'Redesign required; flag for manual review.', $$AUTONOMOUS_TRANSACTION$$),
('OR-20','Oracle','Packages','DBMS_OUTPUT / UTL_FILE / DBMS_STATS','SYSTEM$LOG / COPY INTO @stage / remove',
 $$DBMS_OUTPUT.PUT_LINE('x'); DBMS_STATS.GATHER_TABLE_STATS('AP','T');$$,
 $$SYSTEM$LOG('info', 'x');  -- with an event table configured; DBMS_STATS removed$$,
 'File writes become COPY INTO @stage.', $$DBMS_|UTL_$$);

-- SQL Server ----------------------------------------------------------------
INSERT INTO PATTERN_LIBRARY VALUES
('SS-01','SQL Server','Row limiting','TOP n / TOP n PERCENT','TOP n or LIMIT n; PERCENT -> QUALIFY with PERCENT_RANK or SAMPLE',
 $$SELECT TOP 10 * FROM ORDERS ORDER BY TOTAL DESC;$$,
 $$SELECT * FROM ORDERS ORDER BY TOTAL DESC LIMIT 10;$$,
 'TOP n is also accepted by Snowflake.', $$TOP\s*\(?\s*[0-9]+$$),
('SS-02','SQL Server','Functions','ISNULL(a, b)','IFNULL(a, b) / COALESCE',
 $$SELECT ISNULL(DISCOUNT, 0) FROM LINES;$$,
 $$SELECT IFNULL(DISCOUNT, 0) FROM LINES;$$,
 '', $$ISNULL\s*\($$),
('SS-03','SQL Server','Dates','GETDATE() / SYSDATETIME()','CURRENT_TIMESTAMP()',
 $$SELECT GETDATE();$$,
 $$SELECT CURRENT_TIMESTAMP();$$,
 'Check session TIMEZONE parameter.', $$GETDATE|SYSDATETIME$$),
('SS-04','SQL Server','DDL','IDENTITY(1,1) + SCOPE_IDENTITY()','IDENTITY(1,1); no SCOPE_IDENTITY',
 $$CREATE TABLE T (ID INT IDENTITY(1,1), N VARCHAR(10)); SELECT SCOPE_IDENTITY();$$,
 $$CREATE OR REPLACE TABLE T (ID NUMBER IDENTITY(1,1) ORDER, N VARCHAR(10));$$,
 'Generate keys from a SEQUENCE first if the new ID is needed afterwards.', $$IDENTITY\s*\(|SCOPE_IDENTITY$$),
('SS-05','SQL Server','Temp tables','#temp / ##global temp tables','CREATE TEMPORARY TABLE',
 $$SELECT * INTO #STAGE FROM ORDERS WHERE D > '2026-01-01';$$,
 $$CREATE OR REPLACE TEMPORARY TABLE STAGE AS SELECT * FROM ORDERS WHERE D > '2026-01-01';$$,
 'SELECT INTO a new table becomes CREATE TABLE AS SELECT.', $$#[A-Z0-9_]+|SELECT\s.+\sINTO\s$$),
('SS-06','SQL Server','Dates','CONVERT(VARCHAR, d, 112) style codes','TO_CHAR(d, ''YYYYMMDD'')',
 $$SELECT CONVERT(VARCHAR(8), ORDER_DATE, 112) FROM ORDERS;$$,
 $$SELECT TO_CHAR(ORDER_DATE, 'YYYYMMDD') FROM ORDERS;$$,
 'Map each style code to an explicit format.', $$CONVERT\s*\($$),
('SS-07','SQL Server','Procedural','DECLARE @v / SET @v / PRINT','Snowflake Scripting DECLARE / LET / RETURN',
 $$DECLARE @n INT; SET @n = (SELECT COUNT(*) FROM T); PRINT @n;$$,
 $$DECLARE
  n INTEGER;
BEGIN
  SELECT COUNT(*) INTO :n FROM T;
  RETURN n;
END;$$,
 'Anonymous block; inside SQL statements reference variables as :n.', $$@[A-Z0-9_]+$$),
('SS-08','SQL Server','Procedural','BEGIN TRY ... END TRY BEGIN CATCH','BEGIN ... EXCEPTION WHEN OTHER THEN ... END',
 $$BEGIN TRY INSERT INTO T SELECT * FROM S; END TRY BEGIN CATCH SELECT ERROR_MESSAGE(); END CATCH$$,
 $$BEGIN
  INSERT INTO T SELECT * FROM S;
EXCEPTION
  WHEN OTHER THEN RETURN SQLERRM;
END;$$,
 'ERROR_MESSAGE() -> SQLERRM, ERROR_NUMBER() -> SQLCODE.', $$BEGIN\s+TRY|BEGIN\s+CATCH$$),
('SS-09','SQL Server','Syntax','String concatenation with +','|| or CONCAT()',
 $$SELECT FIRST_NAME + ' ' + LAST_NAME FROM EMP;$$,
 $$SELECT FIRST_NAME || ' ' || LAST_NAME FROM EMP;$$,
 'Note: || returns NULL if any operand is NULL; use CONCAT_WS or COALESCE when needed.', $$'\s*\+|\+\s*'$$),
('SS-10','SQL Server','Joins','CROSS APPLY / OUTER APPLY','Join to a derived table, window function, or LATERAL FLATTEN',
 $$SELECT c.ID, x.LAST_ORDER FROM CUST c CROSS APPLY (SELECT TOP 1 ORDER_DATE AS LAST_ORDER FROM ORDERS o WHERE o.CUST_ID = c.ID ORDER BY ORDER_DATE DESC) x;$$,
 $$SELECT c.ID, o.ORDER_DATE AS LAST_ORDER
FROM CUST c JOIN ORDERS o ON o.CUST_ID = c.ID
QUALIFY ROW_NUMBER() OVER (PARTITION BY c.ID ORDER BY o.ORDER_DATE DESC) = 1;$$,
 'OUTER APPLY -> LEFT JOIN with the same QUALIFY.', $$(CROSS|OUTER)\s+APPLY$$),
('SS-11','SQL Server','DML','MERGE ... OUTPUT inserted.* / deleted.*','MERGE without OUTPUT; use a stream or before/after queries',
 $$MERGE T USING S ON T.ID = S.ID WHEN MATCHED THEN UPDATE SET T.A = S.A OUTPUT $action, inserted.ID;$$,
 $$MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED THEN UPDATE SET T.A = S.A;$$,
 'Capture changes with a STREAM on T if needed.', $$OUTPUT\s+(INSERTED|DELETED|\$ACTION)$$),
('SS-12','SQL Server','Functions','EOMONTH / STUFF / FOR XML PATH','LAST_DAY / INSERT / LISTAGG (or kit UDFs EOMONTH, STUFF)',
 $$SELECT EOMONTH(D), STUFF((SELECT ',' + NAME FROM T FOR XML PATH('')), 1, 1, '');$$,
 $$SELECT LAST_DAY(D), (SELECT LISTAGG(NAME, ',') FROM T);$$,
 '', $$EOMONTH|STUFF\s*\(|FOR\s+XML\s+PATH$$),
('SS-13','SQL Server','Hints','WITH (NOLOCK) / OPTION (RECOMPILE)','Remove',
 $$SELECT * FROM ORDERS WITH (NOLOCK) OPTION (RECOMPILE);$$,
 $$SELECT * FROM ORDERS;$$,
 '', $$NOLOCK|OPTION\s*\($$),
('SS-14','SQL Server','Syntax','[bracketed] identifiers','Unquoted or "double-quoted" identifiers',
 $$SELECT [Order Id], [Total] FROM [dbo].[Orders];$$,
 $$SELECT "Order Id", TOTAL FROM DBO.ORDERS;$$,
 'Quoted identifiers are case-sensitive in Snowflake.', $$\[[A-Z0-9_ ]+\]$$);

CREATE OR REPLACE VIEW V_PATTERN_SEARCH AS
SELECT PATTERN_ID, SOURCE_DIALECT, CATEGORY, LEGACY_PATTERN, SNOWFLAKE_EQUIVALENT, NOTES,
       LEGACY_EXAMPLE, SNOWFLAKE_EXAMPLE
FROM PATTERN_LIBRARY;

-- Example: which patterns appear in a snippet?
SELECT PATTERN_ID, LEGACY_PATTERN, SNOWFLAKE_EQUIVALENT
FROM PATTERN_LIBRARY
WHERE SOURCE_DIALECT = 'Teradata'
  AND REGEXP_LIKE(UPPER('SEL TOP 10 WITH TIES * FROM T QUALIFY ROW_NUMBER() OVER (ORDER BY X) = 1'),
                  '.*(' || DETECT_REGEX || ').*', 's');

SELECT SOURCE_DIALECT, COUNT(*) AS PATTERNS FROM PATTERN_LIBRARY GROUP BY 1 ORDER BY 1;
