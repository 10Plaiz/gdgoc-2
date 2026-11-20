-- Security tests for Events and the Moderator flag.
-- Run against the local Supabase: `npx supabase test db` (from gdgoc/).
-- Users and rows here are fake fixtures created inside a rolled-back transaction.

begin;
create extension if not exists pgtap with schema extensions;

select plan(20);

-- ---------------------------------------------------------------------------
-- Fixtures (as postgres, so no RLS and no website role).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-00000000000a', 'moderator@example.com', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-00000000000b', 'member@example.com',    'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-00000000000c', 'other@example.com',     'authenticated', 'authenticated');

insert into public."Users" (user_id, first_name, last_name, email, is_admin) values
  ('00000000-0000-0000-0000-00000000000a', 'Jane', 'Doe', 'moderator@example.com', true),
  ('00000000-0000-0000-0000-00000000000b', 'John', 'Doe', 'member@example.com',    false);

delete from public.events;  -- ignore seed rows

insert into public.events (id, title, category, starts_at, is_published, is_featured) values
  ('10000000-0000-0000-0000-000000000001', 'Published upcoming', 'workshop', now() + interval '7 days', true,  true),
  ('10000000-0000-0000-0000-000000000002', 'Published past',     'talk',     now() - interval '7 days', true,  false),
  ('10000000-0000-0000-0000-000000000003', 'Draft',              'sprint',   now() + interval '9 days', false, false);

-- Helpers to act as a website role.
create function pg_temp.act_as_anon() returns void language sql as $$
  select set_config('role', 'anon', true),
         set_config('request.jwt.claims', '{"role":"anon"}', true);
$$;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims',
                    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- ---------------------------------------------------------------------------
-- Reading Events
-- ---------------------------------------------------------------------------
select pg_temp.act_as_anon();
select is((select count(*)::int from public.events), 2, 'a visitor sees only published Events');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.events), 2, 'a Member sees only published Events');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.events), 3, 'a Moderator also sees drafts');

-- ---------------------------------------------------------------------------
-- Writing Events
-- ---------------------------------------------------------------------------
select pg_temp.act_as_anon();
select throws_ok(
  $$ insert into public.events (title, category, starts_at) values ('x', 'talk', now()) $$,
  '42501', null, 'a visitor cannot create an Event');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ insert into public.events (title, category, starts_at) values ('x', 'talk', now()) $$,
  '42501', null, 'a Member cannot create an Event');

update public.events set title = 'Hacked' where id = '10000000-0000-0000-0000-000000000001';
delete from public.events where id = '10000000-0000-0000-0000-000000000002';

select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select is((select title from public.events where id = '10000000-0000-0000-0000-000000000001'),
          'Published upcoming', 'a Member cannot edit an Event');
select is((select count(*)::int from public.events where id = '10000000-0000-0000-0000-000000000002'),
          1, 'a Member cannot delete an Event');

select lives_ok(
  $$ insert into public.events (title, category, starts_at, is_published)
     values ('New workshop', 'workshop', now() + interval '1 day', true) $$,
  'a Moderator can create an Event');

-- ---------------------------------------------------------------------------
-- Data rules
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.events (title, category, starts_at) values ('x', 'party', now()) $$,
  '23514', null, 'category must be one of the five Event categories');

select throws_ok(
  $$ insert into public.events (title, category, starts_at, ends_at)
     values ('x', 'talk', now(), now() - interval '1 hour') $$,
  '23514', null, 'an Event cannot end before it starts');

select throws_ok(
  $$ insert into public.events (title, category, starts_at, is_featured, is_published)
     values ('x', 'talk', now(), true, false) $$,
  '23514', null, 'a draft cannot be the Featured event');

select throws_ok(
  $$ update public.events set is_featured = true where id = '10000000-0000-0000-0000-000000000002' $$,
  '23505', null, 'only one Event can be featured at a time');

-- ---------------------------------------------------------------------------
-- set_featured_event()
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ select public.set_featured_event('10000000-0000-0000-0000-000000000002') $$,
  'a Moderator can switch the Featured event');
select is((select array_agg(id) from public.events where is_featured),
          array['10000000-0000-0000-0000-000000000002'::uuid],
          'exactly the chosen Event is featured afterwards');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ select public.set_featured_event('10000000-0000-0000-0000-000000000001') $$,
  '42501', null, 'a Member cannot switch the Featured event');

select pg_temp.act_as_anon();
select throws_ok(
  $$ select public.set_featured_event(null) $$,
  '42501', null, 'a visitor cannot call set_featured_event');

-- ---------------------------------------------------------------------------
-- The Moderator flag (finding F1)
-- ---------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-00000000000c');
select throws_ok(
  $$ insert into public."Users" (user_id, first_name, last_name, email, is_admin)
     values ('00000000-0000-0000-0000-00000000000c', 'Jim', 'Doe', 'other@example.com', true) $$,
  '42501', null, 'a Member cannot sign up as a Moderator');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ update public."Users" set is_admin = true where user_id = '00000000-0000-0000-0000-00000000000b' $$,
  '42501', null, 'a Member cannot make themselves a Moderator');

select is((select count(*)::int from public."Users"), 1, 'a Member reads only their own Users row');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$ update public."Users" set is_admin = true where user_id = '00000000-0000-0000-0000-00000000000b' $$,
  'a Moderator can grant the Moderator role');

select * from finish();
rollback;
