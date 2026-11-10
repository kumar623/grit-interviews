const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
const out = process.argv[2];
const umd = fs.readFileSync(path.join(__dirname, 'node_modules/@supabase/supabase-js/dist/umd/supabase.js'), 'utf8');
const H = 36e5, D = 864e5, now = Date.now();
const iso = t => new Date(t).toISOString();
const hr = Math.floor(now / H) * H;
const skills = (n, names) => names.map((x, i) => ({ name: x, cleared: i < n }));
const FS = ['Computational Thinking L1', 'CS Fundamentals L1', 'Applied Gen AI Development L1', 'UI Engineering L2', 'SQL L2'];
const base = { skills_total: 5, skills_cleared: 5, attempts_used: 0, max_attempts: 3 };
const tomorrow4 = Math.floor(now / D) * D + D * 2 + 10.5 * H;
const st = {
  eligible: { ...base, state: 'eligible', eligible_at: iso(now - 2 * D) },
  not_eligible: { ...base, state: 'not_eligible', skills_cleared: 3 },
  booked: { ...base, state: 'booked', booking: { id: 'b1', starts_at: iso(tomorrow4), ends_at: iso(tomorrow4 + H / 2), meet_url: 'https://meet.google.com/x', interviewer: 'Priya Menon', attempt_no: 1 } },
  awaiting_result: { ...base, state: 'awaiting_result', booking: { id: 'b2', starts_at: iso(hr - H), ends_at: iso(hr - H / 2), interviewer: 'Priya Menon' } },
  passed: { ...base, state: 'passed', badge_awarded_at: iso(now - 10 * D), last_outcome: { result: 'pass', feedback: 'Clear thinking on API design.', interviewer: 'Arjun Rao' } },
  cooldown: { ...base, state: 'cooldown', attempts_used: 1, cooldown_until: iso(now + 9 * D), last_outcome: { result: 'fail', feedback: 'Revise SQL joins.', interviewer: 'Neha Kapoor' } },
  nullified: { ...base, state: 'nullified', nullified_at: iso(now - 3 * D) },
};
const lb = [['Meera Iyer', 1500, 1], ['Aarav Sharma', 800, 0], ['Diya Patel', 500, 0], ['Ishaan Khan', 400, 0]].map((x, i) => ({ name: x[0], points: x[1], badges: x[2], rank: i + 1, campus: 'Pune', me: i === 1 }));
const times = []; for (let d = 1; d < 8; d++) for (const h of [4.5, 5, 5.5, 6, 9.5, 10, 10.5, 11.5, 12, 12.5]) times.push(iso(Math.floor(now / D) * D + d * D + h * H));
const student = (states) => ({ me: { id: 's', role: 'student', name: 'Aarav Sharma' }, now: iso(now), open_times: times, leaderboard: lb,
  tracks: states.map((s, i) => ({ id: i ? 'data' : 'fullstack', name: i ? 'AI Systems Mastery' : 'AI Product Mastery', skills: skills(st[s].skills_cleared, FS), status: st[s] })) });
const bk = (name, o, extra) => ({ id: 'b' + name, status: 'booked', student: name, student_id: 'x', campus: 'Pune', track: 'AI Product Mastery', track_id: 'fullstack', attempt_no: 1, meet_url: 'https://meet.google.com/x', outcome: o || null, ...extra });
const slots = [
  { id: '1', starts_at: iso(hr - H), ends_at: iso(hr - H / 2), status: 'booked', interviewer: 'Priya Menon', booking: bk('Kabir Reddy') },
  { id: '2', starts_at: iso(hr + 2 * H), ends_at: iso(hr + 2.5 * H), status: 'booked', interviewer: 'Priya Menon', booking: bk('Diya Patel') },
  { id: '3', starts_at: iso(hr - 3 * H), ends_at: iso(hr - 2.5 * H), status: 'booked', interviewer: 'Arjun Rao', booking: bk('Meera Iyer', { result: 'pass', feedback: 'Good', notes: 'Strong across the board.', editable: true, recorded_at: iso(now) }) },
  ...times.slice(0, 40).map((t, i) => ({ id: 't' + i, starts_at: t, ends_at: iso(new Date(t).getTime() + H / 2), status: 'open', interviewer: 'Priya Menon', booking: null })),
];
const interviewer = { me: { id: 'i', role: 'interviewer', name: 'Priya Menon' }, now: iso(now), slots };
const row = (n, s, extra) => ({ student_id: n, name: n, email: 'x', campus: 'Pune', track_id: 'fullstack', track: 'AI Product Mastery', status: st[s], ...extra });
const team = { me: { id: 't', role: 'team', name: 'Sanjay Kulkarni' }, now: iso(now), slots,
  students: [row('Aarav Sharma', 'eligible'), row('Sneha Gupta', 'eligible', { status: { ...st.eligible, eligible_at: iso(now - 9 * D) }, last_reminder_at: iso(now - 4 * D) }), row('Diya Patel', 'booked'), row('Kabir Reddy', 'awaiting_result'), row('Meera Iyer', 'passed'), row('Rohan Verma', 'cooldown'), row('Vikram Singh', 'nullified'), row('Ishaan Khan', 'not_eligible')],
  audit: [{ at: iso(now - D), actor: 'Neha Kapoor', action: 'outcome_recorded', student: 'Rohan Verma', track: 'AI Product Mastery', detail: { result: 'fail' } }, { at: iso(now - 3 * D), actor: 'Sanjay Kulkarni', action: 'badge_nullified', student: 'Vikram Singh', track: 'AI Product Mastery', detail: { reason: 'Copied submissions.' } }] };
let state = null, calls = [];
(async () => {
  const browser = await chromium.launch();
  const run = async (name, width, data, steps) => {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 1 });
    if (process.env.THEME) await ctx.addInitScript(t => { try { localStorage.setItem('grit-theme', t); } catch (e) {} }, process.env.THEME);
    const page = await ctx.newPage();
    const errs = [];
    page.on('pageerror', e => errs.push(e.message));
    await page.route('**/*', r => {
      const u = r.request().url();
      if (u.startsWith('file:')) return r.continue();
      if (u.includes('jsdelivr')) return r.fulfill({ contentType: 'text/javascript', body: umd });
      if (u.includes('fonts.g')) return r.continue();
      const json = b => r.fulfill({ contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify(b) });
      if (r.request().method() === 'OPTIONS') return r.fulfill({ status: 200, headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' } });
      if (u.includes('/auth/v1/token')) return json({ access_token: 'a.e30.c', token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(now / 1000) + 3600, refresh_token: 'r', user: { id: 'u', aud: 'authenticated', email: 'a@grit.demo', role: 'authenticated' } });
      if (u.includes('/rpc/app_state')) return json(state);
      if (u.includes('/rpc/race_setup')) return json('2099-01-01T00:00:00Z');
      if (u.includes('/rpc/race_attempt')) { const n = JSON.parse(r.request().postData()).p_n; return json({ n, ok: n === 7, error: 'SLOT_TAKEN' }); }
      if (u.includes('/rpc/race_cleanup')) return json({ bookings_created: 1 });
      if (u.includes('/rpc/book_slot') && state.failBook) { state.failBook = false; return r.fulfill({ status: 400, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify({ message: 'SLOT_TAKEN' }) }); }
      if (u.includes('/rpc/')) { calls.push(u.split('/rpc/')[1] + ' ' + r.request().postData()); return json(null); }
      return r.abort();
    });
    await page.goto('file://' + path.join(__dirname, '..', 'index.html'));
    await page.waitForSelector('.acct');
    if (!data) { await page.screenshot({ path: `${out}/${name}.png`, fullPage: true }); }
    else {
      state = data;
      await page.click('.acct');
      await page.waitForSelector('.wrap');
      await steps(page, async (n) => { await page.waitForTimeout(150); await page.screenshot({ path: `${out}/${name}-${n}.png`, fullPage: true }); });
    }
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
    console.log(name, 'errors:', errs.length ? errs : 'none', 'hscroll:', overflow);
    await ctx.close();
  };
  await run('login', 1200);
  await run('login-m', 390);
  const studentSteps = async (p, shot) => {
    await shot('home');
    await p.click('text=Book interview'); await p.waitForSelector('.times'); await p.click('.time >> nth=2'); await shot('book');
    state.failBook = true; await p.click('text=Confirm booking'); await p.waitForSelector('.msg.warn'); await shot('book-taken');
    await p.click('.time >> nth=1'); await p.click('text=Confirm booking'); await p.waitForSelector('.toast'); await shot('booked-toast');
    await p.click('.nav >> text=Before and after'); await shot('compare-pass');
    for (const k of ['Not cleared', 'Retake later', 'Nullified']) { await p.click(`.seg >> text=${k}`); await shot('compare-' + k.split(' ')[0].toLowerCase()); }
  };
  await run('student', 1200, student(['eligible', 'not_eligible']), studentSteps);
  await run('student-m', 390, student(['eligible', 'not_eligible']), async (p, shot) => { await shot('home'); await p.click('text=Book interview'); await p.click('.time >> nth=2'); await shot('book'); await p.click('.nav >> text=Before and after'); await shot('compare'); });
  for (const [a, b] of [['booked', 'awaiting_result'], ['passed', 'cooldown'], ['nullified', 'eligible']])
    await run('student-' + a, 1200, student([a, b]), async (p, shot) => { await shot('home'); });
  const ivSteps = async (p, shot) => {
    await shot('schedule');
    await p.click('text=Record outcome'); await p.click('.opt >> text=Not cleared'); await p.fill('#fb', 'Revise SQL joins.'); await p.fill('#nt', 'Could not write a join.'); await shot('outcome');
    await p.click('text=Save outcome'); await p.waitForSelector('.toast');
    await p.click('.nav >> text=Availability'); await shot('availability');
    await p.click('.cell:not(.open):not(.booked):not([disabled]) >> nth=5');
  };
  await run('interviewer', 1200, interviewer, ivSteps);
  await run('interviewer-m', 390, interviewer, async (p, shot) => { await shot('schedule'); await p.click('.nav >> text=Availability'); await shot('availability'); });
  const teamSteps = async (p, shot) => {
    await shot('students');
    await p.click('.seg >> text=Needs attention'); await shot('attention'); await p.click('.seg >> text=All');
    await p.click('text=Remind >> nth=0'); await p.waitForSelector('.toast');
    await p.click('text=Flag >> nth=0'); await p.fill('#rs', 'Copied code in contest'); await shot('flag'); await p.click('text=Nullify badge'); await p.waitForTimeout(300);
    await p.click('.nav >> text=Interviews'); await shot('interviews');
    await p.click('.nav >> text=Audit log'); await shot('audit');
    await p.click('.nav >> text=Race test'); await p.click('text=Fire 20 bookings'); await p.waitForSelector('.dot.win'); await shot('race');
  };
  await run('team', 1200, team, teamSteps);
  await run('team-m', 390, team, async (p, shot) => { await shot('students'); });
  console.log(calls.join('\n'));
  await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
