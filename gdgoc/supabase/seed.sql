-- Local development seed: runs on `supabase db reset`, never on production.
-- Fake placeholder content only. Never put real member data here (AGENTS.md).

insert into public.events
  (title, summary, body, category, starts_at, ends_at, venue, registration_url, is_featured, is_published)
values
  ('Sample Hackathon',
   'A placeholder upcoming hackathon used as the Featured event.',
   'Longer description of the sample hackathon. Replace in the CMS.',
   'hackathon', now() + interval '14 days', now() + interval '15 days',
   'Sample Venue, Room 101', 'https://example.com/register', true, true),

  ('Sample Workshop',
   'A placeholder upcoming workshop.',
   'Longer description of the sample workshop.',
   'workshop', now() + interval '30 days', now() + interval '30 days 3 hours',
   'Sample Venue, Lab 2', 'https://example.com/register', false, true),

  ('Sample Talk',
   'A placeholder past talk.',
   'Recap of the sample talk.',
   'talk', now() - interval '20 days', now() - interval '20 days' + interval '2 hours',
   'Sample Venue, Auditorium', null, false, true),

  ('Sample Social',
   'A placeholder past social.',
   'Recap of the sample social.',
   'social', now() - interval '60 days', null,
   'Sample Venue, Lobby', null, false, true),

  ('Draft Sprint',
   'An unpublished draft. Only Moderators see it.',
   '',
   'sprint', now() + interval '45 days', null,
   null, null, false, false);
