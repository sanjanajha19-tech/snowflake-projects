-- Silver: order lines enriched with order header and product cost (mirrors SLV_ORDER_LINES + SLV_ORDERS)
with lines as (
    select *
    from {{ source('demo', 'order_lines') }}
    where order_id is not null and line_no is not null
    qualify row_number() over (partition by order_id, line_no order by net_amount desc nulls last) = 1
),
orders as (
    select *
    from {{ source('demo', 'orders') }}
    qualify row_number() over (partition by order_id order by order_date desc nulls last) = 1
),
products as (
    select product_id, unit_cost, category
    from {{ source('demo', 'products') }}
)
select
    md5(to_varchar(l.order_id) || '-' || to_varchar(l.line_no)) as order_line_sk,
    l.order_id,
    l.line_no,
    o.order_date::date                                          as order_date,
    o.customer_id,
    l.product_id,
    p.category,
    trim(o.channel)                                             as channel,
    upper(trim(o.status))                                       as order_status,
    upper(trim(o.currency))                                     as currency,
    l.quantity,
    l.unit_price::number(10,2)                                  as unit_price,
    coalesce(l.discount_pct, 0)::number(5,2)                    as discount_pct,
    l.net_amount::number(14,2)                                  as net_amount,
    (l.quantity * p.unit_cost)::number(14,2)                    as cost_amount
from lines l
join orders o on o.order_id = l.order_id
left join products p on p.product_id = l.product_id
