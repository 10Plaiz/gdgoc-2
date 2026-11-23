# Events read-side filtering under RLS

Research for issue #7 ("Can the public Events read side drop its performance rules?"), part of map #5. Sources read and plans measured on 2026-11-23.

## Question

Today, callers of `event_listings` must:

- add `publish_status = 'published'` so the partial indexes get used;
- filter years with a Philippine-time range on `starts_at` instead of filtering on `event_year`.

Both rules exist because, under RLS, Postgres only uses an index for leakproof operators. At about 10 Events a year (ADR-0001), are these rules worth what they cost callers, and what is the simplest read interface that stays correct and fast enough?

## Summary

1. **The leakproof rule is real.** Under RLS, Postgres uses a filter as an index condition, or runs it before the policy, only if no non-leakproof function receives a column. `event_year = 2026` calls `private.event_year()` and fails that test; a `starts_at` range passes.
2. **At realistic sizes the two rules save under 1 ms.** With 10 to 100 Events, every public query takes at most 1.4 ms of database time with or without them; the rules save at most 0.7 ms, against about 4 ms for a local PostgREST round trip. Past about 1,000 rows, the time goes to per-row SQL function calls, which the indexes don't remove.
3. **`publish_status = 'published'` is also a correctness rule.** RLS shows draft, unpublished and archived Events to Administrators, so an Administrator viewing a public list without that filter sees them.
4. **A published-only view with the literal filter built in makes the partial indexes match with no caller rule.** This holds even for generic plans of PostgREST's prepared statements. Writing `private.is_public()` in the view instead doesn't match.
5. **A stored generated `event_year` column works and can be indexed under RLS.** The expression is immutable and `int4eq` is leakproof: 0.27 ms at 1,000 rows. It is an upgrade path, not needed at about 10 Events a year.

**Recommendation (details at the end):** give the public page one published-only view, let callers filter on `event_year`, and delete both rules from the README. The admin panel keeps reading `event_listings`.

## Setup and method

- **Stack:** the local Supabase CLI stack: `supabase/postgres:17.11.0.006` (PostgreSQL 17.11) and `supabase/postgrest:v14.13`, on Docker Desktop (WSL 2) on a Windows laptop. All six migrations are applied (branch HEAD `6c209c4`). The Free Plan runs on a shared-CPU Nano instance ([Supabase: Compute and disk](https://supabase.com/docs/guides/platform/compute-and-disk)), so absolute times there will differ. Compare the ratios, not the milliseconds.
- **Data:** every measurement ran inside `begin … rollback`. It deleted the 5 fake seed rows, then inserted N fake Events (`Sample Event n`). They are spaced about 10 a year, counting back from January 2027; 80% are published, the rest draft, unpublished or archived; four categories; each lasts 3 hours. 2026 has 10 of them, 8 published.
- **Role:** plans were checked as `anon` (`set local role anon; set local request.jwt.claims = '{"role":"anon"}'`), as `CODING_STANDARDS.md` requires, except where a comparison with `postgres` is the point.
- **Timing:** each query ran 11 times under `explain (analyze, timing off, buffers)`, and the tables report the median execution time. Queries go through `public.event_listings` with `select *`, so the times include computing the derived columns (`timing`, `status_label`, `registration_open`, `event_year`) for each returned row.
- **Statistics:** `public.events` had never been analyzed (`reltuples = -1`). For such a table the planner assumes at least 10 pages ([`tableam.c` L674–699](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/access/table/tableam.c#L674-L699)). A production table with about 10 Events stays in that state until autovacuum's thresholds are reached (`autovacuum_analyze_threshold` = 50 changed rows on this stack). Experiment E5 shows plans with real statistics, using a copy table created and analyzed inside a transaction.
- **Side effects:** no data was changed, and no test objects remain (`zz_%` relations: 0; `events`: the 5 seed rows). The rolled-back inserts left dead tuples, so autovacuum vacuumed `public.events` at 07:55 UTC. `pg_class` now records its true size (1 page, 5 rows) instead of "never vacuumed". Docker Desktop wasn't running after a reboot; starting it brought the stack back by itself.

## 1. How a supabase-js filter reaches the planner

1. **supabase-js.** postgrest-js turns `.eq('publish_status', 'published')` into the query-string parameter `publish_status=eq.published`. `gte` and `lt` work the same way: `this.url.searchParams.append(column, \`eq.${value}\`)` ([`PostgrestFilterBuilder.ts` L182–197, L372–376, L423–427](https://github.com/supabase/supabase-js/blob/v2.119.2/packages/core/postgrest-js/src/PostgrestFilterBuilder.ts#L182-L197), supabase-js v2.119.2).
2. **PostgREST writes SQL with bind parameters.** v14.13 renders each filter as `"public"."event_listings"."<column>" <op> $n` and sends the value as a bind parameter of type `unknown`, which Postgres resolves to the column's type ([`SqlFragment.hs` L390–391, L532–536](https://github.com/PostgREST/postgrest/blob/v14.13/src/PostgREST/Query/SqlFragment.hs#L390-L391): `unknownEncoder = SQL.encoderAndParam (HE.nonNullable HE.unknown)`). Statements are prepared by default: `db-prepared-statements` defaults to true ([`Config.hs` L268](https://github.com/PostgREST/postgrest/blob/v14.13/src/PostgREST/Config.hs#L268), [`MainTx.hs` L145](https://github.com/PostgREST/postgrest/blob/v14.13/src/PostgREST/MainTx.hs#L145), [PostgREST docs](https://docs.postgrest.org/en/v14/references/configuration.html#db-prepared-statements)), and the local stack doesn't override it.
3. **The statement it sends.** This is a real request to the local PostgREST as `anon`, as recorded by `pg_stat_statements`. That extension also replaces literals with `$n`, so the bind-parameter claim rests on the source above.

   ```sql
   WITH pgrst_source AS ( SELECT "public"."event_listings"."id", "public"."event_listings"."title", "public"."event_listings"."starts_at"
     FROM "public"."event_listings"
     WHERE "public"."event_listings"."publish_status" = $1 AND "public"."event_listings"."starts_at" >= $2 AND "public"."event_listings"."starts_at" < $3
     ORDER BY "public"."event_listings"."starts_at" DESC LIMIT $4 OFFSET $5 )
   SELECT $6::bigint AS total_result_set, pg_catalog.count(_postgrest_t) AS page_total, coalesce(json_agg(_postgrest_t), $7) AS body, …
   FROM ( SELECT * FROM pgrst_source ) _postgrest_t
   ```

   The CTE is referenced once and has no volatile functions, so Postgres folds it into the outer query ([docs: WITH queries](https://www.postgresql.org/docs/17/queries-with.html)). Explaining this exact shape as `anon` gives `Index Scan using events_published_by_start on events e` with `Index Cond` on `starts_at`, so the filters reach the table.
4. **The view is pulled up.** `event_listings` is a plain view: `security_invoker`, not `security_barrier`. The planner only refuses to flatten `security_barrier` views ([`prepjointree.c` L1703–1709](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/optimizer/prep/prepjointree.c#L1703-L1709)), so the caller's filters land on `events` next to the RLS policy. With `security_invoker`, "the policies and permissions of the invoking user are used instead, as if the base relations had been referenced directly from the query using the view" ([docs: CREATE VIEW](https://www.postgresql.org/docs/17/sql-createview.html)).
5. **Security levels.** The rewriter adds the policy to the table's `securityQuals` ([`rowsecurity.c` L98–111, L750–774](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/rewrite/rowsecurity.c#L98-L111)). The planner gives those clauses security level 0 and the caller's clauses a higher level ([`initsplan.c` L1258–1310](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/optimizer/plan/initsplan.c#L1258-L1310), [`planner.c` L799–801](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/optimizer/plan/planner.c#L799-L801)).
6. **Custom and generic plans.** In a custom plan, Postgres replaces each `$n` with its value before planning: protocol parameters are marked `PARAM_FLAG_CONST` ([`postgres.c` L1969–1973](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/tcop/postgres.c#L1969-L1973)) and folded into constants ([`clauses.c` L2495–2500](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/optimizer/util/clauses.c#L2495-L2500)). A generic plan keeps `$n`. Postgres uses custom plans for the first 5 executions, then the generic plan whenever its estimated cost is below the average custom plan's ([`plancache.c` L1054–1100](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/utils/cache/plancache.c#L1054-L1100), [docs: PREPARE](https://www.postgresql.org/docs/17/sql-prepare.html)).

## 2. The leakproof rule, confirmed

**Docs.** "Functions and operators marked by the system (or the system administrator) as LEAKPROOF may be evaluated before policy expressions" ([CREATE POLICY](https://www.postgresql.org/docs/17/sql-createpolicy.html)). "The system will enforce conditions from security policies and security barrier views before any user-supplied conditions from the query itself that contain non-leakproof functions" ([CREATE FUNCTION](https://www.postgresql.org/docs/17/sql-createfunction.html)); see also [RLS](https://www.postgresql.org/docs/17/ddl-rowsecurity.html) and [Rules and privileges](https://www.postgresql.org/docs/17/rules-privileges.html). Only a superuser can mark a function `LEAKPROOF`, so the project can't mark its own helpers.

**Source (PostgreSQL 17.11):**

- A clause above security level 0 counts as leakproof only if `!contain_leaked_vars(clause)` ([`restrictinfo.c` L138–146](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/optimizer/util/restrictinfo.c#L138-L146)). `contain_leaked_vars` returns true when any non-leakproof function or operator has a column beneath it ([`clauses.c` L1255–1330](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/optimizer/util/clauses.c#L1255-L1330)). So `int4eq(event_year_column, 2026)` is leakproof, but `int4eq(private.event_year(starts_at), 2026)` is not, because the inner function receives `starts_at`.
- A clause may move ahead of the policy only if it is leakproof (or nothing at a lower level must run first) ([`restrictinfo.c` L431–443](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/optimizer/util/restrictinfo.c#L431-L443)). A clause that can't move is never an index condition ([`indxpath.c` L2100–2105](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/optimizer/path/indxpath.c#L2100-L2105)). In a filter, a cheap leakproof clause is sorted to level 0, so it runs before the policy ([`createplan.c` L5316, L5362](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/optimizer/plan/createplan.c#L5316-L5370)).
- **Partial-index matching has no security check.** `check_index_predicates` proves a partial index usable from all of the table's restriction clauses ([`indxpath.c` L3244–3378](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/optimizer/path/indxpath.c#L3244-L3378)). The match must be literal ("the predicate condition must exactly match part of the query's WHERE condition"), and "parameterized query clauses do not work with a partial index" ([docs: partial indexes](https://www.postgresql.org/docs/17/indexes-partial.html)). The policy can't prove `publish_status = 'published'` by itself, because of its `or (select private.is_admin())` branch.

**Catalog** (`pg_proc` on the local stack, matching [`pg_proc.dat`](https://github.com/postgres/postgres/blob/REL_17_11/src/include/catalog/pg_proc.dat#L160-L168); the defaults are `provolatile = i` and `proleakproof = f`, [`pg_proc.h` L65, L74](https://github.com/postgres/postgres/blob/REL_17_11/src/include/catalog/pg_proc.h#L65-L74)):

| Function | Used by | Volatility | Leakproof |
|---|---|---|---|
| `int4eq(int4, int4)` | `event_year = 2026` on a stored column | immutable | **yes** |
| `texteq(text, text)` | `publish_status = 'published'`, `category = …` | immutable | **yes** |
| `timestamptz_ge`, `timestamptz_lt` | the Philippine-time range | immutable | **yes** |
| `timezone(text, timestamptz)` | `starts_at at time zone 'Asia/Manila'` | immutable | no |
| `extract(text, timestamp)` | `extract(year from …)` | immutable | no |
| `int4(numeric)` | `::integer` | immutable | no |
| `texticlike(text, text)` | `title ilike …` | immutable | no |
| `private.event_year`, `private.is_public`, `private.event_timing` | the view and the policy | immutable | no |
| `private.is_admin()` | the policy | stable | no |

**Measured (E1).** An expression index `on events (private.event_year(starts_at)) where publish_status = 'published'`, 1,000 rows, `enable_seqscan = off`, query `select id from event_listings where event_year = 2026 and publish_status = 'published'`:

```text
-- as postgres (bypasses RLS)
Index Scan using zz_events_year_expr on events e
  Index Cond: (private.event_year(starts_at) = 2026)

-- as anon
Bitmap Heap Scan on events e
  Recheck Cond: (publish_status = 'published'::text)
  Filter: ((private.is_public(publish_status) OR (InitPlan 1).col1) AND (private.event_year(starts_at) = 2026))
  ->  Bitmap Index Scan on zz_events_year_expr
```

As `anon` the index only lists the published rows (its predicate); the year runs as a filter after the policy. With `explain (verbose)`, the range's leakproof clauses run first and the policy second, while `event_year = 2026` runs after the policy.

A precision for `CODING_STANDARDS.md` ("an index only for leakproof comparisons"): what matters is whether a non-leakproof *function receives a column*. Integer equality on a stored column is fine. The same equality on the result of `private.event_year(starts_at)` is not.

## 3. What the two rules buy, measured

**Database execution time** in ms (median of 11 runs; the planner's default choice; never-analyzed table, as in production), as `anon` through `event_listings`. "+pub" adds `publish_status = 'published'`.

| Query (public page) | 10 rows | 100 rows | 1,000 rows | 10,000 rows |
|---|---:|---:|---:|---:|
| Coming Soon: `timing in ('upcoming','ongoing')` | 0.50 | 1.39 | 7.04 | 61.5 |
| Coming Soon +pub | 0.34 | 1.04 | 5.93 | 54.6 |
| Previous by category: `timing = 'completed' and category = …` limit 12 | 0.27 | 1.17 | 2.76 | 16.8 |
| Previous by category +pub | 0.23 | 0.81 | 0.73 | 0.63 |
| Year as Philippine-time range on `starts_at` | 0.81 | 0.81 | 0.74 | 1.88 |
| Year as range +pub (today's rules) | 0.66 | 0.62 | 0.47 | 0.47 |
| Year as `event_year = 2026` | 1.07 | 1.35 | 6.07 | 53.9 |
| Year as `event_year = 2026` +pub | 0.65 | 1.13 | 5.45 | 49.9 |

Planning took 0.05–0.15 ms in every case. A full request to the local PostgREST, made directly inside the Docker network (no Kong, TLS or internet), took a median of 4.0 ms over 25 requests (`select=*&event_year=eq.2026`, 5 seed rows).

**Plans:**

- **Without `publish_status = 'published'`,** every query is a `Seq Scan`, even with `enable_seqscan = off`: no index is usable, because the partial predicate isn't implied.
- **With it,** the partial indexes are used. `Previous by category +pub` uses `Index Scan using events_published_by_category` and stops after 12 rows, which is why it stays flat. The range uses `Index Scan using events_published_by_start` with an `Index Cond`.
- **Coming Soon +pub and `event_year` +pub at 1,000+ rows** use a `Bitmap Index Scan` on a partial index only as a list of published rows. Their real filter can't be an index condition.
- **A sequential scan itself is cheap.** Forcing one for the range +pub gives 0.65 / 0.71 / 0.57 / 1.76 ms at 10 / 100 / 1,000 / 10,000 rows, against 0.58 / 0.72 / 0.46 / 0.49 ms with the index.

**Reading:** at 10 to 100 rows, the two rules together save at most 0.7 ms (the year query at 100 rows: 1.35 ms down to 0.62 ms). At 1,000 rows (a century of Events at today's pace), the publish filter matters for the limited category list (0.73 vs 2.76 ms) and the range matters against `event_year` (0.74 vs 6.07 ms). Coming Soon is slow either way.

### Where the time actually goes: per-row function calls (E4)

10,000 rows, forced sequential scan, as `postgres` (no RLS), `select count(*) … where <filter>`:

| Filter | ms | Cost per row above a plain scan |
|---|---:|---:|
| PHT range on `starts_at` | 0.93 | – |
| `publish_status = 'published'` (literal) | 1.66 | – |
| `extract(year from starts_at at time zone 'Asia/Manila')::integer = 2026` (inline) | 4.82 | ≈ 0.4 µs |
| `private.is_public(publish_status)` | 29.08 | ≈ 2.7 µs |
| `private.event_year(starts_at) = 2026` | 35.30 | ≈ 3.4 µs |
| `private.event_timing(e, now()) = 'completed'` | 41.24 | ≈ 4.0 µs |

A SQL function with a `SET` clause is never inlined ([`clauses.c` L4561–4597](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/optimizer/util/clauses.c#L4590-L4597): `inline_function` gives up when `proconfig` is set). `CODING_STANDARDS.md` requires `set search_path = ''` on every function, so each helper is a real call, and that includes `private.is_public()` inside the RLS policy. This explains the 1,000-row numbers above. It doesn't matter at this table's size, but if an Events list ever gets slow, look here before adding indexes.

### With real statistics (E5)

A copy of `events` (same columns, constraints, partial indexes and policy), analyzed inside the transaction. Queries hit the table directly, so there are no derived columns and the times are lower.

| Rows | range +pub | range | category +pub, limit 12 | category, limit 12 |
|---:|---|---|---|---|
| 10 | Seq Scan, 0.05 ms | Seq Scan, 0.13 ms | Seq Scan, 0.03 ms | Seq Scan, 0.10 ms |
| 100 | Bitmap Index Scan, 0.06 ms | Seq Scan, 0.14 ms | Bitmap Index Scan, 0.09 ms | Seq Scan, 0.18 ms |
| 1,000 | Index Scan, 0.05 ms | Seq Scan, 0.25 ms | Index Scan, 0.06 ms | Seq Scan, 0.83 ms |

At 10 rows, once the table is analyzed, the planner ignores the index even when the caller adds the filter.

### Prepared statements (part of E3)

As `anon`, 1,000 rows, `enable_seqscan = off`, with `prepare p(text, timestamptz, timestamptz) as select id from event_listings where publish_status = $1 and starts_at >= $2 and starts_at < $3 …`:

- **Custom plan:** `Index Scan using events_published_by_start`. The value is substituted, so the predicate matches.
- **Generic plan:** `Seq Scan … Filter: (… (publish_status = $1) …)`. The partial index can't be proven from `$1`.
- **`plan_cache_mode = auto`** (the default) with sequential scans allowed, after 7 executions: still the custom plan (`custom_plans = 9`, `generic_plans = 1`, the 1 being the forced explain). The generic plan was costed higher, so the auto rule kept replanning.

So the caller's `.eq('publish_status', 'published')` only helps while Postgres plans with the value. That holds in practice whenever the index matters.

## 4. The year: computed, Philippine-time range, or stored generated column

**Is the expression immutable?** Yes. `timezone(text, timestamptz)`, `extract(text, timestamp)` and `int4(numeric)` are all `provolatile = 'i'` (table above; [`pg_proc.dat` L2319–2321](https://github.com/postgres/postgres/blob/REL_17_11/src/include/catalog/pg_proc.dat#L2319-L2321) has no `provolatile`, so it takes the default `i`). The variant without an explicit zone is `stable`.

**Can a stored generated column use it?** Yes. "The generation expression can only use immutable functions" ([docs: generated columns](https://www.postgresql.org/docs/17/ddl-generated-columns.html)), enforced by `contain_mutable_functions_after_planning` ([`heap.c` L2862–2866](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/catalog/heap.c#L2862-L2866)). Measured:

- `alter table public.events add column starts_year integer generated always as (extract(year from starts_at at time zone 'Asia/Manila')::integer) stored` is accepted. On 1,000 rows it matches `private.event_year(starts_at)` everywhere (0 mismatches). A generated column calling `private.event_year(starts_at)` (declared immutable) is accepted too.
- Boundaries: `2026-12-31T16:30Z` gives 2027, `2026-12-31T15:59:59Z` gives 2026, and `2026-01-01T00:00+08` gives 2026.
- **Caveat:** Postgres marks `timezone(text, timestamptz)` immutable even though it reads the time zone database. A tzdata change to Asia/Manila would not rewrite stored values until each row is updated. In this server's tz data, Asia/Manila has been UTC+8 since 28 July 1990 (+9 at times between 1977 and 1990).

**Is an index on it used through the `security_invoker` view as `anon`?** Yes (E2). There is a plain index on `starts_year` and a test view `select e.*, private.event_timing(e, now()) as timing from events e` with `security_invoker`. As `anon`, with no `publish_status` filter:

```text
Bitmap Heap Scan on events e
  Recheck Cond: (starts_year = 2026)
  Filter: (private.is_public(publish_status) OR (InitPlan 1).col1)
  ->  Bitmap Index Scan on zz_events_starts_year
        Index Cond: (starts_year = 2026)
```

That takes 0.27 ms at 1,000 rows, against 6.07 ms for today's computed `event_year`. Part of the gap is that the test view computes fewer derived columns.

**The Philippine-time range rule has its own risk.** The caller must write the `+08:00` offset. The database time zone is UTC on this stack, and PostgREST returns timestamps as `+00:00`. A caller who writes `starts_at=gte.2026-01-01` without an offset gets midnight UTC, which is 08:00 in Manila, so Events starting between 00:00 and 07:59 on 1 January land in the wrong year. The rule pushes the Philippine-time rule into every caller, which is what ADR-0004 and `event_listings` exist to avoid.

**Trade-off of a generated column:** `CODING_STANDARDS.md` says "never store what can be derived". A generated column is derived by the database on every write and can't drift, which meets the purpose of that rule, though not its letter. It also means recreating `event_listings`, which expands `e.*` once, when the view is created.

## 5. A published-only view

E3 adds a test view `select e.*, timing, event_year from events e where e.publish_status = 'published'`, with `security_invoker`. Queried as `anon` at 1,000 rows, with no `publish_status` filter from the caller:

```text
-- year as a range
Index Scan using events_published_by_start on events e
  Index Cond: ((starts_at >= '2025-12-31 16:00:00+00') AND (starts_at < '2026-12-31 16:00:00+00'))
  Filter: (private.is_public(publish_status) OR (InitPlan 1).col1)

-- Previous Events, category, limit 12
Limit
  ->  Index Scan using events_published_by_category on events e
        Index Cond: (category = 'workshop'::text)
        Filter: ((private.is_public(publish_status) OR (InitPlan 1).col1) AND (private.event_timing(e.*, now()) = 'completed'::text))

-- generic plan of a prepared statement on this view
Index Scan using events_published_by_start on events e
  Index Cond: ((starts_at >= $1) AND (starts_at < $2))
```

- **The view's filter is a literal in its definition,** so the partial indexes match in custom and generic plans alike.
- **The same view written with `where private.is_public(e.publish_status)` gets a `Seq Scan`.** The function isn't inlined (section 3), so the predicate can't be matched. The view must use the literal. `private.is_public()` keeps its role in policies and constraints, as the comment in `…_foundation.sql` already says for partial indexes.
- **Times at 1,000 rows:** range 0.28 ms, Previous by category 0.44 ms, Coming Soon 5.98 ms, `event_year = 2026` 5.21 ms. These are the same plan shapes as today's "+pub" queries, because the filter is the same, just written once.
- **The view should not be `security_barrier`.** A barrier view isn't flattened ([`prepjointree.c` L1703–1709](https://github.com/postgres/postgres/blob/REL_17_11/src/backend/optimizer/prep/prepjointree.c#L1703-L1709)), so plans could get worse. RLS on `events` is the protection; the view's filter only decides what the public page lists.

## 6. Correctness: Administrators see drafts

The select policy on `events` is `private.is_public(publish_status) or (select private.is_admin())`. For an Administrator, every Event passes. The README's "RLS already hides drafts" is true for visitors and Members only. An Administrator who opens the public Events page while signed in sees draft, unpublished and archived Events in Coming Soon and Previous Events, unless the query filters them out. So the `publish_status` rule can't simply be dropped; it has to move somewhere callers can't forget it.

## 7. Options compared, and a recommendation

| | A. Today: `event_listings` + 2 rules | B. Drop both rules | C. Published-only view, filter on `event_year` | D. C + stored generated `event_year` + index |
|---|---|---|---|---|
| Rules each public caller must know | 2 (publish filter, `+08:00` range) | 0 | 0 | 0 |
| Correct for an Administrator on the public page | only if the caller remembers the filter | **no** (shows drafts) | yes | yes |
| Partial indexes used | when the caller adds the filter and the plan is custom | never | always (literal in the view) | always |
| Year filter | range, index-backed; offset risk | `event_year`, a function per row | `event_year`, a function per row | `event_year`, index-backed |
| Measured, 100 rows | ≤ 1.1 ms | ≤ 1.4 ms | ≤ 1.2 ms (inferred from the "+pub" rows, which run the same plans) | not measured; ≤ C |
| Measured, 1,000 rows | 0.5–5.9 ms | 2.8–7.0 ms | 0.3–6.0 ms | year 0.27 ms; others as C |
| Schema change | none | none | one view | view, column, index; `event_listings` recreated |

**Recommendation: C.** Treat the Events read side as one module. Its interface for the public page becomes a single view, e.g. `published_event_listings`; the name is for the decision. It has ordinary columns and works with any supabase-js filter. Behind it sit the publish rule, the Event timing rule (ADR-0004), the Philippine year and whatever indexes exist. Callers no longer need to know about partial indexes, leakproof operators or time-zone offsets. That is a deeper module than today's, where the interface is a view plus two rules plus "`event_year` is for display only". The admin panel keeps reading `event_listings`, which shows all Events to Administrators through RLS.

**Deletion test:**

- Delete the two README rules: with C, nothing comes back in any caller. They were pure caller burden.
- Delete the published-only view: the publish filter comes back in every public caller, and forgetting it shows drafts to Administrators. The view earns its keep.
- Delete the two partial indexes: nothing measurable changes at 100 rows or fewer, and no caller changes either. Keeping them costs next to nothing, and the view uses them when they help. This choice no longer touches the interface.

**When to revisit:** move to D if Events approach the high hundreds or the year filter shows up in timings. Before adding indexes, look at the per-row cost of non-inlined helpers (section 3), which is what dominates at 1,000+ rows.

## Not verified

- **Hosted Supabase:** the PostgREST version and settings there. I read v14.13, the version the local CLI stack runs; filter encoding may differ in other versions.
- **Free Plan timings:** absolute times on the Free Plan's Nano instance.
- **hasql:** how it caches prepared statements across PostgREST's connection pool. The plan-choice rule above is Postgres's, per prepared statement.
- **Signed-in Administrators:** whether they will browse the public Events page while signed in. Section 6 assumes they can.

## Sources (all read 2026-11-23)

PostgreSQL 17 documentation:

- [CREATE POLICY](https://www.postgresql.org/docs/17/sql-createpolicy.html), [Row Security Policies](https://www.postgresql.org/docs/17/ddl-rowsecurity.html), [Rules and Privileges](https://www.postgresql.org/docs/17/rules-privileges.html)
- [CREATE FUNCTION](https://www.postgresql.org/docs/17/sql-createfunction.html), [Function Volatility Categories](https://www.postgresql.org/docs/17/xfunc-volatility.html)
- [CREATE VIEW](https://www.postgresql.org/docs/17/sql-createview.html), [Generated Columns](https://www.postgresql.org/docs/17/ddl-generated-columns.html), [Partial Indexes](https://www.postgresql.org/docs/17/indexes-partial.html)
- [PREPARE](https://www.postgresql.org/docs/17/sql-prepare.html), [plan_cache_mode](https://www.postgresql.org/docs/17/runtime-config-query.html), [WITH Queries](https://www.postgresql.org/docs/17/queries-with.html)

PostgreSQL source, tag [`REL_17_11`](https://github.com/postgres/postgres/tree/REL_17_11):

- `src/backend/optimizer/util/restrictinfo.c`, `src/backend/optimizer/util/clauses.c`
- `src/backend/optimizer/path/indxpath.c`, `src/backend/optimizer/plan/createplan.c`
- `src/backend/optimizer/plan/initsplan.c`, `src/backend/optimizer/plan/planner.c`, `src/backend/optimizer/prep/prepjointree.c`
- `src/backend/rewrite/rowsecurity.c`, `src/backend/utils/cache/plancache.c`, `src/backend/tcop/postgres.c`
- `src/backend/catalog/heap.c`, `src/backend/access/table/tableam.c`
- `src/include/catalog/pg_proc.dat`, `src/include/catalog/pg_proc.h`

PostgREST:

- Source at tag [`v14.13`](https://github.com/PostgREST/postgrest/tree/v14.13): `src/PostgREST/Query/SqlFragment.hs`, `src/PostgREST/Query/QueryBuilder.hs`, `src/PostgREST/MainTx.hs`, `src/PostgREST/Config.hs`
- Docs: [configuration: `db-prepared-statements`](https://docs.postgrest.org/en/v14/references/configuration.html#db-prepared-statements), [tables and views: horizontal filtering, index usage](https://docs.postgrest.org/en/v14/references/api/tables_views.html)

supabase-js, tag [`v2.119.2`](https://github.com/supabase/supabase-js/tree/v2.119.2): `packages/core/postgrest-js/src/PostgrestFilterBuilder.ts`.

Supabase docs:

- [Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security): "Views and RLS", "Expose a view safely"
- [RLS performance](https://supabase.com/docs/guides/database/postgres/row-level-security-performance): "Filter in the client query too", which recommends the duplicate filter for large tables. Option C keeps that filter, written once in the view.
- [Compute and disk](https://supabase.com/docs/guides/platform/compute-and-disk): the Free Plan is Nano, shared CPU.

Measurements: the local stack described in "Setup and method". All test data was fake and rolled back.
