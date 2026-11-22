# Database (Supabase)

Every change to the database is a migration in `migrations/`, so the database can be rebuilt and every change reviewed. Requirements: [PRD V.2](../../resource/documentation/PRD/NEW/) §1 and §5. Design: [proposal 0001](../../docs/proposals/0001-freedom-wall-and-events.md) and ADRs [0001](../../docs/adr/0001-supabase-as-cms.md), [0003](../../docs/adr/0003-one-supabase-project.md) and [0004](../../docs/adr/0004-event-status-in-three-parts.md). Terms are in [`GLOSSARY.md`](../../GLOSSARY.md).

## Run it locally

Needs Docker Desktop running. From `gdgoc/`:

```bash
npx supabase start               # local Postgres, Auth, Storage and API; applies migrations and seed.sql
npx supabase db reset            # rebuild from scratch after editing a migration
npx supabase test db             # pgTAP tests in tests/database/
npx supabase db advisors --local # security and performance advisors; must report nothing
npx supabase stop
```

Run `db reset`, `test db` and `db advisors` before every PR that touches this folder.

`supabase start` prints a local API URL and keys. They're public demo values, so you can put them in `.env.local` to point the app at your local database.

If another local Supabase project already uses ports 54320–54329, stop it first (`npx supabase stop --project-id <name>`).

## What's here

| Migration | Adds |
| --- | --- |
| `…_administrators.sql` | `private` schema, `Users` baseline and RLS, `private.is_admin()`, a trigger so only Administrators can change `is_admin` |
| `…_events.sql` | `events` table (categories, `publish_status`, `registration_status`, `registration_closes_at`), RLS, indexes, `set_featured_event()` |
| `…_event_listings.sql` | `event_listings` view with the derived `timing`, `status_label`, `registration_open` and `event_year` (PHT) |
| `…_event_timeline_and_gallery.sql` | `event_timeline_items` and `event_photos` (at most 20 per Event) |
| `…_event_media.sql` | private `event-media` bucket: readable only while the Event is published, Administrators write, WebP/JPEG/PNG up to 2 MB |

## How the website uses Events

- **Read from `event_listings`, write to `events`.** The view adds the fields the page needs and follows the same RLS as `events`: visitors see published Events, Administrators see all.
  - Featured: `is_featured = true`.
  - Coming Soon: `timing in ('upcoming', 'ongoing')`, ordered by `starts_at` ascending.
  - Previous Events: `timing = 'completed'`, ordered by `starts_at` descending, filtered by `event_year` and `category`, searched with `title ilike '%term%'`.
  - Badge: `status_label` is `upcoming`, `registration_open`, `registration_closed`, `ongoing` or `completed`. Enable Register only when `registration_open` is true.
- **Never compute timing in the app.** It lives in one place (`private.event_timing()`), so every page agrees. An Event is ongoing from `starts_at` until `ends_at`, and completed from `coalesce(ends_at, starts_at)` on.
- **Featured event:** call `rpc('set_featured_event', { p_event_id })`, or pass `null` to clear it. Only a published Event can be featured; unpublishing or archiving the Featured event clears it.
- **Images:** upload to `event-media` at `<event id>/<file>.webp` and store that path in `events.cover_path` or `event_photos.path`. The bucket is private, so show images with `createSignedUrl()`. Visitors get a URL only while the Event is published.
- **Times** are `timestamptz`. Show them in Philippine Standard Time (`Asia/Manila`).

## Rules for new migrations

See the Database section of [`CODING_STANDARDS.md`](../../CODING_STANDARDS.md). The reviewer enforces it.

## Before applying to production

The migrations have only run on local databases so far. The `Users` table already exists in production, and `…_administrators.sql` lists what it assumes about it: the columns, no broader old policies on `Users`, and email confirmation being off for sign-up. Check those in the dashboard first. The project is being recreated under an organisation account (PRD §5.5), and a fresh project avoids most of these questions.

## Make the first Administrator

Members can't grant themselves the role. The project owner runs this once in the Supabase SQL editor, using the Member's sign-up email:

```sql
update public."Users" set is_admin = true where email = '<member email>';
```

After that, Administrators grant and revoke the role from `/admin`.
