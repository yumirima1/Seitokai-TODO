create table if not exists public.task_projects (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 1 and 120),
  description text not null default '' check (length(description) <= 2000),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.project_tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.task_projects(id),
  title text not null check (length(trim(title)) between 1 and 160),
  description text not null default '' check (length(description) <= 4000),
  assignee_id uuid references public.profiles(id),
  due_at timestamptz,
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  status text not null default 'todo' check (status in ('todo', 'in_progress', 'done')),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists project_tasks_project_active_idx
  on public.project_tasks (project_id, status, due_at)
  where deleted_at is null;
create index if not exists project_tasks_assignee_due_idx
  on public.project_tasks (assignee_id, due_at)
  where deleted_at is null and status <> 'done';

create table if not exists public.task_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.project_tasks(id),
  author_id uuid not null references public.profiles(id),
  content text not null check (length(trim(content)) between 1 and 2000),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists task_comments_task_active_idx
  on public.task_comments (task_id, created_at)
  where deleted_at is null;

create table if not exists public.notification_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  posts_enabled boolean not null default true,
  chat_enabled boolean not null default true,
  polls_enabled boolean not null default true,
  calendar_enabled boolean not null default true,
  documents_enabled boolean not null default true,
  tasks_enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,
  title text not null check (length(title) <= 120),
  body text not null default '' check (length(body) <= 500),
  resource_type text,
  resource_id text,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists notifications_recipient_recent_idx
  on public.notifications (recipient_id, created_at desc);
create index if not exists notifications_unread_idx
  on public.notifications (recipient_id, created_at desc)
  where read_at is null;
create unique index if not exists notifications_task_deadline_once_idx
  on public.notifications (recipient_id, type, resource_id)
  where type in ('task_deadline', 'poll_deadline');

alter table public.task_projects enable row level security;
alter table public.project_tasks enable row level security;
alter table public.task_comments enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.notifications enable row level security;

drop policy if exists task_projects_read on public.task_projects;
create policy task_projects_read on public.task_projects for select to authenticated
using (public.app_is_officer() and (deleted_at is null or public.app_is_admin()));

drop policy if exists task_projects_create on public.task_projects;
create policy task_projects_create on public.task_projects for insert to authenticated
with check (public.app_is_officer() and created_by = (select auth.uid()));

drop policy if exists task_projects_update on public.task_projects;
create policy task_projects_update on public.task_projects for update to authenticated
using (public.app_is_officer())
with check (public.app_is_officer());

drop policy if exists project_tasks_read on public.project_tasks;
create policy project_tasks_read on public.project_tasks for select to authenticated
using (
  public.app_is_officer()
  and exists (
    select 1 from public.task_projects p
    where p.id = project_id and (p.deleted_at is null or public.app_is_admin())
  )
  and (deleted_at is null or public.app_is_admin())
);

drop policy if exists project_tasks_create on public.project_tasks;
create policy project_tasks_create on public.project_tasks for insert to authenticated
with check (
  public.app_is_officer()
  and created_by = (select auth.uid())
  and exists (
    select 1 from public.task_projects p
    where p.id = project_id and p.deleted_at is null
  )
  and (
    assignee_id is null
    or exists (
      select 1 from public.profiles p
      where p.id = assignee_id and p.status = 'approved' and p.deleted_at is null
        and p.role in ('officer', 'admin', 'superadmin')
    )
  )
);

drop policy if exists project_tasks_update on public.project_tasks;
create policy project_tasks_update on public.project_tasks for update to authenticated
using (public.app_is_officer())
with check (
  public.app_is_officer()
  and (
    assignee_id is null
    or exists (
      select 1 from public.profiles p
      where p.id = assignee_id and p.status = 'approved' and p.deleted_at is null
        and p.role in ('officer', 'admin', 'superadmin')
    )
  )
);

drop policy if exists task_comments_read on public.task_comments;
create policy task_comments_read on public.task_comments for select to authenticated
using (public.app_is_officer() and (deleted_at is null or public.app_is_admin()));

drop policy if exists task_comments_create on public.task_comments;
create policy task_comments_create on public.task_comments for insert to authenticated
with check (
  public.app_is_officer()
  and author_id = (select auth.uid())
  and exists (
    select 1 from public.project_tasks t
    join public.task_projects p on p.id = t.project_id
    where t.id = task_id and t.deleted_at is null and p.deleted_at is null
  )
);

drop policy if exists task_comments_update on public.task_comments;
create policy task_comments_update on public.task_comments for update to authenticated
using (public.app_is_admin() or author_id = (select auth.uid()))
with check (public.app_is_officer());

drop policy if exists notification_preferences_read on public.notification_preferences;
create policy notification_preferences_read on public.notification_preferences for select to authenticated
using (user_id = (select auth.uid()) and public.app_is_approved());

drop policy if exists notification_preferences_create on public.notification_preferences;
create policy notification_preferences_create on public.notification_preferences for insert to authenticated
with check (user_id = (select auth.uid()) and public.app_is_approved());

drop policy if exists notification_preferences_update on public.notification_preferences;
create policy notification_preferences_update on public.notification_preferences for update to authenticated
using (user_id = (select auth.uid()) and public.app_is_approved())
with check (user_id = (select auth.uid()) and public.app_is_approved());

drop policy if exists notifications_read_own on public.notifications;
create policy notifications_read_own on public.notifications for select to authenticated
using (recipient_id = (select auth.uid()) and public.app_is_approved());

drop policy if exists notifications_update_own on public.notifications;
create policy notifications_update_own on public.notifications for update to authenticated
using (recipient_id = (select auth.uid()) and public.app_is_approved())
with check (recipient_id = (select auth.uid()) and public.app_is_approved());

revoke all on public.task_projects, public.project_tasks, public.task_comments,
  public.notification_preferences, public.notifications from public, anon, authenticated;
grant select, insert, update on public.task_projects, public.project_tasks,
  public.task_comments, public.notification_preferences to authenticated;
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

create or replace function public.set_portal_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists task_projects_set_updated_at on public.task_projects;
create trigger task_projects_set_updated_at
before update on public.task_projects
for each row execute function public.set_portal_updated_at();

drop trigger if exists project_tasks_set_updated_at on public.project_tasks;
create trigger project_tasks_set_updated_at
before update on public.project_tasks
for each row execute function public.set_portal_updated_at();

create or replace function public.emit_portal_notifications(
  event_type text,
  event_title text,
  event_body text,
  event_resource_type text,
  event_resource_id text,
  target_recipient uuid default null,
  excluded_recipient uuid default null,
  audience_role text default null
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.notifications (
    recipient_id, type, title, body, resource_type, resource_id
  )
  select p.id, event_type, left(event_title, 120), left(coalesce(event_body, ''), 500),
         event_resource_type, event_resource_id
  from public.profiles p
  left join public.notification_preferences pref on pref.user_id = p.id
  where p.status = 'approved' and p.deleted_at is null
    and (target_recipient is null or p.id = target_recipient)
    and (excluded_recipient is null or p.id <> excluded_recipient)
    and (
      audience_role is null
      or audience_role = 'all'
      or (audience_role = 'officer' and p.role in ('officer', 'admin', 'superadmin'))
      or (audience_role = 'admin' and p.role in ('admin', 'superadmin'))
    )
    and case
      when event_type = 'post' then coalesce(pref.posts_enabled, true)
      when event_type = 'chat' then coalesce(pref.chat_enabled, true)
      when event_type = 'poll' then coalesce(pref.polls_enabled, true)
      when event_type in ('calendar', 'calendar_updated', 'attendance_request') then coalesce(pref.calendar_enabled, true)
      when event_type in ('document', 'document_updated') then coalesce(pref.documents_enabled, true)
      when event_type in ('task_assigned', 'task_deadline') then coalesce(pref.tasks_enabled, true)
      else false
    end;
end;
$$;

create or replace function public.notify_new_post()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.deleted_at is null then
    perform public.emit_portal_notifications(
      'post', case when new.is_pinned then '重要なお知らせ' else '新しい投稿' end,
      new.title, 'post', new.id::text, null, new.author_id, 'all'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists posts_notify_new on public.posts;
create trigger posts_notify_new after insert on public.posts
for each row execute function public.notify_new_post();

create or replace function public.notify_new_chat_message()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.deleted_at is null then
    perform public.emit_portal_notifications(
      'chat', '新しいチャット', new.content, 'chat', new.id::text,
      null, new.sender_id, 'all'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists chat_messages_notify_new on public.chat_messages;
create trigger chat_messages_notify_new after insert on public.chat_messages
for each row execute function public.notify_new_chat_message();

create or replace function public.notify_new_poll()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.deleted_at is null and new.starts_at <= now() then
    perform public.emit_portal_notifications(
      'poll', '投票が開始されました', new.title, 'poll', new.id::text,
      null, new.created_by, 'all'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists polls_notify_new on public.polls;
create trigger polls_notify_new after insert on public.polls
for each row execute function public.notify_new_poll();

create or replace function public.notify_calendar_event_change()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.deleted_at is not null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    perform public.emit_portal_notifications(
      'calendar', '予定が追加されました',
      new.title, 'calendar', new.id::text, null, new.created_by, 'all'
    );
    if new.response_due_at is not null then
      perform public.emit_portal_notifications(
        'attendance_request', '出欠確認の依頼', new.title,
        'calendar', new.id::text, null, new.created_by, 'all'
      );
    end if;
  elsif old.deleted_at is not null
    or old.title is distinct from new.title
    or old.description is distinct from new.description
    or old.starts_at is distinct from new.starts_at
    or old.ends_at is distinct from new.ends_at
    or old.response_due_at is distinct from new.response_due_at then
    perform public.emit_portal_notifications(
      'calendar_updated', '予定が変更されました',
      new.title, 'calendar', new.id::text, null, new.created_by, 'all'
    );
    if old.response_due_at is distinct from new.response_due_at and new.response_due_at is not null then
      perform public.emit_portal_notifications(
        'attendance_request', '出欠確認の依頼', new.title,
        'calendar', new.id::text, null, new.created_by, 'all'
      );
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists calendar_events_notify_change on public.calendar_events;
create trigger calendar_events_notify_change
after insert or update on public.calendar_events
for each row execute function public.notify_calendar_event_change();

create or replace function public.notify_document_change()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.deleted_at is null and tg_op = 'INSERT' then
    perform public.emit_portal_notifications(
      'document', '資料が追加されました', new.title, 'document', new.id::text,
      null, new.created_by, new.access_role
    );
  elsif new.deleted_at is null and (
    old.deleted_at is not null
    or old.title is distinct from new.title
    or old.access_role is distinct from new.access_role
  ) then
    perform public.emit_portal_notifications(
      'document_updated', '資料が更新されました', new.title, 'document', new.id::text,
      null, new.created_by, new.access_role
    );
  end if;
  return new;
end;
$$;

drop trigger if exists documents_notify_new on public.documents;
drop trigger if exists documents_notify_change on public.documents;
create trigger documents_notify_change after insert or update on public.documents
for each row execute function public.notify_document_change();

create or replace function public.notify_task_assignment()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if new.assignee_id is null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    perform public.emit_portal_notifications(
      'task_assigned', 'タスクが割り当てられました', new.title,
      'task', new.id::text, new.assignee_id, null, 'officer'
    );
  elsif old.assignee_id is distinct from new.assignee_id then
    perform public.emit_portal_notifications(
      'task_assigned', 'タスクが割り当てられました', new.title,
      'task', new.id::text, new.assignee_id, null, 'officer'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists project_tasks_notify_assignee on public.project_tasks;
create trigger project_tasks_notify_assignee
after insert or update of assignee_id on public.project_tasks
for each row execute function public.notify_task_assignment();

create or replace function public.generate_task_deadline_notifications()
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.app_is_approved() or not public.app_is_officer() then
    raise exception 'An approved officer account is required';
  end if;

  insert into public.notifications (
    recipient_id, type, title, body, resource_type, resource_id
  )
  select t.assignee_id, 'task_deadline', 'タスクの期限が近づいています',
         t.title, 'task', t.id::text
  from public.project_tasks t
  join public.task_projects p on p.id = t.project_id and p.deleted_at is null
  left join public.notification_preferences pref on pref.user_id = t.assignee_id
  where t.assignee_id = (select auth.uid())
    and t.deleted_at is null and t.status <> 'done'
    and t.due_at is not null and t.due_at <= now() + interval '24 hours'
    and coalesce(pref.tasks_enabled, true)
  on conflict (recipient_id, type, resource_id) where type = 'task_deadline'
  do nothing;
end;
$$;

create or replace function public.generate_poll_deadline_notifications()
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.app_is_approved() then
    raise exception 'An approved account is required';
  end if;

  insert into public.notifications (
    recipient_id, type, title, body, resource_type, resource_id
  )
  select (select auth.uid()), 'poll_deadline', '投票の締切が近づいています',
         p.title, 'poll', p.id::text
  from public.polls p
  left join public.notification_preferences pref on pref.user_id = (select auth.uid())
  where p.deleted_at is null and p.ends_at is not null
    and p.ends_at <= now() + interval '24 hours'
    and p.ends_at > now() - interval '24 hours'
    and coalesce(pref.polls_enabled, true)
  on conflict (recipient_id, type, resource_id)
    where type in ('task_deadline', 'poll_deadline')
  do nothing;
end;
$$;

revoke all on function public.set_portal_updated_at() from public, anon, authenticated;
revoke all on function public.emit_portal_notifications(text, text, text, text, text, uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function public.notify_new_post() from public, anon, authenticated;
revoke all on function public.notify_new_chat_message() from public, anon, authenticated;
revoke all on function public.notify_new_poll() from public, anon, authenticated;
revoke all on function public.notify_calendar_event_change() from public, anon, authenticated;
revoke all on function public.notify_document_change() from public, anon, authenticated;
revoke all on function public.notify_task_assignment() from public, anon, authenticated;
revoke all on function public.generate_task_deadline_notifications() from public, anon;
revoke all on function public.generate_poll_deadline_notifications() from public, anon;
grant execute on function public.generate_task_deadline_notifications() to authenticated;
grant execute on function public.generate_poll_deadline_notifications() to authenticated;

create or replace function public.audit_task_management_change()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  audit_action text;
  resource text;
begin
  resource := case when tg_table_name = 'task_projects' then 'task_project' else 'task' end;
  if tg_op = 'INSERT' then
    audit_action := case when resource = 'task_project' then 'プロジェクトを作成しました' else 'タスクを作成しました' end;
  elsif old.deleted_at is null and new.deleted_at is not null then
    audit_action := case when resource = 'task_project' then 'プロジェクトを削除状態にしました' else 'タスクを削除状態にしました' end;
  else
    audit_action := case when resource = 'task_project' then 'プロジェクトを更新しました' else 'タスクを更新しました' end;
  end if;
  insert into public.audit_logs (actor_id, action, resource_type, resource_id)
  values ((select auth.uid()), audit_action, resource, new.id::text);
  return new;
end;
$$;

drop trigger if exists task_projects_audit_change on public.task_projects;
create trigger task_projects_audit_change after insert or update on public.task_projects
for each row execute function public.audit_task_management_change();

drop trigger if exists project_tasks_audit_change on public.project_tasks;
create trigger project_tasks_audit_change after insert or update on public.project_tasks
for each row execute function public.audit_task_management_change();

revoke all on function public.audit_task_management_change() from public, anon, authenticated;

create or replace function public.current_council_year()
returns text
language sql stable
set search_path = public, pg_temp
as $$
  select case
    when extract(month from timezone('Asia/Tokyo', now())) >= 4
      then extract(year from timezone('Asia/Tokyo', now()))::integer::text
    else (extract(year from timezone('Asia/Tokyo', now()))::integer - 1)::text
  end || '年度';
$$;

alter table public.calendar_events
  add column if not exists response_due_at timestamptz;

create table if not exists public.event_attendance (
  event_id uuid not null references public.calendar_events(id),
  user_id uuid not null references public.profiles(id),
  response text not null check (response in ('attending', 'not_attending')),
  responded_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

alter table public.task_projects
  add column if not exists academic_year text not null default public.current_council_year(),
  add column if not exists archived_at timestamptz;

alter table public.documents
  add column if not exists category text not null default '未分類',
  add column if not exists committee text not null default '',
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists archived_at timestamptz;

do $$
declare
  academic_year_was_missing boolean;
begin
  select not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'documents' and column_name = 'academic_year'
  ) into academic_year_was_missing;

  alter table public.documents add column if not exists academic_year text;
  if academic_year_was_missing then
    update public.documents
    set academic_year = (
      case
        when extract(month from created_at at time zone 'Asia/Tokyo') >= 4
          then extract(year from created_at at time zone 'Asia/Tokyo')::integer
        else extract(year from created_at at time zone 'Asia/Tokyo')::integer - 1
      end
    )::text || '年度';
  end if;

  update public.documents
  set academic_year = coalesce(nullif(academic_year, ''), public.current_council_year())
  where academic_year is null or academic_year = '';
  alter table public.documents alter column academic_year set default public.current_council_year();
  alter table public.documents alter column academic_year set not null;
end;
$$;

update public.documents
set category = '未分類'
where category = '';

create table if not exists public.document_favorites (
  document_id uuid not null references public.documents(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (document_id, user_id)
);

create table if not exists public.document_views (
  id bigint generated always as identity primary key,
  document_id uuid not null references public.documents(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  viewed_at timestamptz not null default now()
);
create index if not exists document_views_user_recent_idx
  on public.document_views (user_id, viewed_at desc);
create index if not exists document_views_document_idx
  on public.document_views (document_id, viewed_at desc);

create table if not exists public.document_revisions (
  id bigint generated always as identity primary key,
  document_id uuid not null references public.documents(id) on delete cascade,
  title text not null,
  storage_path text not null,
  access_role text not null,
  category text not null,
  committee text not null,
  academic_year text not null,
  changed_by uuid references public.profiles(id),
  changed_at timestamptz not null default now()
);
create index if not exists document_revisions_document_idx
  on public.document_revisions (document_id, changed_at desc);

create table if not exists public.meeting_minutes (
  id uuid primary key default gen_random_uuid(),
  calendar_event_id uuid references public.calendar_events(id),
  title text not null check (length(trim(title)) between 1 and 160),
  held_at timestamptz not null,
  attendee_ids uuid[] not null default '{}',
  guest_names text not null default '' check (length(guest_names) <= 1000),
  agenda text not null default '' check (length(agenda) <= 6000),
  discussion text not null default '' check (length(discussion) <= 12000),
  decisions text not null default '' check (length(decisions) <= 6000),
  pending_items text not null default '' check (length(pending_items) <= 6000),
  next_actions text not null default '' check (length(next_actions) <= 6000),
  academic_year text not null default public.current_council_year(),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  archived_at timestamptz
);
create index if not exists meeting_minutes_year_recent_idx
  on public.meeting_minutes (academic_year, held_at desc)
  where deleted_at is null;
alter table public.project_tasks
  add column if not exists source_minutes_id uuid references public.meeting_minutes(id);
create table if not exists public.council_units (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 100),
  description text not null default '' check (length(description) <= 1000),
  parent_id uuid references public.council_units(id),
  sort_order integer not null default 0,
  academic_year text not null default public.current_council_year(),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.council_unit_members (
  unit_id uuid not null references public.council_units(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  position_title text not null default '',
  sort_order integer not null default 0,
  primary key (unit_id, profile_id)
);

create table if not exists public.council_activities (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 1 and 160),
  description text not null default '' check (length(description) <= 6000),
  activity_date date not null,
  academic_year text not null default public.current_council_year(),
  project_id uuid references public.task_projects(id),
  document_id uuid references public.documents(id),
  result text not null default '' check (length(result) <= 4000),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  archived_at timestamptz
);
create index if not exists council_activities_year_date_idx
  on public.council_activities (academic_year, activity_date desc)
  where deleted_at is null;

create table if not exists public.council_handovers (
  id uuid primary key default gen_random_uuid(),
  from_year text not null,
  to_year text not null,
  notes text not null check (length(trim(notes)) between 1 and 12000),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  archived_at timestamptz
);
create unique index if not exists council_handovers_year_transition_idx
  on public.council_handovers (from_year, to_year);

alter table public.event_attendance enable row level security;
alter table public.meeting_minutes enable row level security;
alter table public.document_favorites enable row level security;
alter table public.document_views enable row level security;
alter table public.document_revisions enable row level security;
alter table public.council_units enable row level security;
alter table public.council_unit_members enable row level security;
alter table public.council_activities enable row level security;
alter table public.council_handovers enable row level security;

drop policy if exists event_attendance_read on public.event_attendance;
create policy event_attendance_read on public.event_attendance for select to authenticated
using (
  public.app_is_approved() and (
    user_id = (select auth.uid()) or public.app_is_officer()
  )
);
drop policy if exists event_attendance_insert on public.event_attendance;
create policy event_attendance_insert on public.event_attendance for insert to authenticated
with check (
  user_id = (select auth.uid()) and public.app_is_approved()
  and exists (
    select 1 from public.calendar_events e
    where e.id = event_id and e.deleted_at is null
      and (e.response_due_at is null or e.response_due_at > now())
  )
);
drop policy if exists event_attendance_update on public.event_attendance;
create policy event_attendance_update on public.event_attendance for update to authenticated
using (user_id = (select auth.uid()) and public.app_is_approved())
with check (
  user_id = (select auth.uid()) and public.app_is_approved()
  and exists (
    select 1 from public.calendar_events e
    where e.id = event_id and e.deleted_at is null
      and (e.response_due_at is null or e.response_due_at > now())
  )
);
drop policy if exists event_attendance_delete on public.event_attendance;
create policy event_attendance_delete on public.event_attendance for delete to authenticated
using (user_id = (select auth.uid()) and public.app_is_approved());

drop policy if exists meeting_minutes_read on public.meeting_minutes;
create policy meeting_minutes_read on public.meeting_minutes for select to authenticated
using (public.app_is_officer() and (deleted_at is null or public.app_is_admin()));
drop policy if exists meeting_minutes_create on public.meeting_minutes;
create policy meeting_minutes_create on public.meeting_minutes for insert to authenticated
with check (public.app_is_officer() and created_by = (select auth.uid()));
drop policy if exists meeting_minutes_update on public.meeting_minutes;
create policy meeting_minutes_update on public.meeting_minutes for update to authenticated
using (public.app_is_officer())
with check (public.app_is_officer());

drop policy if exists document_favorites_own on public.document_favorites;
create policy document_favorites_own on public.document_favorites for all to authenticated
using (user_id = (select auth.uid()) and public.app_is_approved())
with check (
  user_id = (select auth.uid()) and public.app_is_approved()
  and exists (
    select 1 from public.documents d
    where d.id = document_id and d.deleted_at is null and d.archived_at is null
      and (d.access_role = 'all' or (d.access_role = 'officer' and public.app_is_officer())
        or (d.access_role = 'admin' and public.app_is_admin()))
  )
);

drop policy if exists document_views_own on public.document_views;
create policy document_views_own on public.document_views for all to authenticated
using (user_id = (select auth.uid()) and public.app_is_approved())
with check (
  user_id = (select auth.uid()) and public.app_is_approved()
  and exists (
    select 1 from public.documents d
    where d.id = document_id and d.deleted_at is null
      and (d.access_role = 'all' or (d.access_role = 'officer' and public.app_is_officer())
        or (d.access_role = 'admin' and public.app_is_admin()))
  )
);

drop policy if exists document_revisions_read on public.document_revisions;
create policy document_revisions_read on public.document_revisions for select to authenticated
using (
  public.app_is_approved() and exists (
    select 1 from public.documents d
    where d.id = document_id and d.deleted_at is null
      and (d.access_role = 'all' or (d.access_role = 'officer' and public.app_is_officer())
        or (d.access_role = 'admin' and public.app_is_admin()))
      and (document_revisions.access_role = 'all'
        or (document_revisions.access_role = 'officer' and public.app_is_officer())
        or (document_revisions.access_role = 'admin' and public.app_is_admin()))
  )
);

drop policy if exists council_units_read on public.council_units;
create policy council_units_read on public.council_units for select to authenticated
using (public.app_is_approved() and (deleted_at is null or public.app_is_admin()));
drop policy if exists council_units_manage on public.council_units;
create policy council_units_manage on public.council_units for all to authenticated
using (public.app_is_admin()) with check (public.app_is_admin());
drop policy if exists council_unit_members_read on public.council_unit_members;
create policy council_unit_members_read on public.council_unit_members for select to authenticated
using (public.app_is_approved() and exists (
  select 1 from public.council_units u where u.id = unit_id and u.deleted_at is null
));
drop policy if exists council_unit_members_manage on public.council_unit_members;
create policy council_unit_members_manage on public.council_unit_members for all to authenticated
using (public.app_is_admin()) with check (public.app_is_admin());

drop policy if exists council_activities_read on public.council_activities;
create policy council_activities_read on public.council_activities for select to authenticated
using (public.app_is_approved() and (deleted_at is null or public.app_is_admin()));
drop policy if exists council_activities_create on public.council_activities;
create policy council_activities_create on public.council_activities for insert to authenticated
with check (
  public.app_is_officer() and created_by = (select auth.uid())
  and (project_id is null or exists (
    select 1 from public.task_projects p where p.id = project_id and p.deleted_at is null
  ))
  and (document_id is null or exists (
    select 1 from public.documents d where d.id = document_id and d.deleted_at is null
      and (d.access_role = 'all' or (d.access_role = 'officer' and public.app_is_officer())
        or (d.access_role = 'admin' and public.app_is_admin()))
  ))
);
drop policy if exists council_activities_update on public.council_activities;
create policy council_activities_update on public.council_activities for update to authenticated
using (public.app_is_admin() or created_by = (select auth.uid()))
with check (
  public.app_is_officer()
  and (project_id is null or exists (
    select 1 from public.task_projects p where p.id = project_id and p.deleted_at is null
  ))
  and (document_id is null or exists (
    select 1 from public.documents d where d.id = document_id and d.deleted_at is null
      and (d.access_role = 'all' or (d.access_role = 'officer' and public.app_is_officer())
        or (d.access_role = 'admin' and public.app_is_admin()))
  ))
);

drop policy if exists council_handovers_read on public.council_handovers;
create policy council_handovers_read on public.council_handovers for select to authenticated
using (public.app_is_admin());
drop policy if exists council_handovers_manage on public.council_handovers;
create policy council_handovers_manage on public.council_handovers for all to authenticated
using (public.app_is_admin()) with check (public.app_is_admin() and created_by = (select auth.uid()));

revoke all on public.event_attendance, public.meeting_minutes, public.document_favorites,
  public.document_views, public.document_revisions, public.council_units,
  public.council_unit_members, public.council_activities, public.council_handovers
  from public, anon, authenticated;
grant select, insert, update, delete on public.event_attendance to authenticated;
grant select, insert, update on public.meeting_minutes to authenticated;
grant select, insert, delete on public.document_favorites to authenticated;
grant select, insert on public.document_views to authenticated;
grant select on public.document_revisions to authenticated;
grant select, insert, update on public.council_units to authenticated;
grant select, insert, update, delete on public.council_unit_members to authenticated;
grant select, insert, update on public.council_activities to authenticated;
grant select, insert, update on public.council_handovers to authenticated;
grant usage, select on sequence public.document_views_id_seq to authenticated;

grant update on public.documents to authenticated;
grant update on public.task_projects to authenticated;
grant select, insert, update on public.project_tasks to authenticated;
grant select, insert, update on public.calendar_events to authenticated;

create or replace function public.capture_document_revision()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if old.title is distinct from new.title
    or old.storage_path is distinct from new.storage_path
    or old.access_role is distinct from new.access_role
    or old.category is distinct from new.category
    or old.committee is distinct from new.committee
    or old.academic_year is distinct from new.academic_year
    or (old.deleted_at is null and new.deleted_at is not null) then
    insert into public.document_revisions (
      document_id, title, storage_path, access_role, category, committee,
      academic_year, changed_by
    ) values (
      old.id, old.title, old.storage_path, old.access_role, old.category,
      old.committee, old.academic_year, (select auth.uid())
    );
    new.updated_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists documents_capture_revision on public.documents;
create trigger documents_capture_revision before update on public.documents
for each row execute function public.capture_document_revision();

drop policy if exists meeting_files_read on storage.objects;
create policy meeting_files_read on storage.objects for select to authenticated
using (
  bucket_id = 'meeting-files' and public.app_is_approved() and (
    exists (
      select 1 from public.documents d
      where d.storage_path = name and d.deleted_at is null
        and (d.access_role = 'all' or (d.access_role = 'officer' and public.app_is_officer())
          or (d.access_role = 'admin' and public.app_is_admin()))
    )
    or exists (
      select 1 from public.document_revisions r
      join public.documents d on d.id = r.document_id
      where r.storage_path = name and d.deleted_at is null
        and (d.access_role = 'all' or (d.access_role = 'officer' and public.app_is_officer())
          or (d.access_role = 'admin' and public.app_is_admin()))
        and (r.access_role = 'all' or (r.access_role = 'officer' and public.app_is_officer())
          or (r.access_role = 'admin' and public.app_is_admin()))
    )
  )
);

create or replace function public.audit_council_record_change()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  record_type text := tg_table_name;
begin
  insert into public.audit_logs (actor_id, action, resource_type, resource_id)
  values (
    (select auth.uid()),
    case when tg_op = 'INSERT' then record_type || '_created' else record_type || '_updated' end,
    record_type, new.id::text
  );
  return new;
end;
$$;

create or replace function public.get_event_attendance_summary(requested_events uuid[])
returns table(event_id uuid, attending_count bigint, not_attending_count bigint)
language sql stable security definer
set search_path = public, pg_temp
as $$
  select a.event_id,
         count(*) filter (where a.response = 'attending'),
         count(*) filter (where a.response = 'not_attending')
  from public.event_attendance a
  join public.calendar_events e on e.id = a.event_id and e.deleted_at is null
  where public.app_is_approved() and a.event_id = any(requested_events)
  group by a.event_id;
$$;

drop trigger if exists meeting_minutes_audit on public.meeting_minutes;
create trigger meeting_minutes_audit after insert or update on public.meeting_minutes
for each row execute function public.audit_council_record_change();
drop trigger if exists meeting_minutes_set_updated_at on public.meeting_minutes;
create trigger meeting_minutes_set_updated_at before update on public.meeting_minutes
for each row execute function public.set_portal_updated_at();
drop trigger if exists council_activities_audit on public.council_activities;
create trigger council_activities_audit after insert or update on public.council_activities
for each row execute function public.audit_council_record_change();
drop trigger if exists council_handovers_audit on public.council_handovers;
create trigger council_handovers_audit after insert or update on public.council_handovers
for each row execute function public.audit_council_record_change();

create or replace function public.perform_council_handover(
  source_year text,
  destination_year text,
  handover_notes text,
  archive_completed_year boolean default true
)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  handover_id uuid;
begin
  if not public.app_is_admin()
    or length(trim(source_year)) = 0
    or length(trim(destination_year)) = 0
    or source_year = destination_year
    or length(trim(handover_notes)) = 0
    or length(handover_notes) > 12000 then
    raise exception 'Handover input is invalid or not authorized';
  end if;

  insert into public.council_handovers (from_year, to_year, notes, created_by)
  values (trim(source_year), trim(destination_year), trim(handover_notes), (select auth.uid()))
  returning id into handover_id;

  if archive_completed_year then
    update public.documents set archived_at = now()
    where academic_year = trim(source_year) and deleted_at is null and archived_at is null;
    update public.meeting_minutes set archived_at = now()
    where academic_year = trim(source_year) and deleted_at is null and archived_at is null;
    update public.council_activities set archived_at = now()
    where academic_year = trim(source_year) and deleted_at is null and archived_at is null;
    update public.task_projects p set archived_at = now()
    where p.academic_year = trim(source_year) and p.deleted_at is null and p.archived_at is null
      and not exists (
        select 1 from public.project_tasks t
        where t.project_id = p.id and t.deleted_at is null and t.status <> 'done'
      );
  end if;

  return handover_id;
end;
$$;

revoke all on function public.current_council_year() from public, anon;
grant execute on function public.current_council_year() to authenticated;
revoke all on function public.capture_document_revision() from public, anon, authenticated;
revoke all on function public.audit_council_record_change() from public, anon, authenticated;
revoke all on function public.get_event_attendance_summary(uuid[]) from public, anon;
grant execute on function public.get_event_attendance_summary(uuid[]) to authenticated;
revoke all on function public.perform_council_handover(text, text, text, boolean) from public, anon;
grant execute on function public.perform_council_handover(text, text, text, boolean) to authenticated;
