# How can the Events page serve images from a private bucket?

Research for issue [#8](https://github.com/10Plaiz/gdgoc-2/issues/8) (map [#5](https://github.com/10Plaiz/gdgoc-2/issues/5), finding 3). Sources read on 2026-11-23. Each claim cites a source; the list is at the end.

## Question

Event covers and Gallery photos live in the private `event-media` bucket. Anyone can read a file while its Event is published; Administrators can read all of them. `gdgoc/next.config.js` lets `next/image` load only `/storage/v1/object/public/**`, and a signed URL carries a token that changes every time it is issued. How should the Events page deliver these images? The app is self-hosted in Docker on the Supabase Free Plan.

## Summary

1. A signed URL is checked against RLS only when it is issued. Downloading it skips RLS until it expires, so unpublishing an Event doesn't revoke URLs already handed out.
2. `next/image` caches by the full URL, token included. Signing on every request makes every view download every original from Supabase: the same egress as `unoptimized`, plus our server's CPU.
3. The Free Plan has no image transformations and only the Basic CDN (Smart CDN starts at Pro). Its 5 GB of uncached egress is shared with the database.
4. A public bucket caches best. It also takes the "published only" rule out of RLS and turns it into copy and delete steps on the write side, which is already the shallow part (finding 1).
5. Recommendation: keep the bucket private. Serve images through a same-origin route that reads them under RLS and feeds `next/image` as a local image. Callers get a stable path, and the URLs carry no token and never expire.

## What's fixed

- **Bucket:** `event-media`, private, files at `<event id>/<file>`, WebP/JPEG/PNG up to 2 MB. Select policy: anon and authenticated users read a file while `private.event_is_published(owner)`; Administrators read all ([migration `…_event_media.sql`](../../gdgoc/supabase/migrations/20261120000500_event_media.sql)).
- **Images** are shrunk in the browser to about 1280 px WebP before upload ([README](../../gdgoc/supabase/README.md), "Images"). The README currently says to show them with `createSignedUrl()`.
- **`next.config.js`** has one `remotePatterns` entry: `https://<project>.supabase.co/storage/v1/object/public/**`.
- **Hosting:** `next start` inside a Docker container ([`gdgoc/Dockerfile`](../../gdgoc/Dockerfile)), with no volume. The `next/image` disk cache lives in the container, so a new container starts with an empty cache. That last point is inferred from the Dockerfile.
- **Precedent in the code:** the shop page uses a public bucket with `getPublicUrl()` and a plain `<img>` ([`shop/page.tsx`](../../gdgoc/src/app/(main)/shop/page.tsx)). About Us uses `next/image` with the public remote pattern. The Events page is still a client component with demo data.
- **Versions:** `next` 16.4.6 and `@supabase/supabase-js` / `storage-js` 2.98.0 (from `gdgoc/package-lock.json`). The Storage API source was read at its latest release, v1.98.5.
- **Local stack:** uploads currently fail with `42P10`, so nothing here was tested end to end. Statements marked *from source* come from reading the code, not from running it.

## How the pieces behave

### Supabase signed URLs

- **Issuing.** `createSignedUrl(path, expiresIn)` posts to `/object/sign/<bucket>/<path>` and returns `https://<project>.supabase.co/storage/v1/object/sign/<bucket>/<path>?token=<JWT>` [J1 L581–610]. The server looks the object up *as the caller*, so the select policy decides. An anonymous visitor gets a URL only for a published Event's file [S3 L1861–1868].
- **The token** is a JWT holding `{url, scope, iat, exp}`, signed with the project's URL signing key [S3 L1889–1913]. `signJWT` always sets `iat` [S4 L512–537], so two calls give different tokens unless they land in the same second.
- **Downloading** checks the signature, the scope, that the path matches and that the token hasn't expired [S3 L2015–2049]. It then reads the object with `asSuperUser()` [S2 L60–72]. **No RLS check runs at download time.**
- **Revoking.** "You can't revoke individual signed URLs. To invalidate a specific one, delete, move, or rename the underlying object." Rotating and then revoking the project's URL signing key revokes all of them [D1, D4]. Rotating the Auth JWT keys doesn't affect signed URLs [D4].
- **Lifetime.** `expiresIn` is a whole number of seconds, at least 1. The upper bound is `MAX_SAFE_INTEGER / 1000` seconds from now, which is effectively unlimited [S4 L41, L553–567].
- **Batch signing.** `createSignedUrls(paths, expiresIn)` signs up to 1,000 paths in one POST and returns a per-path error for missing or forbidden files [J1 L650–682, S3 L1921–1966, S8 L18]. It has **no `transform` option**.
- **Response headers** (*from source*). A signed download sends `Expires: <token expiry>` and does *not* send the file's `Cache-Control`, except a bare `no-transform` [S5 L165–171]. Public and authenticated downloads send the file's `Cache-Control` [S5 L205–231, S6 L48–78, S7]. supabase-js uploads default to `cacheControl: '3600'`, which is stored as `max-age=3600` [J1 L28–29, L93–109]. The hosted CDN may add or change headers in front of the origin. That is **unverified**.

### Supabase CDN on the Free Plan

- The Free Plan gets the **Basic CDN**; Pro and above get the **Smart CDN** [D11].
- Public buckets get a better hit rate. For private buckets, "permissions for accessing each object is checked on a per user level", so two users asking for the same object both miss [D2].
- **Smart CDN** (not ours) treats each signed-URL token as a separate cache key, so "if you generate a new signed URL on every request, the cache will never be warm". Expiring or revoking a token doesn't purge its cached response. Deleting the object invalidates every token's entry within about 60 seconds [D3].
- **Basic CDN with signed URLs** is not documented. The Smart CDN page implies the Basic CDN keys on the full URL, query string included [D3]. Whether it caches signed responses at all is **unverified**. You can check on the real project with the `cf_cache_status` edge-log query [D6].
- **Purging** the CDN cache is Pro and above only [D5].

### Supabase image transformations

- "Image Resizing is currently enabled for Pro Plan and above." The pricing page lists them as "Not included" on Free [D7, D11].
- On Pro, 100 origin images per billing cycle are included, then $5 per 1,000 [D7, D8]. The Pro Plan itself is $25 a month [D9, billing example].
- A signed transform URL has its options baked into the token [D7], so each size needs its own signing call, and batch signing can't do it. *From source:* when transformations are off for the project, `createSignedUrl` drops `transform` and returns a plain `/object/sign/` URL [S1 L76–90].
- The Next.js loader in Supabase's docs builds `/render/image/public/…` URLs, so it only works for public buckets [D7].

### Free Plan quotas

- Each month: 5 GB uncached egress and 5 GB cached egress, shared by every service (database, auth, storage). Storage size is capped at 1 GB [D9, D10, D11].
- Going over on Free leads to a notice, a grace period, and then restrictions under the Fair Use Policy [D8, "Exceeding Quotas"].

### `next/image` on a self-hosted server (Next.js 16.4.6)

- **It works** with `next start` and no configuration [N10]. Optimized images are cached on disk in `.next/cache/images` [N1 L363].
- **Remote patterns.** If `search` is set, it must equal the URL's query string exactly; if it is left out, any query string is allowed [N5]. A token that changes can never match a fixed `search`, so signed URLs need a pattern with `pathname: '/storage/v1/object/sign/event-media/**'` and no `search`. Without that pattern, the dev loader throws "hostname … is not configured" [N7 image-loader.ts L92–118] and the production optimizer answers 400 [N1 L252–254].
- **The cache key** is a hash of the full `href` (query string and token included), the width, the quality and the MIME type [N1 L340–351]. A new token always means a new cache entry.
- **How long a copy is cached:** the larger of `minimumCacheTTL` and the upstream `s-maxage`/`max-age` [N2 transform.ts L204–207, get-max-age.ts]. `Expires` is ignored. The default `minimumCacheTTL` in Next 16 is 14,400 s (4 hours) [N6 L248, N9]. A signed URL sends no `max-age`, so the global `minimumCacheTTL` is the only setting that controls how long its copy is cached.
- **What browsers receive:** `Cache-Control: public, max-age=<that TTL>, must-revalidate` and `Vary: Accept` [N1 L1121–1139].
- **Stale copies outlive their source** (*from source*). Once a copy passes its TTL, the server still sends it and refreshes it in the background [N3 L384–400]. If the refresh fails, for example because Storage returns 400 for an expired token or a now-private file, Next keeps the old copy and stores it again for another TTL [N3 L517–604, N1 L505–509]. The docs agree: "There is no mechanism to invalidate the cache at this time"; the only fix is to change the URL or delete `<distDir>/cache/images` [N8, `minimumCacheTTL`]. So an optimized copy can outlive both the token and an unpublish, for anyone who requests the same `/_next/image` URL.
- **Every refresh re-downloads the whole original.** The fetch isn't conditional; the ETag only skips re-encoding [N1 fetchExternalImage L788+, N2 get-previously-cached-image-or-null.ts].
- **Disk use:** the cache is an LRU that defaults to 50% of the disk space free at startup [N8, `maximumDiskCacheSize`].
- **Custom loader:** a synchronous function `({src, width, quality}) => url` [N8]. It can't await `createSignedUrl`. Setting `images.loader: 'custom'` globally makes `/_next/image` return 404 [N4 L1059], which turns off optimization for *every* image in the app, About Us included. A per-image `loader` prop doesn't. A loader that ignores `width` triggers a warning [N7 get-img-props.ts L594–607].
- **`unoptimized`:** `src` is used as-is, with no `srcset`, no loader and no remote-pattern check [N7 get-img-props.ts L228–252].
- **Local images:** when `localPatterns` is unset, every local path is allowed [N5 match-local-pattern.ts L21–26]. The optimizer fetches a local path in-process, through the app's own request handler, and accepts only a 2xx response; it doesn't follow redirects [N1 fetchInternalImage L938–1023]. Local paths *with* a query string need `localPatterns.search` in Next 16 [N9].
- **Local IP addresses:** by default the optimizer refuses to fetch remote URLs that resolve to a local IP (`dangerouslyAllowLocalIP: false`) [N9, N1 L796–830]. Remote-URL options therefore won't optimize images from a local Supabase at `127.0.0.1` without that flag.

## Options

Assumptions for the numbers. These are estimates, not measurements:

- An average stored image is about 200 KB (1280 px WebP; the cap is 2 MB). **Unverified.**
- Each image is optimized at about 2 widths (1× and 2× screens).
- The Events list shows 10 cards. An Event page shows the cover and 20 Gallery photos (21 images).
- Every page also makes the same PostgREST query, so it is left out of the request counts below.

### 1. Signed URLs with `next/image`

Add a remote pattern for `/storage/v1/object/sign/event-media/**` with no `search`. Sign with `createSignedUrls` (one call per page) and pass the URLs to `<Image>`.

There are two very different ways to run it:

- **1a. Sign on every request** (the current client-side Events page, or a dynamic server render). Every view gets new tokens, and therefore:
  - **Caching:** no optimizer, browser or CDN hits across views.
  - **Requests:** each view makes 1 signing POST, then 10 (list) or 21 (Event) `/_next/image` requests. Each one is a cache miss: a full download from Supabase plus a resize on our server.
  - **Egress:** about 2 MB per list view and about 4.2 MB per Event-page view. That is around 1,200 Event-page views a month before the 5 GB runs out.
  - The disk cache also fills with entries that are never reused, until the LRU evicts them.
- **1b. Reuse each signed URL for days.** A server-side read module memoizes the URL for each path, for example signing for 7 days and re-signing when less than 2 days remain. Alternatively, sign inside a cached server render.
  - **Caching:** the optimizer key stays the same between re-signings, so copies are shared by all visitors.
  - **Supabase egress per month** is roughly (images viewed) × 2 widths × (30 days ÷ TTL) × 200 KB, whatever the number of visitors. With the default 4-hour TTL, a page viewed around the clock costs 31 images × 2 × 180 × 0.2 MB ≈ 2.2 GB. With `minimumCacheTTL` raised to 7 days it is ≈ 55 MB. Raising it changes the TTL for every image in the app, because signed responses send no `max-age` of their own.
- **How long the URLs should last.** At least as long as any HTML containing them can be reused (the page's cache window), plus the time a visitor keeps the page open. Otherwise a new screen width, needing a new optimizer entry, gets a broken image. Example: re-sign at 2 days left, `expiresIn` of 7 days, and a page cache window of an hour or less.
- **Drafts and unpublishing.** Drafts stay private, because signing is checked against RLS. After an Event is unpublished, anyone holding a URL can still download from Supabase until it expires (up to 7 days in the example). Moving or renaming the files cuts that off [D1]. Our optimizer may keep serving its copy beyond that (see "Stale copies outlive their source").
- **What callers get:** ready-to-use URLs from an async call, for example `signEventImages(paths) → Map<path, url>`. The expiry is a hidden rule that leaks to every caller: never cache the HTML longer than the token lives. That makes this a **shallow** interface.

### 2. Supabase image transformations

- **Not available on the Free Plan** [D7, D11]. On Pro ($25 a month), Supabase resizes and serves WebP from its CDN. This fits a public bucket with a custom loader best.
- **With a private bucket**, every size of every image needs its own signing call, because batch signing has no transforms: 21 to 42 POSTs to render one Event page. A synchronous loader can't do this, so the sizes must be signed ahead of time on the server.
- **Cost:** 100 origin images per cycle are included, then $5 per 1,000. About 210 new images a year fits that.
- **Drafts:** same as signed URLs.
- **What callers get:** ready-to-use URLs, one per size.

### 3. A custom `next/image` loader

- A loader only builds a URL string. It is a building block, not a way to get access. It can point at a Supabase transform URL (Pro, public bucket), at another image service, or at our own route with a width parameter (which means re-implementing the optimizer).
- Setting it globally turns off `/_next/image` for the whole app [N4 L1059]. As a per-image prop it doesn't.
- With signed URLs, a loader can't add the width, because the transform is inside the token. All it could do is hand back the signed URL unchanged, which is `unoptimized` with extra steps.
- Caching, cost and privacy are those of whatever URL it builds.
- **What callers get:** paths. The loader composes the URLs.

### 4. Signed URLs with `unoptimized` (or a plain `<img>`)

- **Setup:** no config change; this works today. The browser downloads the original straight from Supabase.
- **Caching:** the browser keeps each file until its token expires, using the `Expires` header (*from source*). There is no optimizer, so no CPU on our server, and full-size 1280 px originals are sent even for small cards. The Basic CDN behaviour is unverified.
- **Requests:** 1 signing POST, then 10 or 21 direct downloads from Supabase.
- **Egress** is paid per visitor cache miss: about 2 MB per list view and 4.2 MB per Event-page view, the same as 1a. The 5 GB is at risk if an Event draws a few hundred people who each open the Gallery a couple of times.
- **Drafts:** as in option 1. After an unpublish, nothing of ours keeps a copy, apart from visitors' own browser caches.
- **What callers get:** ready-to-use URLs, and the same expiry rule as option 1.
- **Best use:** the admin panel's draft previews, where only a few Administrators look and nothing should be cached.

### 5. A public bucket for published media, drafts kept private

- **How it works:** uploads go to the private `event-media`. Publishing copies the files to a public bucket (copying across buckets needs `select` on the source and `insert` on the destination [D13]). Unpublishing or archiving deletes them from the public bucket.
- **Caching:** the best of any option. URLs are stable; the Basic CDN caches public objects [D2]; the optimizer and browsers reuse their copies. The existing remote pattern already covers it, so `next.config.js` doesn't change.
- **Cost:** for one page, about the same number of refreshes as 1b or 6. They go through the CDN, so most count against the separate 5 GB cached-egress quota.
- **Requests:** no signing, then 10 or 21 `/_next/image` requests that reach the CDN only on misses.
- **Drafts:** they never reach the public bucket. An insert policy on the public bucket can require the Event to be published. **But unpublishing depends on app code deleting the copies.** The database can't do it, because only the Storage API removes a file's contents (README). That moves F9's guarantee out of RLS, against AGENTS.md ("RLS policies are the only real protection").
- **After an unpublish:** the deleted files can stay in the Basic CDN for up to their `cacheControl` age, and there is no purge on Free [D5]. Browsers and our optimizer keep their copies too.
- **Write side:** publish and unpublish each become N-file operations across two buckets that can fail halfway. The 21-file cap, the delete guard and `event_media_owner` would all have to cover both buckets. Finding 1 already says the write side is shallow, and this widens it.
- **What callers get:** ready-to-use URLs from a synchronous call (`getPublicUrl`), which is deep on the read side.
- **A variant:** one public bucket with unguessable file names. It treats every path as a URL that never expires, which F9 already rejected.

### 6. Not in the ticket: a same-origin image route over the private bucket

- **How it works:** a route handler such as `GET /events/media/[...path]` checks the path has the shape `<uuid>/<file>`. It reads the file with a server-side anon client, `storage.from('event-media').download(path)`. That calls the authenticated endpoint, which applies RLS as the caller [J1 L748–755, S6 L48–78]. The route then streams the bytes with `Cache-Control: public, max-age=604800`, or answers 404 with `no-store`. Pages render `<Image src="/events/media/<event id>/<file>">`. This is a local image, so `localPatterns` being unset means **no config change** [N5].
- **Caching:** URLs are stable, so the optimizer copy is shared by all visitors. The route's `max-age` sets the optimizer TTL for these images only (the larger of `minimumCacheTTL` and the upstream value [N2]); the global setting stays as it is.
- **Cost:** about the same as 1b with a 7-day TTL (≈ 55 MB a month for a page viewed around the clock), and it doesn't depend on the number of visitors. Our server does the resizing, as with any `next/image` option.
- **Requests:** no signing, then 10 or 21 `/_next/image` requests. Each optimizer miss makes one in-process call to the route and one download from Supabase.
- **Drafts:** RLS is checked on every download from Supabase; the anon role never sees a draft.
- **After an unpublish:** the route starts answering 404 straight away. Copies can remain in three places:
  - the Supabase CDN, for the authenticated endpoint: until the file's `cacheControl` age (1 hour by default) on Smart CDN; unknown on Basic [D3];
  - browsers that already loaded the image: up to the 7-day `max-age`;
  - our optimizer, as in every `next/image` option.
- **What callers get:** a stable path from a pure, synchronous function, `eventImageSrc(path) → '/events/media/' + path`. It works in server and client components. There are no tokens, no expiry, no batching and no network call while rendering. The RLS check, cache headers and egress all sit behind the route. That is a **deep module**, and the route is a natural **seam** for tests: published → 200, draft → 404, bad path → 404.
- **Costs to accept:**
  - About 25 lines of route code to own.
  - Anyone can hit the route directly, and every miss costs a Supabase download. Watch usage, and put a cache in front if it ever gets abused. Our server can be rate-limited, which a Supabase URL can't.
  - With a long TTL, replacing a file *at the same path* shows the old image until the TTL runs out. Either give replaced files new names (this affects the admin-steps ticket; the README currently says to upsert at the same path) or shorten the TTL.

## What stays reachable after an Event is unpublished

| Layer | Signed URLs (1, 4) | Public bucket (5) | Same-origin route (6) |
| --- | --- | --- | --- |
| Supabase origin | Every issued URL works until it expires | Until the app deletes the copy | Stops at once (RLS) |
| Supabase CDN (Basic) | Unknown; on Smart CDN, until the cache age runs out even after the token expires [D3] | Until the `cacheControl` age; no purge on Free | Unknown; on Smart CDN, until the `cacheControl` age (1 hour by default) [D3] |
| Our `next/image` cache (1, 5, 6) | Kept as long as someone keeps requesting that `/_next/image` URL; a new container clears it | Same | Same |
| Visitors' browsers | Until `Expires` (4) or the optimizer's `max-age` (1) | Up to the optimizer's `max-age` | Up to the route's `max-age` |

Unpublishing never instantly removes an image that was once public, whichever option is picked. F9 is about drafts, which no option exposes. If a published image must disappear fast, you also have to delete or rename the file and redeploy (or clear `.next/cache/images`).

## Comparison

| | 1a Signed per request + `next/image` | 1b Signed and reused + `next/image` | 2 Supabase transforms | 3 Custom loader | 4 Signed + `unoptimized` | 5 Public bucket for published | 6 Same-origin route |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Works on Free | Yes | Yes | **No** (Pro) | Building block only | Yes | Yes | Yes |
| Config change | Add a `/object/sign/**` pattern | Add a `/object/sign/**` pattern | Loader + Pro | Loader | None | None | None |
| Optimizer / CDN reuse | None across views | Until re-signing | Supabase CDN | Depends | Browser until expiry | Best | Shared, stable |
| Supabase egress, busy page | Per visitor (≈ 4 MB a view) | Per refresh (≈ 55 MB a month at a 7-day TTL) | Per CDN miss | Depends | Per visitor (≈ 4 MB a view) | Per refresh, mostly cached egress | Per refresh (≈ 55 MB a month) |
| Requests to render (list / Event) | 1 sign + 10 / 21, each a miss | 0–1 sign + 10 / 21 | 10–21 / 21–42 signs | — | 1 sign + 10 / 21 direct | 10 / 21 | 10 / 21 |
| Drafts private | Yes (RLS at signing) | Yes | Yes | — | Yes | Yes, if the copy step is right | Yes (RLS on every download) |
| Unpublish cuts access | When URLs expire | When URLs expire | When URLs expire | — | When URLs expire | When the app deletes the copies | At once at the origin |
| Callers get | URLs that expire | URLs that expire | One URL per size | Paths | URLs that expire | Stable URLs | Stable paths |
| Write side | Unchanged | Unchanged | Unchanged | Unchanged | Unchanged | Copy / delete steps across 2 buckets | Replaced files get new names |
| Interface depth | Shallow | Shallow | Shallow | — | Shallow | Deep read, wider write | Deep |

## Recommendation

**Option 6:** keep `event-media` private and add one same-origin image route. Feed it to `next/image` as a local image.

- Read module: `eventImageSrc(path)` builds the path. The route is the only code that talks to Storage for public pages.
- Route: answers with `Cache-Control: public, max-age=604800` when the file is found, and 404 with `no-store` when it isn't.
- `next.config.js` doesn't change. Adding `localPatterns` later is optional; if you do, list the existing local image folders too.
- Admin panel: preview drafts with `createSignedUrl` (short expiry) and `unoptimized`. Only Administrators look, and no shared cache is involved.
- README: replace "show images with `createSignedUrl()`" with the route. Tell the admin-steps ticket that replaced images need new file names (or the route needs a shorter `max-age`).

**Runner-up:** 1b (signed URLs reused for days, behind a server-side read module), if the team would rather not own a route. It needs the `/object/sign/event-media/**` remote pattern and a raised `minimumCacheTTL` (which applies to the whole app). Callers must also never cache the HTML longer than the tokens last.

**Avoid:**

- 1a: every view re-downloads every image.
- 2: not on Free.
- 3 on its own: it doesn't solve access.
- 4 for public pages: egress grows with visitors.
- 5: privacy moves out of RLS, and the write side grows.

### Check before building

1. On the real project, `curl -sI` a signed URL and an authenticated download. Record `Cache-Control`, `Expires` and `cf-cache-status`, then run the edge-log query in [D6] to see whether the Basic CDN caches either one.
2. Measure real file sizes after the browser shrinks them, and redo the egress numbers.
3. On a production build with `minimumCacheTTL: 60`, request `/_next/image` for a route image, make the route return 404, wait a minute and request it again. This confirms whether the stale copy really stays.

## Sources

Read on 2026-11-23.

**Supabase docs**

- [D1] Serving assets from Storage: <https://supabase.com/docs/guides/storage/serving/downloads>
- [D2] Storage CDN: <https://supabase.com/docs/guides/storage/cdn/fundamentals>
- [D3] Smart CDN: <https://supabase.com/docs/guides/storage/cdn/smart-cdn>
- [D4] URL signing keys: <https://supabase.com/docs/guides/storage/security/signing-keys>
- [D5] Purge CDN cache: <https://supabase.com/docs/guides/storage/cdn/purge-cdn-cache>
- [D6] Cache metrics: <https://supabase.com/docs/guides/storage/cdn/metrics>
- [D7] Storage image transformations: <https://supabase.com/docs/guides/storage/serving/image-transformations>
- [D8] Manage Storage Image Transformations usage: <https://supabase.com/docs/guides/platform/manage-your-usage/storage-image-transformations>
- [D9] Manage Egress usage: <https://supabase.com/docs/guides/platform/manage-your-usage/egress>
- [D10] Storage pricing: <https://supabase.com/docs/guides/storage/management/pricing>
- [D11] Pricing page (rows: Egress, Cached Egress, Content Delivery Network, Image Transformations): <https://supabase.com/pricing>
- [D12] Storage buckets: <https://supabase.com/docs/guides/storage/buckets/fundamentals>
- [D13] Copy and move objects: <https://supabase.com/docs/guides/storage/management/copy-move-objects>

**Storage API source:** [`supabase/storage`](https://github.com/supabase/storage) at tag `v1.98.5` (released 2026-11-20).

- [S1] [`src/http/routes/object/getSignedURL.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/http/routes/object/getSignedURL.ts#L72-L90)
- [S2] [`src/http/routes/object/getSignedObject.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/http/routes/object/getSignedObject.ts#L60-L82)
- [S3] [`src/storage/object.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/storage/object.ts#L1861-L2049): `signObjectUrl`, `signObjectUrls`, `verifyObjectSignature`
- [S4] [`src/internal/auth/jwt.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/internal/auth/jwt.ts#L512-L567)
- [S5] [`src/storage/renderer/renderer.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/storage/renderer/renderer.ts#L130-L231)
- [S6] [`src/http/routes/object/getObject.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/http/routes/object/getObject.ts#L48-L78)
- [S7] [`src/http/routes/object/getPublicObject.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/http/routes/object/getPublicObject.ts)
- [S8] [`src/storage/limits.ts`](https://github.com/supabase/storage/blob/v1.98.5/src/storage/limits.ts#L18)

**storage-js:** [J1] [`packages/core/storage-js/src/packages/StorageFileApi.ts`](https://github.com/supabase/supabase-js/blob/v2.98.0/packages/core/storage-js/src/packages/StorageFileApi.ts) in `supabase/supabase-js` at tag `v2.98.0`, the version in `package-lock.json`.

**Next.js:** [`vercel/next.js`](https://github.com/vercel/next.js) at tag `v16.4.6`, the version in `package-lock.json`.

- [N1] [`packages/next/src/server/image-optimizer.ts`](https://github.com/vercel/next.js/blob/v16.4.6/packages/next/src/server/image-optimizer.ts)
- [N2] [`packages/next/src/server/image-optimizer/transform.ts`](https://github.com/vercel/next.js/blob/v16.4.6/packages/next/src/server/image-optimizer/transform.ts#L204-L207), [`get-max-age.ts`](https://github.com/vercel/next.js/blob/v16.4.6/packages/next/src/server/image-optimizer/get-max-age.ts), [`get-previously-cached-image-or-null.ts`](https://github.com/vercel/next.js/blob/v16.4.6/packages/next/src/server/image-optimizer/get-previously-cached-image-or-null.ts)
- [N3] [`packages/next/src/server/response-cache/index.ts`](https://github.com/vercel/next.js/blob/v16.4.6/packages/next/src/server/response-cache/index.ts#L384-L604)
- [N4] [`packages/next/src/server/next-server.ts`](https://github.com/vercel/next.js/blob/v16.4.6/packages/next/src/server/next-server.ts#L1059)
- [N5] [`packages/next/src/shared/lib/match-remote-pattern.ts`](https://github.com/vercel/next.js/blob/v16.4.6/packages/next/src/shared/lib/match-remote-pattern.ts), [`match-local-pattern.ts`](https://github.com/vercel/next.js/blob/v16.4.6/packages/next/src/shared/lib/match-local-pattern.ts)
- [N6] [`packages/next/src/shared/lib/image-config.ts`](https://github.com/vercel/next.js/blob/v16.4.6/packages/next/src/shared/lib/image-config.ts#L237-L262)
- [N7] [`packages/next/src/shared/lib/get-img-props.ts`](https://github.com/vercel/next.js/blob/v16.4.6/packages/next/src/shared/lib/get-img-props.ts), [`image-loader.ts`](https://github.com/vercel/next.js/blob/v16.4.6/packages/next/src/shared/lib/image-loader.ts)
- [N8] Image component reference: <https://nextjs.org/docs/app/api-reference/components/image> (repo: `docs/01-app/03-api-reference/02-components/image.mdx`)
- [N9] Upgrading to version 16, "`next/image` changes": <https://nextjs.org/docs/app/guides/upgrading/version-16>
- [N10] Self-hosting, "Image Optimization" and "Caching and ISR": <https://nextjs.org/docs/app/guides/self-hosting>

**This repo** at `6c209c4`: `gdgoc/supabase/migrations/20261120000500_event_media.sql`, `gdgoc/supabase/README.md`, `gdgoc/next.config.js`, `gdgoc/Dockerfile`, `gdgoc/package-lock.json`, `gdgoc/src/app/(main)/shop/page.tsx`, `gdgoc/src/app/(main)/events/page.tsx`, `docs/proposals/0001-freedom-wall-and-events.md` (F9).
