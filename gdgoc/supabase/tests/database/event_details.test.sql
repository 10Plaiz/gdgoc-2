-- Event Timeline items and Gallery photos: they are public exactly when their
-- Event is, only Administrators write them, and the Gallery is capped.

begin;
create extension if not exists pgtap with schema extensions;

select plan(27);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@example.com',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-00000000000b', 'member@example.com', 'authenticated', 'authenticated');
insert into public."Users" (user_id, first_name, last_name, email, is_admin) values
  ('00000000-0000-0000-0000-00000000000a', 'Jane', 'Doe', 'admin@example.com',  true),
  ('00000000-0000-0000-0000-00000000000b', 'John', 'Doe', 'member@example.com', false);

delete from public.events;  -- ignore seed rows

insert into public.events (id, title, category, starts_at, publish_status) values
  ('30000000-0000-0000-0000-000000000001', 'Published', 'hackathon', now() - interval '30 days', 'published'),
  ('30000000-0000-0000-0000-000000000002', 'Draft',     'workshop',  now() + interval '30 days', 'draft');

insert into public.event_timeline_items (event_id, position, starts_at, title) values
  ('30000000-0000-0000-0000-000000000001', 0, now() - interval '30 days', 'Opening'),
  ('30000000-0000-0000-0000-000000000001', 1, now() - interval '30 days' + interval '1 hour', 'Hacking starts'),
  ('30000000-0000-0000-0000-000000000002', 0, now() + interval '30 days', 'Draft item');

insert into public.event_photos (event_id, path, alt_text, position, updated_at) values
  ('30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001/1.webp', 'Teams at work', 0, now() - interval '1 day'),
  ('30000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000002/1.webp', 'Draft photo', 0, now() - interval '1 day');

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
-- Reading
-- ---------------------------------------------------------------------------
select pg_temp.act_as_anon();
select is((select array_agg(title order by position) from public.event_timeline_items),
          array['Opening', 'Hacking starts'],
          'a visitor sees the Timeline of published Events only');
select is((select count(*)::int from public.event_photos), 1,
          'a visitor sees the Gallery of published Events only');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.event_timeline_items), 2,
          'a Member sees the Timeline of published Events only');
select is((select count(*)::int from public.event_photos), 1,
          'a Member sees the Gallery of published Events only');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.event_timeline_items), 3,
          'an Administrator sees every Timeline item');
select is((select count(*)::int from public.event_photos), 2,
          'an Administrator sees every Gallery photo');

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------
select pg_temp.act_as_anon();
select throws_ok(
  $$ insert into public.event_timeline_items (event_id, position, starts_at, title)
     values ('30000000-0000-0000-0000-000000000001', 9, now(), 'x') $$,
  '42501', null, 'a visitor cannot add a Timeline item');

select throws_ok(
  $$ update public.event_timeline_items set title = 'Hacked' $$,
  '42501', null, 'a visitor cannot edit Timeline items');
select throws_ok(
  $$ delete from public.event_photos $$,
  '42501', null, 'a visitor cannot delete Gallery photos');
select throws_ok(
  $$ update public.event_photos set caption = 'Hacked' $$,
  '42501', null, 'a visitor cannot edit Gallery photos');
select throws_ok(
  $$ delete from public.event_timeline_items $$,
  '42501', null, 'a visitor cannot delete Timeline items');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ insert into public.event_timeline_items (event_id, position, starts_at, title)
     values ('30000000-0000-0000-0000-000000000001', 9, now(), 'x') $$,
  '42501', null, 'a Member cannot add a Timeline item');
select throws_ok(
  $$ insert into public.event_photos (event_id, path, alt_text, position)
     values ('30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001/x.webp', 'x', 9) $$,
  '42501', null, 'a Member cannot add a Gallery photo');

delete from public.event_photos;
update public.event_photos set caption = 'Hacked';
update public.event_timeline_items set title = 'Hacked';
delete from public.event_timeline_items;

select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.event_photos), 2, 'a Member cannot delete Gallery photos');
select is((select count(*)::int from public.event_timeline_items where title = 'Hacked'), 0,
          'a Member cannot edit Timeline items');
select is((select count(*)::int from public.event_photos where caption = 'Hacked'), 0,
          'a Member cannot edit Gallery photos');
select is((select count(*)::int from public.event_timeline_items), 3,
          'a Member cannot delete Timeline items');

select lives_ok(
  $$ insert into public.event_timeline_items (event_id, position, starts_at, ends_at, title, description)
     values ('30000000-0000-0000-0000-000000000001', 2, now() - interval '29 days', now() - interval '28 days',
             'Judging', 'Teams present to the judges') $$,
  'an Administrator can add a Timeline item');

update public.event_timeline_items set title = 'Opening ceremony' where title = 'Opening';
update public.event_photos set caption = 'Day one' where position = 0;
select is((select count(*)::int from public.event_photos where caption = 'Day one' and updated_at = now()), 2,
          'editing a Gallery photo records when it changed');
select is((select count(*)::int from public.event_timeline_items where title = 'Opening ceremony')
          + (select count(*)::int from public.event_photos where caption = 'Day one'), 3,
          'an Administrator can edit Timeline items and Gallery photos');

delete from public.event_timeline_items where title = 'Draft item';
delete from public.event_photos where path = '30000000-0000-0000-0000-000000000002/1.webp';
select is((select count(*)::int from public.event_timeline_items where title = 'Draft item')
          + (select count(*)::int from public.event_photos where event_id = '30000000-0000-0000-0000-000000000002'), 0,
          'an Administrator can delete Timeline items and Gallery photos');

-- ---------------------------------------------------------------------------
-- Data rules
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.event_timeline_items (event_id, position, starts_at, ends_at, title)
     values ('30000000-0000-0000-0000-000000000001', 3, now(), now() - interval '1 minute', 'x') $$,
  '23514', null, 'a Timeline item cannot end before it starts');

select throws_ok(
  $$ insert into public.event_photos (event_id, path, alt_text, position)
     values ('30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002/x.webp', 'x', 1) $$,
  '23514', null, 'a Gallery photo must live in its Event''s own folder');

select throws_ok(
  $$ insert into public.event_photos (event_id, path, alt_text, position)
     values ('30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001/../x.webp', 'x', 1) $$,
  '23514', null, 'a Gallery photo path cannot climb out of its folder');

select lives_ok(
  $$ insert into public.event_photos (event_id, path, alt_text, position)
     select '30000000-0000-0000-0000-000000000001',
            '30000000-0000-0000-0000-000000000001/' || n || '.webp', 'Photo ' || n, n
     from generate_series(2, 20) n $$,
  'an Event can have up to 20 Gallery photos');

select throws_ok(
  $$ insert into public.event_photos (event_id, path, alt_text, position)
     values ('30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001/21.webp', 'x', 21) $$,
  '23514', null, 'an Event cannot have more than 20 Gallery photos');

delete from public.events where id = '30000000-0000-0000-0000-000000000001';
select is((select count(*)::int from public.event_timeline_items
           where event_id = '30000000-0000-0000-0000-000000000001')
          + (select count(*)::int from public.event_photos
             where event_id = '30000000-0000-0000-0000-000000000001'),
          0, 'deleting an Event deletes its Timeline and Gallery rows');

select * from finish();
rollback;
