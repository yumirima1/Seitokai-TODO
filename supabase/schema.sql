create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  grade text not null check (grade in ('1', '2', '3', 'admin')),
  class_name text not null,
  avatar_url text check (avatar_url is null or avatar_url ~ '^https://'),
  avatar_path text,
  avatar_key text not null default 'council'
    check (avatar_key in ('council', 'blue', 'green', 'rose', 'cat', 'fox', 'rabbit', 'cloud')),
  role text not null default 'student'
    check (role in ('student', 'officer', 'admin')),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  deleted_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.app_is_approved()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid())
      and status = 'approved'
      and deleted_at is null
  );
$$;

create or replace function public.app_is_admin()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid())
      and role = 'admin'
      and status = 'approved'
      and deleted_at is null
  );
$$;

create or replace function public.app_is_officer()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid())
      and role in ('officer', 'admin')
      and status = 'approved'
      and deleted_at is null
  );
$$;

create or replace function public.create_profile_for_new_auth_user()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  metadata jsonb := new.raw_user_meta_data;
begin
  insert into public.profiles (id, full_name, grade, class_name, avatar_url, avatar_key)
  values (
    new.id,
    coalesce(nullif(trim(metadata ->> 'full_name'), ''), '新規ユーザー'),
    case when metadata ->> 'grade' in ('1', '2', '3') then metadata ->> 'grade' else '1' end,
    coalesce(nullif(trim(metadata ->> 'class_name'), ''), ''),
    nullif(metadata ->> 'avatar_url', ''),
    case when metadata ->> 'avatar_key' in ('council', 'blue', 'green', 'rose', 'cat', 'fox', 'rabbit', 'cloud')
      then metadata ->> 'avatar_key' else 'council' end
  );
  return new;
end;
$$;

drop trigger if exists create_profile_after_signup on auth.users;
create trigger create_profile_after_signup
after insert on auth.users
for each row execute function public.create_profile_for_new_auth_user();

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id),
  title text not null,
  content text not null,
  is_pinned boolean not null default false,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create unique index if not exists posts_single_active_notice
on public.posts (is_pinned)
where is_pinned and deleted_at is null;

create table if not exists public.post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id),
  author_id uuid not null references public.profiles(id),
  content text not null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.post_likes (
  post_id uuid not null references public.posts(id),
  user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.post_reads (
  post_id uuid not null references public.posts(id),
  user_id uuid not null references public.profiles(id),
  read_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.polls (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references public.profiles(id),
  title text not null,
  is_named boolean not null default false,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.poll_options (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.polls(id),
  label text not null,
  sort_order integer not null default 0
);

create table if not exists public.poll_votes (
  poll_id uuid not null references public.polls(id),
  option_id uuid not null references public.poll_options(id),
  user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  primary key (poll_id, user_id)
);

create or replace function public.app_option_has_votes(target_option uuid)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.poll_votes where option_id = target_option);
$$;

create or replace view public.poll_results
with (security_barrier = true)
as
  select o.poll_id, o.id as option_id, o.label,
         count(v.user_id)::bigint as vote_count
  from public.poll_options o
  join public.polls p on p.id = o.poll_id and p.deleted_at is null
  left join public.poll_votes v on v.option_id = o.id
  where public.app_is_approved()
  group by o.poll_id, o.id, o.label, o.sort_order
  order by o.sort_order;

create table if not exists public.documents (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  storage_path text not null unique,
  access_role text not null default 'all' check (access_role in ('all', 'officer', 'admin')),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.calendar_events (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 1 and 120),
  description text not null default '' check (length(description) <= 2000),
  starts_at timestamptz not null,
  ends_at timestamptz,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (ends_at is null or ends_at > starts_at)
);

create or replace function public.audit_calendar_event_change()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.audit_logs (actor_id, action, resource_type, resource_id)
    values ((select auth.uid()), 'カレンダー予定を作成しました', 'calendar_event', new.id::text);
  elsif old.deleted_at is null and new.deleted_at is not null then
    insert into public.audit_logs (actor_id, action, resource_type, resource_id)
    values ((select auth.uid()), 'カレンダー予定を削除状態にしました', 'calendar_event', new.id::text);
  end if;
  return new;
end;
$$;

drop trigger if exists audit_calendar_event_change on public.calendar_events;
create trigger audit_calendar_event_change
after insert or update on public.calendar_events
for each row execute function public.audit_calendar_event_change();

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id),
  content text not null,
  is_anonymous boolean not null default false,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create or replace view public.chat_messages_feed
with (security_barrier = true)
as
  select m.id,
         m.content,
         m.is_anonymous,
         m.created_at,
         m.sender_id = (select auth.uid()) as is_self,
         p.grade as sender_grade,
         case when m.is_anonymous and not public.app_is_admin()
              then '匿名ユーザー' else p.full_name end as sender_name,
         case when m.is_anonymous and not public.app_is_admin()
              then null else p.class_name end as sender_class,
         case when m.is_anonymous and not public.app_is_admin()
              then null else p.avatar_url end as sender_avatar,
            case when m.is_anonymous and not public.app_is_admin()
                 then null else p.avatar_path end as sender_avatar_path,
            case when m.is_anonymous and not public.app_is_admin()
                 then null else p.avatar_key end as sender_avatar_key
  from public.chat_messages m
  join public.profiles p on p.id = m.sender_id
  where m.deleted_at is null and public.app_is_approved();

create or replace function public.send_chat_message(message_content text, anonymous boolean)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  message_id uuid;
begin
  if not public.app_is_approved() then
    raise exception 'An approved account is required';
  end if;
  if length(trim(message_content)) = 0 or length(message_content) > 4000 then
    raise exception 'Message length is invalid';
  end if;

  insert into public.chat_messages (sender_id, content, is_anonymous)
  values ((select auth.uid()), trim(message_content), coalesce(anonymous, false))
  returning id into message_id;
  return message_id;
end;
$$;

create table if not exists public.audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id),
  action text not null,
  resource_type text,
  resource_id text,
  created_at timestamptz not null default now()
);

create or replace function public.record_audit_event(
  event_action text,
  event_resource_type text default null,
  event_resource_id text default null
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.app_is_approved() then
    raise exception 'An approved account is required';
  end if;

  if event_action not in (
    'ログインしました', 'ログアウトしました', 'プロフィールを更新しました',
    '投稿を作成しました', '投稿にコメントしました', '案件を削除状態にしました',
    '案件を復元しました', '資料を追加しました', '資料を閲覧しました',
    '投票を作成しました', '投票に参加しました', 'チャットに投稿しました'
  ) then
    raise exception 'Audit action is not allowed';
  end if;

  if event_action = 'プロフィールを更新しました' and event_resource_id <> (select auth.uid())::text then
    raise exception 'Profile audit target is invalid';
  elsif event_action = '投稿を作成しました' and not exists (
    select 1 from public.posts where id::text = event_resource_id and author_id = (select auth.uid())
  ) then
    raise exception 'Post audit target is invalid';
  elsif event_action = '投稿にコメントしました' and not exists (
    select 1 from public.post_comments where post_id::text = event_resource_id and author_id = (select auth.uid())
  ) then
    raise exception 'Comment audit target is invalid';
  elsif event_action = '案件を削除状態にしました' and not exists (
    select 1 from public.posts where id::text = event_resource_id and deleted_at is not null
  ) then
    raise exception 'Post deletion audit target is invalid';
  elsif event_action = '案件を復元しました' and not exists (
    select 1 from public.posts where id::text = event_resource_id and deleted_at is null
  ) then
    raise exception 'Post restore audit target is invalid';
  elsif event_action = '資料を追加しました' and not exists (
    select 1 from public.documents where storage_path = event_resource_id and created_by = (select auth.uid())
  ) then
    raise exception 'Document audit target is invalid';
  elsif event_action = '資料を閲覧しました' and not exists (
    select 1 from public.documents d
    where d.storage_path = event_resource_id and d.deleted_at is null
      and (d.access_role = 'all'
        or (d.access_role = 'officer' and public.app_is_officer())
        or (d.access_role = 'admin' and public.app_is_admin()))
  ) then
    raise exception 'Document access audit target is invalid';
  elsif event_action = '投票を作成しました' and not exists (
    select 1 from public.polls where id::text = event_resource_id and created_by = (select auth.uid())
  ) then
    raise exception 'Poll audit target is invalid';
  elsif event_action = '投票に参加しました' and not exists (
    select 1 from public.poll_votes where poll_id::text = event_resource_id and user_id = (select auth.uid())
  ) then
    raise exception 'Vote audit target is invalid';
  elsif event_action = 'チャットに投稿しました' and not exists (
    select 1 from public.chat_messages where sender_id = (select auth.uid())
      and created_at > now() - interval '1 minute'
  ) then
    raise exception 'Chat audit target is invalid';
  end if;

  insert into public.audit_logs (actor_id, action, resource_type, resource_id)
  values ((select auth.uid()), left(event_action, 160), left(event_resource_type, 80), left(event_resource_id, 160));
end;
$$;

create or replace function public.set_profile_status(target_user uuid, next_status text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.app_is_admin() or next_status not in ('approved', 'rejected') then
    raise exception 'Not authorized';
  end if;
  update public.profiles
  set status = next_status
  where id = target_user and role = 'student' and deleted_at is null;
  if not found then raise exception 'Account not found'; end if;
  insert into public.audit_logs (actor_id, action, resource_type, resource_id)
  values ((select auth.uid()), 'profile_' || next_status, 'profile', target_user::text);
end;
$$;

create or replace function public.set_profile_role(target_user uuid, next_role text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.app_is_admin()
    or target_user = (select auth.uid())
    or next_role not in ('student', 'officer', 'admin') then
    raise exception 'Not authorized';
  end if;
  update public.profiles set role = next_role
  where id = target_user and deleted_at is null;
  if not found then raise exception 'Account not found'; end if;
  insert into public.audit_logs (actor_id, action, resource_type, resource_id)
  values ((select auth.uid()), 'profile_role_changed', 'profile', target_user::text);
end;
$$;

create or replace function public.soft_delete_profile(target_user uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.app_is_admin() or target_user = (select auth.uid()) then
    raise exception 'Not authorized';
  end if;
  update public.profiles set deleted_at = now()
  where id = target_user and deleted_at is null;
  if not found then raise exception 'Account not found'; end if;
  insert into public.audit_logs (actor_id, action, resource_type, resource_id)
  values ((select auth.uid()), 'profile_soft_deleted', 'profile', target_user::text);
end;
$$;

create or replace function public.restore_profile(target_user uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.app_is_admin() then raise exception 'Not authorized'; end if;
  update public.profiles set deleted_at = null
  where id = target_user and status in ('pending', 'approved', 'rejected');
  if not found then raise exception 'Restorable account not found'; end if;
  insert into public.audit_logs (actor_id, action, resource_type, resource_id)
  values ((select auth.uid()), 'profile_restored', 'profile', target_user::text);
end;
$$;

alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.post_comments enable row level security;
alter table public.post_likes enable row level security;
alter table public.post_reads enable row level security;
alter table public.polls enable row level security;
alter table public.poll_options enable row level security;
alter table public.poll_votes enable row level security;
alter table public.documents enable row level security;
alter table public.calendar_events enable row level security;
alter table public.chat_messages enable row level security;
alter table public.audit_logs enable row level security;

create policy profiles_read on public.profiles for select to authenticated
using (
  id = (select auth.uid()) or public.app_is_admin()
  or (status = 'approved' and deleted_at is null and public.app_is_approved())
);
create policy profiles_update_self on public.profiles for update to authenticated
using (id = (select auth.uid()) and deleted_at is null)
with check (
  id = (select auth.uid())
  and deleted_at is null
  and role = (select role from public.profiles where id = (select auth.uid()))
  and status = (select status from public.profiles where id = (select auth.uid()))
  and grade = (select grade from public.profiles where id = (select auth.uid()))
);

create policy posts_read on public.posts for select to authenticated
using (public.app_is_approved() and (deleted_at is null or public.app_is_admin()));
create policy posts_create on public.posts for insert to authenticated
with check (
  public.app_is_approved()
  and author_id = (select auth.uid())
  and (not is_pinned or public.app_is_admin())
);
create policy posts_update on public.posts for update to authenticated
using (public.app_is_admin() or (author_id = (select auth.uid()) and deleted_at is null and not is_pinned))
with check (
  public.app_is_approved()
  and (public.app_is_admin() or (author_id = (select auth.uid()) and not is_pinned))
);

create policy comments_read on public.post_comments for select to authenticated
using (public.app_is_approved() and (deleted_at is null or public.app_is_admin()));
create policy comments_create on public.post_comments for insert to authenticated
with check (public.app_is_approved() and author_id = (select auth.uid()));
create policy comments_update on public.post_comments for update to authenticated
using (public.app_is_admin() or author_id = (select auth.uid()))
with check (public.app_is_approved());

create policy likes_read on public.post_likes for select to authenticated
using (public.app_is_approved());
create policy likes_create on public.post_likes for insert to authenticated
with check (public.app_is_approved() and user_id = (select auth.uid()));
create policy likes_delete on public.post_likes for delete to authenticated
using (user_id = (select auth.uid()) or public.app_is_admin());

create policy reads_self on public.post_reads for all to authenticated
using ((user_id = (select auth.uid()) and public.app_is_approved()) or public.app_is_admin())
with check (user_id = (select auth.uid()) and public.app_is_approved());

create policy polls_read on public.polls for select to authenticated
using (public.app_is_approved() and (deleted_at is null or public.app_is_admin()));
create policy polls_create on public.polls for insert to authenticated
with check (public.app_is_officer() and created_by = (select auth.uid()));
create policy polls_update on public.polls for update to authenticated
using (public.app_is_admin() or created_by = (select auth.uid()))
with check (public.app_is_officer() and (public.app_is_admin() or created_by = (select auth.uid())));
create policy options_read on public.poll_options for select to authenticated
using (public.app_is_approved());
create policy options_create on public.poll_options for insert to authenticated
with check (
  public.app_is_officer() and exists (
    select 1 from public.polls p
    where p.id = poll_id and p.deleted_at is null
      and (p.created_by = (select auth.uid()) or public.app_is_admin())
  )
);
create policy options_update on public.poll_options for update to authenticated
using (
  public.app_is_admin() or exists (
    select 1 from public.polls p
    where p.id = poll_id and p.created_by = (select auth.uid())
      and not public.app_option_has_votes(poll_options.id)
  )
)
with check (
  public.app_is_officer() and (
    public.app_is_admin() or exists (
      select 1 from public.polls p
      where p.id = poll_id and p.created_by = (select auth.uid())
        and not public.app_option_has_votes(poll_options.id)
    )
  )
);
create policy votes_create on public.poll_votes for insert to authenticated
with check (
  public.app_is_approved()
  and user_id = (select auth.uid())
  and exists (
    select 1 from public.polls p
    where p.id = poll_id and p.deleted_at is null
      and p.starts_at <= now() and (p.ends_at is null or p.ends_at > now())
  )
  and exists (select 1 from public.poll_options o where o.id = option_id and o.poll_id = poll_votes.poll_id)
);
create policy votes_read_named on public.poll_votes for select to authenticated
using (
  user_id = (select auth.uid())
  or exists (
    select 1 from public.polls p
    where p.id = poll_id and p.is_named and public.app_is_approved()
  )
);

create policy documents_read on public.documents for select to authenticated
using (
  public.app_is_approved() and deleted_at is null
  and (access_role = 'all' or (access_role = 'officer' and public.app_is_officer())
       or (access_role = 'admin' and public.app_is_admin()))
);
create policy documents_manage on public.documents for all to authenticated
using (public.app_is_admin()) with check (public.app_is_admin());

create policy calendar_events_read on public.calendar_events for select to authenticated
using (public.app_is_approved() and (deleted_at is null or public.app_is_admin()));
create policy calendar_events_create on public.calendar_events for insert to authenticated
with check (public.app_is_officer() and created_by = (select auth.uid()));
create policy calendar_events_update on public.calendar_events for update to authenticated
using (public.app_is_admin() or (created_by = (select auth.uid()) and deleted_at is null))
with check (public.app_is_approved() and (public.app_is_admin() or (
  created_by = (select auth.uid()) and public.app_is_officer()
)));

create policy chat_messages_insert on public.chat_messages for insert to authenticated
with check (false);
create policy audit_logs_read on public.audit_logs for select to authenticated
using (public.app_is_admin());

revoke all on public.chat_messages from public, anon, authenticated;
revoke all on public.poll_results from public, anon, authenticated;
revoke all on public.chat_messages_feed from public, anon, authenticated;
grant select on public.chat_messages_feed to authenticated;
grant select on public.poll_results to authenticated;
grant select on public.profiles, public.posts, public.post_comments, public.post_likes,
  public.post_reads, public.polls, public.poll_options, public.poll_votes,
  public.documents, public.calendar_events, public.audit_logs to authenticated;
grant insert on public.posts, public.post_comments, public.post_likes,
  public.post_reads, public.polls, public.poll_options, public.poll_votes to authenticated;
grant update on public.posts, public.post_comments, public.polls, public.poll_options,
  public.documents, public.calendar_events to authenticated;
grant delete on public.post_likes to authenticated;
grant update (full_name, class_name, avatar_key) on public.profiles to authenticated;
revoke all on function public.send_chat_message(text, boolean) from public, anon;
grant execute on function public.send_chat_message(text, boolean) to authenticated;
revoke all on function public.record_audit_event(text, text, text) from public, anon;
grant execute on function public.record_audit_event(text, text, text) to authenticated;
revoke all on function public.set_profile_status(uuid, text) from public, anon;
grant execute on function public.set_profile_status(uuid, text) to authenticated;
revoke all on function public.set_profile_role(uuid, text) from public, anon;
grant execute on function public.set_profile_role(uuid, text) to authenticated;
revoke all on function public.soft_delete_profile(uuid) from public, anon;
grant execute on function public.soft_delete_profile(uuid) to authenticated;
revoke all on function public.restore_profile(uuid) from public, anon;
grant execute on function public.restore_profile(uuid) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'meeting-files', 'meeting-files', false, 26214400,
  array['application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'text/plain']
)
on conflict (id) do update set public = false, file_size_limit = 26214400,
  allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'profile-avatars', 'profile-avatars', false, 5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic', 'image/heif']
)
on conflict (id) do update set public = false, file_size_limit = 5242880,
  allowed_mime_types = excluded.allowed_mime_types;

revoke all on function public.app_is_approved() from public, anon;
grant execute on function public.app_is_approved() to authenticated;
revoke all on function public.app_is_admin() from public, anon;
grant execute on function public.app_is_admin() to authenticated;
revoke all on function public.app_is_officer() from public, anon;
grant execute on function public.app_is_officer() to authenticated;
revoke all on function public.app_option_has_votes(uuid) from public, anon;
grant execute on function public.app_option_has_votes(uuid) to authenticated;
revoke all on function public.create_profile_for_new_auth_user() from public, anon, authenticated;

create policy meeting_files_read on storage.objects for select to authenticated
using (
  bucket_id = 'meeting-files' and exists (
    select 1 from public.documents d
    where d.storage_path = name and d.deleted_at is null
      and public.app_is_approved()
      and (d.access_role = 'all'
        or (d.access_role = 'officer' and public.app_is_officer())
        or (d.access_role = 'admin' and public.app_is_admin()))
  )
);
create policy meeting_files_insert on storage.objects for insert to authenticated
with check (bucket_id = 'meeting-files' and public.app_is_admin());
create policy meeting_files_delete on storage.objects for delete to authenticated
using (bucket_id = 'meeting-files' and public.app_is_admin());

create policy profile_avatars_read on storage.objects for select to authenticated
using (
  bucket_id = 'profile-avatars' and (
    public.app_is_approved() or exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.status = 'pending' and p.deleted_at is null
        and (storage.foldername(name))[1] = (select auth.uid())::text
    )
  )
);
create policy profile_avatars_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'profile-avatars' and exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.status in ('pending', 'approved') and p.deleted_at is null
  )
  and (storage.foldername(name))[1] = (select auth.uid())::text
);
create policy profile_avatars_update on storage.objects for update to authenticated
using (
  bucket_id = 'profile-avatars' and exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.status in ('pending', 'approved') and p.deleted_at is null
  )
  and (storage.foldername(name))[1] = (select auth.uid())::text
)
with check (
  bucket_id = 'profile-avatars' and exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.status in ('pending', 'approved') and p.deleted_at is null
  )
  and (storage.foldername(name))[1] = (select auth.uid())::text
);
create policy profile_avatars_delete on storage.objects for delete to authenticated
using (
  bucket_id = 'profile-avatars' and exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.status in ('pending', 'approved') and p.deleted_at is null
  )
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

-- Create the first teacher account in Supabase Auth, then run this with its email:
-- update public.profiles
-- set role = 'admin', status = 'approved', grade = 'admin', class_name = '生徒会顧問'
-- where id = (select id from auth.users where email = 'teacher@example.com');