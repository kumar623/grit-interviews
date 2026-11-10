-- Use GRIT's real tracks, skills and skill levels (from grit.niatindia.com/how-grit-works).
-- The AI Product Mastery Novice Badge requirements are the published example;
-- the AI Systems Mastery list is a placeholder until the real one is confirmed.
update public.tracks set name = 'AI Product Mastery' where id = 'fullstack';
update public.tracks set name = 'AI Systems Mastery' where id = 'data';

update public.track_skills set name = 'Computational Thinking L1' where track_id = 'fullstack' and position = 1;
update public.track_skills set name = 'CS Fundamentals L1' where track_id = 'fullstack' and position = 2;
update public.track_skills set name = 'Applied Gen AI Development L1' where track_id = 'fullstack' and position = 3;
update public.track_skills set name = 'UI Engineering L2' where track_id = 'fullstack' and position = 4;
delete from public.track_skills where track_id = 'fullstack' and position = 5;

update public.track_skills set name = 'Computational Thinking L1' where track_id = 'data' and position = 1;
update public.track_skills set name = 'CS Fundamentals L1' where track_id = 'data' and position = 2;
update public.track_skills set name = 'Server Side Engineering L1' where track_id = 'data' and position = 3;
update public.track_skills set name = 'SQL L2' where track_id = 'data' and position = 4;
update public.track_skills set name = 'System Design L1' where track_id = 'data' and position = 5;

-- Patch the demo seed in place so its copy matches the new skills, then reseed.
do $$
declare
  d text := pg_get_functiondef('private.seed_demo()'::regprocedure);
  pairs text[] := array[
    '(ishaan,''fullstack'',4,3)', '(ishaan,''fullstack'',3,3)',
    'SQL Databases skill contest', 'UI Engineering L2 contest',
    'Clear thinking on API design and a clean React walkthrough. Well done.', 'Clear reasoning on the Gen AI feature and a clean UI walkthrough. Well done.',
    'Strong across the board. Built the pagination task without hints.', 'Strong across the board. Built the UI task without hints.',
    'Good grasp of HTML, CSS and React basics. Revise SQL joins and how you handle errors in an API, then come back.', 'Strong on UI Engineering. Revise CS Fundamentals (time complexity, data structures) and how you would evaluate a Gen AI feature, then come back.',
    'Could not write a two-table join. Unsure on HTTP status codes.', 'Could not explain the time complexity of their own solution. Vague on prompt evaluation.'
  ];
  i int;
begin
  for i in 1 .. array_length(pairs, 1) by 2 loop
    if position(pairs[i] in d) = 0 then raise exception 'seed text not found: %', pairs[i]; end if;
    d := replace(d, pairs[i], pairs[i + 1]);
  end loop;
  execute d;
  perform private.seed_demo();
end $$;
