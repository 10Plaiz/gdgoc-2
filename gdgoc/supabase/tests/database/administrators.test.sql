-- The Administrator role (Users.is_admin): who can grant and revoke it, and
-- that losing it takes away Event management straight away.

begin;
create extension if not exists pgtap with schema extensions;

select plan(14);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@example.com',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-00000000000b', 'member@example.com', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-00000000000c', 'other@example.com',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-00000000000d', 'admin2@example.com', 'authenticated', 'authenticated');

insert into public."Users" (user_id, first_name, last_name, email, is_admin) values
  ('00000000-0000-0000-0000-00000000000a', 'Jane', 'Doe', 'admin@example.com',  true),
  ('00000000-0000-0000-0000-00000000000b', 'John', 'Doe', 'member@example.com', false),
  ('00000000-0000-0000-0000-00000000000d', 'June', 'Doe', 'admin2@example.com', true);

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims',
                    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- ---------------------------------------------------------------------------
-- Visitors have no access to Users at all
-- ---------------------------------------------------------------------------
select ok(not has_table_privilege('anon', 'public."Users"', 'select'),
          'a visitor has no select privilege on Users');
select ok(not has_table_privilege('authenticated', 'public."Users"', 'delete'),
          'a Member has no delete privilege on Users');
-- TRUNCATE skips RLS, so no website role may hold it on any table here.
select is(
  (select array_agg(distinct c.relname::text order by c.relname::text)
   from pg_class c
   join pg_namespace n on n.oid = c.relnamespace
   cross join unnest(array['anon', 'authenticated']) r(role)
   where n.nspname = 'public' and c.relkind in ('r', 'v')
     and (has_table_privilege(r.role, c.oid, 'truncate')
          or has_table_privilege(r.role, c.oid, 'trigger')
          or has_table_privilege(r.role, c.oid, 'references'))),
  null,
  'website roles hold no truncate, trigger or references privilege on public tables');

-- ---------------------------------------------------------------------------
-- Granting
-- ---------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-00000000000c');
select throws_ok(
  $$ insert into public."Users" (user_id, first_name, last_name, email, is_admin)
     values ('00000000-0000-0000-0000-00000000000c', 'Jim', 'Doe', 'other@example.com', true) $$,
  '42501', null, 'a Member cannot sign up as an Administrator');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ insert into public."Users" (user_id, first_name, last_name, email)
     values ('00000000-0000-0000-0000-00000000000c', 'Jim', 'Doe', 'other@example.com') $$,
  '42501', null, 'a Member cannot create a Users row for someone else');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ update public."Users" set is_admin = true where user_id = '00000000-0000-0000-0000-00000000000b' $$,
  '42501', null, 'a Member cannot make themselves an Administrator');

select is((select count(*)::int from public."Users"), 1, 'a Member reads only their own Users row');

select lives_ok(
  $$ update public."Users" set first_name = 'Johnny' where user_id = '00000000-0000-0000-0000-00000000000b' $$,
  'a Member can still edit their own profile');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$ update public."Users" set is_admin = true where user_id = '00000000-0000-0000-0000-00000000000b' $$,
  'an Administrator can grant the Administrator role');

-- ---------------------------------------------------------------------------
-- Revoking
-- ---------------------------------------------------------------------------
select is((select count(*)::int from public."Users"), 3,
          'an Administrator reads every Users row (setup check for the next tests)');

select lives_ok(
  $$ update public."Users" set is_admin = false where user_id = '00000000-0000-0000-0000-00000000000d' $$,
  'an Administrator can revoke another Administrator');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000d');
select throws_ok(
  $$ insert into public.events (title, category, starts_at, ends_at) values ('x', 'talk', now(), now() + interval '1 hour') $$,
  '42501', null, 'a revoked Administrator can no longer create Events');
select throws_ok(
  $$ update public."Users" set is_admin = true where user_id = '00000000-0000-0000-0000-00000000000d' $$,
  '42501', null, 'a revoked Administrator cannot grant the role back to themselves');

-- RLS hides other Members' rows, so this update matches nothing.
select pg_temp.act_as('00000000-0000-0000-0000-00000000000c');
update public."Users" set is_admin = false where user_id = '00000000-0000-0000-0000-00000000000a';
reset role;
select is((select is_admin from public."Users" where user_id = '00000000-0000-0000-0000-00000000000a'), true,
          'a Member cannot revoke an Administrator');

select * from finish();
rollback;
