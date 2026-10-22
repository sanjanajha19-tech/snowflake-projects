-- Gold: sales fact at order-line grain (mirrors GOLD.FACT_SALES)
select
    s.order_line_sk,
    s.order_id,
    s.line_no,
    (year(s.order_date) * 10000 + month(s.order_date) * 100 + day(s.order_date))::number(8,0) as date_key,
    s.order_date,
    md5(to_varchar(s.customer_id))                  as customer_sk,
    md5(to_varchar(s.product_id))                   as product_sk,
    s.category,
    s.channel,
    s.order_status,
    s.order_status in ('DELIVERED', 'SHIPPED')      as is_revenue_recognised,
    s.currency,
    s.quantity,
    s.unit_price,
    s.discount_pct,
    s.net_amount,
    s.cost_amount,
    (s.net_amount - s.cost_amount)::number(14,2)    as margin_amount
from {{ ref('stg_sales_lines') }} s
