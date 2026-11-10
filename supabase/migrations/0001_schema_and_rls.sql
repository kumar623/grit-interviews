create schema if not exists private;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('student','interviewer','team')),
  full_name text not null,
  email text not null,
  campus text
);

create table public.tracks (
  id text primary key,
  name text not null,
  hidden boolean not null default false
);

create table public.track_skills (
  id serial primary key,
  track_id text not null references public.tracks(id),
  name text not null,
  position int not null default 0
);

create table public.student_skills (
  student_id uuid not null references public.profiles(id) on delete cascade,
  skill_id int not null references public.track_skills(id) on delete cascade,
  cleared_at timestamptz not null default now(),
  primary key (student_id, skill_id)
);

create table public.slots (
  id uuid primary key default gen_random_uuid(),
  interviewer_id uuid not null references public.profiles(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'open' check (status in ('open','booked','blocked')),
  unique (interviewer_id, starts_at),
  check (ends_at > starts_at)
);
create index slots_open_time on public.slots(starts_at) where status = 'open';

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid not null references public.slots(id),
  student_id uuid not null references public.profiles(id),
  track_id text not null references public.tracks(id),
  attempt_no int not null default 1,
  status text not null default 'booked' check (status in ('booked','completed','no_show','cancelled')),
  meet_url text,
  cancelled_by text,
  cancel_reason text,
  cancelled_at timestamptz,
  created_at timestamptz not null default now()
);
-- Guard 1: a slot can hold at most one live booking.
create unique index one_live_booking_per_slot on public.bookings(slot_id)
  where status in ('booked','completed','no_show');
-- Guard 2: a student can hold at most one upcoming interview per track.
create unique index one_open_booking_per_student_track on public.bookings(student_id, track_id)
  where status = 'booked';
create index bookings_student on public.bookings(student_id, track_id);

create table public.outcomes (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  result text not null check (result in ('pass','fail','retake','no_show')),
  feedback text,
  recorded_by uuid references public.profiles(id),
  recorded_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Interviewer-only notes live outside the exposed schema so students can never read them.
create table private.outcome_notes (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  notes text not null
);

create table public.track_standing (
  student_id uuid not null references public.profiles(id) on delete cascade,
  track_id text not null references public.tracks(id),
  badge_awarded_at timestamptz,
  nullified_at timestamptz,
  primary key (student_id, track_id)
);

create table public.malpractice_flags (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  track_id text not null references public.tracks(id),
  reason text not null,
  flagged_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.audit_log (
  id bigserial primary key,
  actor_id uuid,
  actor_name text,
  action text not null,
  student_id uuid,
  track_id text,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index audit_recent on public.audit_log(created_at desc);

create table private.demo_meta (
  id int primary key default 1 check (id = 1),
  seeded_on date
);
insert into private.demo_meta(id, seeded_on) values (1, null);

-- Role helper used by policies.
create function private.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;
grant usage on schema private to authenticated;
revoke all on all tables in schema private from anon, authenticated;
revoke execute on function private.my_role() from public, anon;
grant execute on function private.my_role() to authenticated;

alter table public.profiles enable row level security;
alter table public.tracks enable row level security;
alter table public.track_skills enable row level security;
alter table public.student_skills enable row level security;
alter table public.slots enable row level security;
alter table public.bookings enable row level security;
alter table public.outcomes enable row level security;
alter table public.track_standing enable row level security;
alter table public.malpractice_flags enable row level security;
alter table public.audit_log enable row level security;

-- Read-only policies. Every write goes through an audited RPC, so there are no write policies.
create policy profiles_read on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.my_role()) in ('interviewer','team'));
create policy tracks_read on public.tracks for select to authenticated using (true);
create policy track_skills_read on public.track_skills for select to authenticated using (true);
create policy student_skills_read on public.student_skills for select to authenticated
  using (student_id = (select auth.uid()) or (select private.my_role()) in ('interviewer','team'));
create policy slots_read on public.slots for select to authenticated using (true);
create policy bookings_read on public.bookings for select to authenticated
  using (student_id = (select auth.uid()) or (select private.my_role()) in ('interviewer','team'));
create policy outcomes_read on public.outcomes for select to authenticated
  using ((select private.my_role()) in ('interviewer','team')
     or exists (select 1 from public.bookings b where b.id = booking_id and b.student_id = (select auth.uid())));
create policy standing_read on public.track_standing for select to authenticated
  using (student_id = (select auth.uid()) or (select private.my_role()) in ('interviewer','team'));
create policy flags_read on public.malpractice_flags for select to authenticated
  using ((select private.my_role()) = 'team');
create policy audit_read on public.audit_log for select to authenticated
  using ((select private.my_role()) in ('interviewer','team'));

revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;
revoke all on all tables in schema public from anon;

alter publication supabase_realtime add table public.slots, public.bookings, public.outcomes, public.track_standing;

insert into public.tracks(id, name, hidden) values
  ('fullstack', 'Full Stack', false),
  ('data', 'Data & AI', false),
  ('race-test', 'Race test', true);
insert into public.track_skills(track_id, name, position) values
  ('fullstack','HTML & CSS',1),('fullstack','JavaScript',2),('fullstack','React',3),('fullstack','Node & APIs',4),('fullstack','SQL Databases',5),
  ('data','Python',1),('data','Statistics',2),('data','SQL for Analysis',3),('data','Machine Learning',4),('data','Data Visualisation',5);
