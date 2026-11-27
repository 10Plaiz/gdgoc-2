-- Events: who reads and writes them, their data rules and the Featured event.
-- Run against the local Supabase: `npx supabase test db` (from gdgoc/).
-- Users and rows here are fake fixtures created inside a rolled-back transaction.

begin;
create extension if not exists pgtap with schema extensions;

select plan(34);

-- ---------------------------------------------------------------------------
-- Fixtures (as postgres, so no RLS and no website role).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@example.com',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-00000000000b', 'member@example.com', 'authenticated', 'authenticated');

insert into public."Users" (user_id, first_name, last_name, email, is_admin) values
  ('00000000-0000-0000-0000-00000000000a', 'Jane', 'Doe', 'admin@example.com',  true),
  ('00000000-0000-0000-0000-00000000000b', 'John', 'Doe', 'member@example.com', false);

delete from public.events;  -- ignore seed rows

insert into public.events (id, title, category, starts_at, ends_at, publish_status, is_featured) values
  ('10000000-0000-0000-0000-000000000001', 'Published upcoming', 'workshop',  now() + interval '7 days',   now() + interval '7 days 2 hours',   'published',   true),
  ('10000000-0000-0000-0000-000000000002', 'Published past',     'talk',      now() - interval '7 days',   now() - interval '7 days' + interval '2 hours', 'published', false),
  ('10000000-0000-0000-0000-000000000003', 'Draft',              'hackathon', now() + interval '9 days',   now() + interval '10 days',          'draft',       false),
  ('10000000-0000-0000-0000-000000000004', 'Unpublished',        'social',    now() + interval '9 days',   now() + interval '9 days 3 hours',   'unpublished', false),
  ('10000000-0000-0000-0000-000000000005', 'Archived',           'social',    now() - interval '400 days', now() - interval '400 days' + interval '3 hours', 'archived', false);

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
-- Reading Events (PRD §5.1: everyone views Events; only Admins manage them)
-- ---------------------------------------------------------------------------
select pg_temp.act_as_anon();
select is((select array_agg(title order by title) from public.events),
          array['Published past', 'Published upcoming'],
          'a visitor sees only published Events');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.events), 2,
          'a Member sees only published Events, not drafts, unpublished or archived ones');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.events), 5, 'an Administrator sees every Event');

-- ---------------------------------------------------------------------------
-- Writing Events
-- ---------------------------------------------------------------------------
select pg_temp.act_as_anon();
select throws_ok(
  $$ insert into public.events (title, category, starts_at, ends_at) values ('x', 'talk', now(), now() + interval '1 hour') $$,
  '42501', null, 'a visitor cannot create an Event');

select throws_ok(
  $$ update public.events set title = 'Hacked' $$,
  '42501', null, 'a visitor cannot edit an Event');
select throws_ok(
  $$ delete from public.events $$,
  '42501', null, 'a visitor cannot delete an Event');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ insert into public.events (title, category, starts_at, ends_at) values ('x', 'talk', now(), now() + interval '1 hour') $$,
  '42501', null, 'a Member cannot create an Event');

update public.events set title = 'Hacked' where id = '10000000-0000-0000-0000-000000000001';
update public.events set publish_status = 'published' where id = '10000000-0000-0000-0000-000000000003';
delete from public.events where id = '10000000-0000-0000-0000-000000000002';

select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select is((select title from public.events where id = '10000000-0000-0000-0000-000000000001'),
          'Published upcoming', 'a Member cannot edit an Event');
select is((select publish_status from public.events where id = '10000000-0000-0000-0000-000000000003'),
          'draft', 'a Member cannot publish an Event');
select is((select count(*)::int from public.events where id = '10000000-0000-0000-0000-000000000002'),
          1, 'a Member cannot delete an Event');

select lives_ok(
  $$ insert into public.events (id, title, category, starts_at, ends_at)
     values ('10000000-0000-0000-0000-000000000006', 'New workshop', 'workshop',
             now() + interval '1 day', now() + interval '1 day 3 hours') $$,
  'an Administrator can create an Event');
select is((select publish_status from public.events where id = '10000000-0000-0000-0000-000000000006'),
          'draft', 'a new Event starts as a draft');

select lives_ok(
  $$ update public.events set publish_status = 'published' where id = '10000000-0000-0000-0000-000000000006';
     update public.events set publish_status = 'unpublished' where id = '10000000-0000-0000-0000-000000000006';
     update public.events set publish_status = 'archived' where id = '10000000-0000-0000-0000-000000000006' $$,
  'an Administrator can publish, unpublish and archive an Event');
select is((select publish_status from public.events where id = '10000000-0000-0000-0000-000000000006'),
          'archived', 'the Event ends up archived');

select lives_ok(
  $$ delete from public.events where id = '10000000-0000-0000-0000-000000000006' $$,
  'an Administrator can delete an Event');
select is((select count(*)::int from public.events where id = '10000000-0000-0000-0000-000000000006'),
          0, 'the deleted Event is gone');

-- ---------------------------------------------------------------------------
-- Data rules
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ insert into public.events (title, category, starts_at, ends_at)
     select 'Category ' || c, c, now(), now() + interval '1 hour' from unnest(array['workshop', 'hackathon', 'talk', 'social']) c $$,
  'the four Event categories are accepted');

select throws_ok(
  $$ insert into public.events (title, category, starts_at, ends_at) values ('x', 'sprint', now(), now() + interval '1 hour') $$,
  '23514', null, 'sprint is no longer an Event category');

select throws_ok(
  $$ insert into public.events (title, category, starts_at, ends_at, publish_status) values ('x', 'talk', now(), now() + interval '1 hour', 'hidden') $$,
  '23514', null, 'publish status must be draft, published, unpublished or archived');

select throws_ok(
  $$ insert into public.events (title, category, starts_at, ends_at, registration_status) values ('x', 'talk', now(), now() + interval '1 hour', 'full') $$,
  '23514', null, 'registration status must be not_open, open or closed');

select throws_ok(
  $$ insert into public.events (title, category, starts_at, ends_at, registration_status) values ('x', 'talk', now(), now() + interval '1 hour', 'open') $$,
  '23514', null, 'open registration needs a registration URL');

select throws_ok(
  $$ insert into public.events (title, category, starts_at, ends_at, registration_url)
     values ('x', 'talk', now(), now() + interval '1 hour', 'javascript:alert(1)') $$,
  '23514', null, 'the registration URL must be https');

select throws_ok(
  $$ insert into public.events (title, category, starts_at) values ('x', 'talk', now()) $$,
  '23502', null, 'every Event needs an end time');

select throws_ok(
  $$ insert into public.events (title, category, starts_at, ends_at)
     values ('x', 'talk', now(), now() - interval '1 hour') $$,
  '23514', null, 'an Event cannot end before it starts');

select throws_ok(
  $$ insert into public.events (title, category, starts_at, ends_at, cover_path)
     values ('x', 'talk', now(), now() + interval '1 hour', 'someone-else/cover.webp') $$,
  '23514', null, 'a cover image must live in the Event''s own folder');

-- ---------------------------------------------------------------------------
-- Featured event: at most one, published only
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.events (title, category, starts_at, ends_at, is_featured) values ('x', 'talk', now(), now() + interval '1 hour', true) $$,
  '23514', null, 'a draft cannot be the Featured event');

select throws_ok(
  $$ update public.events set is_featured = true where id = '10000000-0000-0000-0000-000000000002' $$,
  '23505', null, 'only one Event can be featured at a time');

select lives_ok(
  $$ select public.set_featured_event('10000000-0000-0000-0000-000000000002') $$,
  'an Administrator can switch the Featured event');
select is((select array_agg(id) from public.events where is_featured),
          array['10000000-0000-0000-0000-000000000002'::uuid],
          'exactly the chosen Event is featured afterwards');

select lives_ok(
  $$ select public.set_featured_event(null) $$,
  'an Administrator can clear the Featured event');
select is((select count(*)::int from public.events where is_featured), 0,
          'no Event is featured after clearing');
select public.set_featured_event('10000000-0000-0000-0000-000000000002');  -- feature it again for the next test

update public.events set publish_status = 'unpublished' where id = '10000000-0000-0000-0000-000000000002';
select is((select count(*)::int from public.events where is_featured), 0,
          'unpublishing the Featured event removes it from the headline');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ select public.set_featured_event('10000000-0000-0000-0000-000000000001') $$,
  '42501', null, 'a Member cannot switch the Featured event');

select pg_temp.act_as_anon();
select throws_ok(
  $$ select public.set_featured_event(null) $$,
  '42501', null, 'a visitor cannot call set_featured_event');

select * from finish();
rollback;
