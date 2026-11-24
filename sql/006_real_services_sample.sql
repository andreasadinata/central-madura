-- 24 Nov 2026: replaced the made-up demo services with 20 services from the real price list.
-- Full service price list gets imported with the 2027 pricing.
update products set is_active = false where sku in ('DEMO-BAN-J1','DEMO-BAL-1','DEMO-BAL-2','DEMO-SPO-1','DEMO-SPO-2');
with s(sku, name, cat, grp, price) as (values
  ('BAL-0001','BALANCING FLEET/R12-13','BAL','Balancing',25000), ('BAL-0002','BALANCING R14-R16','BAL','Balancing',30000),
  ('BAL-0003','BALANCING R17++/DUEL','BAL','Balancing',32500),   ('BAL-0004','BALANCING MT/MODIF','BAL','Balancing',42500),
  ('SPO-0001','SPOORING A','SPO','Spooring',160000), ('SPO-0002','SPOORING B','SPO','Spooring',180000),
  ('SPO-0003','SPOORING C','SPO','Spooring',200000), ('SPO-0004','SPOORING D','SPO','Spooring',220000),
  ('BAN-0001','GANTI BAN FLEET/R12-13','BAN','Ganti Ban',17500), ('BAN-0002','GANTI BAN R14-R16','BAN','Ganti Ban',20000),
  ('BAN-0003','GANTI BAN R17++/DUEL','BAN','Ganti Ban',22500),   ('BAN-0004','ISI NITROGEN R14-R16','BAN','Nitrogen',15000),
  ('BAN-0005','ISI NITROGEN R17++/DUEL','BAN','Nitrogen',17500), ('BAN-0006','TAMBAL BAN [LL]','BAN','Tambal Ban',15000),
  ('OLI-0001','GANTI OLI R4 MESIN [LL]','OLI','Ganti Oli',10000), ('OLI-0002','TUNE UP [LL]','OLI','Tune Up',150000),
  ('REM-0001','GANTI KAMPAS REM DEPAN A [LL]','REM','Kampas Rem',80000), ('KAK-0001','GANTI TIE ROD A [LL]','KAK','Tie Rod',50000),
  ('AKI-0001','GANTI AKI [LL]','AKI','Ganti Aki',10000), ('LAI-0001','CUCI R4 MOBIL','LAI','Cuci',50000)
), ins as (
  insert into products (sku, name, category_id, is_service, service_group)
  select s.sku, s.name, c.id, true, s.grp from s join categories c on c.code = s.cat returning id, sku
)
insert into price_tiers (price_list_id, product_id, min_qty, price)
select (select id from price_lists where is_default), ins.id, 1, s.price from ins join s on s.sku = ins.sku;

-- Bonus categories (replaces the [LL] name suffix with a real field)
alter table products
  add column bonus_type text check (bonus_type in ('spooring','balancing','nitrogen','ban','jasa_ll')),
  add column bonus_points numeric;
update products set bonus_type = 'spooring'  where service_group = 'Spooring';
update products set bonus_type = 'balancing' where service_group = 'Balancing';
update products set bonus_type = 'nitrogen'  where service_group = 'Nitrogen';
update products set bonus_type = 'jasa_ll'   where name like '%[LL]%';
update products p set bonus_type = 'ban' from categories c where c.id = p.category_id and c.code = 'BAN' and not p.is_service;
