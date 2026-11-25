# Freedom Wall — Supabase Database

This migration adds the database functionality for the Freedom Wall feature. It uses PostgreSQL tables, row-level security (RLS), triggers, RPC functions, and Supabase Cron.

## Requirements

This migration builds on the database foundation (ADR 0008), which must be applied first:

- Members are rows in `public."Users"`, keyed by `user_id` (equal to `auth.users.id`). The public feed shows `first_name last_name` as the author.
- Administrators are Members with `Users.is_admin = true`, checked with `private.is_admin()`. The same Administrators manage Events.

## What the migration creates

| Database object | Purpose |
|---|---|
| `freedom_wall_submissions` | Stores submissions through pending, approved, and rejected states. An approved submission is the public post; there is no separate posts table. |
| `freedom_wall_reactions` | Stores one reaction per member per submission. |
| `freedom_wall_moderation_logs` | Records moderation and deletion actions, including the moderator. |
| `notifications` | Shared per-user inbox for Freedom Wall, announcements, events, and other app features. |

It also creates topic/status/reaction/action enums, indexes, RLS policies, an `updated_at` trigger, RPC functions, and an hourly cleanup job.

The public feed is served through an RPC, not direct table access. It returns approved posts and safe display fields only. Anonymous posts return `author_label = 'Anonymous'`; the public response does not include the real author ID or anonymity flag.

## Apply the migration

From `gdgoc/`, rebuild the local database and run the tests:

```bash
npx supabase db reset
npx supabase test db
```

Apply it to the hosted project only after it is merged, with the other migrations.

To make someone an Administrator, follow "Make the first Administrator" in `supabase/README.md`. After that, Administrators grant the role from `/admin`.

## Calling the RPC functions

Use `supabase.rpc(function_name, parameters)` from the Supabase client. The caller must be signed in for member and admin operations. Admin RPCs also check that the caller is an Administrator (`private.is_admin()`).

### Public feed

Can be called without authentication. Supports topic filtering, keyword search, sorting, and pagination.

```js
const { data, error } = await supabase.rpc('list_freedom_wall_posts', {
  p_topic: 'general',       // or null; general, project_collaboration, tech_tips, hackathon, shoutout, questions
  p_search: null,           // optional search text
  p_sort: 'newest',         // newest or popular
  p_limit: 20,
  p_offset: 0,
});
```

### Member actions

```js
// Submit; returns the new submission UUID. Status is set to pending.
await supabase.rpc('create_freedom_wall_submission', {
  p_message: message,
  p_topic: 'general',
  p_is_anonymous: false,
});

// List the signed-in member's own submissions and statuses.
await supabase.rpc('get_my_freedom_wall_submissions');

// Delete one of the signed-in member's submissions.
await supabase.rpc('delete_my_freedom_wall_submission', {
  p_submission_id: submissionId,
});

// Add or change the signed-in member's reaction.
await supabase.rpc('set_freedom_wall_reaction', {
  p_submission_id: submissionId,
  p_reaction_type: 'love', // love, ship_it, lit, relatable, tech
});

// Remove the signed-in member's reaction.
await supabase.rpc('remove_my_freedom_wall_reaction', {
  p_submission_id: submissionId,
});
```

The database enforces the 2,000-character limit, non-empty messages, required topics, and at most one pending submission per member. Reactions are limited to one per member per post; setting another reaction replaces the existing one.

### Admin moderation

All admin functions require the caller to be an Administrator (`Users.is_admin`).

```js
// List submissions. Use 'pending', 'approved', 'rejected', or null for all.
await supabase.rpc('admin_list_freedom_wall_submissions', {
  p_status: 'pending',
  p_limit: 50,
  p_offset: 0,
});

await supabase.rpc('admin_approve_freedom_wall_submission', {
  p_submission_id: submissionId,
});

await supabase.rpc('admin_reject_freedom_wall_submission', {
  p_submission_id: submissionId,
  p_rejection_reason: 'Reason for rejection',
});

await supabase.rpc('admin_edit_freedom_wall_submission', {
  p_submission_id: submissionId,
  p_new_message: revisedMessage,
  p_new_topic: 'general',
});

await supabase.rpc('admin_delete_freedom_wall_submission', {
  p_submission_id: submissionId,
});

await supabase.rpc('admin_list_freedom_wall_moderation_logs', {
  p_submission_id: submissionId, // or null for all submissions
  p_limit: 100,
  p_offset: 0,
});
```

Approval and rejection each update the submission, create a moderation log, and create a notification in one transaction. Rejection requires a reason. Admin edits preserve the original author and anonymity setting.

## Notifications

`public.notifications` is a shared inbox, not a Freedom Wall-only table. Each row belongs to one recipient. Use `category` to identify its source (for example, `freedom_wall`, `announcement`, or `event`). `action_url`, `reference_type`, `reference_id`, and `metadata` can link the notification to the relevant feature record.

Users can read only their own notifications and update only `read_at`. Trusted backend code (using a service-role client) can create notifications for other features. **Never expose the service-role key in client-side code.**

```js
// Read the signed-in user's inbox.
const { data, error } = await supabase
  .from('notifications')
  .select('id, category, title, body, action_url, reference_type, reference_id, created_at, read_at')
  .order('created_at', { ascending: false });

// Mark one notification as read.
await supabase.rpc('mark_notification_read', {
  p_notification_id: notificationId,
});

// Mark all of the signed-in user's notifications as read.
await supabase.rpc('mark_all_notifications_read');
```

For announcements, events, or other broadcasts, the trusted backend inserts one notification row for each intended recipient.

## Automatic deletion of rejected submissions

The migration schedules an hourly Supabase Cron job named `freedom-wall-delete-expired-rejections`. It deletes submissions whose `rejected_at` is at least 30 days old. Related reactions are deleted automatically. Notifications and moderation logs are retained as history.

Check the schedule and recent runs in the SQL Editor:

```sql
SELECT jobid, jobname, schedule, command
FROM cron.job
WHERE jobname = 'freedom-wall-delete-expired-rejections';

SELECT jobid, status, start_time, end_time, return_message
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 20;
```

## Frontend notes

- Render submission messages as plain text; do not interpret them as Markdown or HTML.
- Use a textarea and enforce the 2,000-character limit in the UI as well as in the database.
- Do not expose the underlying submissions table directly to the public feed. Use `list_freedom_wall_posts`.
- Handle RPC errors in the UI, including the one-pending-submission constraint.
