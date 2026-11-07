begin;

alter table public.profiles drop constraint if exists profiles_role_check;
update public.profiles set role = 'admin' where role = 'superadmin';
alter table public.profiles
  add constraint profiles_role_check check (role in ('student', 'officer', 'admin'));

alter table public.profiles
  add column if not exists avatar_key text not null default 'council';
alter table public.profiles drop constraint if exists profiles_avatar_key_check;
alter table public.profiles
  add constraint profiles_avatar_key_check
  check (avatar_key in ('council', 'blue', 'green', 'rose', 'cat', 'fox', 'rabbit', 'cloud'));
update public.profiles set avatar_key = 'council' where avatar_key is null;

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
  selected_avatar text := metadata ->> 'avatar_key';
begin
  if selected_avatar is null
    or selected_avatar not in ('council', 'blue', 'green', 'rose', 'cat', 'fox', 'rabbit', 'cloud') then
    selected_avatar := 'council';
  end if;

  insert into public.profiles (id, full_name, grade, class_name, avatar_key)
  values (
    new.id,
    coalesce(nullif(trim(metadata ->> 'full_name'), ''), '新規ユーザー'),
    case when metadata ->> 'grade' in ('1', '2', '3') then metadata ->> 'grade' else '1' end,
    coalesce(nullif(trim(metadata ->> 'class_name'), ''), ''),
    selected_avatar
  );
  return new;
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

revoke update (avatar_url, avatar_path) on public.profiles from authenticated;
grant update (full_name, class_name, avatar_key) on public.profiles to authenticated;

commit;
