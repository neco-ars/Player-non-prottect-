-- Таблица для синхронизации медиатеки Music Player.
-- Выполнить один раз: Supabase → SQL Editor → New query → вставить всё → Run.

create table if not exists public.libraries (
  user_id uuid primary key references auth.users (id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

-- Каждый видит и меняет только свою строку.
alter table public.libraries enable row level security;

drop policy if exists "own library: read" on public.libraries;
drop policy if exists "own library: insert" on public.libraries;
drop policy if exists "own library: update" on public.libraries;
drop policy if exists "own library: delete" on public.libraries;

create policy "own library: read" on public.libraries
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "own library: insert" on public.libraries
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "own library: update" on public.libraries
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own library: delete" on public.libraries
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Доступ через API только для вошедших (анонимам — ничего).
revoke all on public.libraries from anon;
grant select, insert, update, delete on public.libraries to authenticated;
