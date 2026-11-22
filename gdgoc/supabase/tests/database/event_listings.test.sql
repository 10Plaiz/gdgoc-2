-- Event timing, registration and the PRD status label, read through the
-- event_listings view (ADR-0004). now() is fixed for the whole transaction,
-- so fixtures placed exactly at now() test the boundaries.

begin;
create extension if not exists pgtap with schema extensions;

select plan(20);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@example.com', 'authenticated', 'authenticated');
insert into public."Users" (user_id, first_name, last_name, email, is_admin) values
  ('00000000-0000-0000-0000-00000000000a', 'Jane', 'Doe', 'admin@example.com', true);

delete from public.events;  -- ignore seed rows

insert into public.events
  (id, title, category, starts_at, ends_at, registration_status, registration_url, registration_closes_at, publish_status)
values
  -- timing
  ('20000000-0000-0000-0000-000000000001', 'Starts in a second', 'talk', now() + interval '1 second', now() + interval '1 hour', 'not_open', null, null, 'published'),
  ('20000000-0000-0000-0000-000000000002', 'Starts right now',   'talk', now(), now() + interval '1 hour', 'not_open', null, null, 'published'),
  ('20000000-0000-0000-0000-000000000003', 'Half way through',   'hackathon', now() - interval '1 day', now() + interval '1 day', 'open', 'https://example.com/r', null, 'published'),
  ('20000000-0000-0000-0000-000000000004', 'Ends right now',     'talk', now() - interval '1 hour', now(), 'not_open', null, null, 'published'),
  ('20000000-0000-0000-0000-000000000005', 'No end, started',    'social', now() - interval '1 second', null, 'not_open', null, null, 'published'),
  ('20000000-0000-0000-0000-000000000006', 'No end, upcoming',   'social', now() + interval '1 second', null, 'not_open', null, null, 'published'),
  -- registration
  ('20000000-0000-0000-0000-000000000007', 'Registration open',   'workshop', now() + interval '7 days', null, 'open',   'https://example.com/r', null, 'published'),
  ('20000000-0000-0000-0000-000000000008', 'Registration closed', 'workshop', now() + interval '7 days', null, 'closed', 'https://example.com/r', null, 'published'),
  ('20000000-0000-0000-0000-000000000009', 'Closes right now',    'workshop', now() + interval '7 days', null, 'open',   'https://example.com/r', now(), 'published'),
  ('20000000-0000-0000-0000-000000000010', 'Closes in a minute',  'workshop', now() + interval '7 days', null, 'open',   'https://example.com/r', now() + interval '1 minute', 'published'),
  ('20000000-0000-0000-0000-000000000011', 'Was open, now over',  'workshop', now() - interval '7 days', now() - interval '6 days', 'open', 'https://example.com/r', null, 'published'),
  -- year in Philippine time: 2025-12-31 17:00 UTC is 2026-01-01 01:00 PHT
  ('20000000-0000-0000-0000-000000000012', 'New Year in Manila', 'social', '2025-12-31 17:00:00+00', null, 'not_open', null, null, 'published'),
  -- not public
  ('20000000-0000-0000-0000-000000000013', 'Draft', 'talk', now() + interval '1 day', null, 'not_open', null, null, 'draft');

create function pg_temp.listing(p_id text) returns public.event_listings language sql as $$
  select * from public.event_listings where id = p_id::uuid;
$$;

-- ---------------------------------------------------------------------------
-- Event timing: upcoming until it starts, ongoing until it ends, then completed
-- ---------------------------------------------------------------------------
select is((pg_temp.listing('20000000-0000-0000-0000-000000000001')).timing, 'upcoming',
          'an Event that has not started is upcoming');
select is((pg_temp.listing('20000000-0000-0000-0000-000000000002')).timing, 'ongoing',
          'an Event is ongoing from the moment it starts');
select is((pg_temp.listing('20000000-0000-0000-0000-000000000003')).timing, 'ongoing',
          'an Event half way through is ongoing, not a Previous Event');
select is((pg_temp.listing('20000000-0000-0000-0000-000000000004')).timing, 'completed',
          'an Event is completed from the moment it ends');
select is((pg_temp.listing('20000000-0000-0000-0000-000000000005')).timing, 'completed',
          'an Event with no end time is completed once it starts');
select is((pg_temp.listing('20000000-0000-0000-0000-000000000006')).timing, 'upcoming',
          'an Event with no end time is upcoming before it starts');

-- ---------------------------------------------------------------------------
-- Status label (PRD §1.2) and whether Register is enabled
-- ---------------------------------------------------------------------------
select is((pg_temp.listing('20000000-0000-0000-0000-000000000001')).status_label, 'upcoming',
          'an upcoming Event with registration not open yet is labelled Upcoming');
select is((pg_temp.listing('20000000-0000-0000-0000-000000000007')).status_label, 'registration_open',
          'an upcoming Event with open registration is labelled Registration Open');
select is((pg_temp.listing('20000000-0000-0000-0000-000000000008')).status_label, 'registration_closed',
          'an upcoming Event with closed registration is labelled Registration Closed');
select is((pg_temp.listing('20000000-0000-0000-0000-000000000003')).status_label, 'ongoing',
          'an ongoing Event is labelled Ongoing whatever its registration');
select is((pg_temp.listing('20000000-0000-0000-0000-000000000004')).status_label, 'completed',
          'a completed Event is labelled Completed');

select is((pg_temp.listing('20000000-0000-0000-0000-000000000009')).status_label, 'registration_closed',
          'registration closes automatically at registration_closes_at');
select is((pg_temp.listing('20000000-0000-0000-0000-000000000009')).registration_open, false,
          'Register is disabled once registration closes automatically');
select is((pg_temp.listing('20000000-0000-0000-0000-000000000010')).registration_open, true,
          'Register is enabled while registration is open and before it closes');
select is((pg_temp.listing('20000000-0000-0000-0000-000000000011')).registration_open, false,
          'Register is disabled once an Event is completed');

-- ---------------------------------------------------------------------------
-- Year filter in Philippine time, and the public view follows Event RLS
-- ---------------------------------------------------------------------------
select is((pg_temp.listing('20000000-0000-0000-0000-000000000012')).event_year, 2026,
          'the year filter uses Philippine time');

select set_config('role', 'anon', true), set_config('request.jwt.claims', '{"role":"anon"}', true);

select is((select count(*)::int from public.event_listings), 12,
          'a visitor sees only published Events in event_listings');
select is((select count(*)::int from public.event_listings where timing in ('upcoming', 'ongoing')), 8,
          'Coming Soon lists upcoming and ongoing Events');
select is((select count(*)::int from public.event_listings where timing = 'completed'), 4,
          'Previous Events lists completed Events');

select set_config('role', 'authenticated', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
select is((select count(*)::int from public.event_listings), 13,
          'an Administrator sees drafts in event_listings too');

select * from finish();
rollback;
