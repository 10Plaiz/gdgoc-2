-- Events: the table behind the Events page, and its cover-image bucket.
--
-- Spec: docs/proposals/0001-freedom-wall-and-events.md (user stories 23-31).
-- Terms (Event, Featured event, Upcoming/Past event, Event category) are
-- defined in GLOSSARY.md.
--
-- Upcoming or Past is never stored: it follows from starts_at at read time.

create table public.events (
  id               uuid primary key default gen_random_uuid(),
  title            text not null,
  summary          text not null default '',
  body             text not null default '',
  category         text not null,
  starts_at        timestamptz not null,
  ends_at          timestamptz,
  venue            text,
  -- Path of the cover image inside the event-images bucket, e.g. "2026/sync.webp".
  cover_path       text,
  registration_url text,
  is_featured      boolean not null default false,
  is_published     boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint events_title_length      check (char_length(btrim(title)) between 1 and 120),
  constraint events_summary_length    check (char_length(summary) <= 280),
  constraint events_body_length       check (char_length(body) <= 10000),
  constraint events_venue_length      check (venue is null or char_length(venue) <= 200),
  -- A text check instead of an enum, so categories can be renamed or removed later.
  constraint events_category_valid    check (category in ('workshop', 'hackathon', 'sprint', 'talk', 'social')),
  constraint events_ends_after_starts check (ends_at is null or ends_at >= starts_at),
  constraint events_registration_url_https check (registration_url is null or registration_url ~ '^https://'),
  constraint events_cover_path_relative    check (cover_path is null or cover_path !~ '^(/|https?:)'),
  -- A draft can't headline the public page.
  constraint events_featured_is_published  check (not is_featured or is_published)
);

comment on table public.events is
  'Chapter Events shown on the Events page. Upcoming/Past is derived from starts_at, never stored.';
comment on column public.events.is_featured is
  'At most one Event is the Featured event (enforced by events_one_featured). Use public.set_featured_event() to switch it.';

-- At most one Featured event at a time.
create unique index events_one_featured on public.events (is_featured) where is_featured;

-- The public page lists published Events by date.
create index events_published_by_start on public.events (starts_at desc) where is_published;

create trigger events_set_updated_at
  before update on public.events
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS: anyone reads published Events; only Moderators see drafts or write.
-- ---------------------------------------------------------------------------
alter table public.events enable row level security;

create policy "Anyone reads published Events; Moderators read all"
  on public.events for select
  to anon, authenticated
  using (is_published or (select private.is_moderator()));

create policy "Moderators create Events"
  on public.events for insert
  to authenticated
  with check ((select private.is_moderator()));

create policy "Moderators edit Events"
  on public.events for update
  to authenticated
  using ((select private.is_moderator()))
  with check ((select private.is_moderator()));

create policy "Moderators delete Events"
  on public.events for delete
  to authenticated
  using ((select private.is_moderator()));

grant select on public.events to anon, authenticated;
grant insert, update, delete on public.events to authenticated;

-- ---------------------------------------------------------------------------
-- set_featured_event(): make one Event the Featured event, or pass null to
-- clear it. Unfeatures the old one and features the new one in a single
-- transaction, so the one-featured index never trips halfway.
-- security invoker: RLS still applies, so only a Moderator can change anything.
-- ---------------------------------------------------------------------------
create or replace function public.set_featured_event(p_event_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not private.is_moderator() then
    raise exception 'Only a Moderator can feature an Event' using errcode = '42501';
  end if;

  update public.events set is_featured = false
  where is_featured and id is distinct from p_event_id;

  if p_event_id is not null then
    update public.events set is_featured = true where id = p_event_id;
    if not found then
      raise exception 'Event % not found', p_event_id using errcode = 'P0002';
    end if;
  end if;
end;
$$;

revoke all on function public.set_featured_event(uuid) from public, anon;
grant execute on function public.set_featured_event(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Storage: event-images is public to read; only Moderators upload, replace
-- or delete. 2 MB cap; the browser shrinks covers to WebP before upload.
-- There is no public select policy on storage.objects, so nobody can list
-- the bucket; public URLs still work because the bucket is public.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'event-images',
  'event-images',
  true,
  2097152,
  array['image/webp', 'image/jpeg', 'image/png', 'image/gif']
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create policy "Moderators read event images"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'event-images' and (select private.is_moderator()));

create policy "Moderators upload event images"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'event-images' and (select private.is_moderator()));

create policy "Moderators replace event images"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'event-images' and (select private.is_moderator()))
  with check (bucket_id = 'event-images' and (select private.is_moderator()));

create policy "Moderators delete event images"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'event-images' and (select private.is_moderator()));
