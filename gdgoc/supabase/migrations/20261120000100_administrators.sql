-- Administrators: the private schema, the Users baseline and the Administrator check.
--
-- See docs/adr/0001-supabase-as-cms.md and docs/adr/0003-one-supabase-project.md.
-- Every CMS table checks private.is_admin() in its RLS policies, so the
-- Administrator flag (Users.is_admin) must be impossible for a Member to set.

-- ---------------------------------------------------------------------------
-- private schema: helpers the website's API never exposes.
-- It is not in [api].schemas in config.toml, so PostgREST can't reach it.
-- RLS policies run as the calling role, so that role needs USAGE to call
-- the helpers from inside a policy.
-- ---------------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Users baseline.
-- The production table predates this repo and its exact structure was never
-- recorded. This recreates it from the columns the app uses, so a local or
-- rebuilt database works. "if not exists" leaves an existing table alone.
--
-- Production assumptions (check them in the dashboard before applying this
-- to the live project; the Supabase project is being recreated, PRD §5.5):
--   * The live table has at least these columns, with is_admin a boolean.
--   * Existing policies on "Users" are unknown. Permissive policies are OR'd
--     together, so an older broad policy (for example "anyone can select")
--     would quietly override the ones below. List them with
--       select policyname, cmd, roles from pg_policies where tablename = 'Users';
--     and drop any that grant more than these.
--   * The sign-up page inserts the Users row right after auth.signUp(). That
--     only works while a session exists at that moment, i.e. while email
--     confirmation is off (as in config.toml). With confirmation on, the
--     insert runs as anon and the policy below refuses it; the row would then
--     need to come from a trigger on auth.users instead.
-- ---------------------------------------------------------------------------
create table if not exists public."Users" (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  first_name text not null,
  last_name  text not null,
  gdg_id     text,
  email      text not null,
  campus     text,
  is_admin   boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public."Users" enable row level security;

-- ---------------------------------------------------------------------------
-- private.is_admin(): true when the signed-in Member is an Administrator.
-- security definer, so it can read Users whatever the caller's RLS allows.
-- An empty search_path stops a caller from shadowing the objects it uses.
-- ---------------------------------------------------------------------------
create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select u.is_admin from public."Users" u where u.user_id = (select auth.uid())),
    false
  );
$$;

revoke all on function private.is_admin() from public;
grant execute on function private.is_admin() to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Users policies (fixes finding F1 together with the trigger below).
-- A Member reads and edits only their own row; Administrators read and edit all
-- rows, which is how /admin grants and revokes the role.
-- ---------------------------------------------------------------------------
drop policy if exists "Members read their own row; Administrators read all" on public."Users";
create policy "Members read their own row; Administrators read all"
  on public."Users" for select
  to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));

drop policy if exists "Members create their own row" on public."Users";
create policy "Members create their own row"
  on public."Users" for insert
  to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists "Members edit their own row; Administrators edit all" on public."Users";
create policy "Members edit their own row; Administrators edit all"
  on public."Users" for update
  to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()))
  with check (user_id = (select auth.uid()) or (select private.is_admin()));

-- Start from nothing: Supabase's default privileges include TRUNCATE, which
-- skips RLS. Visitors get no access; Members get only what the policies allow.
revoke all on public."Users" from anon, authenticated;
grant select, insert, update on public."Users" to authenticated;

-- ---------------------------------------------------------------------------
-- Guard the Administrator flag.
-- RLS can't restrict a single column, so a trigger refuses any request from
-- the website (roles anon and authenticated) that sets or changes is_admin
-- unless the caller is already an Administrator. The project owner creates the
-- first Administrator from the SQL editor, where no website role applies.
-- ---------------------------------------------------------------------------
create or replace function private.guard_admin_flag()
returns trigger
language plpgsql
-- security invoker, so current_user is the real database role of the request
-- (anon/authenticated from the website, postgres from the SQL editor) and not
-- a JWT claim.
security invoker
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;

  if tg_op = 'INSERT' and new.is_admin then
    raise exception 'Only an Administrator can grant the Administrator role'
      using errcode = '42501';
  end if;

  if tg_op = 'UPDATE'
     and new.is_admin is distinct from old.is_admin
     and not private.is_admin() then
    raise exception 'Only an Administrator can grant or revoke the Administrator role'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke all on function private.guard_admin_flag() from public;

drop trigger if exists guard_admin_flag on public."Users";
create trigger guard_admin_flag
  before insert or update on public."Users"
  for each row execute function private.guard_admin_flag();

-- ---------------------------------------------------------------------------
-- Shared trigger: keep updated_at current on every table that has one.
-- ---------------------------------------------------------------------------
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function private.set_updated_at() from public;
