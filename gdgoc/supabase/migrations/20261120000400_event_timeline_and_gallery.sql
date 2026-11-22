-- Event Timeline items and Gallery photos (PRD §1.2–1.4, proposal 0001).
-- Both are public exactly when their Event is published; only Administrators write.

-- ---------------------------------------------------------------------------
-- private.event_is_published(): the one rule for "is this Event public?",
-- shared by the child-table policies and the event-media storage policies.
-- security invoker: the caller's events RLS applies, and the publish_status
-- check keeps the answer the same for Administrators, who can see drafts.
-- ---------------------------------------------------------------------------
create or replace function private.event_is_published(p_event_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (
    select 1 from public.events e
    where e.id = p_event_id and private.is_public(e.publish_status)
  );
$$;

revoke all on function private.event_is_published(uuid) from public;
grant execute on function private.event_is_published(uuid) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- event_timeline_items: the schedule of an Event, shown in order.
-- ---------------------------------------------------------------------------
create table public.event_timeline_items (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events (id) on delete cascade,
  -- Display order; ties fall back to starts_at.
  position    integer not null default 0,
  starts_at   timestamptz not null,
  ends_at     timestamptz,
  title       text not null,
  description text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint event_timeline_items_title_length       check (char_length(btrim(title)) between 1 and 120),
  constraint event_timeline_items_description_length check (char_length(description) <= 1000),
  constraint event_timeline_items_position_valid     check (position >= 0),
  constraint event_timeline_items_ends_after_starts  check (ends_at is null or ends_at >= starts_at)
);

comment on table public.event_timeline_items is
  'The Timeline of an Event. Public when the Event is published.';

create index event_timeline_items_by_event on public.event_timeline_items (event_id, position, starts_at);

create trigger event_timeline_items_set_updated_at
  before update on public.event_timeline_items
  for each row execute function private.set_updated_at();

alter table public.event_timeline_items enable row level security;

revoke all on public.event_timeline_items from anon, authenticated;
grant select on public.event_timeline_items to anon, authenticated;
grant insert, update, delete on public.event_timeline_items to authenticated;

create policy "Anyone reads Timelines of published Events; Administrators read all"
  on public.event_timeline_items for select
  to anon, authenticated
  using (private.event_is_published(event_id) or (select private.is_admin()));

create policy "Administrators add Timeline items"
  on public.event_timeline_items for insert
  to authenticated
  with check ((select private.is_admin()));

create policy "Administrators edit Timeline items"
  on public.event_timeline_items for update
  to authenticated
  using ((select private.is_admin()))
  with check ((select private.is_admin()));

create policy "Administrators delete Timeline items"
  on public.event_timeline_items for delete
  to authenticated
  using ((select private.is_admin()));

-- ---------------------------------------------------------------------------
-- event_photos: the Gallery of an Event, at most 20 photos each.
-- The files live in the event-media bucket under "<event id>/".
-- ---------------------------------------------------------------------------
create table public.event_photos (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references public.events (id) on delete cascade,
  path       text not null,
  caption    text not null default '',
  alt_text   text not null default '',
  position   integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint event_photos_path_unique         unique (path),
  constraint event_photos_path_in_event_folder check (private.event_media_owner(path) is not distinct from event_id),
  constraint event_photos_caption_length      check (char_length(caption) <= 280),
  constraint event_photos_alt_text_length     check (char_length(alt_text) <= 200),
  constraint event_photos_position_valid      check (position >= 0)
);

comment on table public.event_photos is
  'The Gallery of an Event (max 20 photos, enforced by a trigger). Public when the Event is published.';

create index event_photos_by_event on public.event_photos (event_id, position);

create trigger event_photos_set_updated_at
  before update on public.event_photos
  for each row execute function private.set_updated_at();

-- The cap keeps one Event from using up the Free Plan's 1 GB of storage.
-- Locking the Event row makes concurrent uploads queue, so two inserts can't
-- both see 19 photos and end at 21.
create or replace function private.cap_event_photos()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform 1 from public.events where id = new.event_id for update;

  if (select count(*) from public.event_photos p
      where p.event_id = new.event_id and p.id <> new.id) >= 20 then
    raise exception 'An Event can have at most 20 Gallery photos'
      using errcode = '23514', constraint = 'event_photos_max_per_event';
  end if;

  return new;
end;
$$;

revoke all on function private.cap_event_photos() from public;

create trigger event_photos_cap
  before insert or update of event_id on public.event_photos
  for each row execute function private.cap_event_photos();

alter table public.event_photos enable row level security;

revoke all on public.event_photos from anon, authenticated;
grant select on public.event_photos to anon, authenticated;
grant insert, update, delete on public.event_photos to authenticated;

create policy "Anyone reads Galleries of published Events; Administrators read all"
  on public.event_photos for select
  to anon, authenticated
  using (private.event_is_published(event_id) or (select private.is_admin()));

create policy "Administrators add Gallery photos"
  on public.event_photos for insert
  to authenticated
  with check ((select private.is_admin()));

create policy "Administrators edit Gallery photos"
  on public.event_photos for update
  to authenticated
  using ((select private.is_admin()))
  with check ((select private.is_admin()));

create policy "Administrators delete Gallery photos"
  on public.event_photos for delete
  to authenticated
  using ((select private.is_admin()));
