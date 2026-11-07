alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles
  add column if not exists avatar_key text not null default 'council'
  check (avatar_key in ('council', 'blue', 'green', 'rose', 'cat', 'fox', 'rabbit', 'cloud'));
grant update (full_name, class_name, avatar_url, avatar_path) on public.profiles to authenticated;

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

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'profile-avatars', 'profile-avatars', false, 5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic', 'image/heif']
)
on conflict (id) do update set public = false, file_size_limit = 5242880,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists profile_avatars_read on storage.objects;
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

drop policy if exists profile_avatars_insert on storage.objects;
create policy profile_avatars_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'profile-avatars' and exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.status in ('pending', 'approved') and p.deleted_at is null
  )
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

drop policy if exists profile_avatars_update on storage.objects;
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

drop policy if exists profile_avatars_delete on storage.objects;
create policy profile_avatars_delete on storage.objects for delete to authenticated
using (
  bucket_id = 'profile-avatars' and exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.status in ('pending', 'approved') and p.deleted_at is null
  )
  and (storage.foldername(name))[1] = (select auth.uid())::text
);