-- =====================================================================
--  Shop Time Clock — update 6: Payroll calculator (owner logins only)
--  Pay type + rate per employee, weekly commission / bonus entries.
--  Gross pay is calculated in the app from the time cards.
--  Safe to run more than once. Run AFTER update-5-late-clockin.sql.
-- =====================================================================

create table if not exists pay_settings (
  employee_id uuid primary key references employees(id) on delete cascade,
  pay_type text not null default 'hourly' check (pay_type in ('hourly', 'salary', 'c_hourly', 'c_flat')),
  rate numeric(12,2) not null default 0 check (rate >= 0),
  commission_type text not null default 'none' check (commission_type in ('none', 'percent', 'flat')),
  commission_pct numeric(6,3) not null default 0 check (commission_pct >= 0 and commission_pct <= 100),
  updated_at timestamptz not null default now(),
  updated_by text
);
alter table pay_settings enable row level security;
revoke all on pay_settings from anon, authenticated;

create table if not exists payroll_weeks (
  employee_id uuid not null references employees(id) on delete cascade,
  week_start date not null,
  sales numeric(12,2) not null default 0 check (sales >= 0),
  commission_amt numeric(12,2) not null default 0,
  other_amt numeric(12,2) not null default 0,
  note text,
  updated_at timestamptz not null default now(),
  updated_by text,
  primary key (employee_id, week_start)
);
alter table payroll_weeks enable row level security;
revoke all on payroll_weeks from anon, authenticated;

-- Pay setup + this week's entries for one shop (owner logins only)
create or replace function admin_payroll(p_tok text, p_week_start date, p_shop uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ws date := _week_start(p_week_start);
begin
  perform _owner(p_tok);
  return jsonb_build_object(
    'week_start', ws,
    'settings', coalesce((select jsonb_object_agg(s.employee_id, jsonb_build_object(
        'pay_type', s.pay_type, 'rate', s.rate, 'commission_type', s.commission_type,
        'commission_pct', s.commission_pct, 'updated_by', s.updated_by))
      from pay_settings s join employees e on e.id = s.employee_id
      where p_shop is null or e.shop_id = p_shop), '{}'::jsonb),
    'weeks', coalesce((select jsonb_object_agg(w.employee_id, jsonb_build_object(
        'sales', w.sales, 'commission_amt', w.commission_amt, 'other_amt', w.other_amt, 'note', w.note))
      from payroll_weeks w join employees e on e.id = w.employee_id
      where w.week_start = ws and (p_shop is null or e.shop_id = p_shop)), '{}'::jsonb));
end $$;

create or replace function admin_set_pay(p_tok text, p_employee uuid, p_pay_type text, p_rate numeric,
                                         p_commission_type text, p_commission_pct numeric) returns void
language plpgsql security definer set search_path = public as $$
declare a admins;
begin
  a := _owner(p_tok);
  if not exists (select 1 from employees where id = p_employee) then raise exception 'Employee not found.'; end if;
  insert into pay_settings(employee_id, pay_type, rate, commission_type, commission_pct, updated_at, updated_by)
  values (p_employee, p_pay_type, round(coalesce(p_rate, 0), 2), coalesce(p_commission_type, 'none'),
          coalesce(p_commission_pct, 0), now(), a.name)
  on conflict (employee_id) do update set pay_type = excluded.pay_type, rate = excluded.rate,
    commission_type = excluded.commission_type, commission_pct = excluded.commission_pct,
    updated_at = now(), updated_by = a.name;
end $$;

create or replace function admin_set_payroll_week(p_tok text, p_employee uuid, p_week_start date, p_sales numeric,
                                                  p_commission_amt numeric, p_other_amt numeric, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare a admins;
begin
  a := _owner(p_tok);
  if not exists (select 1 from employees where id = p_employee) then raise exception 'Employee not found.'; end if;
  insert into payroll_weeks(employee_id, week_start, sales, commission_amt, other_amt, note, updated_at, updated_by)
  values (p_employee, _week_start(p_week_start), round(coalesce(p_sales, 0), 2), round(coalesce(p_commission_amt, 0), 2),
          round(coalesce(p_other_amt, 0), 2), nullif(trim(coalesce(p_note, '')), ''), now(), a.name)
  on conflict (employee_id, week_start) do update set sales = excluded.sales, commission_amt = excluded.commission_amt,
    other_amt = excluded.other_amt, note = excluded.note, updated_at = now(), updated_by = a.name;
end $$;

grant execute on function admin_payroll(text, date, uuid),
  admin_set_pay(text, uuid, text, numeric, text, numeric),
  admin_set_payroll_week(text, uuid, date, numeric, numeric, numeric, text) to anon, authenticated;
grant select, insert, update, delete on pay_settings, payroll_weeks to service_role;
