-- 24 Nov 2026 (applied as Supabase migration "v2_banks_required_customer_delete_product";
-- full function text is stored in Supabase → Database → Migrations).
-- 1. bank_accounts table (BCA, Mandiri, BRI, BNI to start; edit in Admin → Rekening bank).
-- 2. payments: bank_account_id (required for transfer), is_change (cash change given back).
-- 3. pay_sale_multi(sale, lines[]): several payment lines; received > due → cash "kembalian" line.
--    pay_sale (single payment) is no longer callable from the browser.
-- 4. refund_sale gets p_bank for refunds by transfer.
-- 5. create_sale now refuses: no vehicle, customer without HP/alamat, vehicle without warna.
--    The UMUM walk-in customer is deactivated: every invoice needs a real (or "-") customer.
-- 6. delete_product(id): owner/admin, only if the product never appeared in a sale or stock move.
-- 7. review_list: cash change is not listed as a refund.
create table bank_accounts (id bigint generated always as identity primary key, name text unique not null, is_active boolean not null default true);
alter table payments add column bank_account_id bigint references bank_accounts(id),
  add column is_change boolean not null default false,
  add constraint transfer_needs_bank check (method <> 'transfer' or bank_account_id is not null);
update customers set is_active = false where name = 'UMUM';
