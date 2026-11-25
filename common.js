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

  // "Lupa password?": Supabase emails a link back to this page; opening it fires PASSWORD_RECOVERY.
  const fb = $("forgotBtn");
  if (fb) fb.onclick = async () => {
    const email = $("email").value.trim();
    if (!email) { $("loginErr").textContent = "Isi email dulu, lalu klik Lupa password."; return; }
    const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname });
    if (error && /rate limit/i.test(error.message)) {
      $("loginErr").textContent = "Email sudah dikirim baru-baru ini. Pakai kode dari email itu, atau tunggu ±1 jam sebelum minta lagi.";
    } else if (error) { $("loginErr").textContent = "Gagal kirim email: " + error.message; return; }
    else $("loginErr").textContent = "Email dikirim ke " + email + " (cek juga Junk).";
    showCodeEntry(email);
  };
  let recovering = false;
  sb.auth.onAuthStateChange(event => { if (event === "PASSWORD_RECOVERY") { recovering = true; showSetPassword(boot); } });
  sb.auth.getSession().then(({ data: { session } }) => {
    if (session && !recovering && !location.hash.includes("type=recovery")) boot();
  });
}

// Enter the 6-digit code from the email. A code works even when Outlook/Hotmail has already
// "clicked" the link in the email to scan it (which uses up the link).
function showCodeEntry(email) {
  if ($("codeBox")) return;
  $("loginErr").insertAdjacentHTML("afterend", `<div id="codeBox" style="margin-top:12px">
    <input id="otp" inputmode="numeric" maxlength="10" placeholder="Kode dari email (6 digit)" autocomplete="one-time-code">
    <button class="primary" id="otpBtn">Pakai kode</button></div>`);
  $("otpBtn").onclick = async () => {
    const token = $("otp").value.replace(/\s/g, "");
    if (!/^\d{6,10}$/.test(token)) { $("loginErr").textContent = "Kode harus angka dari email."; return; }
    const { error } = await sb.auth.verifyOtp({ email, token, type: "recovery" });
    if (error) { $("loginErr").textContent = "Kode ditolak: " + error.message; return; }
    showSetPassword(() => location.reload());
  };
}

function showSetPassword(then) {
  const card = document.querySelector("#login .login-card");
  card.innerHTML = `<h1>Password baru</h1><p>Minimal 8 karakter.</p>
    <input id="np1" type="password" placeholder="Password baru" autocomplete="new-password">
    <input id="np2" type="password" placeholder="Ulangi password baru" autocomplete="new-password">
    <button class="primary" id="npBtn">Simpan password</button><div class="err" id="npErr"></div>`;
  $("login").classList.remove("hide");
  $("npBtn").onclick = async () => {
    const a = $("np1").value, b = $("np2").value;
    if (a.length < 8) { $("npErr").textContent = "Password minimal 8 karakter."; return; }
    if (a !== b) { $("npErr").textContent = "Kedua password tidak sama."; return; }
    const { error } = await sb.auth.updateUser({ password: a });
    if (error) { $("npErr").textContent = "Gagal: " + error.message; return; }
    history.replaceState(null, "", location.pathname);
    then();
  };
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


// Owners work across branches: a dropdown in the topbar switches which branch they are working in.
// (Their profile's branch changes; everything they sell, buy or count after that goes to that branch.)
async function branchSwitcher(el) {
  if (!el || ME.role !== "owner") return;
  const { data } = await sb.from("locations").select("id,code,name").eq("is_active", true).order("id");
  el.innerHTML = `<select title="Cabang tempat Anda bekerja sekarang" style="width:auto;padding:6px 10px">${(data || []).map(l =>
    `<option value="${l.id}" ${l.id === ME.location_id ? "selected" : ""}>${esc(l.code)} · ${esc(l.name)}</option>`).join("")}</select>`;
  el.firstChild.onchange = async e => {
    const { error } = await sb.from("profiles").update({ location_id: Number(e.target.value) }).eq("id", ME.id);
    if (error) { toast("Gagal pindah cabang: " + esc(error.message), "err"); return; }
    location.reload();
  };
}

// ← / → through a list of records while a detail window is open
function arrowNav(modalId, getList, getCurrentId, open) {
  document.addEventListener("keydown", e => {
    if (!$(modalId).classList.contains("open") || !["ArrowLeft", "ArrowRight"].includes(e.key)) return;
    if (["INPUT", "SELECT", "TEXTAREA"].includes(document.activeElement?.tagName)) return;
    const list = getList() || [], i = list.findIndex(r => r.id === getCurrentId());
    const j = i + (e.key === "ArrowRight" ? 1 : -1);
    if (i < 0 || j < 0 || j >= list.length) { toast(j < 0 ? "Sudah yang pertama." : "Sudah yang terakhir.", "ok", 1200); return; }
    e.preventDefault(); open(list[j].id);
  });
}

// colored status banner for a sale
function saleStatusBanner(s) {
  const paid = Number(s.paid_amount), tot = Number(s.total);
  const [bg, fg, txt] = s.status === "void" ? ["#eceef1", "#4b5563", "VOID"]
    : s.status === "paid" ? ["var(--green-soft)", "var(--green)", "LUNAS"]
    : paid > 0 ? ["#e7f0fd", "#1d4ed8", `SEBAGIAN — dibayar ${num(paid)}, sisa ${num(tot - paid)}`]
    : ["var(--red-soft)", "var(--red)", `BELUM DIBAYAR — sisa ${num(tot)}`];
  return `<div style="background:${bg};color:${fg};font-weight:700;padding:10px 14px;border-radius:var(--r);margin-bottom:12px">${txt}${s.is_tempo ? " · TEMPO" : ""}</div>`;
}
