# PRD: GRIT Track Badge Interview Scheduling
## 1. Context
GRIT is NIAT's year-long skilling competition. A student who clears every skill a Track Badge needs must pass a live online interview to earn the badge. A small interviewer team runs these with their own availability. A badge is nullified if the student is later flagged for malpractice. Today there is no product flow for booking, running, or tracking these interviews.

GRIT terminology (Miles, Tracks, Novice to Grand Master badges, skill levels L1 to L4, Level Clearance Interview, Qualiflyers) follows grit.niatindia.com/how-grit-works. The visual style follows the GRIT dashboard (dark, left sidebar), with a light mode switch.

## 2. Goals and success measures
- Eligible students book without help from staff: 80% book within 7 days of becoming eligible.
- Zero double-bookings, guaranteed by the database rather than the UI.
- Every completed interview has an outcome recorded within 24h.
- The team can answer "who is eligible and hasn't booked" in one screen.

Non-goals (v1): video calling (we link out to Meet), automatic interviewer scoring, appeals workflow, payments, mobile app.

## 3. Users and login
Yes, it has login. Supabase Auth (email + password), one `profiles.role` per account: `student`, `interviewer`, `team`. Row Level Security enforces what each role can read and write. The login page has three "Sign in as demo Student / Interviewer / Interview team" buttons so an evaluator gets in with one click, no credentials to hunt for.

## 4. Requirements
**Student**
- S1 Home shows a per-track interview card that reflects the current state (table in §5).
- S2 Book: pick date → 30-min slot (IST, pooled across interviewers; student does not choose the interviewer) → confirm.
- S3 Reschedule or cancel until 12h before start.
- S4 See result, interviewer feedback, next step (badge, cooldown end date, or rebook).
- S5 Slots update live; if someone else takes the slot first, show a clear message and fresh slots.

**Interviewer**
- I1 Weekly availability grid; open/close 30-min slots; a booked slot cannot be silently removed (cancel with reason, student notified and given priority rebooking).
- I2 Daily schedule: student, track, attempt number, join link.
- I3 Record outcome: Pass / Fail / Retake later / No-show, notes required; editable for 24h, every change audited.

**Interview team**
- T1 Eligible students table: Booked / Not booked / Awaiting result / Completed, days since eligible, reminder action.
- T2 Capacity view: open slots this week vs. un-booked eligible students.
- T3 Flag malpractice: nullifies the badge, cancels any upcoming booking, logged with reason.

## 5. States
| State | Enters when | Moves to |
|---|---|---|
| Not eligible | default | Eligible (last required skill cleared) |
| Eligible, not booked | skills cleared; after cancel, retake, or cooldown end | Booked |
| Booked | slot confirmed | Eligible (student/interviewer cancels), Booked (reschedule), Awaiting result (slot ends), No-show |
| Awaiting result | slot ended, no outcome yet | Passed, Failed, Retake later, No-show |
| Passed, badge awarded | outcome = pass | Nullified |
| Failed, cooldown | outcome = fail | Eligible after 14 days (max 3 attempts, assumed) |
| Retake later | outcome = retake (tech issue, incomplete) | Eligible at once, attempt not counted |
| No-show | absent 10 min after start | Eligible; second no-show counts as an attempt |
| Nullified | malpractice flag, from any state | terminal for that track |

## 6. Edge cases and assumptions
Two students, same slot at the same moment; double-click on confirm; student eligible for two tracks (one active booking per track, no overlapping times); interviewer cancels or is sick; late cancel; no slots open (notify-me waitlist); interviewer no-show (retake, not counted); outcome never recorded (team nudge at 24h); outcome recorded wrongly; malpractice flagged while booked or after pass; skill clearance revoked after booking; store UTC, show IST; season end cutoff. Open questions for the GRIT team: cooldown length, attempt cap, points impact of a nullified badge, whether interviewers specialise by track.

## 7. Data model (Supabase Postgres)
`profiles` (id, role, name) · `tracks` · `track_skills` · `student_skills` · `eligibility` (student_id, track_id, eligible_at) · `slots` (id, interviewer_id, starts_at, ends_at, status open/booked/blocked) · `bookings` (id, slot_id, student_id, track_id, attempt_no, status, meet_url) · `outcomes` (booking_id, result, notes, recorded_by, recorded_at) · `malpractice_flags` · `audit_log`.

Double-booking prevention, three layers:
1. Partial unique index `bookings(slot_id) WHERE status IN ('booked','completed')`.
2. Booking only through the `book_slot()` RPC: one transaction doing `UPDATE slots SET status='booked' WHERE id=$1 AND status='open'`; zero rows = slot taken.
3. Partial unique index `(student_id, track_id) WHERE status='booked'` so a student can't hold two slots.

## 8. Student messages (exact copy)
1. "You've cleared every skill level for the Novice Badge in AI Product Mastery. Book your interview to earn the badge and its Miles." [Book interview]
2. "Interview booked for Thu, 12 Nov, 4:00 PM IST. Your join link opens 10 minutes before. You can reschedule until 4:00 AM that day."
3. "You didn't clear the AI Product Mastery interview this time. Your skill levels stay cleared, and you can book again from 26 Nov." (followed by interviewer feedback)

Secondary: pass ("You earned the Novice Badge in AI Product Mastery."), slot taken ("That slot was just booked by someone else. Here are the nearest open times."), nullified.

## 9. Before and after screens
Student home, badge shelf, and public profile/leaderboard row, each shown before the result and after pass / fail / retake / nullified. Built as real states plus a "Before / After" compare view in the app.

## 10. Design direction
Apple-style and quiet: system font stack (SF Pro where available), warm off-white and soft gray surfaces, hairline borders, generous spacing, large calm type, one muted accent (deep ink blue or graphite, no purple, no gradients, no glow). Surfaces and dividers are low contrast; body text stays readable. Higgsfield is used for the Track Badge artwork and the login/hero visual, if its image generation tools are available in the session (only its ads tools are listed right now); fallback is hand-drawn SVG badges.

## 11. What should impress the reviewer
- It is a real app with login, roles, and a database, not a mock-up.
- A "Race test" button on the team screen fires 20 simultaneous bookings at one slot and shows exactly 1 succeed, 19 rejected, live from Postgres.
- Slots update in real time across two open browsers (Supabase Realtime).
- A guided "Demo tour" page walks the reviewer through the brief's six points with deep links.
- Audit log visible on every outcome and nullification.

