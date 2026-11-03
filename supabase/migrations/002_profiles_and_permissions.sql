-- DBD Ranking: profile fields and safe self-service profile updates.
-- Run this AFTER 001_initial_schema.sql in Supabase SQL Editor.

alter table public.profiles
  add column if not exists display_name text not null default '',
  add column if not exists in_game_name text not null default '',
  add column if not exists platform text not null default 'PC',
  add column if not exists discord_tag text not null default '',
  add column if not exists bio text not null default '';

update public.profiles
set display_name = username
where display_name = '';

-- Keep usernames case-insensitively unique.
create unique index if not exists profiles_username_lower_uidx
  on public.profiles (lower(username));

-- Extend the auth trigger so new members get a profile with a display name.
create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  chosen_username text;
  chosen_display_name text;
begin
  chosen_username := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'username'), ''),
    'player_' || substr(new.id::text, 1, 8)
  );
  chosen_display_name := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
    chosen_username
  );

  insert into public.profiles(id, username, display_name)
  values (new.id, chosen_username, chosen_display_name)
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Users may read public profiles, but can update only profile fields, never IDs/timestamps.
revoke update on public.profiles from anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant update (username, display_name, in_game_name, platform, discord_tag, avatar_url, bio)
  on public.profiles to authenticated;

drop policy if exists "users update own profile" on public.profiles;
create policy "users update own profile"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Ensure profile table is readable for public player cards / leaderboard display.
drop policy if exists "profiles are readable" on public.profiles;
create policy "profiles are readable"
  on public.profiles for select
  to anon, authenticated
  using (true);

-- Every registered player starts at 1000 ELO in the active 1v1 season.
-- This also backfills current users and seeds ratings when a new season is activated.
create or replace function public.seed_active_season_player_ratings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.is_active = true
     and new.starts_at <= now()
     and (new.ends_at is null or new.ends_at > now()) then
    insert into public.ratings(season_id, mode, entity_kind, entity_id)
    select new.id, '1v1'::public.ranking_mode, 'player'::public.entity_kind, p.id
    from public.profiles p
    on conflict (season_id, mode, entity_kind, entity_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists seed_player_ratings_for_active_season on public.seasons;
create trigger seed_player_ratings_for_active_season
after insert or update of is_active, starts_at, ends_at on public.seasons
for each row execute function public.seed_active_season_player_ratings();

-- Backfill the active season if it existed before this migration.
insert into public.ratings(season_id, mode, entity_kind, entity_id)
select s.id, '1v1'::public.ranking_mode, 'player'::public.entity_kind, p.id
from public.seasons s
cross join public.profiles p
where s.is_active = true
  and s.starts_at <= now()
  and (s.ends_at is null or s.ends_at > now())
on conflict (season_id, mode, entity_kind, entity_id) do nothing;

-- Also seed a player's rating immediately when their account is created.
create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  chosen_username text;
  chosen_display_name text;
begin
  chosen_username := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'username'), ''),
    'player_' || substr(new.id::text, 1, 8)
  );
  chosen_display_name := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
    chosen_username
  );

  insert into public.profiles(id, username, display_name)
  values (new.id, chosen_username, chosen_display_name)
  on conflict (id) do nothing;

  insert into public.ratings(season_id, mode, entity_kind, entity_id)
  select s.id, '1v1'::public.ranking_mode, 'player'::public.entity_kind, new.id
  from public.seasons s
  where s.is_active = true
    and s.starts_at <= now()
    and (s.ends_at is null or s.ends_at > now())
  on conflict (season_id, mode, entity_kind, entity_id) do nothing;

  return new;
end;
$$;
