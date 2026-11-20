# Proposal 0001: Freedom Wall, Events and the in-site CMS

**Status:** proposed, waiting for review by the Team Lead. Once issues are turned on, this spec moves to a GitHub issue and gets split into tickets.
**Covers:** plan items 6 (Freedom Wall), 7 (Stickers), 10 (Previous Events Quotes, partly; see Out of Scope) and the Events page redesign.
**Vocabulary:** terms in **bold** are defined in [`GLOSSARY.md`](../../GLOSSARY.md).
**Decision records:** [ADR-0001](../adr/0001-supabase-as-cms.md), [ADR-0002](../adr/0002-anonymous-submissions-store-author.md), [ADR-0003](../adr/0003-one-supabase-project.md).

## Problem Statement

- **Events are invisible to everyone else.** The Events page shows hardcoded events. A **Moderator** can "edit" them, but the edit is only saved in that browser's local storage, so nobody else sees it and it disappears when storage is cleared.
- **Content dies with the handoff.** No officer can maintain content across a yearly handoff without editing code.
- **The Freedom Wall doesn't exist yet.** Members have no moderated place to post community messages.
- **The data layer can't be rebuilt or trusted:**
  - The Supabase project the site uses is unreachable.
  - Its structure isn't recorded anywhere in the repo.
  - Members can grant themselves admin rights from the browser.

## Solution

**The CMS:** Supabase plus an `/admin` area inside the site. Moderators use it to:

- create, edit, publish and feature **Events**;
- review every **Submission** in one queue;
- grant or revoke the Moderator role.

**The Events page:** built to Mockup 1.

- A **Featured event** card that shows a countdown before the event and a recap after it.
- An Events grid filterable by **Event category**.
- **Upcoming** and **Past** events sorted automatically by date.

**The Freedom Wall:** signed-in **Members** post **Wall Posts**.

- Each post can have a background color, a category, an optional image and up to three **Stickers**, and can be **Anonymous**.
- A post becomes public only after a Moderator approves it.
- Members follow their Submissions on a "My submissions" page.

**Security:** the database enforces every rule.

## User Stories

### Members and the Freedom Wall

1. As a visitor, I want to read approved Wall Posts without signing in, so that I can see what the community is sharing.
2. As a visitor, I want to filter Wall Posts by category, so that I can find posts I care about.
3. As a Member, I want to write a Wall Post of up to 500 characters, so that I can share something with the chapter.
4. As a Member, I want to choose a background color from a fixed palette, so that my post stands out.
5. As a Member, I want to pick a category for my post, so that it's filed in the right place.
6. As a Member, I want to attach one image or GIF, so that I can express more than text.
7. As a Member, I want my image shrunk before upload, so that it posts quickly on mobile data.
8. As a Member, I want to add up to three GDGoC Stickers, so that my post feels on-brand.
9. As a Member, I want to post Anonymously, so that other Members don't see my name.
10. As a Member, I want the form to say plainly that Moderators can still see who wrote an Anonymous post, so that I understand what "anonymous" means here.
11. As a Member, I want to see that my post is pending review, so that I know it was received.
12. As a Member, I want a "My submissions" page showing each Submission's **Review status**, so that I know what happened to it.
13. As a Member, I want to see the reason when my Submission is rejected, so that I can post something acceptable next time.
14. As a Member, I want to delete my own Submission at any time, along with its image, so that I stay in control of what I've shared.
15. As a Member, I want to be stopped from having more than three pending Submissions, so that the queue stays fair. (This is a spam guard.)
16. As a Member, I want to be signed in to post, so that the wall stays free of spam bots.

### Moderators and the CMS

17. As a Moderator, I want one review queue holding all pending Submissions, so that nothing slips through.
18. As a Moderator, I want to approve a Submission, so that it becomes public.
19. As a Moderator, I want to reject a Submission with a reason, so that the author knows why.
20. As a Moderator, I want to remove an already approved Submission, so that I can take down something harmful after the fact.
21. As a Moderator, I want to see who wrote an Anonymous Submission, so that I can act on harassment.
22. As a Moderator, I want unapproved images to be visible only to me and the author, so that harmful images are never public.
23. As a Moderator, I want to create, edit and publish Events with a cover image, so that the Events page stays current without code changes.
24. As a Moderator, I want to mark an Event as a Featured event, so that it headlines the page.
25. As a Moderator, I want Events to become Upcoming or Past automatically from their start time, so that I never have to move them by hand.
26. As a Moderator, I want to grant and revoke the Moderator role in `/admin`, so that the yearly officer handoff needs no database access.
27. As a Moderator, I want `/admin` to refuse non-Moderators on the server, so that hiding a button isn't our only protection.

### Visitors and the Events page

28. As a visitor, I want to see the Featured event with a countdown and a Register button before it happens, so that I can sign up.
29. As a visitor, I want the Featured event to switch to a recap after it happens, so that the page never shows a stale "Coming Soon".
30. As a visitor, I want to filter Events by category (Workshop, Hackathon, Sprint, Talk, Social), so that I find the kind of event I like.
31. As a visitor, I want Upcoming events listed before Past events, so that the next thing to attend is easy to find.

### The chapter and future officers

32. As the Team Lead, I want every database change committed as a migration, so that the database can be rebuilt and every change reviewed.
33. As the Team Lead, I want the free project kept awake automatically, so that the site doesn't go down between semesters.
34. As the Team Lead, I want a weekly export of Events and CMS content (no member data), so that a lost project doesn't erase a year of events.
35. As a future officer, I want the decisions recorded as ADRs, so that I know why it was built this way before changing it.

## Implementation Decisions

**Architecture** (ADR-0001, ADR-0003)

- One Supabase project.
- Public-facing tables live in `public`, grouped into migration files by feature: events, wall and moderation.
- Internal helpers live in a `private` schema that the website's API never exposes: the `is_moderator()` check, the 30-day cleanup and the pending-limit check.
- Pages that read data are Server Components using a server Supabase client.
- Every write is a Server Action that runs as the signed-in user, so Row Level Security (RLS) always applies.
- A Next.js `proxy` refreshes the login session on every request. This connects the existing but unused auth middleware.
- `/admin` checks the Moderator role on the server.

**Moderation model** (shared by every Submission type)

- Every Submission table carries:
  - `status`: one of pending, approved, rejected or removed;
  - `reviewed_by`, `reviewed_at` and `rejection_reason`.
- Only Moderators can change `status`. A database rule enforces this, and Members can't set it on insert.
- A database rule limits each Member to 3 pending Submissions at a time.
- Rejected Submissions, and their images, are deleted after 30 days by a scheduled job.
- Removed Submissions are kept, but stay hidden.

**Anonymous** (ADR-0002)

- `author_id` is always stored.
- The public reads Submissions only through views, which return approved rows and blank out the author when `is_anonymous` is set.
- The underlying tables can be read only by the author and Moderators.
- No policy may ever give the public direct read access to those tables.

**Tables:**

- **events:** `title`, `summary`, `body`, `category`, `starts_at`, `ends_at`, `venue`, `cover_path`, `registration_url`, `is_featured`, `is_published`, plus timestamps.
  - Upcoming or Past is worked out from `starts_at` and is never stored.
  - `category` is one of Workshop, Hackathon, Sprint, Talk or Social.
- **wall_posts:** `author_id`, `body` (500 characters max), `background` (from a fixed palette), `category` (from a fixed list), an optional `image_path`, `stickers` (up to 3 codes from a fixed set), `is_anonymous`, plus the moderation columns.
- **event_quotes:** `event_id`, `author_id`, `body` (300 characters max), `is_anonymous`, plus the moderation columns. The table is created now, but the submission rules are still open (see Out of Scope).
- **Users (existing):** `is_admin` becomes the Moderator flag. Members can no longer set or change it. The first Moderator is created by the project owner with a one-time SQL command, which the setup guide documents.

**Storage** (Free Plan: 1 GB of files and 5 GB of downloads per month, shared across the organisation)

- `wall-media` is **private**. Images are readable by their author and Moderators, and by everyone once their post is approved.
- `event-images` is public, and only Moderators can upload to it.
- Uploads are limited to 2 MB of images. They're shrunk in the browser to WebP at about 1280 px wide.
- Stickers, palettes and categories are fixed lists in code, and the sticker art lives in the site's static files. None of it uses Supabase storage.

**Operations:**

- Development runs on a local Supabase (`supabase start`) with migrations under `supabase/migrations/`.
- A scheduled GitHub Action reads the database every few days to keep the project awake.
- A weekly GitHub Action exports Events and CMS content as a private workflow artifact. Member data is never included.

## Testing Decisions

- Good tests check behaviour you can observe from outside, such as "a non-Moderator can't approve", not internal details.
- **Database security rules** are tested directly with pgTAP (`supabase test db`) against the local Supabase. These are the highest-stakes tests: the anonymous author can never leak, Members can't approve or escalate themselves, the pending limit holds, and private images stay private.
- **Feature behaviour** is tested with Vitest by calling Server Actions against the local Supabase: submitting, deleting, reviewing, and creating and featuring Events.
- No UI tests in version 1. Checking the UI against the mockup is done by hand.
- There are no tests in the codebase yet. The first ticket sets up Vitest and pgTAP.

## Out of Scope

- **Waiting on the team:**
  - reactions, comments and editing after submitting;
  - who may submit Event Quotes, and when;
  - email notifications. The design allows adding them later with a database webhook and a free email service.
- **Postponed:** the "Propose an Event" form from Mockup 1.
- **Unchanged:** Officers and Products keep their current inline editing.

## Assumptions to verify (Team Lead)

1. The Supabase project the code points to is **paused, not deleted**. Its address doesn't resolve at all. Free projects pause after about a week without activity and can be restored for about 90 days.
2. `is_admin` is currently set **only by hand** in the dashboard, and nobody depends on setting it any other way.
3. **Mockup 1** (the hero, the featured countdown, the categorised grid) is the target Events design.
4. The current RLS policies on `Users`, `Officers` and `Products` are unknown, because nothing about them is recorded in the repo. This proposal assumes they need to be redone as migrations.
5. The chapter stays on the Supabase **Free Plan**.
6. The team plan in `resource/documentation/` (now with names removed) is fine to publish in this public repo.

## Findings (existing bugs and risks)

| # | Finding | Evidence | Severity |
|---|---|---|---|
| F1 | Members can make themselves admin | Sign-up inserts `is_admin` from the browser using the public key. Only RLS, which isn't recorded anywhere, could stop a crafted request. | High |
| F2 | All admin writes rely on the browser | Edits to Officers, Products and their ordering run in the browser. `isAdmin` only hides the buttons. | High (depends on RLS) |
| F3 | Auth middleware is never connected | `utils/supabase/middleware.ts` isn't imported by any `middleware`/`proxy` entry, so `/admin` has no server-side guard. | Medium |
| F4 | Docker builds could include secrets | `.dockerignore` didn't exclude `.env*`, and the Dockerfile copies the whole folder. **Fixed in this PR.** | Medium |
| F5 | Event edits only save locally | The Events page keeps admin edits in each browser's local storage. | Medium |
| F6 | The Supabase project is unreachable | Its address doesn't resolve (checked on 2026-11-20), and the structure can't be rebuilt from the repo. | High (site data) |
| F7 | Two names for the Supabase key | The client and the middleware read different variables (`..._PUBLISHABLE_DEFAULT_KEY` and `..._ANON_KEY`). | Low |
| F8 | Real names were in the planning docs | Member and signatory names were in the team plan. **Removed in this PR.** | Low |

Once issues are turned on, each finding becomes a GitHub issue labelled `needs review`.
