create function private.audit(p_action text, p_student uuid, p_track text, p_detail jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.audit_log(actor_id, actor_name, action, student_id, track_id, detail)
  values (auth.uid(), (select full_name from public.profiles where id = auth.uid()), p_action, p_student, p_track, coalesce(p_detail, '{}'::jsonb));
$$;

-- Single source of truth for where a student stands on a track.
create function private.track_state(p_student uuid, p_track text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c_cooldown constant interval := interval '14 days';
  c_max constant int := 3;
  v_total int; v_cleared int; v_elig timestamptz;
  v_badge timestamptz; v_null timestamptz;
  v_bk record; v_last record; v_lastbk record;
  v_fails int; v_noshows int; v_attempts int; v_cool timestamptz; v_state text;
begin
  select count(*) into v_total from track_skills where track_id = p_track;
  select count(*), max(ss.cleared_at) into v_cleared, v_elig
    from student_skills ss join track_skills ts on ts.id = ss.skill_id
    where ss.student_id = p_student and ts.track_id = p_track;
  select badge_awarded_at, nullified_at into v_badge, v_null
    from track_standing where student_id = p_student and track_id = p_track;

  select b.id, b.attempt_no, b.meet_url, s.starts_at, s.ends_at, p.full_name as interviewer into v_bk
    from bookings b join slots s on s.id = b.slot_id join profiles p on p.id = s.interviewer_id
    where b.student_id = p_student and b.track_id = p_track and b.status = 'booked' limit 1;

  select o.result, o.feedback, o.recorded_at, s.starts_at, p.full_name as interviewer into v_last
    from outcomes o join bookings b on b.id = o.booking_id
    join slots s on s.id = b.slot_id join profiles p on p.id = s.interviewer_id
    where b.student_id = p_student and b.track_id = p_track
    order by o.recorded_at desc limit 1;

  select b.status, b.cancelled_by, b.cancel_reason, b.cancelled_at into v_lastbk
    from bookings b where b.student_id = p_student and b.track_id = p_track
    order by b.created_at desc limit 1;

  select count(*) filter (where o.result = 'fail'), count(*) filter (where o.result = 'no_show')
    into v_fails, v_noshows
    from outcomes o join bookings b on b.id = o.booking_id
    where b.student_id = p_student and b.track_id = p_track;
  v_attempts := v_fails + greatest(v_noshows - 1, 0);
  if v_last.result = 'fail' then v_cool := v_last.recorded_at + c_cooldown; end if;

  v_state := case
    when v_null is not null then 'nullified'
    when v_badge is not null then 'passed'
    when v_total = 0 or v_cleared < v_total then 'not_eligible'
    when v_bk.id is not null and v_bk.ends_at > now() then 'booked'
    when v_bk.id is not null then 'awaiting_result'
    when v_attempts >= c_max then 'exhausted'
    when v_cool is not null and v_cool > now() then 'cooldown'
    else 'eligible' end;

  return jsonb_build_object(
    'state', v_state,
    'skills_total', v_total,
    'skills_cleared', v_cleared,
    'eligible_at', case when v_total > 0 and v_cleared = v_total then v_elig end,
    'attempts_used', v_attempts,
    'max_attempts', c_max,
    'cooldown_until', v_cool,
    'badge_awarded_at', v_badge,
    'nullified_at', v_null,
    'booking', case when v_bk.id is not null then jsonb_build_object(
        'id', v_bk.id, 'starts_at', v_bk.starts_at, 'ends_at', v_bk.ends_at,
        'meet_url', v_bk.meet_url, 'interviewer', v_bk.interviewer, 'attempt_no', v_bk.attempt_no) end,
    'last_outcome', case when v_last.result is not null then jsonb_build_object(
        'result', v_last.result, 'feedback', v_last.feedback, 'recorded_at', v_last.recorded_at,
        'starts_at', v_last.starts_at, 'interviewer', v_last.interviewer) end,
    'last_cancel', case when v_lastbk.status = 'cancelled' and v_lastbk.cancelled_by in ('interviewer','team') then jsonb_build_object(
        'by', v_lastbk.cancelled_by, 'reason', v_lastbk.cancel_reason, 'at', v_lastbk.cancelled_at) end
  );
end $$;

-- The double-booking guard. Interviewers are pooled: the student picks a time, the database
-- picks any free interviewer at that time. The row lock plus the status check mean only one
-- transaction can take a given slot; the unique index on bookings(slot_id) is the backstop.
create function private.claim(p_starts timestamptz, p_student uuid, p_track text, p_attempt int)
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
  values (v_slot, p_student, p_track, p_attempt,
    'https://meet.google.com/grit-' || substr(md5(v_slot::text), 1, 4) || '-' || substr(md5(v_slot::text), 5, 3))
  returning id into v_booking;
  return v_booking;
end $$;

create function public.book_slot(p_starts timestamptz, p_track text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_st jsonb; v_booking uuid;
begin
  if private.my_role() is distinct from 'student' then raise exception 'NOT_ALLOWED'; end if;
  if p_starts <= now() then raise exception 'SLOT_PAST'; end if;
  v_st := private.track_state(v_uid, p_track);
  if v_st->>'state' = 'booked' or v_st->>'state' = 'awaiting_result' then raise exception 'ALREADY_BOOKED'; end if;
  if v_st->>'state' <> 'eligible' then raise exception 'NOT_BOOKABLE'; end if;
  if exists (select 1 from bookings b join slots s on s.id = b.slot_id
             where b.student_id = v_uid and b.status = 'booked' and s.starts_at = p_starts) then
    raise exception 'TIME_CLASH';
  end if;
  begin
    v_booking := private.claim(p_starts, v_uid, p_track, (v_st->>'attempts_used')::int + 1);
  exception when unique_violation then
    raise exception 'ALREADY_BOOKED';
  end;
  perform private.audit('booked', v_uid, p_track, jsonb_build_object('starts_at', p_starts));
  return private.track_state(v_uid, p_track);
end $$;

create function public.reschedule_booking(p_booking uuid, p_starts timestamptz)
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
  update bookings set slot_id = v_new,
    meet_url = 'https://meet.google.com/grit-' || substr(md5(v_new::text), 1, 4) || '-' || substr(md5(v_new::text), 5, 3)
    where id = p_booking;
  update slots set status = 'open' where id = v_b.slot_id;
  perform private.audit('rescheduled', v_uid, v_b.track_id, jsonb_build_object('from', v_b.starts_at, 'to', p_starts));
  return private.track_state(v_uid, v_b.track_id);
end $$;

create function public.cancel_booking(p_booking uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_role text := private.my_role(); v_b record;
begin
  select b.id, b.slot_id, b.track_id, b.student_id, b.status, s.starts_at, s.interviewer_id into v_b
    from bookings b join slots s on s.id = b.slot_id where b.id = p_booking for update of b;
  if v_b.id is null or v_b.status <> 'booked' then raise exception 'NOT_ALLOWED'; end if;
  if v_role = 'student' then
    if v_b.student_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
    if v_b.starts_at - interval '12 hours' <= now() then raise exception 'TOO_LATE'; end if;
  elsif v_role = 'interviewer' then
    if v_b.interviewer_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
    if coalesce(length(trim(p_reason)), 0) < 3 then raise exception 'REASON_REQUIRED'; end if;
  elsif v_role = 'team' then
    if coalesce(length(trim(p_reason)), 0) < 3 then raise exception 'REASON_REQUIRED'; end if;
  else
    raise exception 'NOT_ALLOWED';
  end if;
  update bookings set status = 'cancelled', cancelled_by = v_role, cancel_reason = nullif(trim(p_reason), ''), cancelled_at = now()
    where id = p_booking;
  -- A student cancelling frees the slot for others; staff cancelling means the interviewer is unavailable.
  update slots set status = case when v_role = 'student' then 'open' else 'blocked' end where id = v_b.slot_id;
  perform private.audit('cancelled', v_b.student_id, v_b.track_id,
    jsonb_build_object('by', v_role, 'reason', p_reason, 'starts_at', v_b.starts_at));
end $$;

create function public.set_slot(p_starts timestamptz, p_open boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_status text;
begin
  if private.my_role() is distinct from 'interviewer' then raise exception 'NOT_ALLOWED'; end if;
  if p_starts <= now() then raise exception 'SLOT_PAST'; end if;
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

create function public.record_outcome(p_booking uuid, p_result text, p_feedback text, p_notes text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_role text := private.my_role(); v_b record; v_prev record; v_null timestamptz;
begin
  if v_role not in ('interviewer','team') or v_role is null then raise exception 'NOT_ALLOWED'; end if;
  if p_result not in ('pass','fail','retake','no_show') then raise exception 'BAD_RESULT'; end if;
  if coalesce(length(trim(p_notes)), 0) < 3 then raise exception 'NOTES_REQUIRED'; end if;
  select b.id, b.track_id, b.student_id, b.status, s.interviewer_id into v_b
    from bookings b join slots s on s.id = b.slot_id where b.id = p_booking for update of b;
  if v_b.id is null or v_b.status = 'cancelled' then raise exception 'NOT_ALLOWED'; end if;
  if v_role = 'interviewer' and v_b.interviewer_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  select nullified_at into v_null from track_standing where student_id = v_b.student_id and track_id = v_b.track_id;
  if v_null is not null then raise exception 'NULLIFIED'; end if;
  select result, recorded_at into v_prev from outcomes where booking_id = p_booking;
  if v_prev.result is not null and v_prev.recorded_at < now() - interval '24 hours' then
    raise exception 'EDIT_WINDOW_CLOSED';
  end if;

  insert into outcomes(booking_id, result, feedback, recorded_by)
  values (p_booking, p_result, nullif(trim(p_feedback), ''), v_uid)
  on conflict (booking_id) do update
    set result = excluded.result, feedback = excluded.feedback, recorded_by = excluded.recorded_by, updated_at = now();
  insert into private.outcome_notes(booking_id, notes) values (p_booking, trim(p_notes))
  on conflict (booking_id) do update set notes = excluded.notes;
  update bookings set status = case when p_result = 'no_show' then 'no_show' else 'completed' end where id = p_booking;

  if p_result = 'pass' then
    insert into track_standing(student_id, track_id, badge_awarded_at) values (v_b.student_id, v_b.track_id, now())
    on conflict (student_id, track_id) do update set badge_awarded_at = now();
  else
    update track_standing set badge_awarded_at = null where student_id = v_b.student_id and track_id = v_b.track_id;
  end if;

  perform private.audit(case when v_prev.result is null then 'outcome_recorded' else 'outcome_changed' end,
    v_b.student_id, v_b.track_id, jsonb_build_object('result', p_result, 'previous', v_prev.result));
end $$;

create function public.flag_malpractice(p_student uuid, p_track text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_bk record;
begin
  if private.my_role() is distinct from 'team' then raise exception 'NOT_ALLOWED'; end if;
  if coalesce(length(trim(p_reason)), 0) < 3 then raise exception 'REASON_REQUIRED'; end if;
  insert into malpractice_flags(student_id, track_id, reason, flagged_by) values (p_student, p_track, trim(p_reason), auth.uid());
  insert into track_standing(student_id, track_id, nullified_at) values (p_student, p_track, now())
  on conflict (student_id, track_id) do update set nullified_at = now();
  for v_bk in select id, slot_id from bookings where student_id = p_student and track_id = p_track and status = 'booked' loop
    update bookings set status = 'cancelled', cancelled_by = 'team', cancel_reason = 'Malpractice review', cancelled_at = now() where id = v_bk.id;
    update slots set status = 'open' where id = v_bk.slot_id and starts_at > now();
  end loop;
  perform private.audit('badge_nullified', p_student, p_track, jsonb_build_object('reason', trim(p_reason)));
end $$;

create function public.send_reminder(p_student uuid, p_track text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if private.my_role() is distinct from 'team' then raise exception 'NOT_ALLOWED'; end if;
  perform private.audit('reminder_sent', p_student, p_track, '{}'::jsonb);
end $$;

-- Race test: 20 browser requests call race_attempt at once against one slot.
create function public.race_setup() returns timestamptz
language plpgsql security definer set search_path = public as $$
declare v_t timestamptz := timestamptz '2099-01-01 00:00:00+00' + (floor(random() * 1000000)::int * interval '1 minute');
begin
  if private.my_role() is distinct from 'team' then raise exception 'NOT_ALLOWED'; end if;
  insert into slots(interviewer_id, starts_at, ends_at)
  select id, v_t, v_t + interval '30 minutes' from profiles where role = 'interviewer' order by full_name limit 1;
  return v_t;
end $$;

create function public.race_attempt(p_starts timestamptz, p_n int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_student uuid; v_booking uuid;
begin
  if private.my_role() is distinct from 'team' then raise exception 'NOT_ALLOWED'; end if;
  if p_starts < timestamptz '2099-01-01 00:00:00+00' then raise exception 'NOT_ALLOWED'; end if;
  select id into v_student from profiles where role = 'student' order by full_name
    offset (abs(p_n) % (select count(*) from profiles where role = 'student'))::int limit 1;
  perform pg_sleep(0.3); -- hold every request so all 20 hit the slot together
  begin
    v_booking := private.claim(p_starts, v_student, 'race-test', 1);
    return jsonb_build_object('n', p_n, 'ok', true);
  exception when others then
    return jsonb_build_object('n', p_n, 'ok', false, 'error', sqlerrm);
  end;
end $$;

create function public.race_cleanup(p_starts timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  if private.my_role() is distinct from 'team' then raise exception 'NOT_ALLOWED'; end if;
  if p_starts < timestamptz '2099-01-01 00:00:00+00' then raise exception 'NOT_ALLOWED'; end if;
  select count(*) into v_count from bookings b join slots s on s.id = b.slot_id where s.starts_at = p_starts;
  delete from bookings where slot_id in (select id from slots where starts_at = p_starts);
  delete from slots where starts_at = p_starts;
  return jsonb_build_object('bookings_created', v_count);
end $$;
