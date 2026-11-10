# GRIT Track Badge interview scheduling

Working prototype for the GRIT (NIAT) interview scheduling assignment.

- **Live prototype:** https://grit-web-production.up.railway.app
- **Write-up (2 pages):** [docs/writeup.pdf](docs/writeup.pdf)
- **PRD:** [docs/PRD.md](docs/PRD.md)

Sign in with the one-tap demo accounts on the login page (Student, Interviewer, Interview team). Every demo account uses the password `grit-demo-2026`. Demo data resets itself daily, and "Reset demo" in the top bar restores it at any time.

## What it does

- Students who have cleared every skill for a Track Badge book a 30-minute interview, and can reschedule or cancel until 12 hours before.
- Interviewers open and close availability and record the outcome: passed, not cleared, retake later, or no-show.
- Students see their status, result and feedback on their home screen.
- The interview team sees who has booked and who hasn't, sends reminders, and can flag malpractice, which nullifies the badge.
- "Before and after" shows the student home card, badge shelf, leaderboard row and public profile for each outcome.

## How it is built

| Part | Where |
|---|---|
| Front end | `index.html`: one page, vanilla JS, Supabase JS client |
| Hosting | Railway function (`server.ts` is `index.html` wrapped in a small Bun server) |
| Database, login, live updates | Supabase: Postgres, Auth, row level security, Realtime |
| Schema, access rules | `supabase/migrations/0001_schema_and_rls.sql` |
| Booking, outcomes, nullification | `supabase/migrations/0003_interview_logic.sql` |

The browser never writes to tables. Every write goes through a database function that checks the caller's role and writes to the audit log.

Two migrations are applied to the Supabase project but not yet exported to this repo: `demo_accounts` (creates the demo logins) and `app_state_and_seed` (the per-role data feed and the demo seed data). They are in the project's migration history.

## How double booking is prevented

Booking is one transaction (`private.claim` in `0003_interview_logic.sql`):

1. Lock one open slot at the chosen time with `for update skip locked`. Interviewers are pooled, so the student picks a time and the database picks a free interviewer.
2. Flip it to booked only if it is still open.
3. Two partial unique indexes back this up: one live booking per slot, and one upcoming booking per student per track.

Checked against the live database with real sign-ins: 20 simultaneous bookings on one slot gave 1 booked and 19 rejected. The interview team can rerun this from the **Race test** tab.

## Local screenshots

`test/shots.js` opens `index.html` in Chromium with stand-in data and screenshots every screen:

```bash
cd test && npm install && node shots.js ./out
```

## Assumptions

Track names, skills and points are placeholders. Cooldown (14 days), attempts (3 per track) and badge points (500) are assumptions to confirm with the GRIT team. See the write-up for the full list.
