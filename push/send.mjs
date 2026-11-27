// Sends the Monday / Thursday time card reminders.
// Run by GitHub Actions (.github/workflows/reminders.yml). Needs these secrets:
//   SUPABASE_URL, SUPABASE_SECRET_KEY, VAPID_PRIVATE_KEY
import webpush from 'web-push';

const {
  SUPABASE_URL, SUPABASE_SECRET_KEY, VAPID_PRIVATE_KEY,
  VAPID_PUBLIC_KEY = 'BPgNDPFaCQ1wb3h97AWQmeX1oWxu7oeaufP9UqjY4PKPzyYVh9hFHQS_ZqTX7MNQ7B5A4efXcxixwrAfXsVgzAU',
  VAPID_SUBJECT = 'mailto:office@example.com',
  KIND = '',            // 'mon', 'thu' or 'test' to force one; empty = decide by day/time
  SEND_HOUR = '7',      // local shop time (America/Chicago) to send at or after
} = process.env;

for (const [k, v] of Object.entries({ SUPABASE_URL, SUPABASE_SECRET_KEY, VAPID_PRIVATE_KEY })) {
  if (!v) { console.error(`Missing secret: ${k}`); process.exit(1); }
}
webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

const base = SUPABASE_URL.replace(/\/$/, '') + '/rest/v1';
const headers = { apikey: SUPABASE_SECRET_KEY, 'Content-Type': 'application/json' };
if (SUPABASE_SECRET_KEY.split('.').length === 3) headers.Authorization = 'Bearer ' + SUPABASE_SECRET_KEY; // legacy service_role key

async function db(path, opts = {}) {
  const r = await fetch(base + path, { ...opts, headers: { ...headers, ...(opts.headers || {}) } });
  const t = await r.text();
  if (!r.ok) throw new Error(`Supabase ${r.status}: ${t}`);
  return t ? JSON.parse(t) : null;
}

// Shop-local date/time
const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/Chicago', year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', hourCycle: 'h23', weekday: 'short',
}).formatToParts(new Date()).map((p) => [p.type, p.value]));
const today = `${parts.year}-${parts.month}-${parts.day}`;
const hour = Number(parts.hour);

let kind = KIND.trim().toLowerCase();

// ---------- 8 PM forgotten clock-out check (JOB=clockout) ----------
if (process.env.JOB === 'clockout') {
  const forced = kind === 'out';
  if (!forced && hour < 20) { console.log(`Too early for the clock-out check (${hour}:00 shop time). Skipping.`); process.exit(0); }
  const key = `${today}-out`;
  if (!forced) {
    const done = await db(`/notification_log?key=eq.${encodeURIComponent(key)}&select=key`);
    if (done.length) { console.log(`Already ran ${key}.`); process.exit(0); }
  }
  const res = await db('/rpc/cron_clockout_alert', { method: 'POST', body: '{}' });
  console.log(`Still clocked in: ${res.count}. Office email sent: ${res.emailed}.`);
  const byEmp = new Map(res.list.map((x) => [x.employee_id, x]));
  let sent = 0, gone = 0, failed = 0;
  if (byEmp.size) {
    const subs = await db('/push_subscriptions?select=endpoint,subscription,employee_id');
    for (const s of subs) {
      const x = byEmp.get(s.employee_id);
      if (!x) continue;
      const msg = { title: 'Still clocked in', body: `You've been on the clock since ${x.since}. If you're done for the day, clock out now.`, view: '', tag: 'tc-out' };
      try { await webpush.sendNotification(s.subscription, JSON.stringify(msg), { TTL: 60 * 60 * 4 }); sent++; }
      catch (e) {
        if (e.statusCode === 404 || e.statusCode === 410) { gone++; await db(`/push_subscriptions?endpoint=eq.${encodeURIComponent(s.endpoint)}`, { method: 'DELETE' }); }
        else { failed++; console.error(`Failed for ${x.name}: ${e.statusCode || ''} ${e.body || e.message}`); }
      }
    }
  }
  if (!forced) await db('/notification_log', { method: 'POST', body: JSON.stringify({ key }), headers: { Prefer: 'resolution=ignore-duplicates' } });
  console.log(`clock-out: ${sent} phone reminders sent, ${gone} expired removed, ${failed} failed.`);
  process.exit(0);
}

if (!kind) {
  if (hour < Number(SEND_HOUR)) { console.log(`Too early (${hour}:00 shop time). Skipping.`); process.exit(0); }
  kind = parts.weekday === 'Mon' ? 'mon' : parts.weekday === 'Thu' ? 'thu' : '';
  if (!kind) { console.log(`Not Monday or Thursday (${parts.weekday}). Skipping.`); process.exit(0); }
}

const logKey = `${today}-${kind}`;
if (kind !== 'test') {
  const done = await db(`/notification_log?key=eq.${encodeURIComponent(logKey)}&select=key`);
  if (done.length) { console.log(`Already sent ${logKey}.`); process.exit(0); }
}

// Monday of last week (Mon–Sun weeks)
const d = new Date(`${today}T12:00:00Z`);
const dow = (d.getUTCDay() + 6) % 7;
d.setUTCDate(d.getUTCDate() - dow - 7);
const lastWeekStart = d.toISOString().slice(0, 10);

const MESSAGES = {
  mon:  { title: 'Monday time card check', body: "Look over last week's hours and fill in anything you missed.", view: 'lastweek', tag: 'tc-mon' },
  thu:  { title: 'Time card due today', body: "Submit last week's hours by end of day for Friday payroll.", view: 'lastweek', tag: 'tc-thu' },
  test: { title: 'Time Clock test', body: 'Reminders are working. 👍', view: '', tag: 'tc-test' },
};
const msg = MESSAGES[kind];
if (!msg) { console.error(`Unknown KIND "${kind}"`); process.exit(1); }

let subs = await db('/push_subscriptions?select=endpoint,subscription,employee_id,employees(name,active)');
subs = subs.filter((s) => s.employees && s.employees.active);

// Thursday: only remind people who haven't submitted last week yet
if (kind === 'thu') {
  const submitted = await db(`/week_submissions?week_start=eq.${lastWeekStart}&select=employee_id`);
  const done = new Set(submitted.map((s) => s.employee_id));
  subs = subs.filter((s) => !done.has(s.employee_id));
}

let ok = 0, gone = 0, failed = 0;
for (const s of subs) {
  try {
    await webpush.sendNotification(s.subscription, JSON.stringify(msg), { TTL: 60 * 60 * 12 });
    ok++;
  } catch (e) {
    if (e.statusCode === 404 || e.statusCode === 410) {
      gone++;
      await db(`/push_subscriptions?endpoint=eq.${encodeURIComponent(s.endpoint)}`, { method: 'DELETE' });
    } else { failed++; console.error(`Failed for ${s.employees.name}: ${e.statusCode || ''} ${e.body || e.message}`); }
  }
}

if (failed && !ok) {
  console.error(`${kind}: every send failed. Not marking as sent, so the next hourly run will try again.`);
  process.exit(1);
}
if (kind !== 'test') {
  await db('/notification_log', { method: 'POST', body: JSON.stringify({ key: logKey }), headers: { Prefer: 'resolution=ignore-duplicates' } });
}
console.log(`${kind}: sent ${ok}, removed ${gone} expired, ${failed} failed.`);
