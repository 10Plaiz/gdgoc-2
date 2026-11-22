-- Local development seed: runs on `supabase db reset`, never on production.
-- Fake placeholder content only. Never put real member data here (AGENTS.md).

insert into public.events
  (id, title, summary, body, category, starts_at, ends_at, venue,
   registration_url, registration_status, registration_closes_at, publish_status, is_featured)
values
  ('5eed0000-0000-0000-0000-000000000001', 'Sample Hackathon',
   'A placeholder upcoming hackathon used as the Featured event.',
   'Longer description of the sample hackathon. Replace in the CMS.',
   'hackathon', now() + interval '14 days', now() + interval '15 days',
   'Sample Venue, Room 101', 'https://example.com/register', 'open', now() + interval '10 days',
   'published', true),

  ('5eed0000-0000-0000-0000-000000000002', 'Sample Workshop',
   'A placeholder upcoming workshop. Registration is not open yet.',
   'Longer description of the sample workshop.',
   'workshop', now() + interval '30 days', now() + interval '30 days 3 hours',
   'Sample Venue, Lab 2', 'https://example.com/register', 'not_open', null,
   'published', false),

  ('5eed0000-0000-0000-0000-000000000003', 'Sample Talk',
   'A placeholder past talk.',
   'Recap of the sample talk.',
   'talk', now() - interval '20 days', now() - interval '20 days' + interval '2 hours',
   'Sample Venue, Auditorium', null, 'closed', null,
   'published', false),

  ('5eed0000-0000-0000-0000-000000000004', 'Sample Social',
   'A placeholder past social.',
   'Recap of the sample social.',
   'social', now() - interval '400 days', null,
   'Sample Venue, Lobby', null, 'closed', null,
   'published', false),

  ('5eed0000-0000-0000-0000-000000000005', 'Draft Workshop',
   'An unpublished draft. Only Administrators see it.',
   '',
   'workshop', now() + interval '45 days', null,
   null, null, 'not_open', null,
   'draft', false);

insert into public.event_timeline_items (event_id, position, starts_at, ends_at, title, description)
values
  ('5eed0000-0000-0000-0000-000000000001', 0, now() + interval '14 days', now() + interval '14 days 1 hour',
   'Opening', 'Welcome and team formation.'),
  ('5eed0000-0000-0000-0000-000000000001', 1, now() + interval '14 days 1 hour', now() + interval '15 days',
   'Hacking', 'Build time.'),
  ('5eed0000-0000-0000-0000-000000000003', 0, now() - interval '20 days', now() - interval '20 days' + interval '2 hours',
   'Talk and Q&A', 'Sample talk followed by questions.');
