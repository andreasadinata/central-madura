// Shared helpers for every page. Plain JavaScript, no build step.

const sb = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
let ME = null; // { id, full_name, role, location_id, locations: {...} }

const rp  = n => "Rp " + Math.round(Number(n) || 0).toLocaleString("id-ID");
const num = n => Math.round(Number(n) || 0).toLocaleString("id-ID");
const $   = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));
const parseRp = v => Number(String(v).replace(/[^\d]/g, "")) || 0;

// Show the database's own message. It says what happened; we don't guess.
function errText(e) {
  if (!e) return "Error tanpa pesan.";
  return e.message || e.error_description || String(e);
}

function toast(html, kind = "ok", ms = 3500) {
  let t = $("toast");
  if (!t) { t = document.createElement("div"); t.id = "toast"; document.body.appendChild(t); }
  t.className = "show " + kind;
  t.innerHTML = html;
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.className = "", kind === "err" ? 8000 : ms);
}

// Supabase returns at most 1000 rows per request; this fetches all pages.
async function fetchAll(makeQuery) {
  const out = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await makeQuery().range(from, from + 999);
    if (error) throw error;
    out.push(...data);
    if (data.length < 1000) return out;
  }
}

// Login gate used by every page. Calls onReady() once a valid staff profile is loaded.
function authGate(onReady, allowedRoles) {
  $("loginBtn").onclick = doLogin;
  $("pass").addEventListener("keydown", e => { if (e.key === "Enter") doLogin(); });

  async function doLogin() {
    $("loginErr").textContent = "";
    const email = $("email").value.trim(), password = $("pass").value;
    if (!email || !password) { $("loginErr").textContent = "Isi email dan password."; return; }
    const { error } = await sb.auth.signInWithPassword({ email, password });
    if (error) { $("loginErr").textContent = "Login gagal: " + error.message; return; }
    await boot();
  }

  async function boot() {
    const { data: { user } } = await sb.auth.getUser();
    if (!user) return;
    const { data, error } = await sb.from("profiles").select("*, locations(*)").eq("id", user.id).maybeSingle();
    if (error) { $("loginErr").textContent = "Profil gagal dibaca: " + error.message; return; }
    if (!data) { $("loginErr").textContent = "Login berhasil, tapi akun " + user.email + " belum punya profil staf. Minta owner menambahkan."; return; }
    if (!data.is_active) { $("loginErr").textContent = "Akun " + data.full_name + " dinonaktifkan."; return; }
    if (allowedRoles && !allowedRoles.includes(data.role)) {
      $("loginErr").textContent = "Halaman ini hanya untuk " + allowedRoles.join("/") + ". Peran Anda: " + data.role + ".";
      return;
    }
    ME = data;
    $("login").classList.add("hide");
    $("app").classList.add("show");
    onReady();
  }

  sb.auth.getSession().then(({ data: { session } }) => { if (session) boot(); });
}

async function logout() { await sb.auth.signOut(); location.reload(); }

// Same pricing rule as the database function price_for():
// customer's own list first, otherwise the default list. Highest min_qty <= qty wins.
// The database recomputes this on save — the browser only shows it.
function tierFor(tiersByProduct, productId, listId, defaultListId, qty) {
  const rows = tiersByProduct[productId] || [];
  const pick = lid => rows.filter(t => t.price_list_id === lid && Number(t.min_qty) <= qty)
                          .sort((a, b) => b.min_qty - a.min_qty)[0];
  if (listId) { const r = pick(listId); if (r) return { price: Number(r.price), source: "khusus" }; }
  const r = pick(defaultListId);
  return r ? { price: Number(r.price), source: "umum" } : null;
}

function nextTier(tiersByProduct, productId, listId, defaultListId, qty) {
  const rows = tiersByProduct[productId] || [];
  const own = listId && rows.some(t => t.price_list_id === listId) ? listId : defaultListId;
  return rows.filter(t => t.price_list_id === own && Number(t.min_qty) > qty)
             .sort((a, b) => a.min_qty - b.min_qty)[0] || null;
}
