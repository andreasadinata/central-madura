// Edge function: the ONLY place that uses the service_role key.
// It runs on Supabase's servers, never in a browser.
// Only an active OWNER may call it. Actions: create a staff login, reset a password.
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "Hanya POST." });

  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // Who is calling? Check their login token, then their profile.
  const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
  const { data: { user }, error: uErr } = await admin.auth.getUser(token);
  if (uErr || !user) return reply(401, { error: "Belum login atau sesi habis. Login ulang." });
  const { data: caller, error: pErr } = await admin.from("profiles").select("role,is_active").eq("id", user.id).maybeSingle();
  if (pErr) return reply(500, { error: "Gagal membaca profil pemanggil: " + pErr.message });
  if (!caller) return reply(403, { error: "Akun ini tidak punya profil staf." });
  if (!caller.is_active || caller.role !== "owner") {
    return reply(403, { error: "Hanya owner yang boleh mengelola akun." });
  }

  let body: Record<string, string>;
  try { body = await req.json(); } catch { return reply(400, { error: "Body bukan JSON." }); }

  if (body.action === "create") {
    const { email, password, full_name, role, location_id } = body;
    if (!email || !password || !full_name || !role) return reply(400, { error: "Nama, email, password, peran wajib diisi." });
    if (!email.includes("@")) return reply(400, { error: `"${email}" bukan alamat email. Contoh: mei@centralban.id (tidak harus email asli).` });
    if (!["admin", "kasir", "owner"].includes(role)) return reply(400, { error: `Peran "${role}" tidak dikenal.` });
    if (password.length < 8) return reply(400, { error: "Password minimal 8 karakter." });

    const { data: created, error: cErr } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
    if (cErr) return reply(400, { error: "Gagal membuat login: " + cErr.message });

    const { error: iErr } = await admin.from("profiles").insert({
      id: created.user.id, full_name, email, role, location_id: location_id ? Number(location_id) : null,
    });
    if (iErr) {
      await admin.auth.admin.deleteUser(created.user.id); // undo half-made account
      return reply(400, { error: "Login dibuat tapi profil gagal, login dibatalkan: " + iErr.message });
    }
    await admin.from("audit_log").insert({ user_id: user.id, action: "user_create", table_name: "profiles",
      detail: { email, full_name, role, location_id } });
    return reply(200, { ok: true, id: created.user.id });
  }

  if (body.action === "reset_password") {
    const { user_id, password } = body;
    if (!user_id || !password) return reply(400, { error: "user_id dan password wajib." });
    if (password.length < 8) return reply(400, { error: "Password minimal 8 karakter." });
    const { error } = await admin.auth.admin.updateUserById(user_id, { password });
    if (error) return reply(400, { error: "Gagal ganti password: " + error.message });
    await admin.from("audit_log").insert({ user_id: user.id, action: "user_reset_password", table_name: "profiles",
      detail: { target: user_id } });
    return reply(200, { ok: true });
  }

  return reply(400, { error: `Action "${body.action}" tidak dikenal.` });
});
