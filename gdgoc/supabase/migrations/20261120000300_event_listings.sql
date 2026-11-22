-- Event timing, registration and the PRD status label, computed in one place.
--
-- ADR-0004: Event timing is never stored. Every page that lists Events reads
-- public.event_listings, so Coming Soon, Previous Events, the status badge and
-- the Register button all follow the same rule:
--
--   timing   upcoming   now <  starts_at
--            ongoing    starts_at <= now < ends_at
--            completed  now >= ends_at
--
-- ends_at is required, so every Event is ongoing between its start and end.
-- Coming Soon is timing in (upcoming, ongoing); Previous Events is
-- timing = completed. Register stays enabled until the Event ends.
--
-- Each rule takes the Event row and the moment to judge it at, so the rules
-- are pure (immutable) and the view passes now().

create or replace function private.event_timing(p_event public.events, p_at timestamptz)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select case
    when p_at < p_event.starts_at then 'upcoming'
    when p_at < p_event.ends_at   then 'ongoing'
    else                               'completed'
  end;
$$;

-- Registration counts as open only while the Administrator has it open, before
-- registration_closes_at, and before the Event is over.
create or replace function private.event_registration_open(p_event public.events, p_at timestamptz)
returns boolean
language sql
immutable
security invoker
set search_path = ''
as $$
  select p_event.registration_status = 'open'
     and (p_event.registration_closes_at is null or p_at < p_event.registration_closes_at)
     and private.event_timing(p_event, p_at) <> 'completed';
$$;

-- The PRD §1.2 status: upcoming, registration_open, registration_closed or
-- ongoing; completed for Previous Events.
create or replace function private.event_status_label(p_event public.events, p_at timestamptz)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select case private.event_timing(p_event, p_at)
    when 'ongoing'   then 'ongoing'
    when 'completed' then 'completed'
    else case
      when private.event_registration_open(p_event, p_at) then 'registration_open'
      when p_event.registration_status = 'not_open'     then 'upcoming'
      else                                                   'registration_closed'
    end
  end;
$$;

revoke all on function private.event_timing(public.events, timestamptz) from public;
revoke all on function private.event_registration_open(public.events, timestamptz) from public;
revoke all on function private.event_status_label(public.events, timestamptz) from public;
-- The view runs as the caller, so the website roles must be able to call them.
grant execute on function private.event_timing(public.events, timestamptz)
  to anon, authenticated, service_role;
grant execute on function private.event_registration_open(public.events, timestamptz)
  to anon, authenticated, service_role;
grant execute on function private.event_status_label(public.events, timestamptz)
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
  private.event_timing(e, now())            as timing,
  private.event_status_label(e, now())      as status_label,
  private.event_registration_open(e, now()) as registration_open,
  -- For display and grouping. To filter by year, use a PHT range on starts_at,
  -- which can use the events_published_by_start index.
  private.event_year(e.starts_at)           as event_year
from public.events e;

comment on view public.event_listings is
  'Events with derived timing (upcoming, ongoing, completed), status_label, registration_open and event_year (PHT). Read-only.';

revoke all on public.event_listings from anon, authenticated;
grant select on public.event_listings to anon, authenticated;
