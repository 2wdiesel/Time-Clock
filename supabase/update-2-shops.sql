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
