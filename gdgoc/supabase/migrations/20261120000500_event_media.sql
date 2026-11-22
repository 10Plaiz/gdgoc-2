-- event-media: cover images and Gallery photos (proposal 0001, finding F9).
--
-- The bucket is private. Every file lives under "<event id>/", and storage
-- policies let anyone read it only while that Event is published, so a draft's
-- poster never leaks by URL. Only Administrators upload, replace or delete.
-- The website shows images through signed URLs (createSignedUrl), which the
-- Storage API only issues when the select policy below allows it.
--
-- Limits: 2 MB, WebP/JPEG/PNG only. SVG is refused because it can carry
-- scripts. The browser shrinks images to WebP (about 1280 px) before upload.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'event-media',
  'event-media',
  false,
  2097152,
  array['image/webp', 'image/jpeg', 'image/png']
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- One select policy for both roles, so Postgres evaluates a single policy per row.
create policy "Anyone reads media of published Events; Administrators read all"
  on storage.objects for select
  to anon, authenticated
  using (
    bucket_id = 'event-media'
    and (
      private.event_is_published(private.event_media_owner(name))
      or (select private.is_admin())
    )
  );

-- Uploads must go into the folder of an Event that exists (events RLS lets
-- Administrators see every Event).
create policy "Administrators upload event media"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'event-media'
    and (select private.is_admin())
    and private.event_media_owner(name) in (select e.id from public.events e)
  );

create policy "Administrators replace event media"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'event-media' and (select private.is_admin()))
  with check (
    bucket_id = 'event-media'
    and (select private.is_admin())
    and private.event_media_owner(name) in (select e.id from public.events e)
  );

create policy "Administrators delete event media"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'event-media' and (select private.is_admin()));
