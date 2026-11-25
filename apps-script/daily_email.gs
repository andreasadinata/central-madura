/**
 * Central POS — daily queue email (20:00 WIB).
 * Paste this whole file into a NEW Google Apps Script project (script.google.com → New project).
 * Then: run setupTrigger() once and click "Allow" when Google asks. Done.
 * To test right away: run sendQueueSummary().
 */
var EMAIL_TO     = "adinataandreas@gmail.com";            // more people: "a@gmail.com,b@gmail.com"
var SUPABASE_URL = "https://nqucbmpjqfkydbxtjeoj.supabase.co";
var ANON_KEY     = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5xdWNibXBqcWZreWRieHRqZW9qIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcyODE1NTEsImV4cCI6MjEwMjg1NzU1MX0.mWQMYJiqzKtXtg68CmW1Aq6c96akIpyh4e9uDq_fDq4";
var SUMMARY_KEY  = "PASTE_SUMMARY_KEY_HERE";               // secret: only allows reading this summary

function setupTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === "sendQueueSummary") ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger("sendQueueSummary").timeBased().everyDays(1).atHour(20).inTimezone("Asia/Jakarta").create();
  Logger.log("OK — email akan dikirim setiap hari sekitar jam 20:00 WIB ke " + EMAIL_TO);
}

function sendQueueSummary() {
  var res = UrlFetchApp.fetch(SUPABASE_URL + "/rest/v1/rpc/q_daily_summary", {
    method: "post", contentType: "application/json", muteHttpExceptions: true,
    headers: { apikey: ANON_KEY, Authorization: "Bearer " + ANON_KEY },
    payload: JSON.stringify({ p_secret: SUMMARY_KEY })
  });
  if (res.getResponseCode() !== 200) {
    MailApp.sendEmail(EMAIL_TO, "Ringkasan antrian GAGAL", "Supabase menjawab " + res.getResponseCode() + ":\n" + res.getContentText());
    return;
  }
  var d = JSON.parse(res.getContentText());
  if (!d.branches.length) { MailApp.sendEmail(EMAIL_TO, "Ringkasan antrian " + d.day, "Tidak ada mobil di antrian hari ini."); return; }

  var td = "padding:6px 10px;border-bottom:1px solid #e3e5ea;font-size:13px";
  var th = "padding:6px 10px;background:#f4f5f7;text-align:left;font-size:11px;color:#6b7280;text-transform:uppercase";
  function table(head, rows) {
    return '<table style="border-collapse:collapse;width:100%;margin:6px 0 18px">' +
      "<tr>" + head.map(function (h) { return '<th style="' + th + '">' + h + "</th>"; }).join("") + "</tr>" +
      rows.map(function (r) { return "<tr>" + r.map(function (c) { return '<td style="' + td + '">' + (c == null ? "—" : c) + "</td>"; }).join("") + "</tr>"; }).join("") + "</table>";
  }
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }

  var html = '<div style="font-family:Arial,sans-serif;color:#15171c;max-width:900px">';
  html += '<h2 style="margin:0 0 4px">Ringkasan antrian — ' + d.day + "</h2>";
  d.branches.forEach(function (b) {
    html += '<h3 style="margin:22px 0 4px;color:#3b10b5">' + esc(b.code) + " · " + esc(b.name) + "</h3>";
    html += '<p style="font-size:13px;margin:0 0 8px">Total <b>' + b.total + "</b> mobil · Selesai <b>" + b.done + "</b> · Batal <b>" + b.cancelled +
      "</b> · Belum selesai <b>" + b.open + "</b> · Quick " + b.quick + " / General " + b.general +
      (b.no_invoice ? ' · <span style="color:#c4362b"><b>' + b.no_invoice + "</b> selesai tanpa invoice</span>" : "") + "</p>";
    if (b.mechanics.length) html += table(["Mekanik", "Mobil", "Sendiri / tim", "Menit kerja", "Rata² / mobil", "Beli barang", "Tanda lambat"],
      b.mechanics.map(function (m) { return [esc(m.mechanic), m.jobs, m.solo_jobs + " / " + m.team_jobs, m.work_min, m.avg_min == null ? "—" : m.avg_min + " mnt",
        m.paused_min ? m.paused_min + " mnt" : "—", m.flags ? m.flags + (m.flags_unexplained ? ' <span style="color:#c4362b">(' + m.flags_unexplained + " tanpa alasan)</span>" : "") : "—"]; }));
    if (b.flags.length) html += "<b>Tanda lambat</b>" + table(["Jam", "Mekanik", "Mobil", "Alasan"],
      b.flags.map(function (f) { return [f.at, esc(f.mechanic), esc(f.code + " " + f.plate), f.reason ? esc(f.reason) : '<span style="color:#c4362b">tidak ada alasan</span>']; }));
    if (b.cancels.length) html += "<b>Mobil batal</b>" + table(["No", "Plat", "Alasan"],
      b.cancels.map(function (c) { return [esc(c.code), esc(c.plate), esc(c.reason)]; }));
    html += "<b>Semua mobil</b>" + table(["No", "Plat", "Status", "Masuk", "Tunggu", "Kerja", "Mekanik", "Invoice"],
      b.cars.map(function (c) { return [esc(c.code), esc(c.plate), esc(c.status), c.in, c.wait == null ? "" : c.wait + " mnt", c.work == null ? "" : c.work + " mnt",
        esc(c.mechanics || ""), c.invoice ? esc(c.invoice) : (c.status === "Done" ? '<span style="color:#c4362b">belum</span>' : "")]; }));
  });
  html += '<p style="font-size:11px;color:#9ca3af">Menit kerja = waktu di mobil dikurangi beli barang di luar, istirahat, dan Jumatan.</p></div>';
  MailApp.sendEmail({ to: EMAIL_TO, subject: "Ringkasan antrian — " + d.day, htmlBody: html });
}
