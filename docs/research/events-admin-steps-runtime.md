# Where can the Events admin steps run?

Research for [issue #6](https://github.com/10Plaiz/gdgoc-2/issues/6) (map [#5](https://github.com/10Plaiz/gdgoc-2/issues/5)). Sources read 2026-11-23. The decision is made later with the maintainers; this note only recommends.

**Question.** The admin panel must follow ordered steps to manage an Event and its media: save the Event before uploading its images; upload one file at a time and upsert to replace one; write each file's path into the Event or Gallery row; remove a photo's file along with its row; empty the Event's folder before deleting it; feature an Event only through `set_featured_event()`. The database can't own these steps, because only the Storage API deletes a file's contents. Where can a module that owns them run, and what does each option cost?

## Summary

1. The browser, Next.js server code and Edge Functions can all run every step, because all three reach the Storage API as the signed-in Administrator. Postgres RPC can do only the database part: it can't delete a file's contents.
2. A browser module needs no new wiring. Next.js server code needs the session moved into cookies, a `src/proxy.ts`, a per-request server client, a `getClaims()` check in every action, and a body-size change if files pass through it. Edge Functions need a second deploy pipeline in Deno.
3. Where the steps run doesn't close the parallel-upload gap; only the database can. Since storage-api v1.81.0 the cap is checked again inside the write transaction, but without a lock, so the gap is smaller but still open. A trigger on `storage.objects` that locks the Event's folder closes it.
4. Hosted Supabase lets a migration add that trigger: `postgres` holds every privilege on `storage.objects`, and storage-api v1.84.36+ handles writes a trigger blocks. Supabase's docs, however, say to treat the `storage` schema as read-only.
5. Recommendation: build one deep Events admin module whose only dependency is a `SupabaseClient` (the seam). Run it in the browser first, keep the database-only steps in RPCs that return distinct errors, and close the upload gap in the database.

## What every option shares

These facts hold wherever the module runs.

**supabase-js runs in all three runtimes and sends the user's token.** Every request from a supabase-js client goes through `fetchWithAuth`, which sets `Authorization: Bearer <access token>` (or the key, when signed out) and `apikey` ([`supabase-js/src/lib/fetch.ts`](https://github.com/supabase/supabase-js/blob/v2.98.0/packages/core/supabase-js/src/lib/fetch.ts), v2.98.0). The same module code can therefore run in a browser, in Node (Next.js) or in Deno (Edge Functions). Whatever runtime it uses, the module acts as the signed-in Administrator, and RLS plus `private.is_admin()` remain the security boundary.

**How the Storage API uploads** ([`src/storage/uploader.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/storage/uploader.ts), storage-api v1.98.5, commit `f51b639`):

- Before any bytes are sent, `canUpload` runs the insert (or upsert) as the caller under RLS, inside a transaction it rolls back (`authorizeUpload` → `db.testPermission`, lines 90–128; `testPermission` in [`src/storage/database/pg.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/storage/database/pg.ts) line 451). This much was verified earlier in the storage-api source.
- **Correction to the earlier finding.** In v1.98.5, `completeUpload` writes the real row in one superuser transaction (line 246). That transaction first takes an advisory lock on the *object name* (`waitObjectLock`, line 247), then **runs the caller's policies again** (`this.authorizeUpload(db.asCaller(), …)`, line 281, inside a savepoint) and only then upserts. This second check arrived in [PR #1347](https://github.com/supabase/storage/pull/1347) (merged 2026-10-09) and first shipped in **v1.81.0**. So the policies run twice, and the second run shares a transaction with the real write.
- The gap is smaller but still open. The lock covers one object name, not a folder. `completeUpload` passes no isolation level, so the Postgres default applies (read committed, unless the project changed it; see `buildBeginStatement` in [`src/internal/database/postgres/sql.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/internal/database/postgres/sql.ts)). Two uploads to different names in the same folder can each count 20 committed files and both commit. `private.event_media_has_room()` is a plain `stable` count with no lock. (This is my inference from the code; I couldn't race uploads, see "Unverified".)
- If anything fails after the bytes are stored, the upload queues `ObjectAdminDelete` for that version, so no orphaned bytes remain (lines 197–209 and 389–398).
- The local stack's storage-api is v1.61.3: its `uploader.ts` has no `asCaller` call, so it has neither the second check nor the trigger handling below.

**How the Storage API deletes** ([`src/storage/object.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/storage/object.ts), v1.98.5):

- `deleteObjects` (line 647) locks the target names, runs the caller's delete policy in a rolled-back probe and keeps only the names the caller may delete (`authorizeDeleteTargets`, line 730). It then deletes those rows as superuser and frees their bytes after the commit (`cleanupDeletedObjects`, line 832).
- Names the caller may not delete, and names that don't exist, are **left out without an error**. `remove()` returns the list of objects it actually deleted ([`StorageFileApi.ts`](https://github.com/supabase/supabase-js/blob/v2.98.0/packages/core/storage-js/src/packages/StorageFileApi.ts) line 956), so the caller has to compare that list with what it asked for. One `remove()` call deletes at most 1000 objects ([Delete Objects](https://supabase.com/docs/guides/storage/management/delete-objects)).

**SQL can't delete a file's contents.**

- Since storage migration [`0055-prevent-direct-deletes.sql`](https://github.com/supabase/storage/blob/v1.98.5/migrations/tenant/0055-prevent-direct-deletes.sql), a statement trigger `storage.protect_delete()` refuses `delete from storage.objects` with `42501`, "Direct deletion from storage tables is not allowed. Use the Storage API instead.", unless the setting `storage.allow_delete_query` is `true`.
- Even when it's allowed, deleting the row leaves the bytes behind, still billed ([Storage schema](https://supabase.com/docs/guides/storage/schema/design), [Delete Objects](https://supabase.com/docs/guides/storage/management/delete-objects)).

**How Storage errors reach the caller.**

- storage-api turns Postgres errors into HTTP errors in `DBError.fromDBError` ([`src/storage/database/errors.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/storage/database/errors.ts)).
  - A `42501` becomes `AccessDenied` (403 in the body). The message is "new row violates row-level security policy" when RLS refused the write, so "folder full", "no such Event" and "not an Administrator" all look the same. Any other `42501` keeps its own message.
  - Most other codes become a 500 reading only `database error, code: <sqlstate>`.
- supabase-js wraps the result in `StorageApiError` with `status` (HTTP), `statusCode` (from the body) and `message` ([`storage-js/src/lib/common/errors.ts`](https://github.com/supabase/supabase-js/blob/v2.98.0/packages/core/storage-js/src/lib/common/errors.ts)).

**Signed upload URLs only check policies when the URL is signed.** `signUploadObjectUrl` calls `canUpload` once (`object.ts` line 1976). The upload itself goes through `.asSuperUser()` ([`src/http/routes/object/uploadSignedObject.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/http/routes/object/uploadSignedObject.ts)). Signed upload URLs therefore make the cap weaker, not stronger.

## Option A: a browser module (today's pattern)

The module runs in the admin page, using the browser's supabase-js client. `OfficerModal.tsx` already uploads to Storage this way.

- **Auth.** The session lives in the browser. Today that's `localStorage`, because `utils/supabase/client.ts` uses `createClient` from `@supabase/supabase-js`. Every call carries the user's JWT (see above), PostgREST and Storage evaluate RLS as `authenticated`, and `private.is_admin()` decides.
- **Deletes Storage files.** Yes, with `storage.from('event-media').remove(paths)` under the "Administrators delete event media" policy.
- **Ordering and failure.**
  - The module `await`s each step, so it controls the order.
  - It stops if the tab closes or the network drops partway through. That can leave a file without a row, which still counts toward the folder's 21, or an emptied folder whose Event row is still there.
  - Every step can be made safe to retry. Upserts to the same path replace the file, `remove()` ignores missing names, and deleting a row by id twice is harmless.
  - Leftover files can be found by listing `<event id>/` and comparing the list with the rows. `events_refuse_delete_with_media` already stops an Event from being deleted while files remain.
- **Parallel-upload gap.** Not closed. One module instance can serialize its own uploads, but two tabs or two Administrators still race.
- **Errors.** The module gets `{ data, error }` directly, with `StorageApiError` and `PostgrestError` (`code`, `message`, `details`, `hint`, see [`PostgrestError.ts`](https://github.com/supabase/supabase-js/blob/v2.98.0/packages/core/postgrest-js/src/PostgrestError.ts)), and can map them to its own error kinds.
- **Testing locally.** Write the module as plain TypeScript that takes a `SupabaseClient`, so Vitest (Node) can call it against the local stack with a client signed in as a seeded Administrator. supabase-js runs in Node unchanged. The UI wiring still needs a browser test. Upload tests are blocked until the local Storage API works (it fails with `42P10` today).
- **Cost.** Nothing new. Bytes go straight from the browser to Supabase. Uploads aren't egress: egress is data sent from Supabase to a client ([Egress](https://supabase.com/docs/guides/platform/manage-your-usage/egress)). The Free Plan limits are 1 GB of storage ([Storage size](https://supabase.com/docs/guides/platform/manage-your-usage/storage-size)) and 5 GB each of egress and cached egress. The Docker container plays no part.

## Option B: Next.js 16 server code as the signed-in user

The module runs in Server Actions or Route Handlers, using a `@supabase/ssr` server client built from the request's cookies.

- **Auth and the wiring it needs.**
  - **Session in cookies.** The browser has to keep the session in cookies, or the server can't see it. That means swapping `utils/supabase/client.ts` to `createBrowserClient` from `@supabase/ssr`, which supplies a cookie storage ([`createBrowserClient.ts`](https://github.com/supabase/ssr/blob/v0.8.0/src/createBrowserClient.ts), v0.8.0). Members signed in through the old `localStorage` session would have to sign in again. (That follows from the storage change; I didn't test it.)
  - **Per-request server client.** Each request creates its own `createServerClient` with `cookies: { getAll, setAll }` over `cookies()` from `next/headers` ([Supabase example `lib/supabase/server.ts`](https://github.com/supabase/supabase/blob/9495de919f9ac3b2832e8d9ab966440cf9fd63d3/examples/auth/nextjs/lib/supabase/server.ts)).
  - **Token refresh in `src/proxy.ts`.** Server Components can't write cookies, so a Proxy has to refresh the token with `getClaims()` and copy the cookies onto the response. In Next.js 16 that file is `proxy.ts`, exporting `proxy`; `middleware.ts` is deprecated, and on Next.js 15 and earlier the file is never called ([Supabase SSR client guide](https://supabase.com/docs/guides/auth/server-side/creating-a-client?queryGroups=framework&framework=nextjs); [Next.js `proxy.js`](https://github.com/vercel/next.js/blob/v16.4.6/docs/01-app/03-api-reference/03-file-conventions/proxy.mdx); [`middleware.js` deprecated](https://github.com/vercel/next.js/blob/v16.4.6/docs/01-app/03-api-reference/03-file-conventions/middleware.mdx)). The file goes next to `app/`, so here it's `src/proxy.ts`. Proxy runs on the Node.js runtime by default.
  - **Check auth in every action.** Server Actions are POSTs to the page and skip any path the Proxy's matcher excludes. Next.js says to "verify authentication and authorization inside each Server Function rather than relying on Proxy alone" (same `proxy.mdx`; [Server Actions guide](https://github.com/vercel/next.js/blob/v16.4.6/docs/01-app/02-guides/server-actions.mdx)). Supabase says to use `getClaims()` and *never* `getSession()` in server code.
  - **Library version.** The repo pins `@supabase/ssr ^0.8.0`. Its `setAll` receives only the cookies ([`types.ts` v0.8.0](https://github.com/supabase/ssr/blob/v0.8.0/src/types.ts)). The current docs pass a second `headers` argument with cache headers, which first appears in the 0.12 line ([`types.ts` v0.12.7](https://github.com/supabase/ssr/blob/v0.12.7/src/types.ts)), so following the docs as written means upgrading.
  - **The existing `utils/supabase/middleware.ts` can't be reused as is.** It uses the deprecated `get/set/remove` cookie methods and `getSession()`, and queries `users` by `id`, whereas the table is `"Users"` keyed by `user_id`.
  - RLS still applies, because the server acts as the user with the publishable key. No secret key is needed.
- **Deletes Storage files.** Yes, with the same `remove()` call from the server client.
- **Ordering and failure.**
  - Same sequence and the same retry design as A, but the steps run in a server request rather than in the tab.
  - Next.js runs one Server Action at a time per client. The server doesn't queue them, though: each runs in its own request (Server Actions guide).
  - Whether an action keeps running after the browser disconnects isn't documented. I didn't verify it.
- **Parallel-upload gap.** Not closed by Supabase. A per-Event mutex in the one Docker container could serialize uploads that go through it. It stops working with a second container, and it doesn't cover uploads from the dashboard or from another client.
- **Files through the server.**
  - Server Action bodies are limited to **1 MB** by default. The limit counts multipart overhead too, so 2 MB images need `experimental.serverActions.bodySizeLimit` of about `'2.1mb'` ([`serverActions`](https://github.com/vercel/next.js/blob/v16.4.6/docs/01-app/03-api-reference/05-config/01-next-config-js/serverActions.mdx)).
  - When a Proxy is present, Next.js buffers request bodies up to 10 MB ([`proxyClientMaxBodySize`](https://github.com/vercel/next.js/blob/v16.4.6/docs/01-app/03-api-reference/05-config/01-next-config-js/proxyClientMaxBodySize.mdx)).
  - The alternative is for the browser to keep uploading directly while the server runs only the database and delete steps. That splits the module across two runtimes.
- **Errors.** Next.js says to return expected errors as values (for example with `useActionState`), not to throw them ([Error handling](https://github.com/vercel/next.js/blob/v16.4.6/docs/01-app/01-getting-started/10-error-handling.mdx)). In production, a thrown error reaches the client only as a generic message plus a `digest` ([`error.js`](https://github.com/vercel/next.js/blob/v16.4.6/docs/01-app/03-api-reference/03-file-conventions/error.mdx)). The module's typed result is therefore what the action returns.
- **Testing locally.** The module itself is tested as in A, by passing it a client. The Next.js 16.4.6 docs offer no unit-test utility for Server Actions (the Proxy has `next/experimental/testing/server`), so testing the action end to end means a running app and a browser test.
- **Cost.** No new Supabase cost. Uploads cross the Docker host twice (in from the browser, out to Supabase), which costs host bandwidth and memory. With more than one instance, every instance needs the same `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` ([Self-hosting](https://github.com/vercel/next.js/blob/v16.4.6/docs/01-app/02-guides/self-hosting.mdx)).

## Option C: Supabase Edge Functions

The module runs in a Deno function on Supabase, called with `supabase.functions.invoke`.

- **Auth.**
  - `invoke` sends the user's JWT on `Authorization` (`fetchWithAuth`, above). The platform's `verify_jwt` check is on by default and rejects requests without a valid JWT before the code runs ([Authorization headers](https://supabase.com/docs/guides/functions/auth-headers)).
  - In code, `withSupabase({ auth: 'user' })` from `@supabase/server` gives `ctx.supabase`, which RLS scopes to the caller. It also gives `ctx.supabaseAdmin`, which bypasses RLS and would make the function responsible for its own `is_admin` check ([Securing Edge Functions](https://supabase.com/docs/guides/functions/auth)).
- **Deletes Storage files.** Yes, with `ctx.supabase.storage…remove()`.
- **Ordering and failure.**
  - Same as B, inside one function call.
  - Free Plan limits are 150 s wall clock, 2 s of CPU and 256 MB of memory per worker ([Limits](https://supabase.com/docs/guides/functions/limits)). That's plenty for a few 2 MB files.
- **Parallel-upload gap.** Not closed. Workers don't share memory, so the function can't hold a lock across the Storage call.
- **Errors.** The function returns an HTTP response. The client gets `FunctionsHttpError` and has to read `await error.context.json()`; network failures arrive as `FunctionsRelayError` or `FunctionsFetchError` ([Error handling](https://supabase.com/docs/guides/functions/error-handling)). The module's error kinds would be encoded in the response body.
- **Testing locally.** `supabase start` runs the edge runtime (`[edge_runtime] enabled = true` in `gdgoc/supabase/config.toml`), and the docs test functions with Deno's test runner ([Unit testing](https://supabase.com/docs/guides/functions/unit-test)). That's a second test toolchain next to Vitest.
- **Cost.**
  - The Free Plan includes 500,000 invocations a month ([Pricing](https://supabase.com/docs/guides/functions/pricing)); about 10 Events a year is negligible.
  - The real cost is a second runtime and deploy path. It means Deno code, plus `supabase functions deploy` from CI with a `SUPABASE_ACCESS_TOKEN` secret ([Deploy](https://supabase.com/docs/guides/functions/deploy)), all outside the Docker image. That's one more system to hand over to each year's officers, which ADR-0001 is meant to avoid.

## Option D: Postgres functions (RPC) for the database part

The database steps run as RPCs called through PostgREST.

- **Auth.** PostgREST runs the function as the caller's role with their JWT claims. A `security invoker` function keeps RLS, as `set_featured_event()` does today; a `security definer` function must check `private.is_admin()` itself.
- **Deletes Storage files.** No. Direct deletes are refused by `storage.protect_delete()`. If that's bypassed, the bytes are orphaned. `pg_net` could call the Storage API from SQL, but its requests only start after the transaction commits ([pg_net](https://supabase.com/docs/guides/database/extensions/pg_net)), outside the transaction and without an answer to the caller. It would also need a secret key stored in the database.
- **Ordering and failure.** Everything inside one call is one transaction, all or nothing. That suits steps such as "write the Gallery row and check the 20-photo cap" or "switch the Featured event", but it can't include the Storage steps.
- **Parallel-upload gap.** An RPC can't take part in the Storage API's transaction. The database can still close the gap with a trigger (next section).
- **Errors.** PostgREST maps the SQLSTATE to the HTTP status: `P0001` → 400, `42501` → 401 or 403, `PTxyz` → status `xyz`. It passes on `message`, `details` and `hint` ([PostgREST errors](https://github.com/PostgREST/postgrest/blob/e1e95101e8d37d24c07da7f3683a8c936e098f2c/docs/references/errors.rst)). An RPC can therefore give each failure its own code, which fixes the "everything is `42501`" finding for database steps.
- **Testing locally.** pgTAP, already set up (`npx supabase test db`).
- **Cost.** None.

## Can a project add triggers on `storage.objects` on hosted Supabase?

**Technically yes; the docs advise against it.**

- **Privilege.** Postgres requires the `TRIGGER` privilege on the table to create a trigger ([`CREATE TRIGGER`](https://www.postgresql.org/docs/17/sql-createtrigger.html)). Storage migrations [`0046`](https://github.com/supabase/storage/blob/v1.98.5/migrations/tenant/0046-buckets-objects-grants.sql) and [`0049`](https://github.com/supabase/storage/blob/v1.98.5/migrations/tenant/0049-buckets-objects-grants-postgres.sql) grant `all` on `storage.objects` to `postgres` `with grant option`. That's the role migrations run as. [`0073`](https://github.com/supabase/storage/blob/v1.98.5/migrations/tenant/0073-revoke-grants-to-unused-operations.sql) removes `TRIGGER` only from `anon` and `authenticated`.
- **storage-api handles it.** [PR #1600](https://github.com/supabase/storage/pull/1600) ("improve handling of writes prevented by database triggers", merged 2026-10-28, first shipped in **v1.84.36**) and its test [`object-write-denied-by-trigger.test.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/test/object-write-denied-by-trigger.test.ts) cover "object writes denied by a tenant trigger":
  - a trigger that returns `NULL` gives `AccessDenied`, "Object write was rejected by a database trigger";
  - when the denial comes at the first check, no bytes are uploaded;
  - when it comes only at the final write, the uploaded bytes are removed.
  - Before v1.84.36, the PR says, such writes could fail with a 500 and only fail after the whole file had uploaded.
- **The docs.** "We strongly recommend refraining from making any alterations to the `storage` schema and treating it as read-only… However, we encourage you to add custom indexes" ([The Storage Schema](https://supabase.com/docs/guides/storage/schema/design)). A trigger isn't an index, so this path works in the code but goes against that advice.

## Closing the parallel-upload gap (in any runtime)

Where the module runs doesn't change this. These are the database options, for the decision with the maintainers:

1. **A trigger that locks the folder (closes the gap).** A `before insert or update of name` trigger on `storage.objects` would take `pg_advisory_xact_lock` on the Event folder, count the folder's other files, and raise `42501` with its own message when the folder already holds 21.
   - It runs in the real write's transaction, whatever the role, so the second upload waits for the first to commit and then counts it.
   - It also runs during the early check, so a full folder is refused before any bytes are sent (storage-api v1.84.36+).
   - Because the code is `42501` and the message doesn't mention "row-level security", storage-api forwards the message. "Folder full" (and, if it moves into the trigger, "no such Event") would then reach the caller as their own messages.
   - Costs: a small migration, against the read-only advice above. Untested here, because local uploads fail.

   Illustration only (untested):

   ```sql
   create function private.event_media_cap() returns trigger
   language plpgsql security definer set search_path = '' as $$
   begin
     if new.bucket_id = 'event-media' then
       perform pg_advisory_xact_lock(hashtext('event-media/' || split_part(new.name, '/', 1)));
       if (select count(*) from storage.objects o
           where o.bucket_id = 'event-media'
             and private.event_media_owner(o.name) = private.event_media_owner(new.name)
             and o.name <> new.name) >= 21 then
         raise exception 'Event folder % already holds 21 files', split_part(new.name, '/', 1)
           using errcode = '42501';
       end if;
     end if;
     return new;
   end $$;

   create trigger event_media_cap before insert or update of name on storage.objects
     for each row execute function private.event_media_cap();
   ```

2. **Register the row first (narrows the gap; uses only policies, which the docs endorse).** The insert policy would require a row whose path matches the file (`event_photos.path` or `events.cover_path`). The 20-photo row cap, already serialized by `cap_event_photos()`, would then limit the files too, and the photo and file limits would stop living in two places (map finding 4).
   - The step order changes: row first, then file, so a failed upload leaves a row without a file, which the module has to undo.
   - Files left behind by deleted rows are no longer covered unless `event_media_has_room()` stays.

3. **Accept the best-effort cap.** With about 10 Events a year and a few Administrators, the worst case is a few extra files of at most 2 MB in a 1 GB Free Plan. The 20-row cap on `event_photos` already holds either way.

## Comparison

| | A. Browser module | B. Next.js server (Server Actions / Route Handlers) | C. Edge Functions | D. Postgres RPC |
| --- | --- | --- | --- | --- |
| Auth | User JWT from the browser session; RLS | User JWT from cookies (`@supabase/ssr`); RLS; `getClaims()` in every action | User JWT on `Authorization`; `verify_jwt`; RLS via `ctx.supabase` | Caller's role and claims; invoker keeps RLS |
| Deletes file contents | Yes (`remove()`) | Yes | Yes | **No** (SQL delete blocked; bytes would be orphaned) |
| Order and partial failure | Module awaits each step; stops if the tab closes; steps can be made safe to retry | Same, in a server request | Same, within 150 s / 2 s CPU | One transaction, all or nothing, database steps only |
| Closes the parallel-upload gap | No | Only for uploads through one container's in-process lock | No | Only through a trigger on `storage.objects` (any runtime) |
| Errors reach the caller as | `StorageApiError` / `PostgrestError` | Returned values (thrown errors are hidden in production) | `FunctionsHttpError` + JSON body | `PostgrestError`, with its own SQLSTATE / `PTxyz` |
| Testing locally | Vitest with a signed-in client (Storage blocked by the local `42P10`) | Module as in A; actions need a running app | Deno tests + edge runtime | pgTAP (already set up) |
| New wiring | None | Cookie session, `src/proxy.ts`, server client, `bodySizeLimit`, ssr upgrade | Deno code, deploy pipeline, CI token | Migrations only |
| Cost (Free Plan + Docker) | None | None on Supabase; uploads cross the Docker host | Free within 500k calls/month; second system to hand over | None |

## Recommendation

- **One deep module.** Put the steps behind one Events admin **module** with a small **interface**: `createEvent`, `updateEvent`, `setCover`, `addPhoto`, `replacePhoto`, `removePhoto`, `deleteEvent`, `setFeatured`.
  - It returns typed results (`not_admin`, `event_missing`, `folder_full`, `gallery_full`, `file_rejected`, `partial` with the leftover paths) instead of raw `42501`s.
  - Its **depth** comes from what it hides behind those eight calls: step order, one-at-a-time uploads, upsert-to-replace, listing the folder before a delete, comparing `remove()` results with the request, undoing partial work, and translating errors.
- **The seam is the client.** The module's only dependency is a `SupabaseClient` acting as the signed-in Administrator. Each runtime gets a thin **adapter** that builds that client:
  - the browser client today;
  - a `createServerClient` adapter (B) or an Edge Function adapter (C) later, without touching the module, because supabase-js behaves the same in all three.
  - Tests use a Vitest adapter: a client signed in to the local stack.
- **Run it in the browser first (A).** It needs no new infrastructure, matches the existing `OfficerModal` pattern, and avoids the 1 MB Server Action limit and the cookie migration. B and C add no security, because RLS is the boundary either way. They add wiring (B) or a second system to hand over (C).
  - Move to B if Server Actions are adopted for other reasons, or if steps must keep running when a tab closes. That needs a check of how Next.js handles client disconnects.
- **Deepen the database side with RPCs** where a step only touches the database (for example, write a Gallery row and give "Gallery full" its own code). This also gives the module distinct errors for those steps.
- **Close the parallel-upload gap in the database, not the runtime.** That means choosing between the folder-lock trigger (closes it, against the docs' read-only advice), the row-first policy (documented territory, changes the step order), or accepting the best-effort cap.

## Unverified and open

- **Which storage-api version the hosted project runs.** The second check inside the transaction needs v1.81.0 or later; clean trigger denials need v1.84.36 or later. To check: the Storage version in the dashboard, or `select has_table_privilege('postgres', 'storage.objects', 'TRIGGER')` and a trial trigger on a throwaway project.
- **Concurrent upload behaviour wasn't tested end to end.** The local Storage API (v1.61.3) fails uploads with `42P10` and predates both changes. Run the local stack on the same storage-api version as hosted before testing races or trigger errors.
- Whether the HTTP status of a trigger denial is 400 or 403. storage-api's own test expects HTTP 400 with `statusCode: '403'` in the body. Code should read `error.statusCode` or the message, not only `error.status`.
- Whether a Next.js 16 Server Action keeps running after the client disconnects.
- That moving the browser client from `localStorage` to cookies signs current members out once (inferred from the storage change, not tested).

## Sources (all read 2026-11-23)

- Supabase Storage API source, tag `v1.98.5` (commit `f51b639`): `src/storage/uploader.ts`, `src/storage/object.ts`, `src/storage/database/pg.ts`, `src/storage/database/errors.ts`, `src/internal/errors/codes.ts`, `src/internal/database/postgres/sql.ts`, `src/http/routes/object/uploadSignedObject.ts`, `src/test/object-write-denied-by-trigger.test.ts`, `migrations/tenant/0046`, `0049`, `0055`, `0073`; PRs [#1347](https://github.com/supabase/storage/pull/1347) and [#1600](https://github.com/supabase/storage/pull/1600); tag `v1.61.3` `src/storage/uploader.ts`. https://github.com/supabase/storage
- supabase-js monorepo, tag `v2.98.0` (commit `d30aad0`): `storage-js` `StorageFileApi.ts` and `lib/common/errors.ts`; `functions-js` `FunctionsClient.ts` and `types.ts`; `postgrest-js` `PostgrestError.ts`; `supabase-js` `SupabaseClient.ts` and `lib/fetch.ts`. https://github.com/supabase/supabase-js
- `@supabase/ssr`, tags `v0.8.0` (commit `bcf502f`) and `v0.12.7` (commit `9b28f49`): `createServerClient.ts`, `createBrowserClient.ts`, `types.ts`. https://github.com/supabase/ssr
- Supabase docs, `supabase/supabase` at commit `9495de9`: Storage schema design; Storage access control; Delete Objects; Auth server-side "Creating a client" (Next.js); `examples/auth/nextjs/` (`proxy.ts`, `lib/supabase/{client,server,proxy}.ts`); Edge Functions auth, auth headers, limits, pricing, error handling, unit testing, deploy; pg_net; Free project pausing; usage pages for egress and storage size. https://supabase.com/docs
- Next.js docs, tag `v16.4.6` (commit `54b876b`): `proxy.mdx`, `middleware.mdx`, `serverActions.mdx`, `proxyClientMaxBodySize.mdx`, guides `server-actions.mdx` and `self-hosting.mdx`, getting-started `10-error-handling.mdx`, `error.mdx`. https://github.com/vercel/next.js/tree/v16.4.6/docs
- PostgREST docs, `docs/references/errors.rst` at commit `e1e9510`. https://github.com/PostgREST/postgrest
- PostgreSQL 17 docs: `CREATE TRIGGER` (privileges); "Advisory Locks" (transaction-level locks follow transaction semantics), `REL_17_STABLE` commit `eb332f7`. https://www.postgresql.org/docs/17/
- This repo at `6c209c4`: `gdgoc/supabase/migrations/*`, `gdgoc/supabase/README.md`, `gdgoc/supabase/config.toml`, `gdgoc/src/app/utils/supabase/*`, `gdgoc/src/app/(admin)/layout.tsx`, `gdgoc/package.json`, `docs/adr/0001-supabase-as-cms.md`.
