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

Migrations are grouped by feature (`CODING_STANDARDS.md`). Events spans four files, applied in order: the table, then the derived view, then its child tables, then its storage. Each one can be read and reviewed on its own.

| Migration | Adds |
| --- | --- |
| `…_foundation.sql` | `private` schema, the shared `set_updated_at()` trigger, `private.is_public()` (which Publish status is public) |
| `…_administrators.sql` | `Users` baseline and RLS, `private.is_admin()`, a trigger so only Administrators can change `is_admin` |
| `…_events.sql` | `events` table (categories, `publish_status`, `registration_status`, `registration_closes_at`), RLS, indexes, `set_featured_event()` |
| `…_event_listings.sql` | `event_listings` view with the derived `timing`, `status_label`, `registration_open` and `event_year` (PHT) |
| `…_event_timeline_and_gallery.sql` | `event_timeline_items` and `event_photos` (at most 20 per Event) |
| `…_event_media.sql` | private `event-media` bucket: readable only while the Event is published, Administrators write, WebP/JPEG/PNG up to 2 MB |

## How the website uses Events

- **Read from `event_listings`, write to `events`.** The view adds the fields the page needs and follows the same RLS as `events`: visitors see published Events, Administrators see all.
  - Featured: `is_featured = true`.
  - Coming Soon: `timing in ('upcoming', 'ongoing')`, ordered by `starts_at` ascending.
  - Previous Events: `timing = 'completed'`, ordered by `starts_at` descending, filtered by `category`, searched with `title ilike '%term%'`.
  - Year filter: a Philippine-time range on `starts_at`, for example `starts_at >= '2026-01-01T00:00:00+08:00'` and `< '2027-01-01T00:00:00+08:00'`. `event_year` is for display and grouping. Under RLS, Postgres can only use an index for leakproof comparisons, which a timestamp range is and `event_year = 2026` isn't.
  - Public lists must add `publish_status = 'published'` (`.eq('publish_status', 'published')`). RLS hides drafts from visitors and Members only: an Administrator sees every Event, so without this filter a signed-in Administrator would see drafts, unpublished and archived Events on the public page. The filter also lets the partial indexes be used.
  - Badge: `status_label` is `upcoming`, `registration_open`, `registration_closed`, `ongoing` or `completed`. Enable Register only when `registration_open` is true.
- **Never compute timing in the app.** It lives in one place (`private.event_timing()`), so every page agrees. Every Event has a required `ends_at` after `starts_at`. It is ongoing from `starts_at` until `ends_at`, and completed from `ends_at` on. Register stays enabled while it is ongoing and closes when it ends (or earlier, at `registration_closes_at`).
- **Featured event:** call `rpc('set_featured_event', { p_event_id })`, or pass `null` to clear it. Only a published Event can be featured; unpublishing or archiving the Featured event clears it.
- **Images:** save the Event first, then upload to `event-media` at `<event id>/<file>.webp` (uploads into a folder with no Event are refused) and store that path in `events.cover_path` or `event_photos.path`. The bucket is private, so show images with `createSignedUrl()`. Visitors get a URL only while the Event is published.
- **Deleting an Event:** first remove its files with `storage.from('event-media').remove([...])` (list the `<event id>/` folder), then delete the row. The database refuses to delete an Event whose folder still has files, so nothing is left behind; its Timeline and Gallery rows go with it.
- **Deleting a Gallery photo:** remove its file too. Deleting the `event_photos` row leaves the file behind, still counting toward the folder's 21.
- **Storage budget:** an Event's folder holds at most 21 files (the cover and 20 Gallery photos), counted from the files themselves. To replace a cover or photo, upload over the same path with `upsert: true`; that works even when the folder is full.
  - **Upload one file at a time** (`await` each upload). The Storage API checks the cap before the write and (from storage-api v1.81.0) inside it, but neither check locks the folder, so uploads sent in parallel (`Promise.all`) can each pass and overfill the folder. The 20-row cap on `event_photos` holds either way.
- **Times** are `timestamptz`. Show them in Philippine Standard Time (`Asia/Manila`).

## Data model and normalization

The tables are in third normal form, with a few deliberate exceptions:

- **Derived values are computed, not stored.** Event timing, the status label, whether registration is open, and the year all come from `event_listings`.
- **Storage paths repeat the Event id** (`events.cover_path`, `event_photos.path` = `<event id>/<file>`). The storage policies need the whole path in one string, and the website passes it straight to the Storage API. A check constraint (`private.event_media_owner(path) = event_id`) keeps the copy in step, so it can't drift.
- **The cover image is a column, not a Gallery row.** Every Event has at most one cover, and it shows on cards before any Gallery exists.
- **`Users.email` repeats `auth.users.email`.** It's the production table's existing shape (see below), kept so the current app keeps working. Each Member can edit their own copy, so never use it to identify someone for anything that matters; use `auth.users` (see "Make the first Administrator").
- **Categories, Publish status and Registration status are `text` with a `check`,** not lookup tables or enums, so the lists are easy to change (`CODING_STANDARDS.md`).

## Rules for new migrations

See the Database section of [`CODING_STANDARDS.md`](../../CODING_STANDARDS.md). The reviewer enforces it.

## Before applying to production

The migrations have only run on local databases so far. Check these in the dashboard first. The project is being recreated under an organisation account (PRD §5.5), and a fresh project avoids most of them.

- **`Users` columns:** the table already exists in production. `…_administrators.sql` assumes it has the columns listed there, with `is_admin` a boolean.
- **`Users` policies:** handled. The migration drops every existing policy on `Users` before creating its own, so an older broad policy can't widen access.
- **Email confirmation at sign-up:** the sign-up page inserts the `Users` row right after `auth.signUp()`, which needs a session at that moment, so email confirmation must stay off. Turning it on needs an app change: create the row from a trigger on `auth.users` instead.
- **Old public `event-images` bucket:** handled. The migration makes it private if it exists, so draft posters stop being reachable by URL. Its files are kept; delete them from the dashboard once you've moved anything still needed.
- **Storage policies:** check the existing policies on `storage.objects` (`select policyname, cmd, roles, qual, with_check from pg_policies where schemaname = 'storage' and tablename = 'objects';`). Policies are OR'd, so one that isn't limited to its own bucket (for example `using (true)`) also opens `event-media`, drafts included. Limit it with `bucket_id = '<its bucket>'` or drop it. The migration doesn't drop them for you, because other buckets (officer photos, shop) may depend on theirs.

## Make the first Administrator

Members can't grant themselves the role. The project owner runs this once in the Supabase SQL editor, using the Member's sign-up email:

```sql
update public."Users" set is_admin = true
where user_id = (select id from auth.users where email = '<member email>');
```

Match on `auth.users`, not `Users.email`: Members can edit their own `Users.email`, so a Member who copied the new officer's email onto their row would be promoted too.

After that, Administrators grant and revoke the role from `/admin`.
