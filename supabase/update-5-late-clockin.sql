-- =====================================================================
--  Shop Time Clock — update 5: "Forgot to clock in?" start the clock
--  from an earlier time today (e.g. back from lunch and forgot to tap).
--  Safe to run more than once. Run AFTER update-4-email.sql.
-- =====================================================================

create or replace function emp_clock_in_at(p_token text, p_in timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e employees; p punches; t timestamptz := date_trunc('minute', p_in);
begin
  e := _emp(p_token);
  if exists (select 1 from punches where employee_id = e.id and clock_out is null) then
    raise exception 'You are already clocked in.';
  end if;
  if t > now() + interval '1 minute' then
    raise exception 'That time hasn''t happened yet.';
  end if;
  if (t at time zone 'America/Chicago')::date <> _shop_today() then
    raise exception 'Pick a time from today. For other days, tap the day and type in your times.';
  end if;
  if exists (select 1 from punches where employee_id = e.id
             and clock_in <= t and clock_out > t) then
    raise exception 'That time overlaps a shift you already have. Pick a time after your last clock-out.';
  end if;
  if exists (select 1 from punches where employee_id = e.id and clock_in > t) then
    raise exception 'You already have a shift after that time. Pick a later time.';
  end if;
  insert into punches(employee_id, work_date, clock_in, note)
    values (e.id, _shop_today(), t,
            'Start time entered by hand at ' || to_char(now() at time zone 'America/Chicago', 'HH12:MI AM'))
    returning * into p;
  perform _unsubmit(e.id, p.work_date);
  return _punch_json(p);
end $$;

grant execute on function emp_clock_in_at(text, timestamptz) to anon, authenticated;
