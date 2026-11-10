// Checks the page's behaviour when the login session ends: the server refuses app_state
// the way Supabase does for a signed-out caller, and sign-out must be local to this browser.
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
const umd = fs.readFileSync(path.join(__dirname, 'node_modules/@supabase/supabase-js/dist/umd/supabase.js'), 'utf8');
const now = Date.now();
const state = { me: { id: 'u', role: 'student', name: 'Aarav Sharma', email: 'aarav@grit.demo' }, now: new Date(now).toISOString(), open_times: { fullstack: [], data: [] }, leaderboard: [],
  tracks: [{ id: 'fullstack', name: 'AI Product Mastery', skills: [{ name: 'CS Fundamentals L1', cleared: true }], status: { state: 'eligible', skills_total: 1, skills_cleared: 1, attempts_used: 0, max_attempts: 3 } }] };
(async () => {
  const b = await chromium.launch();
  const page = await (await b.newContext({ viewport: { width: 1200, height: 800 } })).newPage();
  const errs = [], logouts = [];
  let deny = false;
  page.on('pageerror', e => errs.push(e.message));
  await page.route('**/*', r => {
    const u = r.request().url();
    const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' };
    if (u.startsWith('file:')) return r.continue();
    if (u.includes('jsdelivr')) return r.fulfill({ contentType: 'text/javascript', body: umd });
    if (r.request().method() === 'OPTIONS') return r.fulfill({ status: 200, headers: cors });
    if (u.includes('/auth/v1/token')) return r.fulfill({ contentType: 'application/json', headers: cors, body: JSON.stringify({ access_token: 'a.e30.c', token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(now / 1000) + 3600, refresh_token: 'r', user: { id: 'u', aud: 'authenticated', email: 'aarav@grit.demo', role: 'authenticated' } }) });
    if (u.includes('/auth/v1/logout')) { logouts.push(u.split('/auth/v1/')[1]); return r.fulfill({ status: 204, headers: cors }); }
    if (u.includes('/rpc/app_state')) return deny
      ? r.fulfill({ status: 401, contentType: 'application/json', headers: cors, body: JSON.stringify({ code: '42501', message: 'permission denied for function app_state' }) })
      : r.fulfill({ contentType: 'application/json', headers: cors, body: JSON.stringify(state) });
    if (u.includes('/rpc/')) return r.fulfill({ contentType: 'application/json', headers: cors, body: 'null' });
    return r.abort();
  });
  await page.goto('file://' + path.join(__dirname, '..', 'index.html'));
  await page.click('.acct');
  await page.waitForSelector('text=Hi Aarav');
  console.log('1. signed in, dashboard shown');

  // Session ends elsewhere: the next data refresh is refused.
  deny = true;
  await page.click('.nav >> text=Profile').catch(() => {});
  await page.click('text=Reset demo');
  await page.waitForSelector('text=Your session ended', { timeout: 5000 });
  const raw = await page.locator('text=permission denied').count();
  console.log('2. refused refresh -> login page with "session ended" message; raw error shown:', raw > 0);
  await page.screenshot({ path: process.argv[2] + '/session-ended.png' });

  // Signing in again works, and sign-out / switch only end this browser's session.
  deny = false;
  await page.click('.acct');
  await page.waitForSelector('text=Hi Aarav');
  console.log('3. signed in again');
  await page.click('text=Switch account');
  await page.click('.modal .acct >> text=Priya Menon');
  await page.waitForSelector('.wrap');
  await page.click('text=Sign out');
  await page.waitForSelector('text=Sign in');
  console.log('4. logout requests:', logouts.join(', '));
  console.log('page errors:', errs.length ? errs : 'none');
  await b.close();
})().catch(e => { console.error('FAILED', e.message); process.exit(1); });
