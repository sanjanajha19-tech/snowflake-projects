-- Singular test: returns failing rows (net amount should never be negative)
select order_line_sk, net_amount
from {{ ref('fact_sales') }}
where net_amount < 0
