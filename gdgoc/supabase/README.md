# Database (Supabase)

Every change to the database is a migration in `migrations/`, so the database can be rebuilt and every change reviewed. The whole site uses one Supabase project ([ADR 0003](../../docs/adr/0003-one-supabase-project.md)), and the foundation owns the objects every feature shares ([ADR 0008](../../docs/adr/0008-foundation-owns-shared-database-objects.md)). Content is edited through `/admin` ([ADR 0001](../../docs/adr/0001-supabase-as-cms.md)).

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

## The foundation

These two migrations come before any feature. Feature migrations use what they create and never redefine it.

| Migration | Adds |
| --- | --- |
| `…_foundation.sql` | `private` schema, the shared `set_updated_at()` trigger, `private.is_public()` (which Publish status is public) |
| `…_administrators.sql` | `Users` baseline and RLS, `private.is_admin()`, a trigger so only Administrators can change `is_admin` |

When you write a feature migration:

- **Point at Members with `public."Users"(user_id)`.** It equals `auth.users.id` (`auth.uid()`). There is no `profiles` table.
- **Check Administrators with `private.is_admin()`.** Don't add a feature's own admin list.
- **Use `private.set_updated_at()`** for `updated_at` columns. Don't create your own copy.
- **Don't create the `private` schema.** The foundation already does.
- **Something several features share** (for example notifications) goes in its own foundation migration, not inside one feature.

## Before applying to production

The migrations have only run on local databases so far. Check these in the dashboard first. The project is being recreated under an organisation account (PRD §5.5), and a fresh project avoids most of them.

- **`Users` columns:** the table already exists in production. `…_administrators.sql` assumes it has the columns listed there, with `is_admin` a boolean.
- **`Users` policies:** handled. The migration drops every existing policy on `Users` before creating its own, so an older broad policy can't widen access.
- **Email confirmation at sign-up:** the sign-up page inserts the `Users` row right after `auth.signUp()`, which needs a session at that moment, so email confirmation must stay off. Turning it on needs an app change: create the row from a trigger on `auth.users` instead.

## Make the first Administrator

Members can't grant themselves the role. The project owner runs this once in the Supabase SQL editor, using the Member's sign-up email:

```sql
update public."Users" set is_admin = true
where user_id = (select id from auth.users where email = '<member email>');
```

Match on `auth.users`, not `Users.email`: Members can edit their own `Users.email`, so a Member who copied the new officer's email onto their row would be promoted too.

After that, Administrators grant and revoke the role from `/admin`.
