create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault with schema vault;

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique check (length(endpoint) <= 2048 and endpoint like 'https://%'),
  p256dh text not null,
  auth_key text not null,
  expiration_time timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id);

alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from public, anon, authenticated;
grant select, insert, update, delete on public.push_subscriptions to authenticated;

drop policy if exists push_subscriptions_read_own on public.push_subscriptions;
create policy push_subscriptions_read_own on public.push_subscriptions
for select to authenticated
using (user_id = (select auth.uid()) and public.app_is_approved());

drop policy if exists push_subscriptions_create_own on public.push_subscriptions;
create policy push_subscriptions_create_own on public.push_subscriptions
for insert to authenticated
with check (user_id = (select auth.uid()) and public.app_is_approved());

drop policy if exists push_subscriptions_update_own on public.push_subscriptions;
create policy push_subscriptions_update_own on public.push_subscriptions
for update to authenticated
using (user_id = (select auth.uid()) and public.app_is_approved())
with check (user_id = (select auth.uid()) and public.app_is_approved());

drop policy if exists push_subscriptions_delete_own on public.push_subscriptions;
create policy push_subscriptions_delete_own on public.push_subscriptions
for delete to authenticated
using (user_id = (select auth.uid()) and public.app_is_approved());

create table if not exists public.push_delivery_queue (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null unique references public.notifications(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'sent', 'failed')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  sent_at timestamptz,
  last_error text,
  created_at timestamptz not null default now()
);

create index if not exists push_delivery_queue_ready_idx
  on public.push_delivery_queue (available_at, created_at)
  where status in ('pending', 'processing');

alter table public.push_delivery_queue enable row level security;
revoke all on public.push_delivery_queue from public, anon, authenticated;
grant all on public.push_delivery_queue to service_role;

create or replace function public.enqueue_notification_push()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.push_delivery_queue (notification_id)
  values (new.id)
  on conflict (notification_id) do nothing;
  return new;
end;
$$;

revoke all on function public.enqueue_notification_push() from public, anon, authenticated;
drop trigger if exists notifications_enqueue_push on public.notifications;
create trigger notifications_enqueue_push
after insert on public.notifications
for each row execute function public.enqueue_notification_push();

create or replace function public.claim_push_deliveries(batch_size integer default 50)
returns table (
  queue_id uuid,
  notification_id uuid,
  recipient_id uuid,
  title text,
  body text,
  resource_type text,
  resource_id text,
  attempt_count integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.push_delivery_queue q
  set status = 'failed',
      locked_at = null,
      last_error = 'Maximum delivery attempts exceeded'
  where q.attempt_count >= 10
    and (
      (q.status = 'pending' and q.available_at <= now())
      or (q.status = 'processing' and q.locked_at < now() - interval '5 minutes')
    );

  return query
  with candidates as (
    select q.id
    from public.push_delivery_queue q
    where q.attempt_count < 10
      and (
        (q.status = 'pending' and q.available_at <= now())
        or (q.status = 'processing' and q.locked_at < now() - interval '5 minutes')
      )
    order by q.available_at, q.created_at
    for update skip locked
    limit greatest(1, least(coalesce(batch_size, 50), 100))
  ),
  claimed as (
    update public.push_delivery_queue q
    set status = 'processing',
        attempt_count = q.attempt_count + 1,
        locked_at = now(),
        last_error = null
    from candidates c
    where q.id = c.id
    returning q.id, q.notification_id, q.attempt_count
  )
  select c.id, n.id, n.recipient_id, n.title, n.body,
         n.resource_type, n.resource_id, c.attempt_count
  from claimed c
  join public.notifications n on n.id = c.notification_id;
end;
$$;

revoke all on function public.claim_push_deliveries(integer) from public, anon, authenticated;
grant execute on function public.claim_push_deliveries(integer) to service_role;

create or replace function public.invoke_push_dispatch()
returns void
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  project_url text;
  dispatch_secret text;
begin
  select decrypted_secret into project_url
  from vault.decrypted_secrets
  where name = 'supabase_url'
  limit 1;

  select decrypted_secret into dispatch_secret
  from vault.decrypted_secrets
  where name = 'push_dispatch_secret'
  limit 1;

  if coalesce(project_url, '') = '' or coalesce(dispatch_secret, '') = '' then
    raise warning 'Web Push dispatch is not configured in Supabase Vault';
    return;
  end if;

  perform net.http_post(
    url := rtrim(project_url, '/') || '/functions/v1/dispatch-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-push-dispatch-secret', dispatch_secret
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 5000
  );
exception when others then
  raise warning 'Web Push dispatch request failed: %', sqlerrm;
end;
$$;

revoke all on function public.invoke_push_dispatch() from public, anon, authenticated;

do $$
declare
  existing_job bigint;
begin
  select jobid into existing_job from cron.job where jobname = 'dispatch-web-push';
  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;
  perform cron.schedule(
    'dispatch-web-push',
    '* * * * *',
    'select public.invoke_push_dispatch();'
  );
end;
$$;
