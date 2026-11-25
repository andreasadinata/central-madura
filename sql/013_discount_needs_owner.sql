-- v8_discount_needs_owner
-- A price below the list price typed by a non-owner is saved as PENDING.
-- The invoice cannot receive any payment until an owner approves it (Persetujuan).
-- Owner rejects -> the line goes back to the list price.
alter table sale_items add column if not exists discount_status text check (discount_status in ('pending','approved','rejected'));
alter table sale_items add column if not exists discount_decided_by uuid references profiles(id);
alter table sale_items add column if not exists discount_decided_at timestamptz;
create index if not exists sale_items_discount_pending on sale_items (sale_id) where discount_status = 'pending';

create or replace function _add_items(s sales, p_items jsonb, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare it jsonb; pr products; v_std numeric; v_src text; v_qty numeric; v_price numeric; v_reason text; v_id bigint;
        v_owner boolean := coalesce(my_role(), '') = 'owner';
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
    insert into sale_items (sale_id, product_id, qty, standard_price, unit_price, line_total,
                            price_source, price_reason, added_by, added_after_print,
                            discount_status, discount_decided_by, discount_decided_at)
    values (s.id, pr.id, v_qty, v_std, v_price, v_qty * v_price, v_src,
            case when v_price <> v_std then v_reason end, p_user, s.print_count > 0,
            case when v_price < v_std then (case when v_owner then 'approved' else 'pending' end) end,
            case when v_price < v_std and v_owner then p_user end,
            case when v_price < v_std and v_owner then now() end)
    returning id into v_id;
    if not pr.is_service then
      insert into stock_moves (product_id, location_id, qty, kind, sale_item_id, created_by)
      values (pr.id, s.location_id, -v_qty, 'sale', v_id, p_user);
    end if;
  end loop;
end $$;

-- Payment guard: wraps pay_sale_multi with a pending-discount check.
create or replace function _no_pending_discount(p_sale bigint) returns void
language plpgsql security definer set search_path = public as $$
declare n int; inv text;
begin
  select count(*) into n from sale_items where sale_id = p_sale and discount_status = 'pending' and cancelled_at is null;
  if n > 0 then
    select invoice_no into inv from sales where id = p_sale;
    raise exception 'Invoice % punya % harga turun yang belum disetujui owner. Minta owner setujui di Admin → Persetujuan, baru bisa bayar.', inv, n;
  end if;
end $$;

create or replace function trg_payment_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.amount > 0 then perform _no_pending_discount(new.sale_id); end if;
  return new;
end $$;
drop trigger if exists payment_guard on payments;
create trigger payment_guard before insert on payments for each row execute function trg_payment_guard();

create or replace function decide_discount(p_item bigint, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare it sale_items; s sales;
begin
  if coalesce(my_role(), '') <> 'owner' then raise exception 'Hanya owner yang bisa menyetujui harga turun.'; end if;
  select * into it from sale_items where id = p_item for update;
  if not found then raise exception 'Item id % tidak ada.', p_item; end if;
  if it.discount_status is distinct from 'pending' then raise exception 'Item ini sudah diputuskan (%).', it.discount_status; end if;
  select * into s from sales where id = it.sale_id;
  if p_approve then
    update sale_items set discount_status = 'approved', discount_decided_by = auth.uid(), discount_decided_at = now() where id = p_item;
  else
    update sale_items set discount_status = 'rejected', discount_decided_by = auth.uid(), discount_decided_at = now(),
      unit_price = standard_price, line_total = qty * standard_price where id = p_item;
    perform _recalc(it.sale_id);
  end if;
  insert into audit_log (user_id, action, table_name, record_id, detail)
  values (auth.uid(), case when p_approve then 'discount_approve' else 'discount_reject' end, 'sale_items', p_item,
          jsonb_build_object('invoice', s.invoice_no, 'standard', it.standard_price, 'asked', it.unit_price, 'qty', it.qty, 'reason', it.price_reason));
end $$;
revoke execute on function decide_discount(bigint, boolean) from public, anon;
grant execute on function decide_discount(bigint, boolean) to authenticated;
revoke execute on function _no_pending_discount(bigint) from public, anon, authenticated;

create or replace function pending_discounts() returns table (
  item_id bigint, sale_id bigint, invoice text, branch text, at timestamptz, cashier text, customer text,
  product text, qty numeric, standard_price numeric, unit_price numeric, reason text)
language sql stable security definer set search_path = public as $$
  select i.id, s.id, s.invoice_no, l.code, i.added_at, p.full_name, c.name, pr.name, i.qty, i.standard_price, i.unit_price, i.price_reason
  from sale_items i join sales s on s.id = i.sale_id join locations l on l.id = s.location_id
  left join profiles p on p.id = i.added_by left join customers c on c.id = s.customer_id
  join products pr on pr.id = i.product_id
  where i.discount_status = 'pending' and i.cancelled_at is null and s.status <> 'void'
    and my_role() in ('owner','admin')
  order by i.added_at
$$;
revoke execute on function pending_discounts() from public, anon;
grant execute on function pending_discounts() to authenticated;
