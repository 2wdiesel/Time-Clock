-- =====================================================================
--  Shop Time Clock — database setup
--  Paste this whole file into Supabase > SQL Editor > New query > Run.
--  Safe to run once on a fresh project.
--
--  AFTER running it, create the OWNER's office login (change the text in quotes):
--     select add_office_login('Owner Name', 'owner-username', 'owner-password', true);
--  The owner can then add managers from inside the app (Settings tab).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tables ----------------------------------------------------

create table if not exists employees (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  token       text not null unique,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists punches (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references employees(id) on delete cascade,
  work_date    date not null,
  clock_in     timestamptz not null,
  clock_out    timestamptz,
  note         text,
  edited_by    text,          -- office person who last changed it (null = the employee)
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint out_after_in check (clock_out is null or clock_out > clock_in)
);
create index if not exists punches_emp_date on punches(employee_id, work_date);

create table if not exists week_submissions (
  employee_id   uuid not null references employees(id) on delete cascade,
  week_start    date not null,
  submitted_at  timestamptz not null default now(),
  primary key (employee_id, week_start)
);

create table if not exists push_subscriptions (
  endpoint      text primary key,
  employee_id   uuid not null references employees(id) on delete cascade,
  subscription  jsonb not null,
  created_at    timestamptz not null default now()
);

-- Office logins (owner + managers). Each person has their own.
create table if not exists admins (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  username    text not null unique,
  pw_hash     text not null,
  is_owner    boolean not null default false,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists admin_sessions (
  token       text primary key,
  admin_id    uuid not null references admins(id) on delete cascade,
  created_at  timestamptz not null default now()
);

create table if not exists notification_log (
  key      text primary key,
  sent_at  timestamptz not null default now()
);

-- Lock every table: nothing is readable or writable directly from the app.
-- All access goes through the functions below, which check the employee
-- link code or the admin session.
alter table employees          enable row level security;
alter table punches            enable row level security;
alter table week_submissions   enable row level security;
alter table push_subscriptions enable row level security;
alter table admins             enable row level security;
alter table admin_sessions     enable row level security;
alter table notification_log   enable row level security;

-- ---------- Helpers (not callable from the app) ------------------------

create or replace function _shop_today() returns date
language sql stable as $$
  select (now() at time zone 'America/Chicago')::date
$$;

-- Monday of the current week
create or replace function _week_start(d date) returns date
language sql immutable as $$
  select (d - ((extract(isodow from d)::int) - 1))
$$;

create or replace function _new_code() returns text
language sql volatile set search_path = public, extensions as $$
  select substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 10)
$$;

create or replace function _emp(p_token text) returns employees
language plpgsql stable security definer set search_path = public as $$
declare e employees;
begin
  select * into e from employees where token = lower(trim(p_token)) and active;
  if not found then
    raise exception 'This link is not valid. Ask the office for a new one.';
  end if;
  return e;
end $$;

create or replace function _admin(p_tok text) returns admins
language plpgsql stable security definer set search_path = public as $$
declare a admins;
begin
  select ad.* into a from admin_sessions s join admins ad on ad.id = s.admin_id
   where s.token = p_tok and s.created_at > now() - interval '180 days' and ad.active;
  if not found then raise exception 'ADMIN_LOGIN_REQUIRED'; end if;
  return a;
end $$;

create or replace function _owner(p_tok text) returns admins
language plpgsql stable security definer set search_path = public as $$
declare a admins;
begin
  a := _admin(p_tok);
  if not a.is_owner then raise exception 'Only an owner login can do that.'; end if;
  return a;
end $$;

create or replace function _check_pw(p text) returns void
language plpgsql immutable as $$
begin
  if length(coalesce(p, '')) < 6 then raise exception 'Password must be at least 6 characters.'; end if;
end $$;

-- Employees may only change last week and this week (Mon–Sun weeks).
create or replace function _emp_can_edit(d date) returns boolean
language sql stable as $$
  select d >= _week_start(_shop_today()) - 7 and d <= _shop_today() + 1
$$;

-- Editing a week clears that week's "submitted" mark so the office sees it changed.
create or replace function _unsubmit(p_emp uuid, d date) returns void
language sql security definer set search_path = public as $$
  delete from week_submissions where employee_id = p_emp and week_start = _week_start(d)
$$;

create or replace function _punch_json(p punches) returns jsonb
language sql immutable as $$
  select jsonb_build_object('id', p.id, 'employee_id', p.employee_id,
    'work_date', p.work_date, 'clock_in', p.clock_in, 'clock_out', p.clock_out,
    'note', p.note, 'edited_by', p.edited_by)
$$;

-- ---------- Setup ----------------------------------------------------

-- Run these two from the Supabase SQL Editor only (the app can't call them).
create or replace function add_office_login(p_name text, p_username text, p_password text,
  p_is_owner boolean default false) returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_pw(p_password);
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_username), '') = '' then
    raise exception 'Name and username are required.';
  end if;
  insert into admins(name, username, pw_hash, is_owner)
    values (trim(p_name), lower(trim(p_username)),
            extensions.crypt(p_password, extensions.gen_salt('bf')), p_is_owner);
  return 'Office login created for ' || trim(p_name) || '.';
end $$;

-- Emergency reset if someone is locked out: select reset_office_password('username', 'new-password');
create or replace function reset_office_password(p_username text, p_password text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare a admins;
begin
  perform _check_pw(p_password);
  update admins set pw_hash = extensions.crypt(p_password, extensions.gen_salt('bf')), active = true
    where username = lower(trim(p_username)) returning * into a;
  if not found then raise exception 'No office login with that username.'; end if;
  delete from admin_sessions where admin_id = a.id;
  return 'Password reset for ' || a.name || '.';
end $$;

-- ---------- Employee functions (use the code from their link) ---------

create or replace function emp_week(p_token text, p_week_start date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e employees; ws date := _week_start(p_week_start);
begin
  e := _emp(p_token);
  return jsonb_build_object(
    'employee', jsonb_build_object('id', e.id, 'name', e.name),
    'week_start', ws,
    'today', _shop_today(),
    'editable_from', _week_start(_shop_today()) - 7,
    'submitted_at', (select submitted_at from week_submissions
                     where employee_id = e.id and week_start = ws),
    'last_week_submitted', exists (select 1 from week_submissions
                     where employee_id = e.id
                       and week_start = _week_start(_shop_today()) - 7),
    'open_punch', (select _punch_json(p) from punches p
                   where p.employee_id = e.id and p.clock_out is null
                   order by clock_in desc limit 1),
    'punches', coalesce((select jsonb_agg(_punch_json(p) order by p.clock_in)
                         from punches p
                         where p.employee_id = e.id
                           and p.work_date between ws and ws + 6), '[]'::jsonb));
end $$;

create or replace function emp_clock_in(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e employees; p punches;
begin
  e := _emp(p_token);
  if exists (select 1 from punches where employee_id = e.id and clock_out is null) then
    raise exception 'You are already clocked in.';
  end if;
  insert into punches(employee_id, work_date, clock_in)
    values (e.id, _shop_today(), date_trunc('minute', now()))
    returning * into p;
  perform _unsubmit(e.id, p.work_date);
  return _punch_json(p);
end $$;

create or replace function emp_clock_out(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e employees; p punches; t timestamptz := date_trunc('minute', now());
begin
  e := _emp(p_token);
  select * into p from punches where employee_id = e.id and clock_out is null
    order by clock_in desc limit 1;
  if not found then raise exception 'You are not clocked in.'; end if;
  if t <= p.clock_in then t := p.clock_in + interval '1 minute'; end if;
  update punches set clock_out = t, updated_at = now() where id = p.id returning * into p;
  perform _unsubmit(e.id, p.work_date);
  return _punch_json(p);
end $$;

create or replace function emp_save_punch(p_token text, p_id uuid, p_work_date date,
  p_in timestamptz, p_out timestamptz, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e employees; p punches; old_date date;
begin
  e := _emp(p_token);
  if not _emp_can_edit(p_work_date) then
    raise exception 'You can only change last week and this week. Ask the office to fix older days.';
  end if;
  if p_out is not null and p_out <= p_in then
    raise exception 'End time must be after start time.';
  end if;
  if p_id is null then
    insert into punches(employee_id, work_date, clock_in, clock_out, note)
      values (e.id, p_work_date, p_in, p_out, nullif(trim(p_note), ''))
      returning * into p;
  else
    select work_date into old_date from punches where id = p_id and employee_id = e.id;
    if not found then raise exception 'Entry not found.'; end if;
    if not _emp_can_edit(old_date) then
      raise exception 'That entry is locked. Ask the office to change it.';
    end if;
    update punches set work_date = p_work_date, clock_in = p_in, clock_out = p_out,
      note = nullif(trim(p_note), ''), edited_by = null, updated_at = now()
      where id = p_id returning * into p;
    perform _unsubmit(e.id, old_date);
  end if;
  perform _unsubmit(e.id, p.work_date);
  return _punch_json(p);
end $$;

create or replace function emp_delete_punch(p_token text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e employees; d date;
begin
  e := _emp(p_token);
  select work_date into d from punches where id = p_id and employee_id = e.id;
  if not found then raise exception 'Entry not found.'; end if;
  if not _emp_can_edit(d) then raise exception 'That entry is locked. Ask the office to change it.'; end if;
  delete from punches where id = p_id;
  perform _unsubmit(e.id, d);
end $$;

create or replace function emp_submit_week(p_token text, p_week_start date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e employees; ws date := _week_start(p_week_start);
begin
  e := _emp(p_token);
  if exists (select 1 from punches where employee_id = e.id and clock_out is null
             and work_date between ws and ws + 6) then
    raise exception 'Clock out (or fill in the end time) before submitting.';
  end if;
  insert into week_submissions(employee_id, week_start) values (e.id, ws)
    on conflict (employee_id, week_start) do update set submitted_at = now();
  return jsonb_build_object('submitted_at', now());
end $$;

create or replace function emp_save_push(p_token text, p_sub jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare e employees;
begin
  e := _emp(p_token);
  if p_sub ->> 'endpoint' is null then raise exception 'Bad subscription'; end if;
  insert into push_subscriptions(endpoint, employee_id, subscription)
    values (p_sub ->> 'endpoint', e.id, p_sub)
    on conflict (endpoint) do update set employee_id = excluded.employee_id,
      subscription = excluded.subscription, created_at = now();
end $$;

-- ---------- Admin functions ------------------------------------------

create or replace function admin_login(p_username text, p_password text) returns text
language plpgsql volatile security definer set search_path = public, extensions as $$
declare a admins; t text;
begin
  select * into a from admins where username = lower(trim(p_username)) and active;
  if not found or extensions.crypt(p_password, a.pw_hash) <> a.pw_hash then
    perform pg_sleep(1);
    raise exception 'Wrong username or password.';
  end if;
  t := encode(extensions.gen_random_bytes(24), 'hex');
  insert into admin_sessions(token, admin_id) values (t, a.id);
  return t;
end $$;

create or replace function admin_me(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a admins;
begin
  a := _admin(p_tok);
  return jsonb_build_object('id', a.id, 'name', a.name, 'username', a.username, 'is_owner', a.is_owner);
end $$;

create or replace function admin_change_my_password(p_tok text, p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a admins;
begin
  a := _admin(p_tok);
  if extensions.crypt(p_old, a.pw_hash) <> a.pw_hash then raise exception 'Current password is wrong.'; end if;
  perform _check_pw(p_new);
  update admins set pw_hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where id = a.id;
  delete from admin_sessions where admin_id = a.id and token <> p_tok;
end $$;

-- Owner-only: manage office logins
create or replace function admin_logins(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _owner(p_tok);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'username', username,
    'is_owner', is_owner, 'active', active) order by active desc, is_owner desc, lower(name))
    from admins), '[]'::jsonb);
end $$;

create or replace function admin_add_login(p_tok text, p_name text, p_username text,
  p_password text, p_is_owner boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _owner(p_tok);
  if exists (select 1 from admins where username = lower(trim(p_username))) then
    raise exception 'That username is taken.';
  end if;
  perform add_office_login(p_name, p_username, p_password, p_is_owner);
end $$;

create or replace function admin_update_login(p_tok text, p_id uuid, p_active boolean,
  p_is_owner boolean, p_new_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me admins;
begin
  me := _owner(p_tok);
  if p_id = me.id and (not p_active or not p_is_owner) then
    raise exception 'You can''t turn off or demote your own login.';
  end if;
  update admins set active = p_active, is_owner = p_is_owner where id = p_id;
  if not exists (select 1 from admins where is_owner and active) then
    raise exception 'There must always be at least one active owner.';
  end if;
  if coalesce(p_new_password, '') <> '' then
    perform _check_pw(p_new_password);
    update admins set pw_hash = extensions.crypt(p_new_password, extensions.gen_salt('bf')) where id = p_id;
  end if;
  if not p_active or coalesce(p_new_password, '') <> '' then
    delete from admin_sessions where admin_id = p_id;
  end if;
end $$;

create or replace function admin_employees(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_tok);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name,
    'token', token, 'active', active,
    'push', exists (select 1 from push_subscriptions s where s.employee_id = employees.id))
    order by active desc, lower(name)) from employees), '[]'::jsonb);
end $$;

create or replace function admin_add_employee(p_tok text, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e employees;
begin
  perform _admin(p_tok);
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter a name.'; end if;
  insert into employees(name, token) values (trim(p_name), _new_code()) returning * into e;
  return jsonb_build_object('id', e.id, 'name', e.name, 'token', e.token, 'active', e.active);
end $$;

create or replace function admin_update_employee(p_tok text, p_id uuid, p_name text,
  p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_tok);
  update employees set name = coalesce(nullif(trim(p_name), ''), name), active = p_active
    where id = p_id;
  if not p_active then delete from push_subscriptions where employee_id = p_id; end if;
end $$;

create or replace function admin_new_link(p_tok text, p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare t text := _new_code();
begin
  perform _admin(p_tok);
  update employees set token = t where id = p_id;
  delete from push_subscriptions where employee_id = p_id;
  return t;
end $$;

create or replace function admin_week(p_tok text, p_week_start date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ws date := _week_start(p_week_start);
begin
  perform _admin(p_tok);
  return jsonb_build_object(
    'week_start', ws,
    'today', _shop_today(),
    'employees', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name,
        'active', active) order by lower(name)) from employees
        where active or exists (select 1 from punches p where p.employee_id = employees.id
                                and p.work_date between ws and ws + 6)), '[]'::jsonb),
    'punches', coalesce((select jsonb_agg(_punch_json(p) order by p.clock_in) from punches p
        where p.work_date between ws and ws + 6), '[]'::jsonb),
    'submissions', coalesce((select jsonb_object_agg(employee_id, submitted_at)
        from week_submissions where week_start = ws), '{}'::jsonb));
end $$;

create or replace function admin_save_punch(p_tok text, p_id uuid, p_employee_id uuid,
  p_work_date date, p_in timestamptz, p_out timestamptz, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p punches; a admins;
begin
  a := _admin(p_tok);
  if p_out is not null and p_out <= p_in then
    raise exception 'End time must be after start time.';
  end if;
  if p_id is null then
    insert into punches(employee_id, work_date, clock_in, clock_out, note, edited_by)
      values (p_employee_id, p_work_date, p_in, p_out, nullif(trim(p_note), ''), a.name)
      returning * into p;
  else
    update punches set work_date = p_work_date, clock_in = p_in, clock_out = p_out,
      note = nullif(trim(p_note), ''), edited_by = a.name, updated_at = now()
      where id = p_id returning * into p;
    if not found then raise exception 'Entry not found.'; end if;
  end if;
  return _punch_json(p);
end $$;

create or replace function admin_delete_punch(p_tok text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_tok);
  delete from punches where id = p_id;
end $$;

create or replace function admin_set_submitted(p_tok text, p_employee_id uuid,
  p_week_start date, p_submitted boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_tok);
  if p_submitted then
    insert into week_submissions(employee_id, week_start)
      values (p_employee_id, _week_start(p_week_start)) on conflict do nothing;
  else
    delete from week_submissions where employee_id = p_employee_id
      and week_start = _week_start(p_week_start);
  end if;
end $$;

create or replace function admin_logout(p_tok text) returns void
language sql security definer set search_path = public as $$
  delete from admin_sessions where token = p_tok
$$;

-- ---------- Permissions ----------------------------------------------
-- Only the emp_* and admin_* functions can be called from the app.

revoke all on all functions in schema public from public, anon, authenticated;
grant execute on function
  emp_week(text, date), emp_clock_in(text), emp_clock_out(text),
  emp_save_punch(text, uuid, date, timestamptz, timestamptz, text),
  emp_delete_punch(text, uuid), emp_submit_week(text, date), emp_save_push(text, jsonb),
  admin_login(text, text), admin_logout(text), admin_me(text),
  admin_change_my_password(text, text, text), admin_logins(text),
  admin_add_login(text, text, text, text, boolean),
  admin_update_login(text, uuid, boolean, boolean, text), admin_employees(text), admin_add_employee(text, text),
  admin_update_employee(text, uuid, text, boolean), admin_new_link(text, uuid),
  admin_week(text, date),
  admin_save_punch(text, uuid, uuid, date, timestamptz, timestamptz, text),
  admin_delete_punch(text, uuid), admin_set_submitted(text, uuid, date, boolean)
to anon, authenticated;

-- The reminder sender (GitHub Actions) reads these tables with the secret key.
-- Newer Supabase projects don't grant table access automatically, so grant it here.
grant usage on schema public to service_role;
grant select, insert, update, delete on all tables in schema public to service_role;


-- =====================================================================
--  Shop Time Clock — update 2: multiple shops + employee phone/email
--  Safe to run more than once. Run AFTER schema.sql (already included
--  at the end of schema.sql for new installs).
-- =====================================================================

create table if not exists shops (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  sort        int not null default 0,
  created_at  timestamptz not null default now()
);
alter table shops enable row level security;

alter table employees add column if not exists shop_id uuid references shops(id);
alter table employees add column if not exists phone text;
alter table employees add column if not exists email text;

-- Start with two shops; the owner renames them in the app (Settings).
insert into shops(name, sort)
  select v.name, v.sort from (values ('Shop 1', 1), ('Shop 2', 2)) v(name, sort)
  where not exists (select 1 from shops);

-- Anyone without a shop goes to the first one.
update employees set shop_id = (select id from shops order by sort, created_at limit 1)
  where shop_id is null;

create or replace function _first_shop() returns uuid
language sql stable security definer set search_path = public as $$
  select id from shops order by sort, created_at limit 1
$$;

-- ---------- Employee: include shop name ------------------------------
create or replace function emp_week(p_token text, p_week_start date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e employees; ws date := _week_start(p_week_start);
begin
  e := _emp(p_token);
  return jsonb_build_object(
    'employee', jsonb_build_object('id', e.id, 'name', e.name,
                  'shop', (select name from shops where id = e.shop_id)),
    'week_start', ws,
    'today', _shop_today(),
    'editable_from', _week_start(_shop_today()) - 7,
    'submitted_at', (select submitted_at from week_submissions
                     where employee_id = e.id and week_start = ws),
    'last_week_submitted', exists (select 1 from week_submissions
                     where employee_id = e.id
                       and week_start = _week_start(_shop_today()) - 7),
    'open_punch', (select _punch_json(p) from punches p
                   where p.employee_id = e.id and p.clock_out is null
                   order by clock_in desc limit 1),
    'punches', coalesce((select jsonb_agg(_punch_json(p) order by p.clock_in)
                         from punches p
                         where p.employee_id = e.id
                           and p.work_date between ws and ws + 6), '[]'::jsonb));
end $$;

-- ---------- Shops (office) -------------------------------------------
create or replace function admin_shops(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_tok);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name,
    'employees', (select count(*) from employees e where e.shop_id = shops.id and e.active))
    order by sort, created_at) from shops), '[]'::jsonb);
end $$;

create or replace function admin_add_shop(p_tok text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _owner(p_tok);
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter a shop name.'; end if;
  insert into shops(name, sort) values (trim(p_name), coalesce((select max(sort) from shops), 0) + 1);
end $$;

create or replace function admin_rename_shop(p_tok text, p_id uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _owner(p_tok);
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter a shop name.'; end if;
  update shops set name = trim(p_name) where id = p_id;
end $$;

-- ---------- Employees, now per shop, with phone/email -----------------
drop function if exists admin_employees(text);
drop function if exists admin_add_employee(text, text);
drop function if exists admin_update_employee(text, uuid, text, boolean);
drop function if exists admin_week(text, date);

create or replace function admin_employees(p_tok text, p_shop uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_tok);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name,
    'token', token, 'active', active, 'shop_id', shop_id, 'phone', phone, 'email', email,
    'push', exists (select 1 from push_subscriptions s where s.employee_id = employees.id))
    order by active desc, lower(name))
    from employees where p_shop is null or shop_id = p_shop), '[]'::jsonb);
end $$;

create or replace function admin_add_employee(p_tok text, p_name text, p_shop uuid,
  p_phone text, p_email text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e employees;
begin
  perform _admin(p_tok);
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter a name.'; end if;
  insert into employees(name, token, shop_id, phone, email)
    values (trim(p_name), _new_code(), coalesce(p_shop, _first_shop()),
            nullif(trim(p_phone), ''), nullif(lower(trim(p_email)), ''))
    returning * into e;
  return jsonb_build_object('id', e.id, 'name', e.name, 'token', e.token, 'active', e.active,
    'shop_id', e.shop_id, 'phone', e.phone, 'email', e.email, 'push', false);
end $$;

create or replace function admin_update_employee(p_tok text, p_id uuid, p_name text,
  p_active boolean, p_shop uuid, p_phone text, p_email text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_tok);
  update employees set
    name = coalesce(nullif(trim(p_name), ''), name),
    active = p_active,
    shop_id = coalesce(p_shop, shop_id),
    phone = nullif(trim(p_phone), ''),
    email = nullif(lower(trim(p_email)), '')
  where id = p_id;
  if not p_active then delete from push_subscriptions where employee_id = p_id; end if;
end $$;

create or replace function admin_week(p_tok text, p_week_start date, p_shop uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ws date := _week_start(p_week_start);
begin
  perform _admin(p_tok);
  return jsonb_build_object(
    'week_start', ws,
    'today', _shop_today(),
    'employees', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name,
        'active', active) order by lower(name)) from employees
        where (p_shop is null or shop_id = p_shop)
          and (active or exists (select 1 from punches p where p.employee_id = employees.id
                                 and p.work_date between ws and ws + 6))), '[]'::jsonb),
    'punches', coalesce((select jsonb_agg(_punch_json(p) order by p.clock_in) from punches p
        join employees e on e.id = p.employee_id
        where p.work_date between ws and ws + 6
          and (p_shop is null or e.shop_id = p_shop)), '[]'::jsonb),
    'submissions', coalesce((select jsonb_object_agg(w.employee_id, w.submitted_at)
        from week_submissions w join employees e on e.id = w.employee_id
        where w.week_start = ws and (p_shop is null or e.shop_id = p_shop)), '{}'::jsonb));
end $$;

-- ---------- Permissions ----------------------------------------------
revoke all on function _first_shop() from public, anon, authenticated;
grant execute on function
  admin_shops(text), admin_add_shop(text, text), admin_rename_shop(text, uuid, text),
  admin_employees(text, uuid), admin_add_employee(text, text, uuid, text, text),
  admin_update_employee(text, uuid, text, boolean, uuid, text, text),
  admin_week(text, date, uuid)
to anon, authenticated;
grant select, insert, update, delete on shops to service_role;
