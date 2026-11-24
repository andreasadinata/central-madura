-- Run ONCE, before 001. Removes the empty v0 prototype tables (verified 0 rows on 24 Nov 2026).
drop table if exists sale_item_mechanics, contract_prices, contracts, payments,
  sale_items, sales, price_tiers, vehicles, customers, products, categories,
  audit_log, profiles, locations cascade;
drop function if exists get_price, next_invoice_no, log_changes cascade;

