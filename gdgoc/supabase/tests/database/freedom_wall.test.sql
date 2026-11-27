-- The Freedom Wall on the shared foundation: Members submit, the same
-- Administrators who manage Events moderate, and the public feed never
-- reveals who wrote an Anonymous post.

begin;
create extension if not exists pgtap with schema extensions;

select plan(17);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@example.com',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-00000000000b', 'member@example.com', 'authenticated', 'authenticated');

insert into public."Users" (user_id, first_name, last_name, email, is_admin) values
  ('00000000-0000-0000-0000-00000000000a', 'Jane', 'Doe', 'admin@example.com',  true),
  ('00000000-0000-0000-0000-00000000000b', 'John', 'Doe', 'member@example.com', false);

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
$$;

-- ---------------------------------------------------------------------------
-- Member
-- ---------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');

select throws_ok(
  $$ select public.create_freedom_wall_submission('Hello wall', 'gossip', true) $$,
  '23514', null, 'an unknown Topic is refused');

select lives_ok(
  $$ select public.create_freedom_wall_submission('Hello wall', 'general', true) $$,
  'a Member can submit an Anonymous post');

select throws_ok(
  $$ select public.create_freedom_wall_submission('Second post', 'general', false) $$,
  null, null, 'a Member cannot have two pending Submissions');

select throws_ok(
  $$ select * from public.admin_list_freedom_wall_submissions() $$,
  null, 'Administrator access required.', 'a Member cannot use the moderation functions');

select throws_ok(
  $$ select * from public.freedom_wall_submissions $$,
  '42501', null, 'a Member cannot read the Submissions table directly');

-- ---------------------------------------------------------------------------
-- Administrator (Users.is_admin, the same flag Events uses)
-- ---------------------------------------------------------------------------
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');

select is((select count(*)::int from public.admin_list_freedom_wall_submissions('pending')), 1,
          'an Administrator sees the pending Submission');

select is((select author_email from public.admin_list_freedom_wall_submissions('pending')), 'member@example.com',
          'an Administrator can identify an Anonymous submitter (ADR 0002)');

select lives_ok(
  $$ select public.admin_approve_freedom_wall_submission(
       (select submission_id from public.admin_list_freedom_wall_submissions('pending'))) $$,
  'an Administrator can approve a Submission');

select throws_ok(
  $$ select * from public.freedom_wall_moderation_logs $$,
  '42501', null, 'even an Administrator cannot read or edit the log table directly');

-- ---------------------------------------------------------------------------
-- Visitor
-- ---------------------------------------------------------------------------
reset role;
set local role anon;

select results_eq(
  $$ select author_label, message from public.list_freedom_wall_posts() $$,
  $$ values ('Anonymous'::text, 'Hello wall'::text) $$,
  'a visitor sees the approved post with its author hidden');

select throws_ok(
  $$ select * from public.admin_list_freedom_wall_submissions() $$,
  '42501', null, 'a visitor cannot call the moderation functions at all');

-- Supabase grants every new function in public to anon by default, so a
-- migration must revoke it from anon explicitly. Only the public feed may
-- reach visitors; add a function here only if visitors should call it.
select is(
  (select array_agg(p.proname::text order by p.proname::text)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and not exists (select 1 from pg_depend d
                     where d.objid = p.oid and d.deptype = 'e')),
  array['list_freedom_wall_posts'],
  'visitors can run only the functions meant for them');

-- ---------------------------------------------------------------------------
-- Reactions: a Member gives each type at most once per post
-- ---------------------------------------------------------------------------
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select public.set_freedom_wall_reaction((select submission_id from public.list_freedom_wall_posts()), 'love');
select public.set_freedom_wall_reaction((select submission_id from public.list_freedom_wall_posts()), 'lit');

select results_eq(
  $$ select love_count, lit_count from public.list_freedom_wall_posts() $$,
  $$ values (1::bigint, 1::bigint) $$,
  'two different Reactions from one Member on one post both count');

select public.set_freedom_wall_reaction((select submission_id from public.list_freedom_wall_posts()), 'love');

select results_eq(
  $$ select love_count, total_reactions from public.list_freedom_wall_posts() $$,
  $$ values (1::bigint, 2::bigint) $$,
  'the same Reaction given twice counts once');

select public.remove_my_freedom_wall_reaction((select submission_id from public.list_freedom_wall_posts()), 'love');

select results_eq(
  $$ select love_count, lit_count from public.list_freedom_wall_posts() $$,
  $$ values (0::bigint, 1::bigint) $$,
  'removing one Reaction leaves the other');

-- ---------------------------------------------------------------------------
-- Moderation log (ADR 0007): every action writes exactly one row, with the
-- Administrator who acted. A deleted post's text and author leave no trace.
-- ---------------------------------------------------------------------------
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select public.admin_edit_freedom_wall_submission(
  (select submission_id from public.admin_list_freedom_wall_submissions('approved')), 'Edited wall', 'general');
select public.admin_delete_freedom_wall_submission(
  (select submission_id from public.admin_list_freedom_wall_submissions('approved')));

reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select public.create_freedom_wall_submission('To be rejected', 'questions', false);
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select public.admin_reject_freedom_wall_submission(
  (select submission_id from public.admin_list_freedom_wall_submissions('pending')), 'Off topic');

reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select public.create_freedom_wall_submission('Mine to delete', 'general', false);
select public.delete_my_freedom_wall_submission(
  (select submission_id from public.get_my_freedom_wall_submissions() where status = 'pending'));

reset role;
select bag_eq(
  $$ select action::text, actor_id from public.freedom_wall_moderation_logs $$,
  $$ values ('approve',      '00000000-0000-0000-0000-00000000000a'::uuid),
            ('edit',         '00000000-0000-0000-0000-00000000000a'::uuid),
            ('admin_delete', '00000000-0000-0000-0000-00000000000a'::uuid),
            ('reject',       '00000000-0000-0000-0000-00000000000a'::uuid),
            ('member_delete', null::uuid) $$,
  'each moderation action writes one log row, with the Administrator who acted (none when a Member deletes their own post)');

-- Every column of every log row about a deleted post, as text.
select results_eq(
  $$ select count(*)::int,
            count(*) filter (
              where l::text ~ 'Hello wall|Edited wall|Mine to delete|00000000-0000-0000-0000-00000000000b')::int
     from public.freedom_wall_moderation_logs as l
     where not exists (select 1 from public.freedom_wall_submissions as s
                       where s.id = l.submission_id) $$,
  $$ values (4, 0) $$,
  'after a Member or an Administrator deletes a post, none of its 4 log rows holds its text or its author');

select * from finish();
rollback;
