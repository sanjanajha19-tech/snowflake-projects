-- Silver: conformed customers, one row per CUSTOMER_ID (mirrors SILVER.SLV_CUSTOMERS)
select
    md5(to_varchar(customer_id))                         as customer_sk,
    customer_id,
    trim(customer_name)                                  as customer_name,
    trim(segment)                                        as segment,
    trim(industry)                                       as industry,
    trim(region)                                         as region,
    trim(country)                                        as country,
    initcap(trim(city))                                  as city,
    lower(trim(email))                                   as email,
    regexp_replace(phone, '[^0-9+]', '')                 as phone,
    created_date::date                                   as created_date,
    credit_limit::number(12,2)                           as credit_limit
from {{ source('demo', 'customers') }}
where customer_id is not null
qualify row_number() over (partition by customer_id order by created_date desc nulls last) = 1
