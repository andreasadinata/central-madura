-- Run ONCE, before 001. Removes the v0 prototype tables. They held sample data only (no sales);
-- a full copy is in backup_v0_prototype_2026-11-24.json.
drop table if exists sale_item_mechanics, contract_prices, contracts, payments,
  sale_items, sales, price_tiers, vehicles, customers, products, categories,
  audit_log, profiles, locations cascade;
drop function if exists get_price, next_invoice_no, log_changes cascade;

