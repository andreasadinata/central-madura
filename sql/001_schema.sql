-- ════════════════════════════════════════════════════════════════
--  CENTRAL POS — schema v1 (MVP)
--  Plain Postgres. Every rule that protects money lives HERE, not in
--  the browser: the browser can be edited by anyone, the database can't.
--
--  Golden rules
--   1. Nothing that touched money is ever deleted. Lines are "cancelled",
--      invoices are "void", always with a reason, who and when.
--   2. An invoice can be changed only on its own business day (Jakarta).
--      After that: make a new invoice (nota susulan).
--   3. The browser never writes to sales/payments/stock directly. It calls
--      the functions at the bottom, which check everything.
--   4. Stock = sum of stock_moves. Never a number someone types.
-- ════════════════════════════════════════════════════════════════

-- ════════════════ MASTER DATA ════════════════

create table locations (
  id         bigint generated always as identity primary key,
  code       text unique not null,          -- CBP, CSP, CAU, CBS
  name       text not null,
  address    text,
  phone      text,
  is_active  boolean not null default true
);

create table profiles (
  id          uuid primary key references auth.users(id),
  full_name   text not null,
  email       text,
  role        text not null check (role in ('owner','admin','kasir')),
  location_id bigint references locations(id),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table categories (
  id    bigint generated always as identity primary key,
  code  text unique not null,               -- used in SKU: BAN-0001
  name  text not null,
  sort  int not null default 0
);

create table products (
  id            bigint generated always as identity primary key,
  sku           text unique not null,
  barcode       text unique,                -- manufacturer barcode, optional
  name          text not null,
  category_id   bigint not null references categories(id),
  brand         text,
  service_group text,                       -- "Balancing", "Spooring": rolls variants up in reports
  is_service    boolean not null default false,
  isi_per_dus   int,                        -- information only, shown on purchase screen
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);
create index on products (category_id);

create table price_lists (
  id         bigint generated always as identity primary key,
  name       text unique not null,
  is_default boolean not null default false
);
create unique index one_default_price_list on price_lists (is_default) where is_default;

-- "from this quantity → this price". The end of each range is implied.
create table price_tiers (
  id            bigint generated always as identity primary key,
  price_list_id bigint not null references price_lists(id),
  product_id    bigint not null references products(id),
  min_qty       numeric not null check (min_qty > 0),
  price         numeric not null check (price >= 0),
  unique (price_list_id, product_id, min_qty)
);
create index on price_tiers (product_id);

create table customers (
  id            bigint generated always as identity primary key,
  name          text not null,
  phone         text,
  address       text,
  price_list_id bigint references price_lists(id),   -- null = default list
  allow_tempo   boolean not null default false,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid references profiles(id)
);
create index on customers (phone);

create table car_models (
  id    bigint generated always as identity primary key,
  brand text not null,
  model text not null,
  unique (brand, model)
);

create table vehicles (
  id           bigint generated always as identity primary key,
  customer_id  bigint not null references customers(id),
  plate        text not null,               -- NOT unique: fake / shared plates exist
  plate_key    text generated always as (upper(regexp_replace(plate, '[^A-Za-z0-9]', '', 'g'))) stored,
  car_model_id bigint references car_models(id),
  color        text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);
create index on vehicles (plate_key);
create index on vehicles (customer_id);

-- ════════════════ TRANSACTIONS ════════════════

create table invoice_counters (
  location_id bigint references locations(id),
  period      text,                         -- 'YYMM', resets on the 1st
  last_no     int not null default 0,
  primary key (location_id, period)
);

create table sales (
  id              bigint generated always as identity primary key,
  invoice_no      text unique not null,
  location_id     bigint not null references locations(id),
  customer_id     bigint not null references customers(id),
  vehicle_id      bigint references vehicles(id),
  plate           text,                     -- plate exactly as it was that day
  cashier_id      uuid not null references profiles(id),
  is_tempo        boolean not null default false,
  status          text not null default 'open' check (status in ('open','paid','void')),
  revision        int not null default 1,   -- goes up when a PRINTED invoice changes
  opened_at       timestamptz not null default now(),
  business_date   date not null default (now() at time zone 'Asia/Jakarta')::date,
  paid_at         timestamptz,
  subtotal        numeric not null default 0,
  total           numeric not null default 0,
  paid_amount     numeric not null default 0,
  print_count     int not null default 0,
  last_printed_at timestamptz,
  void_reason     text,
  voided_by       uuid references profiles(id),
  voided_at       timestamptz,
  queue_ref       text,                     -- later: queue number + date from the queue system
  notes           text
);
create index on sales (location_id, business_date);
create index on sales (status);
create index on sales (customer_id);

create table sale_items (
  id               bigint generated always as identity primary key,
  sale_id          bigint not null references sales(id),
  product_id       bigint not null references products(id),
  qty              numeric not null check (qty > 0),
  standard_price   numeric not null,        -- what the price list said
  unit_price       numeric not null check (unit_price >= 0),
  line_total       numeric not null,
  price_source     text not null,           -- 'umum' | 'khusus' | 'manual'
  price_reason     text,                    -- required when unit_price < standard_price
  added_by         uuid not null references profiles(id),
  added_at         timestamptz not null default now(),
  added_after_print boolean not null default false,
  cancelled_at     timestamptz,
  cancelled_by     uuid references profiles(id),
  cancel_reason    text
);
create index on sale_items (sale_id);
create index on sale_items (product_id);

create table payments (
  id          bigint generated always as identity primary key,
  sale_id     bigint not null references sales(id),
  amount      numeric not null check (amount <> 0),  -- negative = money returned to customer
  method      text not null check (method in ('tunai','transfer')),
  received_by uuid not null references profiles(id),
  created_at  timestamptz not null default now(),
  notes       text
);
create index on payments (sale_id);

create table stock_moves (
  id          bigint generated always as identity primary key,
  product_id  bigint not null references products(id),
  location_id bigint not null references locations(id),
  qty         numeric not null,             -- + in, − out
  kind        text not null check (kind in ('sale','sale_cancel','purchase','adjust','opening')),
  sale_item_id bigint references sale_items(id),
  unit_cost   numeric,
  reason      text,
  created_by  uuid references profiles(id),
  created_at  timestamptz not null default now()
);
create index on stock_moves (product_id, location_id);

create table audit_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  user_id    uuid,
  action     text not null,
  table_name text,
  record_id  bigint,
  detail     jsonb
);
create index on audit_log (at);

create view product_stock with (security_invoker = true) as
  select product_id, location_id, sum(qty) as qty
  from stock_moves group by product_id, location_id;

-- ════════════════ SECURITY (row level) ════════════════

create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and is_active
$$;

do $$
declare t text;
begin
  foreach t in array array['locations','profiles','categories','products','price_lists',
    'price_tiers','customers','car_models','vehicles','invoice_counters','sales',
    'sale_items','payments','stock_moves','audit_log'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy staff_read on %I for select to authenticated using (my_role() is not null)', t);
  end loop;
end $$;

-- master data editable by owner/admin
do $$
declare t text;
begin
  foreach t in array array['locations','categories','products','price_lists','price_tiers'] loop
    execute format($p$create policy mgr_insert on %I for insert to authenticated with check (my_role() in ('owner','admin'))$p$, t);
    execute format($p$create policy mgr_update on %I for update to authenticated using (my_role() in ('owner','admin'))$p$, t);
  end loop;
end $$;
create policy mgr_delete on price_tiers for delete to authenticated using (my_role() in ('owner','admin'));

-- customers, vehicles, car models: any staff (kasir registers new customers)
do $$
declare t text;
begin
  foreach t in array array['customers','vehicles','car_models'] loop
    execute format($p$create policy staff_insert on %I for insert to authenticated with check (my_role() is not null)$p$, t);
    execute format($p$create policy staff_update on %I for update to authenticated using (my_role() is not null)$p$, t);
  end loop;
end $$;

-- only the owner manages staff
create policy owner_update on profiles for update to authenticated using (my_role() = 'owner');

-- sales, sale_items, payments, stock_moves, invoice_counters, audit_log:
-- NO write policies on purpose. Only the functions below can write.
revoke update, delete on audit_log from anon, authenticated;

-- ════════════════ AUDIT for master data ════════════════

create or replace function audit_master() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (user_id, action, table_name, record_id, detail)
  values (auth.uid(), lower(tg_op), tg_table_name,
          coalesce((to_jsonb(new)->>'id')::bigint, (to_jsonb(old)->>'id')::bigint),
          jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new)));
  return coalesce(new, old);
end $$;

create trigger audit_products    after insert or update            on products    for each row execute function audit_master();
create trigger audit_price_tiers after insert or update or delete  on price_tiers for each row execute function audit_master();
create trigger audit_customers   after update                      on customers   for each row execute function audit_master();
create trigger audit_profiles    after update                      on profiles    for each row execute function audit_master();

-- ════════════════ PRICING ════════════════

-- Price for a product, customer and quantity.
-- Customer's own list first; if that list has no row for this product, the default list.
create or replace function price_for(p_product bigint, p_customer bigint, p_qty numeric)
returns table (price numeric, source text)
language plpgsql stable security definer set search_path = public as $$
declare v_list bigint;
begin
  select price_list_id into v_list from customers where id = p_customer;
  if v_list is not null then
    return query
      select t.price, 'khusus'::text from price_tiers t
      where t.price_list_id = v_list and t.product_id = p_product and t.min_qty <= p_qty
      order by t.min_qty desc limit 1;
    if found then return; end if;
  end if;
  return query
    select t.price, 'umum'::text from price_tiers t
    join price_lists l on l.id = t.price_list_id and l.is_default
    where t.product_id = p_product and t.min_qty <= p_qty
    order by t.min_qty desc limit 1;
  if not found then
    raise exception 'Produk id % belum punya harga di daftar harga umum.', p_product;
  end if;
end $$;

-- ════════════════ SALES ENGINE ════════════════

create or replace function _staff() returns profiles
language plpgsql stable security definer set search_path = public as $$
declare p profiles;
begin
  select * into p from profiles where id = auth.uid() and is_active;
  if not found then raise exception 'Akun ini tidak aktif atau belum punya profil.'; end if;
  return p;
end $$;

create or replace function _same_day(s sales) returns void
language plpgsql as $$
begin
  if s.business_date <> (now() at time zone 'Asia/Jakarta')::date then
    raise exception 'Invoice % tanggal % sudah lewat hari. Buat nota susulan.', s.invoice_no, s.business_date;
  end if;
end $$;

create or replace function _recalc(p_sale bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_sub numeric; v_paid numeric; s sales;
begin
  select coalesce(sum(line_total),0) into v_sub from sale_items where sale_id = p_sale and cancelled_at is null;
  select coalesce(sum(amount),0)     into v_paid from payments  where sale_id = p_sale;
  update sales set subtotal = v_sub, total = v_sub, paid_amount = v_paid
  where id = p_sale returning * into s;
  if s.status <> 'void' then
    if v_paid >= v_sub and v_sub > 0 then
      update sales set status = 'paid', paid_at = coalesce(paid_at, now()) where id = p_sale;
    else
      update sales set status = 'open', paid_at = null where id = p_sale;
    end if;
  end if;
end $$;

-- items: [{ "product_id":1, "qty":2, "unit_price":90000, "reason":"" }, ...]
create or replace function _add_items(s sales, p_items jsonb, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare it jsonb; pr products; v_std numeric; v_src text; v_qty numeric; v_price numeric; v_reason text; v_id bigint;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Tidak ada item.';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into pr from products where id = (it->>'product_id')::bigint;
    if not found then raise exception 'Produk id % tidak ada.', it->>'product_id'; end if;
    v_qty   := (it->>'qty')::numeric;
    v_price := (it->>'unit_price')::numeric;
    v_reason := nullif(trim(coalesce(it->>'reason','')), '');
    if v_qty is null or v_qty <= 0 then raise exception 'Qty % harus lebih dari 0.', pr.name; end if;
    if v_price is null or v_price < 0 then raise exception 'Harga % tidak valid.', pr.name; end if;
    select f.price, f.source into v_std, v_src from price_for(pr.id, s.customer_id, v_qty) f;
    if v_price < v_std and v_reason is null then
      raise exception 'Harga % (%) di bawah normal (%). Alasan wajib diisi.', pr.name, v_price, v_std;
    end if;
    if v_price <> v_std then v_src := 'manual'; end if;
    insert into sale_items (sale_id, product_id, qty, standard_price, unit_price, line_total,
                            price_source, price_reason, added_by, added_after_print)
    values (s.id, pr.id, v_qty, v_std, v_price, v_qty * v_price, v_src,
            case when v_price <> v_std then v_reason end, p_user, s.print_count > 0)
    returning id into v_id;
    if not pr.is_service then
      insert into stock_moves (product_id, location_id, qty, kind, sale_item_id, created_by)
      values (pr.id, s.location_id, -v_qty, 'sale', v_id, p_user);
    end if;
  end loop;
end $$;

-- Create a new invoice. p_tempo = credit sale (customer must have allow_tempo).
create or replace function create_sale(p_customer bigint, p_vehicle bigint, p_plate text,
                                       p_items jsonb, p_tempo boolean default false)
returns sales
language plpgsql security definer set search_path = public as $$
declare me profiles; loc locations; c customers; v_period text; v_no int; s sales;
begin
  me := _staff();
  if me.location_id is null then raise exception 'Akun % belum punya cabang.', me.full_name; end if;
  select * into loc from locations where id = me.location_id;
  select * into c from customers where id = p_customer and is_active;
  if not found then raise exception 'Pelanggan id % tidak ada / tidak aktif.', p_customer; end if;
  if p_tempo and not c.allow_tempo then
    raise exception 'Pelanggan % tidak diizinkan tempo.', c.name;
  end if;
  if p_vehicle is not null and not exists (select 1 from vehicles where id = p_vehicle and customer_id = p_customer) then
    raise exception 'Kendaraan id % bukan milik pelanggan %.', p_vehicle, c.name;
  end if;

  v_period := to_char(now() at time zone 'Asia/Jakarta', 'YYMM');
  insert into invoice_counters (location_id, period, last_no) values (loc.id, v_period, 1)
  on conflict (location_id, period) do update set last_no = invoice_counters.last_no + 1
  returning last_no into v_no;

  insert into sales (invoice_no, location_id, customer_id, vehicle_id, plate, cashier_id, is_tempo)
  values (loc.code || '-' || v_period || '-' || lpad(v_no::text, 4, '0'),
          loc.id, p_customer, p_vehicle, upper(nullif(trim(p_plate), '')), me.id, p_tempo)
  returning * into s;

  perform _add_items(s, p_items, me.id);
  perform _recalc(s.id);
  insert into audit_log (user_id, action, table_name, record_id, detail)
  values (me.id, 'sale_create', 'sales', s.id, jsonb_build_object('invoice', s.invoice_no));
  select * into s from sales where id = s.id;
  return s;
end $$;

-- Add lines to an existing invoice (same day only).
create or replace function add_sale_items(p_sale bigint, p_items jsonb)
returns sales
language plpgsql security definer set search_path = public as $$
declare me profiles; s sales;
begin
  me := _staff();
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Invoice id % tidak ada.', p_sale; end if;
  if s.status = 'void' then raise exception 'Invoice % sudah void.', s.invoice_no; end if;
  perform _same_day(s);
  perform _add_items(s, p_items, me.id);
  if s.print_count > 0 then update sales set revision = revision + 1 where id = s.id; end if;
  perform _recalc(s.id);
  insert into audit_log (user_id, action, table_name, record_id, detail)
  values (me.id, 'sale_add_items', 'sales', s.id, jsonb_build_object('invoice', s.invoice_no, 'items', p_items, 'after_print', s.print_count > 0));
  select * into s from sales where id = p_sale;
  return s;
end $$;

-- Cancel one line (same day only). The line stays visible, struck through.
create or replace function cancel_sale_item(p_item bigint, p_reason text)
returns sales
language plpgsql security definer set search_path = public as $$
declare me profiles; it sale_items; s sales; pr products;
begin
  me := _staff();
  if nullif(trim(coalesce(p_reason,'')), '') is null then raise exception 'Alasan pembatalan wajib diisi.'; end if;
  select * into it from sale_items where id = p_item for update;
  if not found then raise exception 'Item id % tidak ada.', p_item; end if;
  if it.cancelled_at is not null then raise exception 'Item ini sudah dibatalkan.'; end if;
  select * into s from sales where id = it.sale_id for update;
  if s.status = 'void' then raise exception 'Invoice % sudah void.', s.invoice_no; end if;
  perform _same_day(s);
  update sale_items set cancelled_at = now(), cancelled_by = me.id, cancel_reason = trim(p_reason) where id = p_item;
  select * into pr from products where id = it.product_id;
  if not pr.is_service then
    insert into stock_moves (product_id, location_id, qty, kind, sale_item_id, reason, created_by)
    values (it.product_id, s.location_id, it.qty, 'sale_cancel', it.id, trim(p_reason), me.id);
  end if;
  if s.print_count > 0 then update sales set revision = revision + 1 where id = s.id; end if;
  perform _recalc(s.id);
  insert into audit_log (user_id, action, table_name, record_id, detail)
  values (me.id, 'sale_cancel_item', 'sales', s.id,
          jsonb_build_object('invoice', s.invoice_no, 'product', pr.name, 'qty', it.qty,
                             'line_total', it.line_total, 'reason', trim(p_reason), 'after_print', s.print_count > 0));
  select * into s from sales where id = s.id;
  return s;
end $$;

-- Record a payment. Any day (tempo invoices get paid weeks later).
create or replace function pay_sale(p_sale bigint, p_method text, p_amount numeric)
returns sales
language plpgsql security definer set search_path = public as $$
declare me profiles; s sales;
begin
  me := _staff();
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Invoice id % tidak ada.', p_sale; end if;
  if s.status = 'void' then raise exception 'Invoice % sudah void.', s.invoice_no; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Jumlah bayar harus lebih dari 0.'; end if;
  if s.total - s.paid_amount <= 0 then
    raise exception 'Invoice % sudah lunas (dibayar %, total %).', s.invoice_no, s.paid_amount, s.total;
  end if;
  if p_amount > s.total - s.paid_amount then
    raise exception 'Bayar % melebihi sisa tagihan %.', p_amount, s.total - s.paid_amount;
  end if;
  insert into payments (sale_id, amount, method, received_by) values (s.id, p_amount, p_method, me.id);
  perform _recalc(s.id);
  insert into audit_log (user_id, action, table_name, record_id, detail)
  values (me.id, 'sale_pay', 'sales', s.id, jsonb_build_object('invoice', s.invoice_no, 'method', p_method, 'amount', p_amount));
  select * into s from sales where id = s.id;
  return s;
end $$;

-- Give money back: after a line was cancelled on a paid invoice, or after a void.
create or replace function refund_sale(p_sale bigint, p_method text, p_amount numeric, p_reason text)
returns sales
language plpgsql security definer set search_path = public as $$
declare me profiles; s sales; v_max numeric;
begin
  me := _staff();
  if nullif(trim(coalesce(p_reason,'')), '') is null then raise exception 'Alasan pengembalian wajib diisi.'; end if;
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Invoice id % tidak ada.', p_sale; end if;
  v_max := case when s.status = 'void' then s.paid_amount else s.paid_amount - s.total end;
  if p_amount is null or p_amount <= 0 then raise exception 'Jumlah pengembalian harus lebih dari 0.'; end if;
  if p_amount > v_max then
    raise exception 'Pengembalian % melebihi kelebihan bayar %.', p_amount, greatest(v_max, 0);
  end if;
  insert into payments (sale_id, amount, method, received_by, notes)
  values (s.id, -p_amount, p_method, me.id, trim(p_reason));
  perform _recalc(s.id);
  insert into audit_log (user_id, action, table_name, record_id, detail)
  values (me.id, 'sale_refund', 'sales', s.id,
          jsonb_build_object('invoice', s.invoice_no, 'method', p_method, 'amount', p_amount, 'reason', trim(p_reason)));
  select * into s from sales where id = s.id;
  return s;
end $$;

-- Void a whole invoice (same day only). Number stays, so no gaps.
create or replace function void_sale(p_sale bigint, p_reason text)
returns sales
language plpgsql security definer set search_path = public as $$
declare me profiles; s sales;
begin
  me := _staff();
  if nullif(trim(coalesce(p_reason,'')), '') is null then raise exception 'Alasan void wajib diisi.'; end if;
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'Invoice id % tidak ada.', p_sale; end if;
  if s.status = 'void' then raise exception 'Invoice % sudah void.', s.invoice_no; end if;
  perform _same_day(s);
  insert into stock_moves (product_id, location_id, qty, kind, sale_item_id, reason, created_by)
  select i.product_id, s.location_id, i.qty, 'sale_cancel', i.id, 'void: ' || trim(p_reason), me.id
  from sale_items i join products p on p.id = i.product_id
  where i.sale_id = s.id and i.cancelled_at is null and not p.is_service;
  update sales set status = 'void', void_reason = trim(p_reason), voided_by = me.id, voided_at = now()
  where id = s.id returning * into s;
  insert into audit_log (user_id, action, table_name, record_id, detail)
  values (me.id, 'sale_void', 'sales', s.id,
          jsonb_build_object('invoice', s.invoice_no, 'total', s.total, 'paid', s.paid_amount, 'reason', trim(p_reason)));
  return s;
end $$;

create or replace function mark_printed(p_sale bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _staff();
  update sales set print_count = print_count + 1, last_printed_at = now() where id = p_sale;
end $$;

-- Owner's daily list: everything that changed money after the fact.
create or replace function review_list(p_from date, p_to date)
returns table (at timestamptz, kind text, invoice text, who text, detail text, amount numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if my_role() not in ('owner','admin') then raise exception 'Hanya owner/admin.'; end if;
  return query
  select i.cancelled_at, 'Item dibatalkan'::text, s.invoice_no, p.full_name,
         pr.name || ' ×' || i.qty || ' — ' || i.cancel_reason || case when s.print_count > 0 then ' (sudah dicetak)' else '' end,
         i.line_total
  from sale_items i join sales s on s.id = i.sale_id join products pr on pr.id = i.product_id
  left join profiles p on p.id = i.cancelled_by
  where i.cancelled_at is not null and s.business_date between p_from and p_to
  union all
  select s.voided_at, 'Invoice void', s.invoice_no, p.full_name, s.void_reason, s.total
  from sales s left join profiles p on p.id = s.voided_by
  where s.status = 'void' and s.business_date between p_from and p_to
  union all
  select i.added_at, 'Harga di bawah normal', s.invoice_no, p.full_name,
         pr.name || ': ' || i.unit_price || ' (normal ' || i.standard_price || ') — ' || coalesce(i.price_reason,''),
         (i.standard_price - i.unit_price) * i.qty
  from sale_items i join sales s on s.id = i.sale_id join products pr on pr.id = i.product_id
  left join profiles p on p.id = i.added_by
  where i.unit_price < i.standard_price and s.business_date between p_from and p_to
  union all
  select i.added_at, 'Ditambah setelah cetak', s.invoice_no, p.full_name,
         pr.name || ' ×' || i.qty, i.line_total
  from sale_items i join sales s on s.id = i.sale_id join products pr on pr.id = i.product_id
  left join profiles p on p.id = i.added_by
  where i.added_after_print and s.business_date between p_from and p_to
  union all
  select py.created_at, 'Uang dikembalikan', s.invoice_no, p.full_name, py.method || ' — ' || coalesce(py.notes,''), -py.amount
  from payments py join sales s on s.id = py.sale_id left join profiles p on p.id = py.received_by
  where py.amount < 0 and s.business_date between p_from and p_to
  union all
  select null::timestamptz, 'Lebih bayar belum dikembalikan', s.invoice_no, null::text,
         'dibayar ' || s.paid_amount || ', total ' || case when s.status = 'void' then 0 else s.total end,
         s.paid_amount - case when s.status = 'void' then 0 else s.total end
  from sales s
  where s.paid_amount > case when s.status = 'void' then 0 else s.total end
  union all
  select null::timestamptz, 'Stok minus', null::text, null::text,
         pr.name || ' di ' || l.code || ': ' || ps.qty, null::numeric
  from product_stock ps join products pr on pr.id = ps.product_id join locations l on l.id = ps.location_id
  where ps.qty < 0
  order by 1 desc nulls last;
end $$;

-- functions: logged-in staff only
revoke execute on all functions in schema public from public, anon;
grant execute on function price_for, create_sale, add_sale_items, cancel_sale_item,
  pay_sale, refund_sale, void_sale, mark_printed, review_list, my_role to authenticated;
