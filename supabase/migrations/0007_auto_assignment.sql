-- Automatic interviewer assignment.
-- The student picks a time. The database picks the interviewer:
--   1. only interviewers who assess that track,
--   2. who have an open slot at that time,
--   3. the one with the fewest interviews that week (IST), ties broken at random.

create table public.interviewer_tracks (
  interviewer_id uuid not null references public.profiles(id) on delete cascade,
  track_id text not null references public.tracks(id),
  primary key (interviewer_id, track_id)
);
alter table public.interviewer_tracks enable row level security;
create policy interviewer_tracks_read on public.interviewer_tracks for select to authenticated using (true);
revoke all on public.interviewer_tracks from anon;
revoke insert, update, delete, truncate on public.interviewer_tracks from authenticated;

insert into public.interviewer_tracks values
  ('00000000-0000-4000-a000-000000000011', 'fullstack'),  -- Priya: AI Product Mastery
  ('00000000-0000-4000-a000-000000000012', 'fullstack'),  -- Arjun: both tracks
  ('00000000-0000-4000-a000-000000000012', 'data'),
  ('00000000-0000-4000-a000-000000000013', 'data');       -- Neha: AI Systems Mastery

create function private.iv_tracks(p uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(t.name order by t.name), '[]'::jsonb)
  from interviewer_tracks it join tracks t on t.id = it.track_id where it.interviewer_id = p
$$;

-- Picks and locks the slot for a booking. Shared by booking and rescheduling.
create function private.pick_slot(p_starts timestamptz, p_track text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_slot uuid;
begin
  select s.id into v_slot from slots s
   where s.starts_at = p_starts and s.status = 'open'
     and (exists (select 1 from interviewer_tracks it where it.interviewer_id = s.interviewer_id and it.track_id = p_track)
          or (select hidden from tracks where id = p_track))
   order by (select count(*) from bookings b join slots s2 on s2.id = b.slot_id
              where s2.interviewer_id = s.interviewer_id and b.status in ('booked','completed','no_show')
                and date_trunc('week', s2.starts_at at time zone 'Asia/Kolkata') = date_trunc('week', p_starts at time zone 'Asia/Kolkata')),
            random()
   limit 1
   for update of s skip locked;
  return v_slot;
end $$;

create or replace function private.claim(p_starts timestamptz, p_student uuid, p_track text, p_attempt int)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_slot uuid; v_booking uuid; v_rows int;
begin
  v_slot := private.pick_slot(p_starts, p_track);
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
  v_new := private.pick_slot(p_starts, v_b.track_id);
  if v_new is null then raise exception 'SLOT_TAKEN'; end if;
  update slots set status = 'booked' where id = v_new;
  update bookings set slot_id = v_new, meet_url = private.meet_link(v_new) where id = p_booking;
  update slots set status = 'open' where id = v_b.slot_id;
  perform private.audit('rescheduled', v_uid, v_b.track_id, jsonb_build_object('from', v_b.starts_at, 'to', p_starts,
    'interviewer', (select p.full_name from slots s join profiles p on p.id = s.interviewer_id where s.id = v_new)));
  return private.track_state(v_uid, v_b.track_id);
end $$;

-- Patch app_state, book_slot and the demo seed in place (exact text replacements, each must match once).
do $$
declare
  f text; pairs text[]; i int;
begin
  f := pg_get_functiondef('public.app_state()'::regprocedure);
  pairs := array[
    $a$'open_times', (select coalesce(jsonb_agg(x.starts_at order by x.starts_at), '[]'::jsonb) from (
          select distinct starts_at from slots
          where status = 'open' and starts_at > now() + interval '15 minutes' and starts_at < now() + interval '21 days') x),$a$,
    $b$'open_times', (select coalesce(jsonb_object_agg(t.id, (select coalesce(jsonb_agg(x.starts_at order by x.starts_at), '[]'::jsonb) from (
          select distinct s.starts_at from slots s join interviewer_tracks it on it.interviewer_id = s.interviewer_id and it.track_id = t.id
          where s.status = 'open' and s.starts_at > now() + interval '15 minutes' and s.starts_at < now() + interval '21 days') x)), '{}'::jsonb)
        from tracks t where not t.hidden),$b$,
    $a$'stats', private.iv_stats(v_uid));$a$,
    $b$'stats', private.iv_stats(v_uid), 'tracks', private.iv_tracks(v_uid));$b$,
    $a$'stats', private.iv_stats(p.id)$a$,
    $b$'stats', private.iv_stats(p.id), 'tracks', private.iv_tracks(p.id)$b$
  ];
  for i in 1 .. array_length(pairs, 1) by 2 loop
    if (length(f) - length(replace(f, pairs[i], ''))) / length(pairs[i]) <> 1 then raise exception 'app_state text not found once: %', left(pairs[i], 60); end if;
    f := replace(f, pairs[i], pairs[i + 1]);
  end loop;
  execute f;

  f := pg_get_functiondef('public.book_slot(timestamptz, text)'::regprocedure);
  pairs := array[
    $a$perform private.audit('booked', v_uid, p_track, jsonb_build_object('starts_at', p_starts));$a$,
    $b$perform private.audit('booked', v_uid, p_track, jsonb_build_object('starts_at', p_starts,
    'interviewer', (select p.full_name from bookings b join slots s on s.id = b.slot_id join profiles p on p.id = s.interviewer_id where b.id = v_booking)));$b$
  ];
  if position(pairs[1] in f) = 0 then raise exception 'book_slot text not found'; end if;
  execute replace(f, pairs[1], pairs[2]);

  -- Rohan's past AI Product Mastery interview was with Neha, who now only assesses AI Systems Mastery.
  f := pg_get_functiondef('private.seed_demo()'::regprocedure);
  if position($a$(rohan,  'fullstack', neha,$a$ in f) = 0 then raise exception 'seed text not found'; end if;
  execute replace(f, $a$(rohan,  'fullstack', neha,$a$, $b$(rohan,  'fullstack', arjun,$b$);
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.my_role() to authenticated;

select private.seed_demo();
