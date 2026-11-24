-- =====================================================================
--  Shop Time Clock — update 3: managers can clock in too + invites
--  Safe to run more than once. Run AFTER update-2-shops.sql.
-- =====================================================================

alter table admins add column if not exists phone text;
alter table admins add column if not exists email text;
alter table admins add column if not exists employee_id uuid references employees(id) on delete set null;

-- Who am I (now includes my own time clock, if I have one)
create or replace function admin_me(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a admins;
begin
  a := _admin(p_tok);
  return jsonb_build_object('id', a.id, 'name', a.name, 'username', a.username, 'is_owner', a.is_owner,
    'phone', a.phone, 'email', a.email,
    'employee', (select jsonb_build_object('id', e.id, 'name', e.name, 'token', e.token, 'shop_id', e.shop_id,
                   'phone', e.phone, 'email', e.email, 'active', e.active)
                 from employees e where e.id = a.employee_id and e.active));
end $$;

create or replace function admin_update_my_name(p_tok text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare a admins;
begin
  a := _admin(p_tok);
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter a name.'; end if;
  update admins set name = trim(p_name) where id = a.id;
end $$;

-- Owner: list office logins with contact info and their time clock link
create or replace function admin_logins(p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _owner(p_tok);
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'username', a.username,
    'is_owner', a.is_owner, 'active', a.active, 'phone', a.phone, 'email', a.email,
    'employee', case when e.id is null then null else jsonb_build_object('id', e.id, 'name', e.name,
        'token', e.token, 'shop_id', e.shop_id, 'phone', e.phone, 'email', e.email, 'active', e.active) end)
    order by a.active desc, a.is_owner desc, lower(a.name))
    from admins a left join employees e on e.id = a.employee_id and e.active), '[]'::jsonb);
end $$;

-- Owner: add an office login, optionally with its own time clock
drop function if exists admin_add_login(text, text, text, text, boolean);
create or replace function admin_add_login(p_tok text, p_name text, p_username text,
  p_password text, p_is_owner boolean, p_phone text, p_email text, p_shop uuid, p_clock boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare new_id uuid; e employees;
begin
  perform _owner(p_tok);
  if exists (select 1 from admins where username = lower(trim(p_username))) then
    raise exception 'That username is taken.';
  end if;
  perform add_office_login(p_name, p_username, p_password, p_is_owner);
  select id into new_id from admins where username = lower(trim(p_username));
  update admins set phone = nullif(trim(p_phone), ''), email = nullif(lower(trim(p_email)), '') where id = new_id;
  if p_clock then
    insert into employees(name, token, shop_id, phone, email)
      values (trim(p_name), _new_code(), coalesce(p_shop, _first_shop()),
              nullif(trim(p_phone), ''), nullif(lower(trim(p_email)), ''))
      returning * into e;
    update admins set employee_id = e.id where id = new_id;
  end if;
  return jsonb_build_object('id', new_id, 'name', trim(p_name), 'username', lower(trim(p_username)),
    'phone', nullif(trim(p_phone), ''), 'email', nullif(lower(trim(p_email)), ''),
    'employee', case when e.id is null then null else jsonb_build_object('id', e.id, 'name', e.name,
        'token', e.token, 'shop_id', e.shop_id, 'phone', e.phone, 'email', e.email, 'active', e.active) end);
end $$;

-- Give an existing office login (or yourself) a time clock
create or replace function admin_add_clock(p_tok text, p_id uuid, p_shop uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me admins; a admins; e employees;
begin
  me := _admin(p_tok);
  if p_id <> me.id and not me.is_owner then raise exception 'Only an owner login can do that.'; end if;
  select * into a from admins where id = p_id;
  if not found then raise exception 'Login not found.'; end if;
  select * into e from employees where id = a.employee_id and active;
  if not found then
    insert into employees(name, token, shop_id, phone, email)
      values (a.name, _new_code(), coalesce(p_shop, _first_shop()), a.phone, a.email)
      returning * into e;
    update admins set employee_id = e.id where id = a.id;
  end if;
  return jsonb_build_object('id', e.id, 'name', e.name, 'token', e.token, 'shop_id', e.shop_id,
    'phone', e.phone, 'email', e.email, 'active', e.active);
end $$;

grant execute on function
  admin_me(text), admin_update_my_name(text, text), admin_logins(text),
  admin_add_login(text, text, text, text, boolean, text, text, uuid, boolean),
  admin_add_clock(text, uuid, uuid)
to anon, authenticated;
