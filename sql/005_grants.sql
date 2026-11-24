-- Supabase does not automatically give logged-in users access to tables made by a migration.
-- Row-level rules in 001 still decide WHAT each user may see or change.
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
revoke all on all tables in schema public from anon;           -- not logged in = sees nothing
revoke update, delete on audit_log from authenticated;          -- audit log is append-only
alter function public._same_day(sales) set search_path = public;
revoke execute on function public.rls_auto_enable() from authenticated, anon, public;
