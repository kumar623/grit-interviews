# GRIT Track Badge interview scheduling

Working prototype for the GRIT (NIAT) interview scheduling assignment.

- **Live prototype:** https://grit-web-production.up.railway.app
- **Write-up (2 pages):** [docs/writeup.pdf](docs/writeup.pdf)
- **PRD:** [docs/PRD.md](docs/PRD.md)

Sign in with the one-tap demo accounts on the login page: 12 students, 3 interviewers and 1 interview team member. Inside the app, **Switch account** jumps to any of them in one tap. Every demo account uses the password `grit-demo-2026`. Demo data resets itself daily, and "Reset demo" in the top bar restores it at any time.

## What it does

- Students who have cleared every skill for a Track Badge book a 30-minute interview, and can reschedule or cancel until 12 hours before.
- Interviewers set weekly working hours (for example Monday to Friday, 10 AM to 5 PM, weekends off) and days off. Open slots for the next 3 weeks follow automatically; single slots can still be opened or closed by hand. A day off that already has bookings asks first, then cancels them and tells the students, without costing them an attempt.
- Who takes the interview is automatic: the student picks a time, and the database assigns an interviewer who assesses that track, is free then, and has the fewest interviews that week. The student sees who it is, and the interviewer gets a notice and the interview on their schedule.
- Interviewers record the outcome: passed, not cleared, retake later, or no-show.
- Students see their status, result and feedback on their home screen.
- The interview team sees who has booked and who hasn't, sends reminders, and can flag malpractice, which nullifies the badge.
- Every user has a profile page. Students see their Miles, rank, Track Badges and full interview history; the team can open any student's profile, including private notes and malpractice flags. Interviewers can set their own meeting link.
- The team's Interviewers page shows everyone's hours, days off and capacity for the week.
- "Before and after" shows the student home card, badge shelf, leaderboard row and public profile for each outcome.

## How it is built

| Part | Where |
|---|---|
| Front end | `index.html`: one page, vanilla JS, Supabase JS client |
| Hosting | Railway function (`server.ts`): serves `index.html` from `main`, so a push updates the live site within a minute |
| Database, login, live updates | Supabase: Postgres, Auth, row level security, Realtime |
| Schema, access rules | `supabase/migrations/0001_schema_and_rls.sql` |
| GRIT tracks and skill levels | `supabase/migrations/0005_grit_terminology.sql` |
| Working hours, days off, profiles | `supabase/migrations/0006_hours_time_off_profiles.sql` |
| Interviewer assignment | `supabase/migrations/0007_auto_assignment.sql` |
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

Tracks, badges and skill levels follow grit.niatindia.com (the AI Product Mastery Novice Badge skills are the published example; the AI Systems Mastery list is a placeholder). The look follows the GRIT dashboard: dark by default with a left sidebar, and a Light mode switch. Cooldown (14 days) and attempts (3 per badge) are assumptions to confirm with the GRIT team.
