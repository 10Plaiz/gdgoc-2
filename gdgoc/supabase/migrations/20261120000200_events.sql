-- Events: the table behind the Events page.
--
-- Spec: PRD V.2 §1 and §5.1 (resource/documentation/PRD/NEW/), designed in
-- docs/proposals/0001-freedom-wall-and-events.md and ADR-0004.
-- Terms (Event, Publish status, Event timing, Registration status, Featured
-- event, Timeline, Gallery) are defined in GLOSSARY.md.
--
-- Event timing (upcoming, ongoing, completed) is never stored. It is computed
-- in one place, private.event_timing(), and exposed by the event_listings view
-- (see the event_listings migration).

-- ---------------------------------------------------------------------------
-- Shared rules used by constraints, indexes, views and storage policies, so
-- each one is written once.
-- ---------------------------------------------------------------------------

-- private.event_media_owner(): the Event a file in the event-media bucket
-- belongs to. Files live at "<event id>/<file>"; any other path (no uuid
-- folder, no file name, or a ".." segment) has no owner and returns null, so
-- a bad path never raises a cast error.
create or replace function private.event_media_owner(p_path text)
returns uuid
language sql
immutable
security invoker
set search_path = ''
as $$
  select case
    when p_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[^/]'
     and p_path !~ '(^|/)\.\.(/|$)'
      then split_part(p_path, '/', 1)::uuid
  end;
$$;

-- private.event_year(): the calendar year of a time in Philippine time, shown
-- as event_year in event_listings (PRD §1.3, §5.3).
create or replace function private.event_year(p_at timestamptz)
returns integer
language sql
immutable
security invoker
set search_path = ''
as $$
  select extract(year from (p_at at time zone 'Asia/Manila'))::integer;
$$;

revoke all on function private.event_media_owner(text) from public;
revoke all on function private.event_year(timestamptz) from public;
-- Storage policies and the event_listings view run as the caller.
grant execute on function private.event_media_owner(text) to anon, authenticated, service_role;
grant execute on function private.event_year(timestamptz) to anon, authenticated, service_role;

create table public.events (
  id                     uuid primary key default gen_random_uuid(),
  title                  text not null,
  -- PRD "Description": the short overview shown on cards.
  summary                text not null default '',
  -- Longer description, or the recap once the Event is over.
  body                   text not null default '',
  category               text not null,
  starts_at              timestamptz not null,
  ends_at                timestamptz,
  venue                  text,
  -- Path inside the event-media bucket, always "<event id>/<file>".
  cover_path             text,
  registration_url       text,
  registration_status    text not null default 'not_open',
  -- Optional: registration counts as closed from this moment on (ADR-0004).
  registration_closes_at timestamptz,
  publish_status         text not null default 'draft',
  is_featured            boolean not null default false,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint events_title_length      check (char_length(btrim(title)) between 1 and 120),
  constraint events_summary_length    check (char_length(summary) <= 280),
  constraint events_body_length       check (char_length(body) <= 10000),
  constraint events_venue_length      check (venue is null or char_length(venue) <= 200),
  -- Text checks instead of enums, so the lists can change later (CODING_STANDARDS.md).
  constraint events_category_valid    check (category in ('workshop', 'hackathon', 'talk', 'social')),
  constraint events_publish_status_valid
    check (publish_status in ('draft', 'published', 'unpublished', 'archived')),
  constraint events_registration_status_valid
    check (registration_status in ('not_open', 'open', 'closed')),
  constraint events_ends_after_starts check (ends_at is null or ends_at >= starts_at),
  constraint events_registration_url_https
    check (registration_url is null or registration_url ~ '^https://[^\s]+$'),
  constraint events_registration_url_length
    check (registration_url is null or char_length(registration_url) <= 2048),
  -- Visitors can't register without somewhere to go.
  constraint events_open_registration_has_url
    check (registration_status <> 'open' or registration_url is not null),
  -- Ties the file to its Event, so storage can tell whether it is public.
  constraint events_cover_path_in_event_folder
    check (cover_path is null or private.event_media_owner(cover_path) is not distinct from id),
  -- A draft, unpublished or archived Event can't headline the public page.
  constraint events_featured_is_published
    check (not is_featured or private.is_public(publish_status))
);

comment on table public.events is
  'Chapter Events shown on the Events page. Event timing is derived (see event_listings), never stored.';
comment on column public.events.publish_status is
  'draft, published, unpublished or archived. Only published Events are public.';
comment on column public.events.registration_status is
  'not_open, open or closed, set by an Administrator. registration_closes_at closes it automatically.';
comment on column public.events.is_featured is
  'At most one published Event is the Featured event. Use public.set_featured_event() to switch it.';

-- At most one Featured event at a time.
create unique index events_one_featured on public.events (is_featured) where is_featured;

create trigger events_set_updated_at
  before update on public.events
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------
-- Taking an Event off the public page also takes it out of the headline, so
-- an Administrator can unpublish or archive the Featured event in one step.
-- Inserting a featured draft still fails on events_featured_is_published.
-- ---------------------------------------------------------------------------
create or replace function private.unfeature_unpublished_event()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not private.is_public(new.publish_status) then
    new.is_featured := false;
  end if;
  return new;
end;
$$;

revoke all on function private.unfeature_unpublished_event() from public;

create trigger events_unfeature_unpublished
  before update of publish_status on public.events
  for each row execute function private.unfeature_unpublished_event();

-- ---------------------------------------------------------------------------
-- Indexes for the public page (PRD §1.2–1.3). Partial, because the public only
-- lists published Events; queries must add publish_status = 'published' for
-- the planner to use them (see gdgoc/supabase/README.md).
--
-- Under RLS, Postgres applies a filter before the policy only when its
-- operator is leakproof. Comparisons on timestamptz and text equality are;
-- ilike and function calls such as private.event_year() are not, so an index
-- on them would never serve the website's queries. Hence:
--   * by date:     starts_at, also serving the year filter as a PHT range
--                  (starts_at >= '2026-01-01T00:00+08:00' and < '2027-01-01T00:00+08:00');
--   * by category: category, then date;
--   * title search (ilike '%term%') scans the published rows. A chapter has a
--     few dozen Events a year, so that stays fast; revisit with a search RPC
--     if it ever grows to thousands.
-- ---------------------------------------------------------------------------
create index events_published_by_start
  on public.events (starts_at desc) where publish_status = 'published';

create index events_published_by_category
  on public.events (category, starts_at desc) where publish_status = 'published';

-- ---------------------------------------------------------------------------
-- RLS: anyone reads published Events; only Administrators see the rest or write.
-- Supabase grants every privilege on new public tables to anon and
-- authenticated by default, so revoke those first and grant only what the
-- policies allow.
-- ---------------------------------------------------------------------------
alter table public.events enable row level security;

revoke all on public.events from anon, authenticated;
grant select on public.events to anon, authenticated;
grant insert, update, delete on public.events to authenticated;

create policy "Anyone reads published Events; Administrators read all"
  on public.events for select
  to anon, authenticated
  using (private.is_public(publish_status) or (select private.is_admin()));

create policy "Administrators create Events"
  on public.events for insert
  to authenticated
  with check ((select private.is_admin()));

create policy "Administrators edit Events"
  on public.events for update
  to authenticated
  using ((select private.is_admin()))
  with check ((select private.is_admin()));

create policy "Administrators delete Events"
  on public.events for delete
  to authenticated
  using ((select private.is_admin()));

-- ---------------------------------------------------------------------------
-- set_featured_event(): make one Event the Featured event, or pass null to
-- clear it. Unfeatures the old one and features the new one in a single
-- transaction, so the one-featured index never trips halfway.
-- security invoker: RLS still applies, so only an Administrator can change anything.
-- ---------------------------------------------------------------------------
create or replace function public.set_featured_event(p_event_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'Only an Administrator can feature an Event' using errcode = '42501';
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

