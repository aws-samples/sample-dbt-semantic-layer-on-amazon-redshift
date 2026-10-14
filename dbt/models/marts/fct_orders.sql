{{ config(materialized='table') }}

select
    order_id,
    store,
    cast(ordered_at as date) as ordered_at,
    amount
from {{ ref('raw_orders') }}
