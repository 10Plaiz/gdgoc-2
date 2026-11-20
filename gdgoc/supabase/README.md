# Database (Supabase)

Every change to the database is a migration in `migrations/`, so the database can be rebuilt and every change reviewed. The design is in [proposal 0001](../../docs/proposals/0001-freedom-wall-and-events.md) and ADRs [0001](../../docs/adr/0001-supabase-as-cms.md)–[0003](../../docs/adr/0003-one-supabase-project.md).

## Run it locally

Needs Docker Desktop running. From `gdgoc/`:

```bash
npx supabase start     # local Postgres, Auth, Storage and API; applies migrations and seed.sql
npx supabase test db   # pgTAP security tests in tests/database/
npx supabase db reset  # rebuild from scratch after editing a migration
npx supabase stop
```

`supabase start` prints a local API URL and keys. They're public demo values, so you can put them in `.env.local` to point the app at your local database.

If another local Supabase project already uses ports 54320–54329, stop it first (`npx supabase stop --project-id <name>`).

## What's here

| Migration | Adds |
| --- | --- |
| `…_moderators.sql` | `private` schema, `Users` baseline and RLS, `private.is_moderator()`, a trigger so only Moderators can change `is_admin` |
| `…_events.sql` | `events` table and RLS, `set_featured_event()`, the public `event-images` bucket (Moderators write, 2 MB, images only) |

## Rules for new migrations

- Add a new migration file (`npx supabase migration new <name>`). Never edit one that has already been applied to production.
- Every new table enables RLS in the same migration, and writes check `(select private.is_moderator())` (ADR-0001).
- Put helpers in `private`, with `security definer` only when needed and always with `set search_path = ''`.
- Add a pgTAP test for every rule a Member shouldn't be able to get around.
- `seed.sql` holds fake placeholder data only. Never use real member data.

## Make the first Moderator

Members can't grant themselves the role. The project owner runs this once in the Supabase SQL editor, using the Member's sign-up email:

```sql
update public."Users" set is_admin = true where email = '<member email>';
```

After that, Moderators grant and revoke the role from `/admin`.
