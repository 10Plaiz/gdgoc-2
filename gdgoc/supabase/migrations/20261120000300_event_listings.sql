-- Event timing, registration and the PRD status label, computed in one place.
--
-- ADR-0004: Event timing is never stored. Every page that lists Events reads
-- public.event_listings, so Coming Soon, Previous Events, the status badge and
-- the Register button all follow the same rule:
--
--   timing   upcoming   now <  starts_at
--            ongoing    starts_at <= now < ends_at
--            completed  now >= coalesce(ends_at, starts_at)
--
-- An Event with no end time goes straight from upcoming to completed when it
-- starts. Coming Soon is timing in (upcoming, ongoing); Previous Events is
-- timing = completed.
--
-- The rules are pure functions of their arguments (the time is passed in),
-- so they are immutable and easy to test; the view passes now().

create or replace function private.event_timing(
  p_starts_at timestamptz,
  p_ends_at   timestamptz,
  p_at        timestamptz
)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select case
    when p_at < p_starts_at                         then 'upcoming'
    when p_at < coalesce(p_ends_at, p_starts_at)    then 'ongoing'
    else                                                 'completed'
  end;
$$;

-- Registration counts as open only while the Administrator has it open, before
-- registration_closes_at, and before the Event is over.
create or replace function private.event_registration_open(
  p_registration_status    text,
  p_registration_closes_at timestamptz,
  p_starts_at              timestamptz,
  p_ends_at                timestamptz,
  p_at                     timestamptz
)
returns boolean
language sql
immutable
security invoker
set search_path = ''
as $$
  select p_registration_status = 'open'
     and (p_registration_closes_at is null or p_at < p_registration_closes_at)
     and private.event_timing(p_starts_at, p_ends_at, p_at) <> 'completed';
$$;

-- The PRD §1.2 status: upcoming, registration_open, registration_closed or
-- ongoing; completed for Previous Events.
create or replace function private.event_status_label(
  p_registration_status    text,
  p_registration_closes_at timestamptz,
  p_starts_at              timestamptz,
  p_ends_at                timestamptz,
  p_at                     timestamptz
)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select case private.event_timing(p_starts_at, p_ends_at, p_at)
    when 'ongoing'   then 'ongoing'
    when 'completed' then 'completed'
    else case
      when private.event_registration_open(
             p_registration_status, p_registration_closes_at, p_starts_at, p_ends_at, p_at)
        then 'registration_open'
      when p_registration_status = 'not_open' then 'upcoming'
      else 'registration_closed'
    end
  end;
$$;

revoke all on function private.event_timing(timestamptz, timestamptz, timestamptz) from public;
revoke all on function private.event_registration_open(text, timestamptz, timestamptz, timestamptz, timestamptz) from public;
revoke all on function private.event_status_label(text, timestamptz, timestamptz, timestamptz, timestamptz) from public;
-- The view runs as the caller, so the website roles must be able to call them.
grant execute on function private.event_timing(timestamptz, timestamptz, timestamptz)
  to anon, authenticated, service_role;
grant execute on function private.event_registration_open(text, timestamptz, timestamptz, timestamptz, timestamptz)
  to anon, authenticated, service_role;
grant execute on function private.event_status_label(text, timestamptz, timestamptz, timestamptz, timestamptz)
  to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- event_listings: every Event column plus the derived ones.
-- security_invoker, so the events RLS applies: visitors see published Events,
-- Administrators see everything. Writes still go to public.events.
-- ---------------------------------------------------------------------------
create view public.event_listings
with (security_invoker = true)
as
select
  e.*,
  private.event_timing(e.starts_at, e.ends_at, now()) as timing,
  private.event_status_label(
    e.registration_status, e.registration_closes_at, e.starts_at, e.ends_at, now()) as status_label,
  private.event_registration_open(
    e.registration_status, e.registration_closes_at, e.starts_at, e.ends_at, now()) as registration_open,
  -- Same expression as the events_published_by_year index.
  private.event_year(e.starts_at) as event_year
from public.events e;

comment on view public.event_listings is
  'Events with derived timing (upcoming, ongoing, completed), status_label, registration_open and event_year (PHT). Read-only.';

revoke all on public.event_listings from anon, authenticated;
grant select on public.event_listings to anon, authenticated;
