# Central POS

Plain HTML + JavaScript + Supabase. No framework, no build step.

| File | What it is |
|---|---|
| `index.html` | Cashier screen (kasir) |
| `admin.html` | Products & prices, customers, daily review, users |
| `common.js` / `style.css` / `config.js` | Shared helpers, design, public Supabase settings |
| `sql/` | Database, run in order 000 → 005 |
| `supabase/functions/admin-users` | Creates staff logins. The only code that uses the service_role key, and it runs on Supabase's servers. |

## Rules the database enforces (not the browser)
- Prices come from tiers: "from this qty → this price". Customer's own price list first, else **Umum**.
- Price below normal needs a reason. Recorded with who and when.
- An invoice can change only on its own day (Jakarta time). Lines are **cancelled**, never deleted; whole invoices are **void**, number kept.
- Changing a printed invoice raises its revision (Rev 2, Rev 3…).
- Stock = sum of `stock_moves`. Nobody types a stock number.
- Everything above shows up in **Admin → Tinjauan harian**.
