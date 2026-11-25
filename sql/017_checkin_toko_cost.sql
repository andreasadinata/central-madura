-- v12_checkin_toko_cost
-- A. Queue check-in by plate: ticket knows its customer + car (auto-matched by plate, or completed later).
-- B. A car can have several invoices (sales.queue_ticket_id). queue_tickets.sale_id = first invoice.
-- C. Invoice with jasa at a branch that uses the queue needs a queue car or a written reason (create_sale_q).
-- D. Tinjauan: car done without invoice, jasa without queue, toko prices, harga beli changes (review_more).
-- E. Customer flag is_toko (owner only): admin may lower a price down to harga beli without approval.
-- F. Harga beli per product (product_costs; owner/admin only, cashiers can't read). Updated by owner,
--    by Excel upload, and automatically by every Pembelian.

-- ── F. harga beli
create table product_costs (
  product_id bigint primary key references products(id),
  purchase_price numeric not null check (purchase_price >= 0),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
alter table product_costs enable row level security;
create policy mgr_read on product_costs for select to authenticated using (my_role() in ('owner','admin'));
create policy owner_insert on product_costs for insert to authenticated with check (my_role() = 'owner');
create policy owner_update on product_costs for update to authenticated using (my_role() = 'owner') with check (my_role() = 'owner');
grant select, insert, update on product_costs to authenticated;

insert into product_costs (product_id, purchase_price, updated_by)
select distinct on (pi.product_id) pi.product_id, pi.unit_cost, null
from purchase_items pi join purchases p on p.id = pi.purchase_id
where pi.qty > 0 order by pi.product_id, p.received_date desc, pi.id desc;

create or replace function trg_audit_product_costs() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.purchase_price is distinct from old.purchase_price then
    insert into audit_log (user_id, action, table_name, record_id, detail)
    values (auth.uid(), lower(tg_op), 'product_costs', new.product_id,
            jsonb_build_object('old', case when tg_op = 'UPDATE' then old.purchase_price end, 'new', new.purchase_price,
                               'source', coalesce(nullif(current_setting('app.cost_source', true), ''), 'diubah manual')));
  end if;
  return new;
end $$;
create trigger audit_product_costs after insert or update on product_costs for each row execute function trg_audit_product_costs();

-- every Pembelian line (qty > 0) becomes the product's harga beli
create or replace function trg_purchase_sets_cost() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.cost_source', 'Pembelian ' || coalesce((select doc_no from purchases where id = new.purchase_id), ''), true);
  insert into product_costs (product_id, purchase_price, updated_at, updated_by)
  values (new.product_id, new.unit_cost, now(), auth.uid())
  on conflict (product_id) do update set purchase_price = excluded.purchase_price, updated_at = now(), updated_by = auth.uid()
  where product_costs.purchase_price is distinct from excluded.purchase_price;
  perform set_config('app.cost_source', '', true);
  return new;
end $$;
create trigger purchase_sets_cost after insert on purchase_items for each row when (new.qty > 0) execute function trg_purchase_sets_cost();

-- ── E. toko flag
alter table customers add column if not exists is_toko boolean not null default false;
create or replace function guard_customer_pricing() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role(), '') <> 'owner' then
    if tg_op = 'INSERT' and (new.price_list_id is not null or new.allow_tempo or new.is_toko) then
      raise exception 'Hanya owner yang boleh memberi daftar harga khusus / izin tempo / status toko.';
    elsif tg_op = 'UPDATE' and (new.price_list_id is distinct from old.price_list_id or new.allow_tempo is distinct from old.allow_tempo
                                or new.is_toko is distinct from old.is_toko) then
      raise exception 'Hanya owner yang boleh mengubah daftar harga / izin tempo / status toko pelanggan.';
    end if;
  end if;
  return new;
end $$;

alter table sale_items drop constraint sale_items_discount_status_check;
alter table sale_items add constraint sale_items_discount_status_check check (discount_status in ('pending','approved','rejected','auto_toko'));

create or replace function _add_items(s sales, p_items jsonb, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare it jsonb; pr products; v_std numeric; v_src text; v_qty numeric; v_price numeric; v_reason text; v_id bigint;
        v_owner boolean := coalesce(my_role(), '') = 'owner';
        v_toko boolean := coalesce((select is_toko from customers where id = s.customer_id), false);
        v_floor numeric; v_status text;
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
      raise exception 'Harga % (%) di bawah normal (%). Tulis alasan dan siapa owner yang menyuruh.', pr.name, v_price, v_std;
    end if;
    if v_price <> v_std then v_src := 'manual'; end if;
    v_status := null;
    if v_price < v_std then
      if v_owner then v_status := 'approved';
      else
        v_floor := coalesce((select purchase_price from product_costs where product_id = pr.id),
                            (select unit_cost from product_last_cost where product_id = pr.id and location_id = s.location_id));
        v_status := case when v_toko and v_floor is not null and v_price >= v_floor then 'auto_toko' else 'pending' end;
      end if;
    end if;
    insert into sale_items (sale_id, product_id, qty, standard_price, unit_price, line_total,
                            price_source, price_reason, added_by, added_after_print,
                            discount_status, discount_decided_by, discount_decided_at)
    values (s.id, pr.id, v_qty, v_std, v_price, v_qty * v_price, v_src,
            case when v_price <> v_std then v_reason end, p_user, s.print_count > 0,
            v_status, case when v_status = 'approved' then p_user end, case when v_status in ('approved','auto_toko') then now() end)
    returning id into v_id;
    if not pr.is_service then
      insert into stock_moves (product_id, location_id, qty, kind, sale_item_id, created_by)
      values (pr.id, s.location_id, -v_qty, 'sale', v_id, p_user);
    end if;
  end loop;
end $$;

-- ── A/B. check-in links + many invoices per car
alter table queue_tickets add column customer_id bigint references customers(id);
alter table queue_tickets add column vehicle_id bigint references vehicles(id);
alter table sales add column queue_ticket_id bigint references queue_tickets(id);
alter table sales add column no_queue_reason text;
create index sales_queue_ticket on sales (queue_ticket_id) where queue_ticket_id is not null;
update sales s set queue_ticket_id = t.id from queue_tickets t where t.sale_id = s.id;

drop function q_add(text, text, bigint);
create function q_add(p_plate text, p_lane text, p_reserved bigint, p_vehicle bigint default null) returns queue_tickets
language plpgsql security definer set search_path = public as $$
declare me profiles; t queue_tickets; v_seq int; v vehicles; v_plate text; v_key text;
begin
  me := _q_staff();
  if coalesce(p_lane, '') not in ('Quick','General') then raise exception 'Jalur "%" tidak dikenal.', p_lane; end if;
  if p_reserved is not null and not exists (select 1 from mechanics where id = p_reserved and location_id = me.location_id and is_active) then
    raise exception 'Mekanik id % tidak ada di cabang ini.', p_reserved;
  end if;
  if p_vehicle is not null then
    select * into v from vehicles where id = p_vehicle and is_active;
    if not found then raise exception 'Kendaraan id % tidak ada.', p_vehicle; end if;
    v_plate := v.plate;
  else
    v_plate := upper(trim(coalesce(p_plate, '')));
    if v_plate = '' then raise exception 'Plat nomor wajib diisi.'; end if;
    v_key := upper(regexp_replace(v_plate, '[^A-Za-z0-9]', '', 'g'));
    if (select count(*) from vehicles where is_active and plate_key = v_key) = 1 then   -- known plate: link automatically
      select * into v from vehicles where is_active and plate_key = v_key;
    end if;
  end if;
  perform _q_tick(me.location_id);
  if exists (select 1 from queue_tickets where location_id = me.location_id and day = _q_today() and status in ('Waiting','Serving')
             and plate_key = upper(regexp_replace(v_plate, '[^A-Za-z0-9]', '', 'g'))) then
    raise exception 'Plat % sudah ada di antrian yang belum selesai.', v_plate;
  end if;
  perform pg_advisory_xact_lock(me.location_id);
  select coalesce(max(seq), 0) + 1 into v_seq from queue_tickets where location_id = me.location_id and day = _q_today() and lane = p_lane;
  insert into queue_tickets (location_id, day, lane, seq, code, plate, reserved_mechanic_id, vehicle_id, customer_id)
  values (me.location_id, _q_today(), p_lane, v_seq,
          case p_lane when 'Quick' then 'A' else 'B' end || lpad(v_seq::text, 2, '0'),
          v_plate, p_reserved, v.id, v.customer_id)
  returning * into t;
  perform _q_log(me.location_id, 'add', t.id, null, to_jsonb(t));
  perform _q_tick(me.location_id);
  return t;
end $$;

create or replace function q_set_vehicle(p_ticket bigint, p_vehicle bigint) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; t queue_tickets; v vehicles;
begin
  me := _q_staff();
  t := _q_ticket(p_ticket, me);
  if t.status = 'Cancelled' then raise exception 'Antrian % sudah batal.', t.code; end if;
  select * into v from vehicles where id = p_vehicle and is_active;
  if not found then raise exception 'Kendaraan id % tidak ada.', p_vehicle; end if;
  update queue_tickets set vehicle_id = v.id, customer_id = v.customer_id, plate = v.plate where id = t.id;
  perform _q_log(me.location_id, 'set_vehicle', t.id, null, jsonb_build_object('vehicle', v.id, 'old_plate', t.plate, 'plate', v.plate));
end $$;

create or replace function q_link_sale(p_ticket bigint, p_sale bigint) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; t queue_tickets; s sales;
begin
  me := _q_staff();
  t := _q_ticket(p_ticket, me);
  if t.status = 'Cancelled' then raise exception 'Antrian % sudah batal.', t.code; end if;
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Invoice id % tidak ada.', p_sale; end if;
  if s.location_id <> t.location_id then raise exception 'Invoice % dan antrian % beda cabang.', s.invoice_no, t.code; end if;
  if s.queue_ticket_id is not null and s.queue_ticket_id <> t.id then raise exception 'Invoice % sudah tersambung ke antrian lain.', s.invoice_no; end if;
  if t.vehicle_id is not null and s.vehicle_id is not null and t.vehicle_id <> s.vehicle_id then
    raise exception 'Mobil di invoice % (%) beda dengan mobil antrian % (%).', s.invoice_no, s.plate, t.code, t.plate;
  end if;
  update sales set queue_ticket_id = t.id, queue_ref = t.code where id = p_sale;
  update queue_tickets set sale_id = coalesce(sale_id, p_sale),
    vehicle_id = coalesce(vehicle_id, s.vehicle_id),
    customer_id = case when vehicle_id is null and s.vehicle_id is not null then s.customer_id else customer_id end
  where id = t.id;
  perform _q_log(me.location_id, 'link_sale', t.id, null, jsonb_build_object('sale', p_sale, 'invoice', s.invoice_no));
end $$;

drop function q_for_cashier();
create function q_for_cashier() returns table (id bigint, code text, plate text, plate_key text, status text, mechanics text, day date,
                                               vehicle_id bigint, customer_id bigint, invoices bigint)
language sql stable security definer set search_path = public as $$
  select t.id, t.code, t.plate, t.plate_key, t.status,
         (select string_agg(m.name, ', ' order by a.assigned_at) from queue_assignments a join mechanics m on m.id = a.mechanic_id
           where a.ticket_id = t.id and a.removed_at is null), t.day, t.vehicle_id, t.customer_id,
         (select count(*) from sales s where s.queue_ticket_id = t.id and s.status <> 'void')
  from queue_tickets t
  where t.location_id = _my_loc() and t.status <> 'Cancelled' and t.day >= _q_today() - 1
  order by (select count(*) from sales s where s.queue_ticket_id = t.id and s.status <> 'void') > 0, t.day desc,
           case t.status when 'Done' then 0 when 'Serving' then 1 when 'Unfinished' then 2 else 3 end, t.created_at
$$;

-- board: customer, car, completeness, all invoices of the car
do $$ declare d text; begin
  d := pg_get_functiondef('q_board()'::regprocedure);
  d := replace(d, $r$'invoice', (select invoice_no from sales where id = t.sale_id),$r$,
    $r$'invoice', (select string_agg(invoice_no, ', ' order by id) from sales where queue_ticket_id = t.id and status <> 'void'),
        'customer', (select name from customers where id = t.customer_id),
        'car', (select coalesce(cm.brand || ' ' || cm.model, '') || coalesce(' · ' || nullif(v.color, ''), '') from vehicles v left join car_models cm on cm.id = v.car_model_id where v.id = t.vehicle_id),
        'vehicle_id', t.vehicle_id, 'customer_id', t.customer_id,
        'incomplete', t.vehicle_id is null or exists (select 1 from vehicles v join customers c on c.id = v.customer_id where v.id = t.vehicle_id
                        and (nullif(trim(coalesce(c.phone, '')), '') is null or nullif(trim(coalesce(c.address, '')), '') is null or nullif(trim(coalesce(v.color, '')), '') is null)),$r$);
  if position('incomplete' in d) = 0 then raise exception 'q_board patch failed'; end if;
  execute d;
end $$;

-- ── C. invoice creation through the queue rule
create or replace function create_sale_q(p_customer bigint, p_vehicle bigint, p_plate text, p_items jsonb, p_tempo boolean,
                                         p_ticket bigint default null, p_no_queue_reason text default null) returns sales
language plpgsql security definer set search_path = public as $$
declare me profiles; s sales; v_service boolean; v_queue boolean;
begin
  me := _staff();
  select exists (select 1 from jsonb_array_elements(p_items) e join products p on p.id = (e->>'product_id')::bigint where p.is_service) into v_service;
  v_queue := exists (select 1 from mechanics where location_id = me.location_id and is_active);
  if v_service and v_queue and p_ticket is null and nullif(trim(coalesce(p_no_queue_reason, '')), '') is null then
    raise exception 'Ada jasa di invoice ini: pilih mobilnya dari Antrian, atau tulis alasan kenapa tanpa antrian.';
  end if;
  s := create_sale(p_customer, p_vehicle, p_plate, p_items, p_tempo);
  if p_ticket is not null then
    perform q_link_sale(p_ticket, s.id);
  elsif v_service and v_queue then
    update sales set no_queue_reason = trim(p_no_queue_reason) where id = s.id;
  end if;
  select * into s from sales where id = s.id;
  return s;
end $$;
revoke execute on function create_sale_q(bigint, bigint, text, jsonb, boolean, bigint, text) from public, anon;
grant execute on function create_sale_q(bigint, bigint, text, jsonb, boolean, bigint, text) to authenticated;
revoke execute on function create_sale(bigint, bigint, text, jsonb, boolean) from public, anon, authenticated;
revoke execute on function q_set_vehicle(bigint, bigint) from public, anon;
grant execute on function q_set_vehicle(bigint, bigint) to authenticated;
revoke execute on function q_add(text, text, bigint, bigint) from public, anon;
grant execute on function q_add(text, text, bigint, bigint) to authenticated;
revoke execute on function q_for_cashier() from public, anon;
grant execute on function q_for_cashier() to authenticated;

-- ── D. Tinjauan extras
create or replace function review_more(p_from date, p_to date)
returns table (at timestamptz, kind text, invoice text, who text, detail text, amount numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_loc bigint := case when my_role() = 'owner' then null else _my_loc() end;
begin
  if my_role() not in ('owner','admin') then raise exception 'Hanya owner/admin.'; end if;
  return query
  select t.done_at, 'Mobil selesai tanpa invoice'::text, t.code, l.code::text,
         t.plate || coalesce(' · ' || (select name from customers where id = t.customer_id), '') || ' · mekanik: ' ||
           coalesce((select string_agg(m.name, ', ') from queue_assignments a join mechanics m on m.id = a.mechanic_id where a.ticket_id = t.id and a.removed_at is null), '-'),
         null::numeric
  from queue_tickets t join locations l on l.id = t.location_id
  where t.status = 'Done' and not exists (select 1 from sales s where s.queue_ticket_id = t.id and s.status <> 'void')
    and t.day between p_from and p_to and (v_loc is null or t.location_id = v_loc)
  union all
  select s.opened_at, 'Jasa tanpa antrian', s.invoice_no, p.full_name, 'alasan: ' || s.no_queue_reason, s.total
  from sales s left join profiles p on p.id = s.cashier_id
  where s.no_queue_reason is not null and s.business_date between p_from and p_to and (v_loc is null or s.location_id = v_loc)
  union all
  select i.added_at, 'Harga toko (grosir)', s.invoice_no, p.full_name,
         c.name || ': ' || pr.name || ' ×' || trim(to_char(i.qty, 'FM999G999')) || ' @ ' || to_char(i.unit_price, 'FM999G999G999')
           || ' (normal ' || to_char(i.standard_price, 'FM999G999G999') || ') — ' || coalesce(i.price_reason, ''),
         (i.unit_price - i.standard_price) * i.qty
  from sale_items i join sales s on s.id = i.sale_id join products pr on pr.id = i.product_id
  left join customers c on c.id = s.customer_id left join profiles p on p.id = i.added_by
  where i.discount_status = 'auto_toko' and i.cancelled_at is null
    and (i.added_at at time zone 'Asia/Jakarta')::date between p_from and p_to and (v_loc is null or s.location_id = v_loc)
  union all
  select a.at, 'Harga beli berubah', null::text, p.full_name,
         coalesce(pr.name, 'produk ' || a.record_id) || ': ' || coalesce(to_char((a.detail->>'old')::numeric, 'FM999G999G999'), 'baru')
           || ' → ' || to_char((a.detail->>'new')::numeric, 'FM999G999G999') || ' (' || coalesce(a.detail->>'source', '') || ')',
         null::numeric
  from audit_log a left join profiles p on p.id = a.user_id left join products pr on pr.id = a.record_id
  where a.table_name = 'product_costs' and (a.at at time zone 'Asia/Jakarta')::date between p_from and p_to;
end $$;
revoke execute on function review_more(date, date) from public, anon;
grant execute on function review_more(date, date) to authenticated;

-- ── Excel upload: purchase price + Umum tiers for many products at once (owner only, all or nothing)
create or replace function bulk_set_prices(p_rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare r record; pr products; v_list bigint; v numeric; n int := 0; v_new jsonb; v_old jsonb;
begin
  if coalesce(my_role(), '') <> 'owner' then raise exception 'Hanya owner yang bisa mengubah harga.'; end if;
  select id into v_list from price_lists where is_default;
  for r in select value, ordinality from jsonb_array_elements(p_rows) with ordinality loop
    select * into pr from products where upper(sku) = upper(trim(r.value->>'sku'));
    if not found then raise exception 'Baris %: SKU "%" tidak ada.', r.ordinality, r.value->>'sku'; end if;
    if nullif(r.value->>'purchase_price', '') is not null then
      v := (r.value->>'purchase_price')::numeric;
      if v < 0 then raise exception 'Baris % (%): harga beli tidak boleh minus.', r.ordinality, pr.name; end if;
      perform set_config('app.cost_source', 'upload Excel', true);
      insert into product_costs (product_id, purchase_price, updated_at, updated_by) values (pr.id, v, now(), auth.uid())
      on conflict (product_id) do update set purchase_price = excluded.purchase_price, updated_at = now(), updated_by = auth.uid()
      where product_costs.purchase_price is distinct from excluded.purchase_price;
      perform set_config('app.cost_source', '', true);
    end if;
    if jsonb_typeof(r.value->'tiers') = 'array' and jsonb_array_length(r.value->'tiers') > 0 then
      select jsonb_agg(jsonb_build_array((e->>'min_qty')::numeric, (e->>'price')::numeric) order by (e->>'min_qty')::numeric)
        into v_new from jsonb_array_elements(r.value->'tiers') e;
      if exists (select 1 from jsonb_array_elements(v_new) e where (e->>0)::numeric <= 0 or (e->>1)::numeric < 0) then
        raise exception 'Baris % (%): qty harus > 0 dan harga ≥ 0.', r.ordinality, pr.name; end if;
      if not exists (select 1 from jsonb_array_elements(v_new) e where (e->>0)::numeric = 1) then
        raise exception 'Baris % (%): harga mulai qty 1 wajib ada.', r.ordinality, pr.name; end if;
      if (select count(distinct (e->>0)::numeric) from jsonb_array_elements(v_new) e) <> jsonb_array_length(v_new) then
        raise exception 'Baris % (%): ada qty yang sama dua kali.', r.ordinality, pr.name; end if;
      select coalesce(jsonb_agg(jsonb_build_array(min_qty, price) order by min_qty), '[]') into v_old
        from price_tiers where product_id = pr.id and price_list_id = v_list;
      if v_old is distinct from v_new then
        delete from price_tiers where product_id = pr.id and price_list_id = v_list;
        insert into price_tiers (product_id, price_list_id, min_qty, price)
        select pr.id, v_list, (e->>0)::numeric, (e->>1)::numeric from jsonb_array_elements(v_new) e;
      end if;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function bulk_set_prices(jsonb) from public, anon;
grant execute on function bulk_set_prices(jsonb) to authenticated;

-- v12b_checkin_plate_spelling: q_add stores the registered plate spelling when it auto-matches a car.
