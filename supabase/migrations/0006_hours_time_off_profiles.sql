-- Working hours, days off, profile fields, two more demo students, and the profile feed.

alter table public.profiles
  add column if not exists phone text,
  add column if not exists batch text,
  add column if not exists bio text,
  add column if not exists meet_url text;

-- One row per working weekday (0 = Sunday ... 6 = Saturday). No row = day off every week.
create table public.interviewer_hours (
  interviewer_id uuid not null references public.profiles(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  start_time time not null,
  end_time time not null,
  primary key (interviewer_id, weekday),
  check (end_time > start_time)
);

-- One-off days off (leave, holidays).
create table public.time_off (
  interviewer_id uuid not null references public.profiles(id) on delete cascade,
  off_date date not null,
  reason text,
  created_at timestamptz not null default now(),
  primary key (interviewer_id, off_date)
);

alter table public.interviewer_hours enable row level security;
alter table public.time_off enable row level security;
create policy hours_read on public.interviewer_hours for select to authenticated
  using (interviewer_id = (select auth.uid()) or (select private.my_role()) = 'team');
create policy time_off_read on public.time_off for select to authenticated
  using (interviewer_id = (select auth.uid()) or (select private.my_role()) = 'team');
revoke all on public.interviewer_hours, public.time_off from anon;
revoke insert, update, delete, truncate on public.interviewer_hours, public.time_off from authenticated;

-- Two more demo students.
do $$
declare r record;
begin
  for r in select * from (values
      ('00000000-0000-4000-a000-000000000015'::uuid, 'nikhil@grit.demo', 'Nikhil Das', 'Kolkata'),
      ('00000000-0000-4000-a000-000000000016'::uuid, 'pooja@grit.demo', 'Pooja Shetty', 'Bengaluru')
    ) as t(id, email, full_name, campus)
  loop
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token,
      email_change_token_current, phone_change, phone_change_token, reauthentication_token
    ) values (
      '00000000-0000-0000-0000-000000000000', r.id, 'authenticated', 'authenticated', r.email,
      extensions.crypt('grit-demo-2026', extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', r.full_name), now(), now(),
      '', '', '', '', '', '', '', ''
    );
    insert into auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), r.id, jsonb_build_object('sub', r.id::text, 'email', r.email, 'email_verified', true),
      'email', r.id::text, now(), now(), now());
    insert into public.profiles (id, role, full_name, email, campus) values (r.id, 'student', r.full_name, r.email, r.campus);
  end loop;
end $$;

-- Open times an interviewer should have over the next 3 weeks, from their hours minus days off (IST).
create function private.desired_slots(p_iv uuid) returns table(ts timestamptz)
language sql stable security definer set search_path = public as $$
  select (t at time zone 'Asia/Kolkata') as ts
  from generate_series((now() at time zone 'Asia/Kolkata')::date, (now() at time zone 'Asia/Kolkata')::date + 20, interval '1 day') d
  join interviewer_hours h on h.interviewer_id = p_iv and h.weekday = extract(dow from d)::int
  cross join lateral generate_series(d::date + h.start_time, d::date + h.end_time - interval '30 minutes', interval '30 minutes') t
  where not exists (select 1 from time_off o where o.interviewer_id = p_iv and o.off_date = d::date)
    and (t at time zone 'Asia/Kolkata') > now() + interval '30 minutes'
$$;

-- Make the next 3 weeks of open slots match the pattern. Booked slots are never touched.
create function private.regen_slots(p_iv uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_end timestamptz := (((now() at time zone 'Asia/Kolkata')::date + 21)::timestamp) at time zone 'Asia/Kolkata';
  v_n int;
begin
  delete from slots s
   where s.interviewer_id = p_iv and s.starts_at > now() and s.starts_at < v_end and s.status in ('open','blocked')
     and not exists (select 1 from private.desired_slots(p_iv) w where w.ts = s.starts_at)
     and not exists (select 1 from bookings b where b.slot_id = s.id);
  update slots s set status = 'blocked'
   where s.interviewer_id = p_iv and s.starts_at > now() and s.starts_at < v_end and s.status = 'open'
     and not exists (select 1 from private.desired_slots(p_iv) w where w.ts = s.starts_at);
  insert into slots(interviewer_id, starts_at, ends_at)
  select p_iv, w.ts, w.ts + interval '30 minutes' from private.desired_slots(p_iv) w
  on conflict (interviewer_id, starts_at) do update set status = 'open' where slots.status = 'blocked';
  select count(*) into v_n from slots where interviewer_id = p_iv and status = 'open' and starts_at > now();
  return v_n;
end $$;

create function public.save_hours(p_hours jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); r jsonb; v_s time; v_e time; v_open int;
begin
  if private.my_role() is distinct from 'interviewer' then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(p_hours) is distinct from 'array' then raise exception 'BAD_HOURS'; end if;
  delete from interviewer_hours where interviewer_id = v_uid;
  for r in select * from jsonb_array_elements(p_hours) loop
    v_s := (r->>'start')::time; v_e := (r->>'end')::time;
    if v_e <= v_s or extract(minute from v_s) not in (0, 30) or extract(minute from v_e) not in (0, 30) then
      raise exception 'BAD_HOURS';
    end if;
    insert into interviewer_hours values (v_uid, (r->>'weekday')::int, v_s, v_e);
  end loop;
  v_open := private.regen_slots(v_uid);
  perform private.audit('hours_saved', null, null, jsonb_build_object('working_days', jsonb_array_length(p_hours)));
  return jsonb_build_object('open_slots', v_open);
end $$;

create function public.add_time_off(p_date date, p_reason text, p_cancel boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_from timestamptz := (p_date::timestamp) at time zone 'Asia/Kolkata';
  v_n int; v_bk record;
begin
  if private.my_role() is distinct from 'interviewer' then raise exception 'NOT_ALLOWED'; end if;
  if p_date is null or p_date < (now() at time zone 'Asia/Kolkata')::date then raise exception 'SLOT_PAST'; end if;
  select count(*) into v_n from bookings b join slots s on s.id = b.slot_id
   where s.interviewer_id = v_uid and b.status = 'booked' and s.starts_at >= v_from and s.starts_at < v_from + interval '1 day' and s.starts_at > now();
  if v_n > 0 and not coalesce(p_cancel, false) then raise exception 'HAS_BOOKINGS:%', v_n; end if;
  insert into time_off(interviewer_id, off_date, reason) values (v_uid, p_date, nullif(trim(p_reason), ''))
  on conflict (interviewer_id, off_date) do update set reason = excluded.reason;
  for v_bk in select b.id, b.student_id, b.track_id, s.id as slot_id, s.starts_at from bookings b join slots s on s.id = b.slot_id
     where s.interviewer_id = v_uid and b.status = 'booked' and s.starts_at >= v_from and s.starts_at < v_from + interval '1 day' and s.starts_at > now() loop
    update bookings set status = 'cancelled', cancelled_by = 'interviewer', cancel_reason = 'Interviewer is on leave', cancelled_at = now() where id = v_bk.id;
    update slots set status = 'blocked' where id = v_bk.slot_id;
    perform private.audit('cancelled', v_bk.student_id, v_bk.track_id, jsonb_build_object('by', 'interviewer', 'reason', 'Day off', 'starts_at', v_bk.starts_at));
  end loop;
  perform private.regen_slots(v_uid);
  perform private.audit('day_off_added', null, null, jsonb_build_object('date', p_date, 'reason', nullif(trim(p_reason), ''), 'cancelled', v_n));
  return jsonb_build_object('cancelled', v_n);
end $$;

create function public.remove_time_off(p_date date) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if private.my_role() is distinct from 'interviewer' then raise exception 'NOT_ALLOWED'; end if;
  delete from time_off where interviewer_id = v_uid and off_date = p_date;
  perform private.regen_slots(v_uid);
  perform private.audit('day_off_removed', null, null, jsonb_build_object('date', p_date));
end $$;

-- One-off open/close of a single half hour. Now refuses days off, so the grid can't contradict them.
create or replace function public.set_slot(p_starts timestamptz, p_open boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_status text;
begin
  if private.my_role() is distinct from 'interviewer' then raise exception 'NOT_ALLOWED'; end if;
  if p_starts <= now() then raise exception 'SLOT_PAST'; end if;
  if p_open and exists (select 1 from time_off where interviewer_id = v_uid and off_date = (p_starts at time zone 'Asia/Kolkata')::date) then
    raise exception 'DAY_OFF';
  end if;
  select status into v_status from slots where interviewer_id = v_uid and starts_at = p_starts for update;
  if v_status = 'booked' then raise exception 'SLOT_BOOKED'; end if;
  if p_open then
    insert into slots(interviewer_id, starts_at, ends_at) values (v_uid, p_starts, p_starts + interval '30 minutes')
    on conflict (interviewer_id, starts_at) do update set status = 'open';
  else
    delete from slots s where s.interviewer_id = v_uid and s.starts_at = p_starts and s.status in ('open','blocked')
      and not exists (select 1 from bookings b where b.slot_id = s.id);
    update slots set status = 'blocked' where interviewer_id = v_uid and starts_at = p_starts and status = 'open';
  end if;
end $$;

-- Interviews use the interviewer's own meeting link when they have set one.
create or replace function private.meet_link(p_slot uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(p.meet_url, 'https://meet.google.com/grit-' || substr(md5(s.id::text), 1, 4) || '-' || substr(md5(s.id::text), 5, 3))
  from slots s join profiles p on p.id = s.interviewer_id where s.id = p_slot
$$;

create or replace function private.claim(p_starts timestamptz, p_student uuid, p_track text, p_attempt int)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_slot uuid; v_booking uuid; v_rows int;
begin
  select id into v_slot from slots
    where starts_at = p_starts and status = 'open'
    order by random() limit 1
    for update skip locked;
  if v_slot is null then raise exception 'SLOT_TAKEN'; end if;
  update slots set status = 'booked' where id = v_slot and status = 'open';
  get diagnostics v_rows = row_count;
  if v_rows = 0 then raise exception 'SLOT_TAKEN'; end if;
  insert into bookings(slot_id, student_id, track_id, attempt_no, meet_url)
  values (v_slot, p_student, p_track, p_attempt, private.meet_link(v_slot))
  returning id into v_booking;
  return v_booking;
end $$;

create or replace function public.reschedule_booking(p_booking uuid, p_starts timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_b record; v_new uuid;
begin
  select b.id, b.slot_id, b.track_id, b.student_id, b.status, s.starts_at into v_b
    from bookings b join slots s on s.id = b.slot_id where b.id = p_booking for update of b;
  if v_b.id is null or v_b.student_id <> v_uid or v_b.status <> 'booked' then raise exception 'NOT_ALLOWED'; end if;
  if v_b.starts_at - interval '12 hours' <= now() then raise exception 'TOO_LATE'; end if;
  if p_starts <= now() then raise exception 'SLOT_PAST'; end if;
  select id into v_new from slots where starts_at = p_starts and status = 'open'
    order by random() limit 1 for update skip locked;
  if v_new is null then raise exception 'SLOT_TAKEN'; end if;
  update slots set status = 'booked' where id = v_new;
  update bookings set slot_id = v_new, meet_url = private.meet_link(v_new) where id = p_booking;
  update slots set status = 'open' where id = v_b.slot_id;
  perform private.audit('rescheduled', v_uid, v_b.track_id, jsonb_build_object('from', v_b.starts_at, 'to', p_starts));
  return private.track_state(v_uid, v_b.track_id);
end $$;

create function public.update_profile(p_phone text, p_bio text default null, p_meet_url text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_role text := private.my_role();
begin
  if v_role is null then raise exception 'NOT_ALLOWED'; end if;
  if nullif(trim(p_phone), '') is not null and trim(p_phone) !~ '^\+?[0-9 ()-]{7,20}$' then raise exception 'BAD_PHONE'; end if;
  if v_role = 'interviewer' and nullif(trim(p_meet_url), '') is not null and trim(p_meet_url) !~ '^https://\S+$' then raise exception 'BAD_URL'; end if;
  update profiles set
    phone = nullif(trim(p_phone), ''),
    bio = case when v_role in ('interviewer','team') then left(nullif(trim(p_bio), ''), 280) else bio end,
    meet_url = case when v_role = 'interviewer' then nullif(trim(p_meet_url), '') else meet_url end
  where id = auth.uid();
end $$;

create function private.hours_json(p uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('weekday', weekday, 'start', to_char(start_time, 'HH24:MI'), 'end', to_char(end_time, 'HH24:MI')) order by weekday), '[]'::jsonb)
  from interviewer_hours where interviewer_id = p
$$;

create function private.time_off_json(p uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('date', off_date, 'reason', reason) order by off_date), '[]'::jsonb)
  from time_off where interviewer_id = p and off_date >= (now() at time zone 'Asia/Kolkata')::date
$$;

create function private.iv_stats(p uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'done', count(*) filter (where b.status in ('completed','no_show')),
    'upcoming', count(*) filter (where b.status = 'booked' and s.starts_at > now()),
    'awaiting', count(*) filter (where b.status = 'booked' and s.ends_at <= now()),
    'passed', count(*) filter (where o.result = 'pass'),
    'open_7', (select count(*) from slots s2 where s2.interviewer_id = p and s2.status = 'open' and s2.starts_at > now() and s2.starts_at < now() + interval '7 days'))
  from bookings b join slots s on s.id = b.slot_id left join outcomes o on o.booking_id = b.id
  where s.interviewer_id = p and b.track_id <> 'race-test'
$$;

-- Everything on a student's profile. Staff also see private notes and malpractice flags.
create function private.student_profile(p_student uuid, p_staff boolean) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_p profiles; v_lb jsonb; v_row jsonb;
begin
  select * into v_p from profiles where id = p_student and role = 'student';
  if v_p.id is null then raise exception 'NOT_FOUND'; end if;
  v_lb := private.leaderboard(p_student);
  select x into v_row from jsonb_array_elements(v_lb) x where (x->>'me')::boolean;
  return jsonb_build_object(
    'id', v_p.id, 'name', v_p.full_name, 'email', v_p.email, 'phone', v_p.phone, 'campus', v_p.campus, 'batch', v_p.batch,
    'miles', v_row->'points', 'rank', v_row->'rank', 'of', jsonb_array_length(v_lb), 'badges', v_row->'badges',
    'tracks', (select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name,
        'skills', (select jsonb_agg(jsonb_build_object('name', ts.name,
              'cleared', ss.cleared_at is not null, 'cleared_at', ss.cleared_at) order by ts.position)
            from track_skills ts left join student_skills ss on ss.skill_id = ts.id and ss.student_id = p_student
            where ts.track_id = t.id),
        'status', private.track_state(p_student, t.id)) order by t.id desc)
      from tracks t where not t.hidden),
    'history', (select coalesce(jsonb_agg(jsonb_build_object(
        'starts_at', s.starts_at, 'ends_at', s.ends_at, 'track', t.name, 'interviewer', ip.full_name,
        'status', b.status, 'attempt_no', b.attempt_no, 'cancelled_by', b.cancelled_by, 'cancel_reason', b.cancel_reason,
        'result', o.result, 'feedback', o.feedback,
        'notes', case when p_staff then (select n.notes from private.outcome_notes n where n.booking_id = b.id) end
      ) order by s.starts_at desc), '[]'::jsonb)
      from bookings b join slots s on s.id = b.slot_id join profiles ip on ip.id = s.interviewer_id
      join tracks t on t.id = b.track_id left join outcomes o on o.booking_id = b.id
      where b.student_id = p_student and not t.hidden),
    'flags', case when p_staff then (select coalesce(jsonb_agg(jsonb_build_object('track', t.name, 'reason', f.reason, 'at', f.created_at) order by f.created_at desc), '[]'::jsonb)
      from malpractice_flags f join tracks t on t.id = f.track_id where f.student_id = p_student) end
  );
end $$;

create function public.student_profile(p_student uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_role text := private.my_role(); v_id uuid := coalesce(p_student, auth.uid());
begin
  if v_role is null then raise exception 'NOT_ALLOWED'; end if;
  if v_id <> auth.uid() and v_role not in ('interviewer','team') then raise exception 'NOT_ALLOWED'; end if;
  return private.student_profile(v_id, v_role in ('interviewer','team'));
end $$;

create or replace function public.app_state() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_me profiles; v_out jsonb;
begin
  select * into v_me from profiles where id = v_uid;
  if v_me.id is null then raise exception 'NO_PROFILE'; end if;
  v_out := jsonb_build_object(
    'me', jsonb_build_object('id', v_me.id, 'role', v_me.role, 'name', v_me.full_name, 'email', v_me.email, 'campus', v_me.campus,
      'phone', v_me.phone, 'batch', v_me.batch, 'bio', v_me.bio, 'meet_url', v_me.meet_url),
    'now', now());

  if v_me.role = 'student' then
    v_out := v_out || jsonb_build_object(
      'tracks', (select jsonb_agg(jsonb_build_object(
          'id', t.id, 'name', t.name,
          'skills', (select jsonb_agg(jsonb_build_object('name', ts.name,
                'cleared', exists (select 1 from student_skills ss where ss.student_id = v_uid and ss.skill_id = ts.id)) order by ts.position)
              from track_skills ts where ts.track_id = t.id),
          'status', private.track_state(v_uid, t.id)) order by t.id desc)
        from tracks t where not t.hidden),
      'open_times', (select coalesce(jsonb_agg(x.starts_at order by x.starts_at), '[]'::jsonb) from (
          select distinct starts_at from slots
          where status = 'open' and starts_at > now() + interval '15 minutes' and starts_at < now() + interval '21 days') x),
      'leaderboard', private.leaderboard(v_uid));

  elsif v_me.role in ('interviewer','team') then
    v_out := v_out || jsonb_build_object(
      'slots', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', s.id, 'starts_at', s.starts_at, 'ends_at', s.ends_at, 'status', s.status,
          'interviewer', ip.full_name, 'interviewer_id', s.interviewer_id,
          'booking', (select jsonb_build_object(
              'id', b.id, 'status', b.status, 'student', sp.full_name, 'student_id', b.student_id, 'campus', sp.campus,
              'track', t.name, 'track_id', b.track_id, 'attempt_no', b.attempt_no, 'meet_url', b.meet_url,
              'outcome', (select jsonb_build_object('result', o.result, 'feedback', o.feedback, 'recorded_at', o.recorded_at,
                    'notes', (select n.notes from private.outcome_notes n where n.booking_id = b.id),
                    'editable', o.recorded_at > now() - interval '24 hours')
                  from outcomes o where o.booking_id = b.id))
            from bookings b join profiles sp on sp.id = b.student_id join tracks t on t.id = b.track_id
            where b.slot_id = s.id and b.status in ('booked','completed','no_show') limit 1)
        ) order by s.starts_at), '[]'::jsonb)
        from slots s join profiles ip on ip.id = s.interviewer_id
        where s.starts_at > now() - interval '7 days' and s.starts_at < now() + interval '22 days'
          and (v_me.role = 'team' or s.interviewer_id = v_uid)));
  end if;

  if v_me.role = 'interviewer' then
    v_out := v_out || jsonb_build_object('hours', private.hours_json(v_uid), 'time_off', private.time_off_json(v_uid), 'stats', private.iv_stats(v_uid));
  end if;

  if v_me.role = 'team' then
    v_out := v_out || jsonb_build_object(
      'students', (select coalesce(jsonb_agg(jsonb_build_object(
          'student_id', p.id, 'name', p.full_name, 'email', p.email, 'campus', p.campus, 'batch', p.batch,
          'track_id', t.id, 'track', t.name,
          'status', private.track_state(p.id, t.id),
          'last_reminder_at', (select max(a.created_at) from audit_log a where a.action = 'reminder_sent' and a.student_id = p.id and a.track_id = t.id)
        ) order by p.full_name, t.id), '[]'::jsonb)
        from profiles p cross join tracks t
        where p.role = 'student' and not t.hidden
          and exists (select 1 from student_skills ss join track_skills ts on ts.id = ss.skill_id where ss.student_id = p.id and ts.track_id = t.id)),
      'interviewers', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', p.id, 'name', p.full_name, 'email', p.email, 'phone', p.phone, 'bio', p.bio,
          'hours', private.hours_json(p.id), 'time_off', private.time_off_json(p.id), 'stats', private.iv_stats(p.id)
        ) order by p.full_name), '[]'::jsonb)
        from profiles p where p.role = 'interviewer'),
      'audit', (select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb) from (
          select a.created_at, jsonb_build_object('at', a.created_at, 'actor', a.actor_name, 'action', a.action,
              'student', (select full_name from profiles where id = a.student_id),
              'track', (select name from tracks where id = a.track_id), 'detail', a.detail) as j
          from audit_log a order by a.created_at desc limit 50) x));
  end if;
  return v_out;
end $$;

create or replace function private.seed_demo() returns void
language plpgsql security definer set search_path = public as $$
declare
  u text := '00000000-0000-4000-a000-0000000000';
  aarav uuid := (u||'01')::uuid; diya uuid := (u||'02')::uuid; kabir uuid := (u||'03')::uuid; meera uuid := (u||'04')::uuid;
  rohan uuid := (u||'05')::uuid; ananya uuid := (u||'06')::uuid; vikram uuid := (u||'07')::uuid; sneha uuid := (u||'08')::uuid;
  ishaan uuid := (u||'09')::uuid; tara uuid := (u||'10')::uuid; nikhil uuid := (u||'15')::uuid; pooja uuid := (u||'16')::uuid;
  priya uuid := (u||'11')::uuid; arjun uuid := (u||'12')::uuid; neha uuid := (u||'13')::uuid; sanjay uuid := (u||'21')::uuid;
  today date := (now() at time zone 'Asia/Kolkata')::date;
  r record; v_slot uuid; v_bk uuid; v_d date;
  k_ts timestamptz; d_ts timestamptz; t_ts timestamptz; neha_off date;
begin
  perform pg_advisory_xact_lock(424242);
  delete from audit_log; delete from malpractice_flags; delete from track_standing;
  delete from outcomes; delete from bookings; delete from slots; delete from student_skills;
  delete from time_off; delete from interviewer_hours;

  -- Profile details (restored on every reset). Phone numbers are placeholders, not real numbers.
  update profiles p set phone = x.phone, batch = x.batch, bio = x.bio, meet_url = x.meet
  from (values
    (aarav,  '+91 90000 00001', '2024', null::text, null::text),
    (diya,   '+91 90000 00002', '2024', null, null),
    (kabir,  '+91 90000 00003', '2023', null, null),
    (meera,  '+91 90000 00004', '2023', null, null),
    (rohan,  '+91 90000 00005', '2024', null, null),
    (ananya, '+91 90000 00006', '2025', null, null),
    (vikram, '+91 90000 00007', '2023', null, null),
    (sneha,  '+91 90000 00008', '2025', null, null),
    (ishaan, '+91 90000 00009', '2025', null, null),
    (tara,   '+91 90000 00010', '2024', null, null),
    (nikhil, '+91 90000 00015', '2025', null, null),
    (pooja,  '+91 90000 00016', '2023', null, null),
    (priya,  '+91 90000 00011', null, 'Interviews for AI Product Mastery. Works weekdays.', 'https://meet.google.com/grit-priya-room'),
    (arjun,  '+91 90000 00012', null, 'Interviews for both tracks. Works Monday to Saturday.', null),
    (neha,   '+91 90000 00013', null, 'Interviews for AI Systems Mastery. Afternoons and evenings.', null),
    (sanjay, '+91 90000 00021', null, 'GRIT interview team lead.', null)
  ) as x(id, phone, batch, bio, meet) where p.id = x.id;

  -- Skill levels cleared: (student, track, how many, days since the last one)
  for r in select * from (values
      (aarav,'fullstack',4,2),(aarav,'data',3,4),(diya,'fullstack',4,6),(kabir,'fullstack',4,8),
      (meera,'fullstack',4,20),(meera,'data',5,1),(rohan,'fullstack',4,15),(ananya,'data',5,7),
      (vikram,'fullstack',4,30),(sneha,'data',5,9),(ishaan,'fullstack',3,3),(tara,'data',5,3),
      (nikhil,'data',5,1),(pooja,'fullstack',4,12)
    ) as t(student, track, n, days) loop
    insert into student_skills(student_id, skill_id, cleared_at)
    select r.student, ts.id, now() - make_interval(days => r.days) - make_interval(days => (r.n - ts.position) * 4)
    from track_skills ts where ts.track_id = r.track and ts.position <= r.n;
  end loop;

  -- Working hours. Priya: weekdays. Arjun: Monday to Saturday. Neha: Tuesday to Saturday, with one day off coming up.
  insert into interviewer_hours select priya, w, time '10:00', time '17:00' from generate_series(1, 5) w;
  insert into interviewer_hours select arjun, w, time '11:00', time '18:00' from generate_series(1, 6) w;
  insert into interviewer_hours select neha, w, time '14:00', time '20:00' from generate_series(2, 6) w;
  select d::date into neha_off from generate_series(today + 2, today + 9, interval '1 day') d
   where extract(dow from d) between 2 and 6 order by d limit 1;
  insert into time_off(interviewer_id, off_date, reason) values (neha, neha_off, 'Personal leave');
  perform private.regen_slots(priya);
  perform private.regen_slots(arjun);
  perform private.regen_slots(neha);

  -- Kabir: Priya's most recent 4:00 PM interview that has already ended, still waiting for an outcome.
  v_d := today;
  if ((today + time '16:30') at time zone 'Asia/Kolkata') > now() then v_d := today - 1; end if;
  while extract(dow from v_d) not between 1 and 5 loop v_d := v_d - 1; end loop;
  k_ts := (v_d + time '16:00') at time zone 'Asia/Kolkata';
  -- Diya: Priya's next working day at 3:00 PM.
  v_d := today + 1;
  while extract(dow from v_d) not between 1 and 5 loop v_d := v_d + 1; end loop;
  d_ts := (v_d + time '15:00') at time zone 'Asia/Kolkata';
  -- Tara: Arjun, two working days out at 11:00 AM.
  v_d := today + 2;
  while extract(dow from v_d) not between 1 and 6 loop v_d := v_d + 1; end loop;
  t_ts := (v_d + time '11:00') at time zone 'Asia/Kolkata';

  for r in select * from (values
      (diya,   'fullstack', priya, d_ts, null::text, null::text, null::text),
      (kabir,  'fullstack', priya, k_ts, null, null, null),
      (tara,   'data',      arjun, t_ts, null, null, null),
      (meera,  'fullstack', arjun, ((today - 10) + time '12:00') at time zone 'Asia/Kolkata', 'pass',
         'Clear reasoning on the Gen AI feature and a clean UI walkthrough. Well done.', 'Strong across the board. Built the UI task without hints.'),
      (rohan,  'fullstack', neha,  ((today - 5) + time '15:00') at time zone 'Asia/Kolkata', 'fail',
         'Strong on UI Engineering. Revise CS Fundamentals (time complexity, data structures) and how you would evaluate a Gen AI feature, then come back.',
         'Could not explain the time complexity of their own solution. Vague on prompt evaluation.'),
      (ananya, 'data',      neha,  ((today - 2) + time '16:00') at time zone 'Asia/Kolkata', 'retake',
         'Your connection dropped twice, so we could not finish. This does not count as an attempt.', 'Network issue on student side after 8 minutes. Rebook.'),
      (vikram, 'fullstack', priya, ((today - 18) + time '11:00') at time zone 'Asia/Kolkata', 'pass',
         'Solid answers throughout.', 'Passed comfortably at the time.')
    ) as t(student, track, iv, starts, result, feedback, notes) loop
    insert into slots(interviewer_id, starts_at, ends_at, status)
    values (r.iv, r.starts, r.starts + interval '30 minutes', 'booked')
    on conflict (interviewer_id, starts_at) do update set status = 'booked'
    returning id into v_slot;
    insert into bookings(slot_id, student_id, track_id, attempt_no, status, meet_url, created_at)
    values (v_slot, r.student, r.track, 1, case when r.result is null then 'booked' else 'completed' end,
      private.meet_link(v_slot), r.starts - interval '2 days')
    returning id into v_bk;
    if r.result is not null then
      insert into outcomes(booking_id, result, feedback, recorded_by, recorded_at, updated_at)
      values (v_bk, r.result, r.feedback, r.iv, r.starts + interval '40 minutes', r.starts + interval '40 minutes');
      insert into private.outcome_notes(booking_id, notes) values (v_bk, r.notes);
      insert into audit_log(actor_id, actor_name, action, student_id, track_id, detail, created_at)
      values (r.iv, (select full_name from profiles where id = r.iv), 'outcome_recorded', r.student, r.track,
        jsonb_build_object('result', r.result), r.starts + interval '40 minutes');
    end if;
  end loop;

  insert into track_standing(student_id, track_id, badge_awarded_at) values (meera, 'fullstack', ((today - 10) + time '12:40') at time zone 'Asia/Kolkata');
  insert into track_standing(student_id, track_id, badge_awarded_at, nullified_at)
    values (vikram, 'fullstack', ((today - 18) + time '11:40') at time zone 'Asia/Kolkata', now() - interval '3 days');
  insert into malpractice_flags(student_id, track_id, reason, flagged_by, created_at)
    values (vikram, 'fullstack', 'Contest review found copied submissions in the UI Engineering L2 contest.', sanjay, now() - interval '3 days');
  insert into audit_log(actor_id, actor_name, action, student_id, track_id, detail, created_at)
    values (sanjay, 'Sanjay Kulkarni', 'badge_nullified', vikram, 'fullstack',
      jsonb_build_object('reason', 'Contest review found copied submissions in the UI Engineering L2 contest.'), now() - interval '3 days'),
    (sanjay, 'Sanjay Kulkarni', 'reminder_sent', sneha, 'data', '{}'::jsonb, now() - interval '4 days'),
    (neha, 'Neha Kapoor', 'day_off_added', null, null, jsonb_build_object('date', neha_off, 'reason', 'Personal leave', 'cancelled', 0), now() - interval '1 day');

  update private.demo_meta set seeded_on = today where id = 1;
end $$;

-- Lock down who can call what (new functions default to PUBLIC execute).
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.my_role() to authenticated;

select private.seed_demo();
