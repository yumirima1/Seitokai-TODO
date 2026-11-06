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

alter table public.calendar_events enable row level security;

drop policy if exists calendar_events_read on public.calendar_events;
create policy calendar_events_read on public.calendar_events for select to authenticated
using (public.app_is_approved() and (deleted_at is null or public.app_is_admin()));

drop policy if exists calendar_events_create on public.calendar_events;
create policy calendar_events_create on public.calendar_events for insert to authenticated
with check (public.app_is_officer() and created_by = (select auth.uid()));

drop policy if exists calendar_events_update on public.calendar_events;
create policy calendar_events_update on public.calendar_events for update to authenticated
using (public.app_is_admin() or (created_by = (select auth.uid()) and deleted_at is null))
with check (public.app_is_approved() and (public.app_is_admin() or (
  created_by = (select auth.uid()) and public.app_is_officer()
)));

revoke all on public.calendar_events from public, anon, authenticated;
grant select, insert, update on public.calendar_events to authenticated;

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