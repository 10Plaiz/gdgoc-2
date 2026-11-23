-- The event-media bucket: images stay private until their Event is published,
-- and only Administrators upload, replace or delete them.
-- Rows in storage.objects stand in for uploads; the Storage API applies the
-- same RLS policies when the website uploads or downloads.

begin;
create extension if not exists pgtap with schema extensions;

select plan(27);

-- Supabase blocks direct SQL deletes on storage tables; allow them in this
-- rolled-back transaction so the delete policies themselves are tested.
select set_config('storage.allow_delete_query', 'true', true);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@example.com',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-00000000000b', 'member@example.com', 'authenticated', 'authenticated');
insert into public."Users" (user_id, first_name, last_name, email, is_admin) values
  ('00000000-0000-0000-0000-00000000000a', 'Jane', 'Doe', 'admin@example.com',  true),
  ('00000000-0000-0000-0000-00000000000b', 'John', 'Doe', 'member@example.com', false);

delete from public.events;  -- ignore seed rows

insert into public.events (id, title, category, starts_at, ends_at, publish_status) values
  ('40000000-0000-0000-0000-000000000001', 'Published', 'talk',     now() + interval '1 day',  now() + interval '1 day 2 hours',  'published'),
  ('40000000-0000-0000-0000-000000000002', 'Draft',     'workshop', now() + interval '9 days', now() + interval '9 days 3 hours', 'draft');

insert into storage.objects (bucket_id, name) values
  ('event-media', '40000000-0000-0000-0000-000000000001/cover.webp'),
  ('event-media', '40000000-0000-0000-0000-000000000002/cover.webp'),
  ('event-media', 'loose-file.webp');

create function pg_temp.act_as_anon() returns void language sql as $$
  select set_config('role', 'anon', true),
         set_config('request.jwt.claims', '{"role":"anon"}', true);
$$;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims',
                    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

create function pg_temp.visible_media() returns text[] language sql as $$
  select coalesce(array_agg(name order by name), '{}') from storage.objects where bucket_id = 'event-media';
$$;

-- ---------------------------------------------------------------------------
-- The bucket
-- ---------------------------------------------------------------------------
select is((select public from storage.buckets where id = 'event-media'), false,
          'event-media is a private bucket, so files have no public URL');
select is((select file_size_limit from storage.buckets where id = 'event-media'), 2097152::bigint,
          'event-media accepts files up to 2 MB');
select is((select allowed_mime_types from storage.buckets where id = 'event-media'),
          array['image/webp', 'image/jpeg', 'image/png'],
          'event-media accepts WebP, JPEG and PNG images only (no SVG)');

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------
select pg_temp.act_as_anon();
select is(pg_temp.visible_media(), array['40000000-0000-0000-0000-000000000001/cover.webp'],
          'a visitor can read images of published Events only');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select is(pg_temp.visible_media(), array['40000000-0000-0000-0000-000000000001/cover.webp'],
          'a Member cannot read images of draft Events');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select is(cardinality(pg_temp.visible_media()), 3, 'an Administrator can read every event image');

update public.events set publish_status = 'unpublished' where id = '40000000-0000-0000-0000-000000000001';
select pg_temp.act_as_anon();
select is(pg_temp.visible_media(), '{}'::text[],
          'unpublishing an Event makes its images private again');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
update public.events set publish_status = 'archived' where id = '40000000-0000-0000-0000-000000000001';
select pg_temp.act_as_anon();
select is(pg_temp.visible_media(), '{}'::text[], 'images of archived Events are private');

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('event-media', '40000000-0000-0000-0000-000000000001/x.webp') $$,
  '42501', null, 'a visitor cannot upload an event image');

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('event-media', '40000000-0000-0000-0000-000000000001/x.webp') $$,
  '42501', null, 'a Member cannot upload an event image');

-- A Member can't see draft images, and these are archived now, so give them a
-- published Event to try to change.
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
update public.events set publish_status = 'published' where id = '40000000-0000-0000-0000-000000000001';

select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
update storage.objects set name = '40000000-0000-0000-0000-000000000001/renamed.webp'
  where name = '40000000-0000-0000-0000-000000000001/cover.webp';
delete from storage.objects where bucket_id = 'event-media';

select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select is(pg_temp.visible_media(),
          array['40000000-0000-0000-0000-000000000001/cover.webp',
                '40000000-0000-0000-0000-000000000002/cover.webp',
                'loose-file.webp'],
          'a Member cannot rename or delete event images');

select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('event-media', '40000000-0000-0000-0000-000000000002/gallery-1.webp') $$,
  'an Administrator can upload an image into an Event''s folder');

select throws_ok(
  $$ insert into storage.objects (bucket_id, name) values ('event-media', 'not-an-event/x.webp') $$,
  '42501', null, 'an image must be uploaded into an existing Event''s folder');

select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('event-media', '40000000-0000-0000-0000-0000000000ff/x.webp') $$,
  '42501', null, 'an image cannot be uploaded for an Event that does not exist');

select lives_ok(
  $$ delete from storage.objects where name = '40000000-0000-0000-0000-000000000002/gallery-1.webp' $$,
  'an Administrator can delete an event image');
select is((select count(*)::int from storage.objects
           where name = '40000000-0000-0000-0000-000000000002/gallery-1.webp'), 0,
          'the deleted image is gone');

-- ---------------------------------------------------------------------------
-- Storage budget: a capped folder per Event, and no files left behind
-- ---------------------------------------------------------------------------
-- The draft Event's folder already holds its cover. The Storage API writes one
-- file per request, so each upload is its own statement: the room check can't
-- see rows added earlier in the same statement.
select lives_ok(
  $$ do $do$ begin
       for n in 1..20 loop
         insert into storage.objects (bucket_id, name)
         values ('event-media', '40000000-0000-0000-0000-000000000002/photo-' || n || '.webp');
       end loop;
     end $do$ $$,
  'an Event folder holds a cover and 20 Gallery photos, uploaded one by one');

select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('event-media', '40000000-0000-0000-0000-000000000002/photo-21.webp') $$,
  '42501', null, 'an Event folder cannot hold more than 21 files');

-- Replacing a file (an upload with upsert) must pass the insert policy too.
-- "on conflict do nothing" runs that check without naming a unique index,
-- because storage.objects' indexes differ between Storage versions.
select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('event-media', '40000000-0000-0000-0000-000000000002/photo-1.webp')
     on conflict do nothing $$,
  'an Administrator can replace a file in a full folder');

select lives_ok(
  $$ update storage.objects set metadata = '{"replaced": true}'
     where name = '40000000-0000-0000-0000-000000000002/photo-1.webp' $$,
  'an Administrator can overwrite a file in a full folder');
select is((select metadata ->> 'replaced' from storage.objects
           where name = '40000000-0000-0000-0000-000000000002/photo-1.webp'), 'true',
          'the overwritten file is updated');

select lives_ok(
  $$ update storage.objects set name = '40000000-0000-0000-0000-000000000002/photo-1b.webp'
     where name = '40000000-0000-0000-0000-000000000002/photo-1.webp' $$,
  'an Administrator can rename a file within a full folder');
select is((select count(*)::int from storage.objects
           where name = '40000000-0000-0000-0000-000000000002/photo-1b.webp'), 1,
          'the renamed file is there');

select throws_ok(
  $$ update storage.objects set name = '40000000-0000-0000-0000-000000000002/moved.webp'
     where name = '40000000-0000-0000-0000-000000000001/cover.webp' $$,
  '42501', null, 'a file cannot be moved into a full folder');

select throws_ok(
  $$ delete from public.events where id = '40000000-0000-0000-0000-000000000002' $$,
  '23503', null, 'an Event cannot be deleted while its folder still has files');

select lives_ok(
  $$ delete from storage.objects where name like '40000000-0000-0000-0000-000000000002/%' $$,
  'an Administrator can empty an Event''s folder');

select lives_ok(
  $$ delete from public.events where id = '40000000-0000-0000-0000-000000000002' $$,
  'an Event with an empty folder can be deleted');

select * from finish();
rollback;
