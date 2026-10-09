-- VisitLog database setup for Supabase PostgreSQL.
-- Run this whole file in Supabase Dashboard > SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (char_length(username) between 3 and 40),
  role text not null default 'User' check (role in ('Admin','User')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.visit_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete restrict,
  customer_name text not null check (char_length(trim(customer_name)) between 1 and 160),
  contact_number text not null check (char_length(trim(contact_number)) between 6 and 20),
  city text not null check (char_length(trim(city)) between 1 and 100),
  visit_date date not null default current_date,
  reason text not null check (char_length(trim(reason)) between 1 and 180),
  remarks text not null default '' check (char_length(remarks) <= 5000),
  start_time time not null,
  end_time time not null,
  duration_minutes integer generated always as (
    (extract(hour from end_time)::integer * 60 + extract(minute from end_time)::integer) -
    (extract(hour from start_time)::integer * 60 + extract(minute from start_time)::integer)
  ) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint visit_end_after_start check (end_time > start_time)
);

create index if not exists visit_reports_user_date_idx on public.visit_reports(user_id, visit_date desc);
create index if not exists visit_reports_date_idx on public.visit_reports(visit_date desc);
create index if not exists visit_reports_customer_idx on public.visit_reports(lower(customer_name));
create index if not exists visit_reports_city_idx on public.visit_reports(city);
create index if not exists visit_reports_reason_idx on public.visit_reports(reason);

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists visit_reports_touch_updated_at on public.visit_reports;
create trigger visit_reports_touch_updated_at before update on public.visit_reports
for each row execute function public.touch_updated_at();

-- Profile metadata is set only by trusted account provisioning (dashboard/Edge Function).
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_username text;
begin
  v_username := coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1));
  insert into public.profiles(id, username, role, active)
  values(new.id, v_username, 'User', true)
  on conflict (id) do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created_visitlog on auth.users;
create trigger on_auth_user_created_visitlog after insert on auth.users
for each row execute function public.handle_new_auth_user();

alter table public.profiles enable row level security;
alter table public.visit_reports enable row level security;

drop policy if exists "Read own profile or admin profiles" on public.profiles;
create policy "Read own profile or admin profiles" on public.profiles for select to authenticated
using (id = (select auth.uid()) or exists (
  select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'Admin' and p.active
));

drop policy if exists "Users read own visits admins read all" on public.visit_reports;
create policy "Users read own visits admins read all" on public.visit_reports for select to authenticated
using (user_id = (select auth.uid()) or exists (
  select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'Admin' and p.active
));

drop policy if exists "Users insert own visits" on public.visit_reports;
create policy "Users insert own visits" on public.visit_reports for insert to authenticated
with check (user_id = (select auth.uid()) and exists (
  select 1 from public.profiles p where p.id = (select auth.uid()) and p.active
));

drop policy if exists "Users update own visits admins update all" on public.visit_reports;
create policy "Users update own visits admins update all" on public.visit_reports for update to authenticated
using (user_id = (select auth.uid()) or exists (
  select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'Admin' and p.active
))
with check (user_id = (select auth.uid()) or exists (
  select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'Admin' and p.active
));

drop policy if exists "Users delete own visits admins delete all" on public.visit_reports;
create policy "Users delete own visits admins delete all" on public.visit_reports for delete to authenticated
using (user_id = (select auth.uid()) or exists (
  select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'Admin' and p.active
));

-- Admin-only profile mutation RPCs. Direct profile INSERT/UPDATE/DELETE is not granted.
create or replace function public.username_to_email(p_username text)
returns text language sql stable security definer set search_path = ''
as $$
  select case when p.active then lower(p.username) || '@visitlog.app' else null end
  from public.profiles p where lower(p.username) = lower(trim(p_username)) limit 1;
$$;
revoke all on function public.username_to_email(text) from public;
grant execute on function public.username_to_email(text) to anon, authenticated;

create or replace function public.admin_set_user_status(p_user_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='Admin' and active) then
   raise exception 'Administrator access required';
 end if;
 if p_user_id = auth.uid() and not p_active then raise exception 'You cannot deactivate your own account'; end if;
 if not p_active and exists(select 1 from public.profiles where id=p_user_id and role='Admin')
   and (select count(*) from public.profiles where role='Admin' and active) <= 1 then
   raise exception 'The last active administrator cannot be deactivated';
 end if;
 update public.profiles set active=p_active where id=p_user_id;
 if not found then raise exception 'User not found'; end if;
end; $$;
revoke all on function public.admin_set_user_status(uuid,boolean) from public;
grant execute on function public.admin_set_user_status(uuid,boolean) to authenticated;

create or replace function public.admin_set_user_role(p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='Admin' and active) then raise exception 'Administrator access required'; end if;
 if p_role not in ('Admin','User') then raise exception 'Invalid role'; end if;
 if p_user_id=auth.uid() and p_role <> 'Admin' then raise exception 'You cannot remove your own administrator role'; end if;
 if p_role='User' and (select role from public.profiles where id=p_user_id)='Admin'
   and (select count(*) from public.profiles where role='Admin' and active)>1 then
   update public.profiles set role=p_role where id=p_user_id;
 elsif p_role='User' and (select role from public.profiles where id=p_user_id)='Admin' then
   raise exception 'The last administrator cannot be demoted';
 else
   update public.profiles set role=p_role where id=p_user_id;
 end if;
 if not found then raise exception 'User not found'; end if;
end; $$;
revoke all on function public.admin_set_user_role(uuid,text) from public;
grant execute on function public.admin_set_user_role(uuid,text) to authenticated;

grant usage on schema public to anon, authenticated;
grant select on public.profiles to authenticated;
grant select, insert, update, delete on public.visit_reports to authenticated;

-- IMPORTANT: Create the first administrator only after running this script.
-- In Authentication > Users, create a user with email "admin@visitlog.app",
-- a strong password, and user metadata {"username":"admin","role":"Admin"}.
-- Then promote the profile using the SQL below, replacing the email if needed:
-- update public.profiles set role='Admin', active=true where lower(username)='admin';
-- Keep email confirmation disabled for this internal username/password login setup,
-- or mark provisioned users as confirmed in the Edge Function.

-- SECURITY DEFINER helper avoids recursive RLS lookups on profiles.
create or replace function public.is_active_admin()
returns boolean language sql stable security definer set search_path = ''
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role='Admin' and active); $$;
revoke all on function public.is_active_admin() from public;
grant execute on function public.is_active_admin() to authenticated;

drop policy if exists "Read own profile or admin profiles" on public.profiles;
create policy "Read own profile or admin profiles" on public.profiles for select to authenticated
using (id = (select auth.uid()) or (select public.is_active_admin()));

drop policy if exists "Users read own visits admins read all" on public.visit_reports;
create policy "Users read own visits admins read all" on public.visit_reports for select to authenticated
using ((user_id = (select auth.uid()) and exists(select 1 from public.profiles p where p.id=auth.uid() and p.active)) or (select public.is_active_admin()));

drop policy if exists "Users insert own visits" on public.visit_reports;
create policy "Users insert own visits" on public.visit_reports for insert to authenticated
with check (user_id = (select auth.uid()) and exists(select 1 from public.profiles p where p.id=auth.uid() and p.active));

drop policy if exists "Users update own visits admins update all" on public.visit_reports;
create policy "Users update own visits admins update all" on public.visit_reports for update to authenticated
using ((user_id = (select auth.uid()) and exists(select 1 from public.profiles p where p.id=auth.uid() and p.active)) or (select public.is_active_admin()))
with check ((user_id = (select auth.uid()) and exists(select 1 from public.profiles p where p.id=auth.uid() and p.active)) or (select public.is_active_admin()));

drop policy if exists "Users delete own visits admins delete all" on public.visit_reports;
create policy "Users delete own visits admins delete all" on public.visit_reports for delete to authenticated
using ((user_id = (select auth.uid()) and exists(select 1 from public.profiles p where p.id=auth.uid() and p.active)) or (select public.is_active_admin()));
