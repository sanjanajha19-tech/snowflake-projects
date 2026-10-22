/*=============================================================================
  CODE CONVERSION KIT 02 - Legacy function emulation (UDFs / UDTFs)
  Functions that Teradata / Oracle / SQL Server code calls but Snowflake does
  not provide (or provides with different semantics). Converted code can call
  them unchanged by putting ACCEL_DB.CODE_CONVERSION on the search path or by
  qualifying the name.
  Not included because Snowflake has them natively: NVL, NVL2, DECODE,
  ZEROIFNULL, NULLIFZERO, ADD_MONTHS, MONTHS_BETWEEN, LAST_DAY, NEXT_DAY,
  CHARINDEX, LPAD/RPAD, REGEXP_LIKE, STRTOK, LISTAGG.
  Run as : ACCEL_ADMIN. Rerun: safe.
=============================================================================*/

USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS CODE_CONVERSION;
USE SCHEMA CODE_CONVERSION;

------------------------------------------------------------------------------
-- Teradata
------------------------------------------------------------------------------
-- OREPLACE(source, search [, replace]) - 2-argument form deletes the search string
CREATE OR REPLACE FUNCTION OREPLACE(S VARCHAR, SEARCH_STR VARCHAR, REPLACE_STR VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Teradata OREPLACE'
AS $$ REPLACE(S, SEARCH_STR, COALESCE(REPLACE_STR, '')) $$;

CREATE OR REPLACE FUNCTION OREPLACE(S VARCHAR, SEARCH_STR VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Teradata OREPLACE (delete form)'
AS $$ REPLACE(S, SEARCH_STR, '') $$;

-- OTRANSLATE(source, from_chars, to_chars)
CREATE OR REPLACE FUNCTION OTRANSLATE(S VARCHAR, FROM_CHARS VARCHAR, TO_CHARS VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Teradata OTRANSLATE'
AS $$ TRANSLATE(S, FROM_CHARS, COALESCE(TO_CHARS, '')) $$;

-- INDEX(string, substring): 1-based position, 0 if not found
CREATE OR REPLACE FUNCTION TD_INDEX(S VARCHAR, SUB VARCHAR)
RETURNS NUMBER
LANGUAGE SQL
COMMENT = 'Teradata INDEX(string, substring)'
AS $$ POSITION(SUB, S) $$;

-- Teradata day-of-week numbering: Sunday = 1 ... Saturday = 7 (independent of WEEK_START)
CREATE OR REPLACE FUNCTION TD_DAY_OF_WEEK(D DATE)
RETURNS NUMBER
LANGUAGE SQL
COMMENT = 'Teradata TD_DAY_OF_WEEK / calendar day_of_week'
AS $$ MOD(DAYOFWEEKISO(D), 7) + 1 $$;

-- Teradata internal integer date: (year - 1900) * 10000 + month * 100 + day
CREATE OR REPLACE FUNCTION TD_DATE_TO_INT(D DATE)
RETURNS NUMBER
LANGUAGE SQL
COMMENT = 'CAST(date AS INTEGER) in Teradata'
AS $$ (YEAR(D) - 1900) * 10000 + MONTH(D) * 100 + DAY(D) $$;

CREATE OR REPLACE FUNCTION TD_INT_TO_DATE(N NUMBER)
RETURNS DATE
LANGUAGE SQL
COMMENT = 'CAST(integer AS DATE) in Teradata'
AS $$ DATE_FROM_PARTS(FLOOR(N / 10000) + 1900, MOD(FLOOR(N / 100), 100), MOD(N, 100)) $$;

-- EXPAND ON PERIOD replacement: one row per day between two dates (inclusive)
CREATE OR REPLACE FUNCTION TD_EXPAND_DATES(FROM_DATE DATE, TO_DATE_INCL DATE)
RETURNS TABLE (CAL_DATE DATE)
LANGUAGE SQL
COMMENT = 'Teradata EXPAND ON PERIOD (daily) replacement'
AS $$
  SELECT DATEADD(DAY, f.VALUE::INTEGER, FROM_DATE) AS CAL_DATE
  FROM TABLE(FLATTEN(INPUT => ARRAY_GENERATE_RANGE(0, DATEDIFF(DAY, FROM_DATE, TO_DATE_INCL) + 1))) f
$$;

------------------------------------------------------------------------------
-- Oracle
------------------------------------------------------------------------------
-- INSTR(string, substring [, position [, occurrence]]) incl. negative position (search backwards)
CREATE OR REPLACE FUNCTION ORA_INSTR(S VARCHAR, SUB VARCHAR, POS NUMBER, OCC NUMBER)
RETURNS NUMBER
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'instr'
COMMENT = 'Oracle INSTR with position and occurrence'
AS $$
def instr(s, sub, pos, occ):
    if s is None or sub is None or sub == "":
        return None
    pos = 1 if pos is None else int(pos)
    occ = 1 if occ is None else int(occ)
    if pos == 0 or occ < 1:
        return 0
    if pos > 0:
        start = pos - 1
        idx = -1
        for _ in range(occ):
            idx = s.find(sub, start)
            if idx < 0:
                return 0
            start = idx + 1
        return idx + 1
    max_start = len(s) + pos
    idx = -1
    for _ in range(occ):
        if max_start < 0:
            return 0
        idx = s.rfind(sub, 0, max_start + len(sub))
        if idx < 0:
            return 0
        max_start = idx - 1
    return idx + 1
$$;

CREATE OR REPLACE FUNCTION ORA_INSTR(S VARCHAR, SUB VARCHAR, POS NUMBER)
RETURNS NUMBER
LANGUAGE SQL
AS $$ ACCEL_DB.CODE_CONVERSION.ORA_INSTR(S, SUB, POS, 1) $$;

CREATE OR REPLACE FUNCTION ORA_INSTR(S VARCHAR, SUB VARCHAR)
RETURNS NUMBER
LANGUAGE SQL
AS $$ ACCEL_DB.CODE_CONVERSION.ORA_INSTR(S, SUB, 1, 1) $$;

-- ROUND(date, fmt) for the common formats: 'DD', 'MM', 'Q', 'YYYY'
CREATE OR REPLACE FUNCTION ORA_ROUND_DATE(D DATE, FMT VARCHAR)
RETURNS DATE
LANGUAGE SQL
COMMENT = 'Oracle ROUND(date, fmt): MM rounds up from the 16th, YYYY from 1 July, Q from the 16th of the 2nd month'
AS $$
  CASE UPPER(FMT)
    WHEN 'MM'   THEN IFF(DAY(D) >= 16, DATEADD(MONTH, 1, DATE_TRUNC('MONTH', D)), DATE_TRUNC('MONTH', D))
    WHEN 'MON'  THEN IFF(DAY(D) >= 16, DATEADD(MONTH, 1, DATE_TRUNC('MONTH', D)), DATE_TRUNC('MONTH', D))
    WHEN 'YYYY' THEN IFF(MONTH(D) >= 7, DATEADD(YEAR, 1, DATE_TRUNC('YEAR', D)), DATE_TRUNC('YEAR', D))
    WHEN 'YEAR' THEN IFF(MONTH(D) >= 7, DATEADD(YEAR, 1, DATE_TRUNC('YEAR', D)), DATE_TRUNC('YEAR', D))
    WHEN 'Q'    THEN IFF(DATEDIFF(DAY, DATEADD(MONTH, 1, DATE_TRUNC('QUARTER', D)), D) >= 15,
                         DATEADD(QUARTER, 1, DATE_TRUNC('QUARTER', D)), DATE_TRUNC('QUARTER', D))
    ELSE D
  END
$$;

-- LNNVL(condition): TRUE when the condition is FALSE or UNKNOWN
CREATE OR REPLACE FUNCTION LNNVL(C BOOLEAN)
RETURNS BOOLEAN
LANGUAGE SQL
COMMENT = 'Oracle LNNVL'
AS $$ COALESCE(NOT C, TRUE) $$;

-- SYS_GUID(): 32-character uppercase hex string
CREATE OR REPLACE FUNCTION ORA_SYS_GUID()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Oracle SYS_GUID (as hex string)'
AS $$ UPPER(REPLACE(UUID_STRING(), '-', '')) $$;

-- CONNECT BY LEVEL <= n row generator: SELECT LVL FROM TABLE(ORA_LEVELS(10))
CREATE OR REPLACE FUNCTION ORA_LEVELS(N NUMBER)
RETURNS TABLE (LVL NUMBER)
LANGUAGE SQL
COMMENT = 'Replacement for SELECT LEVEL FROM DUAL CONNECT BY LEVEL <= n'
AS $$
  SELECT f.VALUE::NUMBER AS LVL
  FROM TABLE(FLATTEN(INPUT => ARRAY_GENERATE_RANGE(1, N + 1))) f
$$;

------------------------------------------------------------------------------
-- SQL Server
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION EOMONTH(D DATE)
RETURNS DATE
LANGUAGE SQL
COMMENT = 'SQL Server EOMONTH(date)'
AS $$ LAST_DAY(D) $$;

CREATE OR REPLACE FUNCTION EOMONTH(D DATE, MONTHS_TO_ADD NUMBER)
RETURNS DATE
LANGUAGE SQL
COMMENT = 'SQL Server EOMONTH(date, months_to_add)'
AS $$ LAST_DAY(DATEADD(MONTH, MONTHS_TO_ADD, D)) $$;

CREATE OR REPLACE FUNCTION STUFF(S VARCHAR, START_POS NUMBER, DEL_LEN NUMBER, INS VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'SQL Server STUFF(string, start, length, insert)'
AS $$ INSERT(S, START_POS, DEL_LEN, COALESCE(INS, '')) $$;

------------------------------------------------------------------------------
-- Smoke tests (expected values in comments)
------------------------------------------------------------------------------
SELECT
  OREPLACE('ACME LTD', 'LTD', 'LIMITED')                  AS T1,  -- ACME LIMITED
  OREPLACE('A-B-C', '-')                                  AS T2,  -- ABC
  OTRANSLATE('2026/09/30', '/', '-')                      AS T3,  -- 2026-09-30
  TD_INDEX('SNOWFLAKE', 'FLAKE')                          AS T4,  -- 5
  TD_DAY_OF_WEEK('2026-09-27'::DATE)                      AS T5,  -- 1 (Sunday)
  TD_DATE_TO_INT('2026-09-30'::DATE)                      AS T6,  -- 1260930
  TD_INT_TO_DATE(1260930)                                 AS T7,  -- 2026-09-30
  ORA_INSTR('CORPORATE FLOOR', 'OR', 3, 2)                AS T8,  -- 14
  ORA_INSTR('CORPORATE FLOOR', 'OR', -3, 2)               AS T9,  -- 2
  ORA_INSTR('CORPORATE FLOOR', 'OR')                      AS T10, -- 2
  ORA_ROUND_DATE('2026-09-20'::DATE, 'MM')                AS T11, -- 2026-10-01
  LNNVL(NULL::BOOLEAN)                                    AS T12, -- TRUE
  LENGTH(ORA_SYS_GUID())                                  AS T13, -- 32
  EOMONTH('2026-02-10'::DATE)                             AS T14, -- 2026-02-28
  EOMONTH('2026-02-10'::DATE, 1)                          AS T15, -- 2026-03-31
  STUFF('abcdef', 2, 3, 'XYZ')                            AS T16; -- aXYZef

SELECT LVL FROM TABLE(ORA_LEVELS(5));                                       -- 1..5
SELECT CAL_DATE FROM TABLE(TD_EXPAND_DATES('2026-09-28'::DATE, '2026-10-02'::DATE));  -- 5 rows
