/*=============================================================================
  ASSET 11 - Semantic KPI Library
  File 04   : HR_SEMANTIC_VIEW
  KPIs      : headcount, exits, attrition rate %, average tenure,
              annual salary cost, average salary
  Run as    : ACCEL_ADMIN
  Rerun     : safe (CREATE OR REPLACE ... COPY GRANTS)
  Privacy   : no names / emails exposed. Salary metrics are aggregated;
              restrict this semantic view to HR roles in production.
=============================================================================*/
USE ROLE ACCEL_ADMIN;
USE WAREHOUSE ACCEL_WH;
USE DATABASE ACCEL_DB;
CREATE SCHEMA IF NOT EXISTS KPI_LIBRARY;
USE SCHEMA KPI_LIBRARY;

CREATE OR REPLACE SEMANTIC VIEW HR_SEMANTIC_VIEW
  TABLES (
    employees AS ACCEL_DB.KPI_LIBRARY.HR_EMPLOYEES_V
      PRIMARY KEY (employee_id)
      WITH SYNONYMS ('staff', 'workforce', 'people', 'headcount')
      COMMENT = 'One row per employee (active or exited), no PII'
  )
  FACTS (
    employees.is_active AS is_active
      COMMENT = '1 for active employees',
    employees.is_exited AS is_exited
      COMMENT = '1 for employees who have left',
    employees.tenure_years AS tenure_years
      COMMENT = 'Years since hire for active employees',
    employees.active_salary AS active_salary
      COMMENT = 'Annual salary for active employees, 0 for exited',
    employees.salary AS salary
      COMMENT = 'Annual salary (last known for exited employees)'
  )
  DIMENSIONS (
    employees.department AS department
      WITH SYNONYMS = ('function', 'team', 'org')
      COMMENT = 'Department',
    employees.job_title AS job_title
      WITH SYNONYMS = ('role', 'position')
      COMMENT = 'Job title',
    employees.location AS location
      WITH SYNONYMS = ('office', 'site')
      COMMENT = 'Work location',
    employees.hire_date AS hire_date
      COMMENT = 'Date of hire',
    employees.hire_year AS hire_year
      WITH SYNONYMS = ('joining year', 'cohort')
      COMMENT = 'Year of hire',
    employees.employment_status AS employment_status
      WITH SYNONYMS = ('status')
      COMMENT = 'Active or Exited'
  )
  METRICS (
    employees.headcount AS SUM(employees.is_active)
      WITH SYNONYMS = ('HC', 'active employees', 'FTE')
      COMMENT = 'Number of active employees',
    employees.exits AS SUM(employees.is_exited)
      WITH SYNONYMS = ('leavers', 'terminations')
      COMMENT = 'Number of employees who have exited',
    employees.attrition_rate_pct AS SUM(employees.is_exited) / NULLIF(COUNT(employee_id), 0) * 100
      WITH SYNONYMS = ('attrition', 'turnover rate', 'churn rate')
      COMMENT = 'Exited / all employees on file x 100 (cumulative; demo data has no exit date)',
    employees.avg_tenure_years AS AVG(employees.tenure_years)
      WITH SYNONYMS = ('tenure', 'average service')
      COMMENT = 'Average tenure in years of active employees',
    employees.salary_cost AS SUM(employees.active_salary)
      WITH SYNONYMS = ('payroll cost', 'salary bill', 'people cost')
      COMMENT = 'Annual salary cost of active employees',
    employees.avg_salary AS SUM(employees.active_salary) / NULLIF(SUM(employees.is_active), 0)
      COMMENT = 'Average annual salary of active employees'
  )
  COMMENT = 'HR KPI library: headcount, attrition, tenure, salary cost (ACCEL asset 11)'
  COPY GRANTS;

GRANT SELECT ON SEMANTIC VIEW ACCEL_DB.KPI_LIBRARY.HR_SEMANTIC_VIEW TO ROLE ACCEL_ANALYST;

SELECT * FROM SEMANTIC_VIEW(
    HR_SEMANTIC_VIEW
    DIMENSIONS employees.department
    METRICS employees.headcount, employees.attrition_rate_pct, employees.avg_tenure_years, employees.salary_cost
  )
ORDER BY headcount DESC;
