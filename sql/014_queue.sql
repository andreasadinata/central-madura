-- v9_queue : queue + mechanics, per branch. Replaces the Google-Sheets queue.
-- Rules kept from the old system: Quick (A01..) / General (B01..) lanes, strict order
-- (a car can only be taken when no OLDER unreserved car waits in its lane), max 2 jobs per
-- mechanic, 1 break of 1 hour per day, slow-response flags with a required reason
-- (one reason covers flags chained within 30 minutes).
-- Changed: grace 7 minutes (was 10). Friday: automatic Jumatan break 11:00-12:30 for everyone,
-- no regular break on Friday. Grace clock starts when the mechanic became free (fixes the
-- old bug where a reserved car flagged its mechanic while he was still busy on another car).
-- New: pause "Beli barang di luar" (paused minutes are not counted as work).
-- Each day starts clean: cars still open from an earlier day become 'Unfinished' (kept in
-- history, not counted as work). A ticket can be linked to an invoice. Full history kept.

create table mechanics (
  id bigserial primary key,
  location_id bigint not null references locations(id),
  name text not null check (trim(name) <> ''),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);
create unique index mechanics_loc_name on mechanics (location_id, lower(trim(name)));

create table mechanic_days (
  id bigserial primary key,
  mechanic_id bigint not null references mechanics(id),
  location_id bigint not null references locations(id),
  day date not null,
  role text not null check (role in ('Quick','General')),
  status text not null check (status in ('Available','Busy','Break','GoneHome')),
  available_since timestamptz,
  activated_at timestamptz not null default now(),
  break_start timestamptz,
  break_end timestamptz,
  gone_home_at timestamptz,
  unique (mechanic_id, day)
);

create table queue_tickets (
  id bigserial primary key,
  location_id bigint not null references locations(id),
  day date not null,
  lane text not null check (lane in ('Quick','General')),
  seq int not null,
  code text not null,
  plate text not null check (trim(plate) <> ''),
  plate_key text generated always as (upper(regexp_replace(plate, '[^A-Za-z0-9]', '', 'g'))) stored,
  reserved_mechanic_id bigint references mechanics(id),
  status text not null default 'Waiting' check (status in ('Waiting','Serving','Done','Cancelled','Unfinished')),
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  taken_at timestamptz,
  done_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  sale_id bigint references sales(id),
  unique (location_id, day, lane, seq)
);
create index queue_tickets_open on queue_tickets (location_id) where status in ('Waiting','Serving');
create unique index queue_tickets_sale on queue_tickets (sale_id) where sale_id is not null;

create table queue_assignments (
  id bigserial primary key,
  ticket_id bigint not null references queue_tickets(id) on delete cascade,
  mechanic_id bigint not null references mechanics(id),
  assigned_at timestamptz not null default now(),
  removed_at timestamptz
);
create index queue_assign_ticket on queue_assignments (ticket_id);
create index queue_assign_mech on queue_assignments (mechanic_id);

create table queue_pauses (
  id bigserial primary key,
  ticket_id bigint not null references queue_tickets(id) on delete cascade,
  reason text not null default 'Beli barang di luar',
  started_at timestamptz not null default now(),
  started_by uuid default auth.uid(),
  ended_at timestamptz,
  ended_by uuid
);
create unique index queue_pause_open on queue_pauses (ticket_id) where ended_at is null;

create table queue_flags (
  id bigserial primary key,
  location_id bigint not null references locations(id),
  ticket_id bigint not null references queue_tickets(id) on delete cascade,
  mechanic_id bigint not null references mechanics(id),
  clock_start timestamptz not null,
  flagged_at timestamptz not null,
  reason text,
  reason_by uuid,
  reason_at timestamptz,
  unique (ticket_id, mechanic_id)
);

create table queue_log (
  id bigserial primary key,
  location_id bigint not null references locations(id),
  at timestamptz not null default now(),
  user_id uuid default auth.uid(),
  action text not null,
  ticket_id bigint,
  mechanic_id bigint,
  detail jsonb,
  undone_at timestamptz
);
create index queue_log_loc on queue_log (location_id, at desc);

alter table locations add column if not exists display_token text not null default replace(gen_random_uuid()::text, '-', '');

-- ── RLS: read for staff of that branch (owner: all). Writes only through the functions below,
--    except the mechanic master list (owner/admin).
alter table mechanics enable row level security;
alter table mechanic_days enable row level security;
alter table queue_tickets enable row level security;
alter table queue_assignments enable row level security;
alter table queue_pauses enable row level security;
alter table queue_flags enable row level security;
alter table queue_log enable row level security;

create or replace function _my_loc() returns bigint language sql stable security definer set search_path = public as
$$ select location_id from profiles where id = auth.uid() and is_active $$;

create policy read_branch on mechanics for select to authenticated using (my_role() = 'owner' or location_id = _my_loc());
create policy mgr_insert on mechanics for insert to authenticated with check (my_role() = 'owner' or (my_role() = 'admin' and location_id = _my_loc()));
create policy mgr_update on mechanics for update to authenticated using (my_role() = 'owner' or (my_role() = 'admin' and location_id = _my_loc()))
  with check (my_role() = 'owner' or (my_role() = 'admin' and location_id = _my_loc()));
create policy read_branch on mechanic_days for select to authenticated using (my_role() = 'owner' or location_id = _my_loc());
create policy read_branch on queue_tickets for select to authenticated using (my_role() = 'owner' or location_id = _my_loc());
create policy read_branch on queue_assignments for select to authenticated using (exists (select 1 from queue_tickets t where t.id = ticket_id and (my_role() = 'owner' or t.location_id = _my_loc())));
create policy read_branch on queue_pauses for select to authenticated using (exists (select 1 from queue_tickets t where t.id = ticket_id and (my_role() = 'owner' or t.location_id = _my_loc())));
create policy read_branch on queue_flags for select to authenticated using (my_role() = 'owner' or location_id = _my_loc());
create policy read_branch on queue_log for select to authenticated using (my_role() in ('owner','admin') and (my_role() = 'owner' or location_id = _my_loc()));
grant select on mechanics, mechanic_days, queue_tickets, queue_assignments, queue_pauses, queue_flags, queue_log to authenticated;
grant insert, update on mechanics to authenticated;
grant usage on sequence mechanics_id_seq to authenticated;

-- ── time helpers (all business time is Asia/Jakarta)
create or replace function _q_today() returns date language sql stable as $$ select (now() at time zone 'Asia/Jakarta')::date $$;
create or replace function _q_grace() returns interval language sql immutable as $$ select interval '7 minutes' $$;
-- Jumatan window of the Friday that contains ts (null when ts is not a Friday)
create or replace function _jumatan(ts timestamptz, out j_start timestamptz, out j_end timestamptz)
language sql stable as $$
  select case when extract(isodow from ts at time zone 'Asia/Jakarta') = 5
              then ((ts at time zone 'Asia/Jakarta')::date + time '11:00') at time zone 'Asia/Jakarta' end,
         case when extract(isodow from ts at time zone 'Asia/Jakarta') = 5
              then ((ts at time zone 'Asia/Jakarta')::date + time '12:30') at time zone 'Asia/Jakarta' end
$$;
create or replace function _in_jumatan(ts timestamptz) returns boolean language sql stable as $$
  select coalesce(ts >= j.j_start and ts < j.j_end, false) from _jumatan(ts) j $$;
-- minutes of [a,b) overlapping [c,d)
create or replace function _overlap_min(a timestamptz, b timestamptz, c timestamptz, d timestamptz) returns numeric
language sql immutable as $$
  select case when a is null or b is null or c is null or d is null then 0
              else greatest(0, extract(epoch from (least(b, d) - greatest(a, c))) / 60) end $$;
-- jumatan minutes inside [a,b) (a job can span several days)
create or replace function _jumatan_min(a timestamptz, b timestamptz) returns numeric
language sql stable as $$
  select coalesce(sum(_overlap_min(a, b, j.j_start, j.j_end)), 0)
  from generate_series((a at time zone 'Asia/Jakarta')::date, (b at time zone 'Asia/Jakarta')::date, interval '1 day') d,
       lateral _jumatan((d::date + time '12:00') at time zone 'Asia/Jakarta') j
  where a is not null and b is not null and j.j_start is not null $$;

-- ── staff + branch check
create or replace function _q_staff() returns profiles
language plpgsql stable security definer set search_path = public as $$
declare me profiles;
begin
  me := _staff();
  if me.location_id is null then raise exception 'Akun % belum punya cabang.', me.full_name; end if;
  return me;
end $$;

create or replace function _q_ticket(p_ticket bigint, me profiles) returns queue_tickets
language plpgsql security definer set search_path = public as $$
declare t queue_tickets;
begin
  select * into t from queue_tickets where id = p_ticket for update;
  if not found then raise exception 'Antrian id % tidak ada.', p_ticket; end if;
  if t.location_id <> me.location_id then raise exception 'Antrian % milik cabang lain.', t.code; end if;
  return t;
end $$;

-- active jobs of a mechanic (today)
create or replace function _q_jobs(p_mech bigint) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(t.code order by t.taken_at), '{}')
  from queue_assignments a join queue_tickets t on t.id = a.ticket_id
  where a.mechanic_id = p_mech and a.removed_at is null and t.status = 'Serving' and t.day = _q_today() $$;

-- set Available/Busy from job count; Break/GoneHome untouched
create or replace function _q_refresh_mech(p_mech bigint) returns void
language plpgsql security definer set search_path = public as $$
declare d mechanic_days; n int;
begin
  select * into d from mechanic_days where mechanic_id = p_mech and day = _q_today() for update;
  if not found or d.status in ('Break','GoneHome') then return; end if;
  n := cardinality(_q_jobs(p_mech));
  if n > 0 and d.status <> 'Busy' then
    update mechanic_days set status = 'Busy' where id = d.id;
  elsif n = 0 and d.status <> 'Available' then
    update mechanic_days set status = 'Available', available_since = now() where id = d.id;
  end if;
end $$;

create or replace function _q_log(p_loc bigint, p_action text, p_ticket bigint, p_mech bigint, p_detail jsonb) returns void
language sql security definer set search_path = public as $$
  insert into queue_log (location_id, action, ticket_id, mechanic_id, detail) values (p_loc, p_action, p_ticket, p_mech, p_detail) $$;

-- ── slow-response flags. Called at the start of every queue action and by the board.
-- A mechanic is flagged for a waiting car when he has been Available (not on break, not in
-- Jumatan) for 7 minutes while that car waited in his lane and the car was not reserved for
-- someone else. The clock starts at the later of: car arrived, mechanic became free.
create or replace function _q_tick(p_loc bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_start timestamptz; j record;
begin
  -- new day = clean list: close what is left from earlier days
  update queue_pauses p set ended_at = ((t.day + 1)::timestamp at time zone 'Asia/Jakarta'), ended_by = null
    from queue_tickets t where p.ticket_id = t.id and p.ended_at is null
      and t.location_id = p_loc and t.day < _q_today() and t.status in ('Waiting','Serving');
  update queue_tickets set status = 'Unfinished', cancel_reason = 'Belum selesai saat tutup hari'
   where location_id = p_loc and day < _q_today() and status in ('Waiting','Serving');
  for r in
    select t.id tid, t.created_at, d.mechanic_id, d.available_since
    from queue_tickets t
    join mechanic_days d on d.location_id = t.location_id and d.day = _q_today()
                        and d.role = t.lane and d.status = 'Available'
    where t.location_id = p_loc and t.status = 'Waiting'
      and (t.reserved_mechanic_id is null or t.reserved_mechanic_id = d.mechanic_id)
      and not exists (select 1 from queue_flags f where f.ticket_id = t.id and f.mechanic_id = d.mechanic_id)
  loop
    v_start := greatest(r.created_at, coalesce(r.available_since, r.created_at));
    select * into j from _jumatan(now());
    if j.j_start is not null and v_start < j.j_end and now() >= j.j_start then
      v_start := greatest(v_start, j.j_end);          -- nobody is flagged for Jumatan time
    end if;
    if now() - v_start >= _q_grace() then
      insert into queue_flags (location_id, ticket_id, mechanic_id, clock_start, flagged_at)
      values (p_loc, r.tid, r.mechanic_id, v_start, v_start + _q_grace())
      on conflict do nothing;
    end if;
  end loop;
end $$;

-- ── board (Queue Control screen)
create or replace function q_board() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_loc bigint; res jsonb;
begin
  me := _q_staff(); v_loc := me.location_id;
  perform _q_tick(v_loc);
  select jsonb_build_object(
    'branch', (select code from locations where id = v_loc),
    'today', _q_today(),
    'now', now(),
    'is_friday', extract(isodow from now() at time zone 'Asia/Jakarta') = 5,
    'jumatan_now', _in_jumatan(now()),
    'grace_min', extract(epoch from _q_grace()) / 60,
    'mechanics', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'name', m.name, 'role', d.role,
        'status', coalesce(d.status, 'Inactive'),
        'available_since', d.available_since, 'break_start', d.break_start, 'break_end', d.break_end,
        'jobs', _q_jobs(m.id)) order by m.name)
      from mechanics m left join mechanic_days d on d.mechanic_id = m.id and d.day = _q_today()
      where m.location_id = v_loc and m.is_active), '[]'),
    'tickets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id, 'code', t.code, 'lane', t.lane, 'plate', t.plate, 'status', t.status, 'day', t.day,
        'created_at', t.created_at, 'taken_at', t.taken_at, 'done_at', t.done_at, 'cancel_reason', t.cancel_reason,
        'reserved_id', t.reserved_mechanic_id, 'reserved', rm.name, 'sale_id', t.sale_id,
        'invoice', (select invoice_no from sales where id = t.sale_id),
        'paused_since', (select started_at from queue_pauses p where p.ticket_id = t.id and p.ended_at is null),
        'paused_min', (select coalesce(sum(extract(epoch from coalesce(p.ended_at, now()) - p.started_at)) / 60, 0)
                       from queue_pauses p where p.ticket_id = t.id),
        'mechanics', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name) order by a.assigned_at)
                       from queue_assignments a join mechanics m on m.id = a.mechanic_id
                       where a.ticket_id = t.id and a.removed_at is null), '[]')
      ) order by t.created_at)
      from queue_tickets t left join mechanics rm on rm.id = t.reserved_mechanic_id
      where t.location_id = v_loc and t.day = _q_today()), '[]'),
    'flags', coalesce((
      select jsonb_agg(jsonb_build_object('id', f.id, 'mechanic_id', f.mechanic_id, 'mechanic', m.name,
        'ticket_id', f.ticket_id, 'code', t.code, 'plate', t.plate, 'flagged_at', f.flagged_at, 'reason', f.reason) order by f.flagged_at)
      from queue_flags f join mechanics m on m.id = f.mechanic_id join queue_tickets t on t.id = f.ticket_id
      where f.location_id = v_loc and (f.flagged_at at time zone 'Asia/Jakarta')::date = _q_today()), '[]')
  ) into res;
  return res;
end $$;

-- ── cars
create or replace function q_add(p_plate text, p_lane text, p_reserved bigint) returns queue_tickets
language plpgsql security definer set search_path = public as $$
declare me profiles; t queue_tickets; v_seq int;
begin
  me := _q_staff();
  if coalesce(p_lane, '') not in ('Quick','General') then raise exception 'Jalur "%" tidak dikenal.', p_lane; end if;
  if nullif(trim(coalesce(p_plate, '')), '') is null then raise exception 'Plat nomor wajib diisi.'; end if;
  if p_reserved is not null and not exists (select 1 from mechanics where id = p_reserved and location_id = me.location_id and is_active) then
    raise exception 'Mekanik id % tidak ada di cabang ini.', p_reserved;
  end if;
  perform _q_tick(me.location_id);
  if exists (select 1 from queue_tickets where location_id = me.location_id and day = _q_today() and status in ('Waiting','Serving')
             and plate_key = upper(regexp_replace(p_plate, '[^A-Za-z0-9]', '', 'g'))) then
    raise exception 'Plat % sudah ada di antrian yang belum selesai.', upper(trim(p_plate));
  end if;
  perform pg_advisory_xact_lock(me.location_id);
  select coalesce(max(seq), 0) + 1 into v_seq from queue_tickets where location_id = me.location_id and day = _q_today() and lane = p_lane;
  insert into queue_tickets (location_id, day, lane, seq, code, plate, reserved_mechanic_id)
  values (me.location_id, _q_today(), p_lane, v_seq,
          case p_lane when 'Quick' then 'A' else 'B' end || lpad(v_seq::text, 2, '0'),
          upper(trim(p_plate)), p_reserved)
  returning * into t;
  perform _q_log(me.location_id, 'add', t.id, null, to_jsonb(t));
  perform _q_tick(me.location_id);
  return t;
end $$;

create or replace function _q_check_mechs(me profiles, t queue_tickets, p_mechs bigint[], p_is_edit boolean) returns void
language plpgsql security definer set search_path = public as $$
declare mid bigint; d mechanic_days; m mechanics; n int; v_open int;
begin
  if p_mechs is null or cardinality(p_mechs) = 0 then raise exception 'Pilih minimal satu mekanik.'; end if;
  foreach mid in array p_mechs loop
    select * into m from mechanics where id = mid;
    if not found or m.location_id <> me.location_id then raise exception 'Mekanik id % tidak ada di cabang ini.', mid; end if;
    select * into d from mechanic_days where mechanic_id = mid and day = _q_today();
    if not found then raise exception '% belum diaktifkan hari ini.', m.name; end if;
    if exists (select 1 from queue_assignments a where a.ticket_id = t.id and a.mechanic_id = mid and a.removed_at is null) then
      continue;   -- already on this car
    end if;
    if d.role <> t.lane then raise exception '% hari ini di jalur %, mobil % di jalur %.', m.name, d.role, t.code, t.lane; end if;
    if not p_is_edit and d.status in ('Break','GoneHome') then raise exception '% sedang %.', m.name, case d.status when 'Break' then 'istirahat' else 'pulang' end; end if;
    if not p_is_edit and _in_jumatan(now()) then raise exception 'Sedang Jumatan (11:00–12:30).'; end if;
    n := cardinality(_q_jobs(mid));
    if n >= 2 then raise exception '% sudah pegang 2 mobil (%).', m.name, array_to_string(_q_jobs(mid), ', '); end if;
    select count(*) into v_open from queue_flags where mechanic_id = mid and reason is null
      and (flagged_at at time zone 'Asia/Jakarta')::date = _q_today();
    if v_open > 0 then raise exception '% punya % tanda lambat yang belum dijelaskan. Isi alasannya dulu.', m.name, v_open; end if;
  end loop;
end $$;

create or replace function q_take(p_ticket bigint, p_mechs bigint[]) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; t queue_tickets; older text; mid bigint;
begin
  me := _q_staff();
  perform _q_tick(me.location_id);
  t := _q_ticket(p_ticket, me);
  if t.status <> 'Waiting' then raise exception 'Mobil % statusnya %, bukan Waiting.', t.code, t.status; end if;
  select code into older from queue_tickets
   where location_id = t.location_id and lane = t.lane and status = 'Waiting' and reserved_mechanic_id is null
     and (created_at, id) < (t.created_at, t.id) order by created_at, id limit 1;
  if older is not null then raise exception 'Urutan: % harus diambil dulu sebelum %.', older, t.code; end if;
  perform _q_check_mechs(me, t, p_mechs, false);
  update queue_tickets set status = 'Serving', taken_at = now() where id = t.id;
  foreach mid in array p_mechs loop
    insert into queue_assignments (ticket_id, mechanic_id) values (t.id, mid);
    perform _q_refresh_mech(mid);
  end loop;
  perform _q_log(me.location_id, 'take', t.id, null, jsonb_build_object('mechanics', p_mechs));
end $$;

create or replace function q_edit_mechs(p_ticket bigint, p_mechs bigint[]) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; t queue_tickets; a record; mid bigint; v_old bigint[];
begin
  me := _q_staff();
  t := _q_ticket(p_ticket, me);
  if t.status <> 'Serving' then raise exception 'Mekanik hanya bisa diubah saat mobil % sedang dikerjakan.', t.code; end if;
  select array_agg(mechanic_id) into v_old from queue_assignments where ticket_id = t.id and removed_at is null;
  perform _q_check_mechs(me, t, p_mechs, true);
  for a in select * from queue_assignments where ticket_id = t.id and removed_at is null and not (mechanic_id = any(p_mechs)) loop
    if now() - a.assigned_at < interval '3 minutes' then delete from queue_assignments where id = a.id;   -- quick correction
    else update queue_assignments set removed_at = now() where id = a.id; end if;
    perform _q_refresh_mech(a.mechanic_id);
  end loop;
  foreach mid in array p_mechs loop
    if not exists (select 1 from queue_assignments where ticket_id = t.id and mechanic_id = mid and removed_at is null) then
      insert into queue_assignments (ticket_id, mechanic_id) values (t.id, mid);
    end if;
    perform _q_refresh_mech(mid);
  end loop;
  perform _q_log(me.location_id, 'edit_mechanics', t.id, null, jsonb_build_object('old', v_old, 'new', p_mechs));
end $$;

create or replace function q_done(p_ticket bigint) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; t queue_tickets; mid bigint;
begin
  me := _q_staff();
  t := _q_ticket(p_ticket, me);
  if t.status <> 'Serving' then raise exception 'Mobil % statusnya %, bukan sedang dikerjakan.', t.code, t.status; end if;
  update queue_pauses set ended_at = now(), ended_by = auth.uid() where ticket_id = t.id and ended_at is null;
  update queue_tickets set status = 'Done', done_at = now() where id = t.id;
  for mid in select mechanic_id from queue_assignments where ticket_id = t.id and removed_at is null loop
    perform _q_refresh_mech(mid);
  end loop;
  perform _q_log(me.location_id, 'done', t.id, null, null);
end $$;

create or replace function q_cancel(p_ticket bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; t queue_tickets; mid bigint;
begin
  me := _q_staff();
  t := _q_ticket(p_ticket, me);
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Alasan batal wajib diisi.'; end if;
  if t.status not in ('Waiting','Serving') then raise exception 'Mobil % sudah %.', t.code, t.status; end if;
  update queue_pauses set ended_at = now(), ended_by = auth.uid() where ticket_id = t.id and ended_at is null;
  update queue_tickets set status = 'Cancelled', cancelled_at = now(), cancel_reason = trim(p_reason) where id = t.id;
  for mid in select mechanic_id from queue_assignments where ticket_id = t.id and removed_at is null loop
    perform _q_refresh_mech(mid);
  end loop;
  perform _q_log(me.location_id, 'cancel', t.id, null, jsonb_build_object('old_status', t.status, 'reason', trim(p_reason)));
end $$;

create or replace function q_pause(p_ticket bigint, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; t queue_tickets;
begin
  me := _q_staff();
  t := _q_ticket(p_ticket, me);
  if t.status <> 'Serving' then raise exception 'Mobil % tidak sedang dikerjakan.', t.code; end if;
  if p_on then
    if exists (select 1 from queue_pauses where ticket_id = t.id and ended_at is null) then raise exception '% sudah dalam status beli barang.', t.code; end if;
    insert into queue_pauses (ticket_id) values (t.id);
  else
    update queue_pauses set ended_at = now(), ended_by = auth.uid() where ticket_id = t.id and ended_at is null;
    if not found then raise exception '% tidak sedang beli barang.', t.code; end if;
  end if;
  perform _q_log(me.location_id, case when p_on then 'pause' else 'resume' end, t.id, null, null);
end $$;

-- undo the last add / take / done / cancel of this branch (only if nothing changed since)
create or replace function q_undo() returns text
language plpgsql security definer set search_path = public as $$
declare me profiles; l queue_log; t queue_tickets; mid bigint;
begin
  me := _q_staff();
  select * into l from queue_log where location_id = me.location_id and undone_at is null
    and action in ('add','take','done','cancel') and at > now() - interval '1 day' order by at desc, id desc limit 1 for update;
  if not found then raise exception 'Tidak ada yang bisa di-undo.'; end if;
  select * into t from queue_tickets where id = l.ticket_id for update;
  if not found then raise exception 'Mobil dari langkah terakhir sudah tidak ada.'; end if;
  if t.sale_id is not null then raise exception '% sudah tersambung ke invoice, tidak bisa di-undo.', t.code; end if;
  if l.action = 'add' then
    if t.status <> 'Waiting' then raise exception '% sudah %, tidak bisa di-undo.', t.code, t.status; end if;
    delete from queue_flags where ticket_id = t.id;
    delete from queue_tickets where id = t.id;
  elsif l.action = 'take' then
    if t.status <> 'Serving' then raise exception '% sudah %, tidak bisa di-undo.', t.code, t.status; end if;
    delete from queue_pauses where ticket_id = t.id;
    update queue_tickets set status = 'Waiting', taken_at = null where id = t.id;
    for mid in select mechanic_id from queue_assignments where ticket_id = t.id loop
      delete from queue_assignments where ticket_id = t.id and mechanic_id = mid;
      perform _q_refresh_mech(mid);
    end loop;
  elsif l.action = 'done' then
    if t.status <> 'Done' then raise exception '% sudah %, tidak bisa di-undo.', t.code, t.status; end if;
    update queue_tickets set status = 'Serving', done_at = null where id = t.id;
    for mid in select mechanic_id from queue_assignments where ticket_id = t.id and removed_at is null loop
      perform _q_refresh_mech(mid);
    end loop;
  elsif l.action = 'cancel' then
    if t.status <> 'Cancelled' then raise exception '% sudah %, tidak bisa di-undo.', t.code, t.status; end if;
    update queue_tickets set status = l.detail->>'old_status', cancelled_at = null, cancel_reason = null where id = t.id;
    for mid in select mechanic_id from queue_assignments where ticket_id = t.id and removed_at is null loop
      perform _q_refresh_mech(mid);
    end loop;
  end if;
  update queue_log set undone_at = now() where id = l.id;
  perform _q_log(me.location_id, 'undo', t.id, null, jsonb_build_object('undid', l.action, 'log_id', l.id));
  return l.action || ' ' || t.code;
end $$;

-- delete the most recently added car of today (wrong entry), only while nothing is linked to it
create or replace function q_delete_last() returns text
language plpgsql security definer set search_path = public as $$
declare me profiles; t queue_tickets; mid bigint;
begin
  me := _q_staff();
  select * into t from queue_tickets where location_id = me.location_id and day = _q_today() order by created_at desc, id desc limit 1 for update;
  if not found then raise exception 'Belum ada mobil hari ini.'; end if;
  if t.sale_id is not null then raise exception '% sudah tersambung ke invoice, tidak bisa dihapus.', t.code; end if;
  perform _q_log(me.location_id, 'delete', t.id, null, to_jsonb(t));
  delete from queue_flags where ticket_id = t.id;
  for mid in select mechanic_id from queue_assignments where ticket_id = t.id loop
    delete from queue_assignments where ticket_id = t.id and mechanic_id = mid;
    perform _q_refresh_mech(mid);
  end loop;
  delete from queue_tickets where id = t.id;
  return t.code || ' ' || t.plate;
end $$;

-- one reason covers this mechanic's unexplained flags chained within 30 minutes of each other
create or replace function q_flag_reason(p_flag bigint, p_reason text) returns int
language plpgsql security definer set search_path = public as $$
declare me profiles; f queue_flags; lo timestamptz; hi timestamptz; changed boolean := true; n int;
begin
  me := _q_staff();
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Alasan wajib diisi.'; end if;
  select * into f from queue_flags where id = p_flag;
  if not found or f.location_id <> me.location_id then raise exception 'Tanda id % tidak ada di cabang ini.', p_flag; end if;
  lo := f.flagged_at; hi := f.flagged_at;
  while changed loop
    select min(flagged_at), max(flagged_at) into lo, hi from queue_flags
     where mechanic_id = f.mechanic_id and reason is null
       and flagged_at between lo - interval '30 minutes' and hi + interval '30 minutes';
    changed := exists (select 1 from queue_flags where mechanic_id = f.mechanic_id and reason is null
       and flagged_at between lo - interval '30 minutes' and hi + interval '30 minutes'
       and (flagged_at < lo or flagged_at > hi));
  end loop;
  update queue_flags set reason = trim(p_reason), reason_by = auth.uid(), reason_at = now()
   where mechanic_id = f.mechanic_id and reason is null and flagged_at between lo and hi;
  get diagnostics n = row_count;
  perform _q_log(me.location_id, 'flag_reason', f.ticket_id, f.mechanic_id, jsonb_build_object('reason', trim(p_reason), 'flags', n));
  return n;
end $$;

-- ── mechanics for the day
create or replace function q_mech(p_mech bigint, p_action text, p_role text default null) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; m mechanics; d mechanic_days; v_fri boolean := extract(isodow from now() at time zone 'Asia/Jakarta') = 5;
begin
  me := _q_staff();
  select * into m from mechanics where id = p_mech;
  if not found or m.location_id <> me.location_id then raise exception 'Mekanik id % tidak ada di cabang ini.', p_mech; end if;
  select * into d from mechanic_days where mechanic_id = p_mech and day = _q_today() for update;
  if p_action = 'activate' then
    if coalesce(p_role, '') not in ('Quick','General') then raise exception 'Pilih Quick atau General.'; end if;
    if found then raise exception '% sudah aktif hari ini.', m.name; end if;
    insert into mechanic_days (mechanic_id, location_id, day, role, status, available_since)
    values (p_mech, me.location_id, _q_today(), p_role, 'Available', now());
    perform _q_refresh_mech(p_mech);
  else
    if not found then raise exception '% belum diaktifkan hari ini.', m.name; end if;
    if p_action = 'role' then
      if coalesce(p_role, '') not in ('Quick','General') then raise exception 'Pilih Quick atau General.'; end if;
      update mechanic_days set role = p_role where id = d.id;
    elsif p_action = 'break' then
      if v_fri then raise exception 'Hari Jumat tidak ada istirahat biasa — Jumatan otomatis 11:00–12:30.'; end if;
      if d.break_start is not null then raise exception '% sudah pakai istirahat hari ini.', m.name; end if;
      if d.status = 'GoneHome' then raise exception '% sudah pulang.', m.name; end if;
      update mechanic_days set status = 'Break', break_start = now() where id = d.id;
    elsif p_action = 'back' then
      if d.status <> 'Break' then raise exception '% tidak sedang istirahat.', m.name; end if;
      update mechanic_days set status = 'Available', break_end = now(), available_since = now() where id = d.id;
      perform _q_refresh_mech(p_mech);
    elsif p_action = 'gonehome' then
      update mechanic_days set status = 'GoneHome', gone_home_at = now(),
        break_end = case when status = 'Break' then now() else break_end end where id = d.id;
    elsif p_action = 'available' then
      if d.status <> 'GoneHome' then raise exception '% tidak sedang pulang.', m.name; end if;
      update mechanic_days set status = 'Available', gone_home_at = null, available_since = now() where id = d.id;
      perform _q_refresh_mech(p_mech);
    else
      raise exception 'Aksi "%" tidak dikenal.', p_action;
    end if;
  end if;
  perform _q_log(me.location_id, 'mech_' || p_action, null, p_mech, jsonb_build_object('role', p_role));
end $$;

-- ── cashier: today's cars not yet on an invoice, and linking
create or replace function q_for_cashier() returns table (id bigint, code text, plate text, plate_key text, status text, mechanics text, day date)
language sql stable security definer set search_path = public as $$
  select t.id, t.code, t.plate, t.plate_key, t.status,
         (select string_agg(m.name, ', ' order by a.assigned_at) from queue_assignments a join mechanics m on m.id = a.mechanic_id
           where a.ticket_id = t.id and a.removed_at is null), t.day
  from queue_tickets t
  where t.location_id = _my_loc() and t.sale_id is null and t.status <> 'Cancelled'
    and t.day >= _q_today() - 1
  order by t.day desc, case t.status when 'Done' then 0 when 'Serving' then 1 when 'Unfinished' then 2 else 3 end, t.created_at
$$;

create or replace function q_link_sale(p_ticket bigint, p_sale bigint) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; t queue_tickets; s sales;
begin
  me := _q_staff();
  t := _q_ticket(p_ticket, me);
  select * into s from sales where id = p_sale;
  if not found then raise exception 'Invoice id % tidak ada.', p_sale; end if;
  if s.location_id <> t.location_id then raise exception 'Invoice % dan antrian % beda cabang.', s.invoice_no, t.code; end if;
  if t.sale_id is not null and t.sale_id <> p_sale then raise exception 'Antrian % sudah tersambung ke invoice lain.', t.code; end if;
  if exists (select 1 from queue_tickets where sale_id = p_sale and id <> t.id) then raise exception 'Invoice % sudah tersambung ke antrian lain.', s.invoice_no; end if;
  update queue_tickets set sale_id = p_sale where id = t.id;
  update sales set queue_ref = t.code where id = p_sale;
  perform _q_log(me.location_id, 'link_sale', t.id, null, jsonb_build_object('sale', p_sale, 'invoice', s.invoice_no));
end $$;

-- ── customer TV display: no login, needs the branch's secret display_token
create or replace function q_public_board(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('branch', l.name, 'now', now(), 'tickets', coalesce((
    select jsonb_agg(jsonb_build_object('code', t.code, 'lane', t.lane, 'plate', t.plate, 'status', t.status,
                     'paused', exists (select 1 from queue_pauses p where p.ticket_id = t.id and p.ended_at is null)) order by t.created_at)
    from queue_tickets t where t.location_id = l.id and t.day = _q_today() and t.status in ('Waiting','Serving')), '[]'))
  from locations l where l.display_token = p_token and length(p_token) >= 20
$$;

-- ── performance (owner/admin): per mechanic over a date range.
-- Work minutes = time on the car (from when he was put on it until Done / removed)
--   minus "Beli barang di luar" pauses, minus his own break, minus Jumatan.
create or replace function q_performance(p_from date, p_to date, p_loc bigint default null)
returns table (mechanic_id bigint, mechanic text, branch text, jobs bigint, solo_jobs bigint, team_jobs bigint,
               quick_jobs bigint, general_jobs bigint, work_min numeric, avg_min numeric, paused_min numeric,
               flags bigint, flags_unexplained bigint, days_worked bigint)
language sql stable security definer set search_path = public as $$
  with scope as (
    select case when my_role() = 'owner' then p_loc else _my_loc() end loc
    where my_role() in ('owner','admin')
  ), a as (
    select a.mechanic_id, t.id tid, t.lane, a.removed_at,
           greatest(t.taken_at, a.assigned_at) s, coalesce(a.removed_at, t.done_at) e,
           (select count(*) from queue_assignments b where b.ticket_id = t.id and b.removed_at is null) team_size
    from queue_assignments a join queue_tickets t on t.id = a.ticket_id, scope
    where t.status = 'Done' and t.day between p_from and p_to
      and (scope.loc is null or t.location_id = scope.loc)
  ), w as (
    select a.*,
      (select coalesce(sum(_overlap_min(a.s, a.e, p.started_at, coalesce(p.ended_at, a.e))), 0) from queue_pauses p where p.ticket_id = a.tid) pz,
      (select coalesce(sum(_overlap_min(a.s, a.e, d.break_start, coalesce(d.break_end, a.e))), 0) from mechanic_days d where d.mechanic_id = a.mechanic_id and d.break_start is not null) bk,
      _jumatan_min(a.s, a.e) jm
    from a
  ), per as (
    select mechanic_id,
      count(*) filter (where removed_at is null) jobs,
      count(*) filter (where removed_at is null and team_size = 1) solo,
      count(*) filter (where removed_at is null and team_size > 1) team,
      count(*) filter (where removed_at is null and lane = 'Quick') q,
      count(*) filter (where removed_at is null and lane = 'General') g,
      sum(greatest(0, extract(epoch from (e - s)) / 60 - pz - bk - jm)) work,
      sum(pz) paused
    from w group by mechanic_id
  )
  select m.id, m.name, l.code, coalesce(per.jobs, 0), coalesce(per.solo, 0), coalesce(per.team, 0),
         coalesce(per.q, 0), coalesce(per.g, 0), round(coalesce(per.work, 0)),
         case when coalesce(per.jobs, 0) > 0 then round(per.work / per.jobs) end, round(coalesce(per.paused, 0)),
         (select count(*) from queue_flags f where f.mechanic_id = m.id and (f.flagged_at at time zone 'Asia/Jakarta')::date between p_from and p_to),
         (select count(*) from queue_flags f where f.mechanic_id = m.id and f.reason is null and (f.flagged_at at time zone 'Asia/Jakarta')::date between p_from and p_to),
         (select count(*) from mechanic_days d where d.mechanic_id = m.id and d.day between p_from and p_to)
  from mechanics m join locations l on l.id = m.location_id cross join scope
  left join per on per.mechanic_id = m.id
  where (scope.loc is null or m.location_id = scope.loc)
    and (per.mechanic_id is not null or m.is_active)
  order by l.code, m.name
$$;

-- job list behind the performance numbers
create or replace function q_jobs_detail(p_from date, p_to date, p_mech bigint)
returns table (day date, code text, plate text, lane text, taken_at timestamptz, done_at timestamptz,
               work_min numeric, paused_min numeric, team text, invoice text, sale_total numeric)
language sql stable security definer set search_path = public as $$
  select t.day, t.code, t.plate, t.lane, greatest(t.taken_at, a.assigned_at), coalesce(a.removed_at, t.done_at),
    round(greatest(0, extract(epoch from (coalesce(a.removed_at, t.done_at) - greatest(t.taken_at, a.assigned_at))) / 60
      - (select coalesce(sum(_overlap_min(greatest(t.taken_at, a.assigned_at), coalesce(a.removed_at, t.done_at), p.started_at, coalesce(p.ended_at, t.done_at))), 0) from queue_pauses p where p.ticket_id = t.id)
      - (select coalesce(sum(_overlap_min(greatest(t.taken_at, a.assigned_at), coalesce(a.removed_at, t.done_at), d.break_start, coalesce(d.break_end, t.done_at))), 0) from mechanic_days d where d.mechanic_id = a.mechanic_id and d.break_start is not null)
      - _jumatan_min(greatest(t.taken_at, a.assigned_at), coalesce(a.removed_at, t.done_at)))),
    round((select coalesce(sum(_overlap_min(greatest(t.taken_at, a.assigned_at), coalesce(a.removed_at, t.done_at), p.started_at, coalesce(p.ended_at, t.done_at))), 0) from queue_pauses p where p.ticket_id = t.id)),
    (select string_agg(m.name, ', ' order by b.assigned_at) from queue_assignments b join mechanics m on m.id = b.mechanic_id where b.ticket_id = t.id and b.removed_at is null),
    s.invoice_no, s.total
  from queue_assignments a join queue_tickets t on t.id = a.ticket_id
  left join sales s on s.id = t.sale_id
  where a.mechanic_id = p_mech and t.status = 'Done' and t.day between p_from and p_to
    and my_role() in ('owner','admin')
    and (my_role() = 'owner' or t.location_id = _my_loc())
  order by t.done_at desc
$$;

-- ── grants: browser may call only these
do $$ declare f text; begin
  foreach f in array array['q_board()','q_add(text,text,bigint)','q_take(bigint,bigint[])','q_edit_mechs(bigint,bigint[])',
    'q_done(bigint)','q_cancel(bigint,text)','q_pause(bigint,boolean)','q_undo()','q_delete_last()','q_flag_reason(bigint,text)',
    'q_mech(bigint,text,text)','q_for_cashier()','q_link_sale(bigint,bigint)','q_performance(date,date,bigint)','q_jobs_detail(date,date,bigint)'] loop
    execute 'revoke execute on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
  foreach f in array array['_q_staff()','_q_ticket(bigint,profiles)','_q_jobs(bigint)','_q_refresh_mech(bigint)','_q_log(bigint,text,bigint,bigint,jsonb)',
    '_q_tick(bigint)','_q_check_mechs(profiles,queue_tickets,bigint[],boolean)','_my_loc()'] loop
    execute 'revoke execute on function ' || f || ' from public, anon';
  end loop;
end $$;
grant execute on function _my_loc() to authenticated;   -- used inside RLS policies
revoke execute on function q_public_board(text) from public;
grant execute on function q_public_board(text) to anon, authenticated;
