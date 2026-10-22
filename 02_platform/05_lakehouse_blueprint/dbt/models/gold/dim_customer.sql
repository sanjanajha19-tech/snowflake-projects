-- Gold: customer dimension (mirrors GOLD.DIM_CUSTOMER)
select
    customer_sk,
    customer_id,
    customer_name,
    segment,
    industry,
    region,
    country,
    city,
    created_date,
    credit_limit,
    case when credit_limit >= 500000 then 'High'
         when credit_limit >= 100000 then 'Medium'
         else 'Low' end as credit_band
from {{ ref('stg_customers') }}
