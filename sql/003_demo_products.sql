-- DEMO products for testing only (SKU starts with DEMO-).
-- These get removed (set inactive) before the real CSV import.
do $$
declare
  umum bigint := (select id from price_lists where is_default);
  cat  bigint;
  pid  bigint;
begin
  -- Oil with two quantity tiers (your screenshot: 1–11 → 105k, 12+ → 90k)
  select id into cat from categories where code = 'OLI';
  insert into products (sku, name, category_id, brand, isi_per_dus)
    values ('DEMO-OLI-1', 'Oli Castrol Magnatec 10W-40 1L [12]', cat, 'Castrol', 12) returning id into pid;
  insert into price_tiers (price_list_id, product_id, min_qty, price) values (umum, pid, 1, 105000), (umum, pid, 12, 90000);
  insert into stock_moves (product_id, location_id, qty, kind, reason)
    values (pid, (select id from locations where code='CBP'), 24, 'opening', 'demo');

  insert into products (sku, name, category_id, brand, isi_per_dus)
    values ('DEMO-OLI-2', 'Oli Shell Helix HX7 10W-40 4L', cat, 'Shell', 4) returning id into pid;
  insert into price_tiers (price_list_id, product_id, min_qty, price) values (umum, pid, 1, 420000), (umum, pid, 3, 400000);
  insert into stock_moves (product_id, location_id, qty, kind, reason)
    values (pid, (select id from locations where code='CBP'), 10, 'opening', 'demo');

  insert into products (sku, name, category_id, brand)
    values ('DEMO-OLI-3', 'Filter Oli Avanza', cat, 'Toyota') returning id into pid;
  insert into price_tiers (price_list_id, product_id, min_qty, price) values (umum, pid, 1, 65000);
  insert into stock_moves (product_id, location_id, qty, kind, reason)
    values (pid, (select id from locations where code='CBP'), 6, 'opening', 'demo');

  -- Tyre: 1 price, and a 4+ price
  select id into cat from categories where code = 'BAN';
  insert into products (sku, name, category_id, brand)
    values ('DEMO-BAN-1', 'Ban GT Radial Champiro 185/65 R15', cat, 'GT Radial') returning id into pid;
  insert into price_tiers (price_list_id, product_id, min_qty, price) values (umum, pid, 1, 785000), (umum, pid, 4, 765000);
  insert into stock_moves (product_id, location_id, qty, kind, reason)
    values (pid, (select id from locations where code='CBP'), 12, 'opening', 'demo');

  -- Services: separate products per variant, rolled up by service_group
  insert into products (sku, name, category_id, is_service, service_group)
    values ('DEMO-BAN-J1', 'Ganti Ban R14-R16', cat, true, 'Ganti Ban') returning id into pid;
  insert into price_tiers (price_list_id, product_id, min_qty, price) values (umum, pid, 1, 20000);

  select id into cat from categories where code = 'BAL';
  insert into products (sku, name, category_id, is_service, service_group)
    values ('DEMO-BAL-1', 'Balancing R14-R16', cat, true, 'Balancing') returning id into pid;
  insert into price_tiers (price_list_id, product_id, min_qty, price) values (umum, pid, 1, 25000);
  insert into products (sku, name, category_id, is_service, service_group)
    values ('DEMO-BAL-2', 'Balancing R17+', cat, true, 'Balancing') returning id into pid;
  insert into price_tiers (price_list_id, product_id, min_qty, price) values (umum, pid, 1, 30000);

  select id into cat from categories where code = 'SPO';
  insert into products (sku, name, category_id, is_service, service_group)
    values ('DEMO-SPO-1', 'Spooring R14-R16', cat, true, 'Spooring') returning id into pid;
  insert into price_tiers (price_list_id, product_id, min_qty, price) values (umum, pid, 1, 75000);
  insert into products (sku, name, category_id, is_service, service_group)
    values ('DEMO-SPO-2', 'Spooring R17+', cat, true, 'Spooring') returning id into pid;
  insert into price_tiers (price_list_id, product_id, min_qty, price) values (umum, pid, 1, 90000);
end $$;
