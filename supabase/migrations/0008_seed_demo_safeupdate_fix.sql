-- Fix: Reset demo / daily refresh failed from the browser with "DELETE requires a WHERE clause".
-- Supabase's `authenticator` role preloads the `safeupdate` extension, which blocks unqualified
-- DELETE/UPDATE even inside a SECURITY DEFINER function. (The SQL editor runs as a privileged
-- role without safeupdate, so it never reproduced there.) seed_demo() wiped its tables with
-- `delete from <t>;` and no WHERE clause. Give each wipe an explicit `where true`.
do $$
declare f text; tbls text[] := array['audit_log','malpractice_flags','track_standing','outcomes','bookings','slots','student_skills','time_off','interviewer_hours'];
  tb text;
begin
  f := pg_get_functiondef('private.seed_demo()'::regprocedure);
  foreach tb in array tbls loop
    if position('delete from ' || tb || ';' in f) = 0 then raise exception 'pattern not found: delete from % ;', tb; end if;
    f := replace(f, 'delete from ' || tb || ';', 'delete from ' || tb || ' where true;');
  end loop;
  execute f;
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.my_role() to authenticated;

select private.seed_demo();
