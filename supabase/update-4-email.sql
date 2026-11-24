-- =====================================================================
--  Shop Time Clock — update 4: the app sends invite emails by itself
--  Mail goes out through a small Google Apps Script running in the
--  shop's Gmail account. The script address + password are saved
--  privately with mail_setup(...) — never in this file.
--  Safe to run more than once. Run AFTER update-3-managers.sql.
-- =====================================================================

create extension if not exists pg_net;

create table if not exists mail_config (
  id int primary key default 1 check (id = 1),
  url text not null,
  secret text not null,
  from_name text not null default 'Shop Time Clock'
);
alter table mail_config enable row level security;
revoke all on mail_config from anon, authenticated;

create table if not exists mail_log (
  id bigserial primary key,
  sent_at timestamptz not null default now(),
  admin_id uuid references admins(id) on delete set null,
  to_email text not null,
  request_id bigint
);
alter table mail_log enable row level security;
revoke all on mail_log from anon, authenticated;
revoke all on sequence mail_log_id_seq from anon, authenticated;

-- Run once in the SQL editor (not from the app) to save the mail script address.
create or replace function mail_setup(p_url text, p_secret text, p_from_name text) returns text
language plpgsql security definer set search_path = public as $$
begin
  insert into mail_config(id, url, secret, from_name) values (1, trim(p_url), trim(p_secret), trim(p_from_name))
  on conflict (id) do update set url = excluded.url, secret = excluded.secret, from_name = excluded.from_name;
  return 'Email sending is set up.';
end $$;
revoke all on function mail_setup(text, text, text) from public, anon, authenticated;

-- Is automatic email turned on?
create or replace function admin_mail_ready(p_tok text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_tok);
  return exists (select 1 from mail_config);
end $$;

-- Send one email (invite). Returns a number used to check that it went out.
create or replace function admin_send_email(p_tok text, p_to text, p_subject text, p_body text) returns bigint
language plpgsql security definer set search_path = public, net as $$
declare a admins; c mail_config; rid bigint; addr text := lower(trim(p_to));
begin
  a := _admin(p_tok);
  select * into c from mail_config where id = 1;
  if not found then raise exception 'Email sending is not set up yet.'; end if;
  if addr !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Type in a valid email first.'; end if;
  if length(coalesce(p_body, '')) > 5000 or length(coalesce(p_subject, '')) > 200 then
    raise exception 'That message is too long.';
  end if;
  if (select count(*) from mail_log where sent_at > now() - interval '1 day') >= 60 then
    raise exception 'Daily email limit reached. Try again tomorrow, or use Copy link.';
  end if;
  select net.http_post(
    url := c.url,
    body := jsonb_build_object('secret', c.secret, 'to', addr, 'subject', p_subject, 'body', p_body,
                               'name', c.from_name, 'replyTo', coalesce(a.email, '')),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 20000) into rid;
  insert into mail_log(admin_id, to_email, request_id) values (a.id, addr, rid);
  return rid;
end $$;

-- Did that email go out? 'sent', 'waiting' or 'failed'
create or replace function admin_email_status(p_tok text, p_id bigint) returns text
language plpgsql security definer set search_path = public, net as $$
declare r record;
begin
  perform _admin(p_tok);
  if not exists (select 1 from mail_log where request_id = p_id) then return 'failed'; end if;
  select status_code, content, timed_out, error_msg into r from net._http_response where id = p_id;
  if not found then return 'waiting'; end if;
  -- Apps Script answers with a redirect (302) after it has already sent the email.
  if r.status_code = 302 or (r.status_code = 200 and coalesce(r.content, '') like '%ok%') then return 'sent'; end if;
  return 'failed';
end $$;

grant execute on function admin_mail_ready(text), admin_send_email(text, text, text, text),
  admin_email_status(text, bigint) to anon, authenticated;
