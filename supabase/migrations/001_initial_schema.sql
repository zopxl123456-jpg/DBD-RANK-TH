-- DBD Ranking starter schema for Supabase PostgreSQL
-- Run in Supabase SQL Editor or with Supabase CLI migrations.
create extension if not exists pgcrypto;

create type public.ranking_mode as enum ('1v1', '4v4');
create type public.entity_kind as enum ('player', 'team');
create type public.match_status as enum ('pending', 'confirmed', 'disputed', 'cancelled');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (char_length(username) between 2 and 24),
  avatar_url text,
  created_at timestamptz not null default now()
);

create function public.create_profile_for_new_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  chosen_username text;
begin
  chosen_username := coalesce(
    nullif(new.raw_user_meta_data ->> 'username', ''),
    'player_' || substr(new.id::text, 1, 8)
  );
  insert into public.profiles(id, username)
  values (new.id, chosen_username)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.create_profile_for_new_user();

create table public.seasons (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  starts_at timestamptz not null,
  ends_at timestamptz,
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  check (ends_at is null or ends_at > starts_at)
);
create unique index one_active_season on public.seasons(is_active) where is_active = true;

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.team_members (
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  team_role text not null default 'member' check (team_role in ('captain','member')),
  joined_at timestamptz not null default now(),
  primary key (team_id, user_id)
);

-- A separate rating is maintained for each season and competitive mode.
-- entity_id refers to profiles.id when entity_kind='player', teams.id when 'team'.
create table public.ratings (
  season_id uuid not null references public.seasons(id),
  mode public.ranking_mode not null,
  entity_kind public.entity_kind not null,
  entity_id uuid not null,
  elo integer not null default 1000 check (elo >= 0),
  wins integer not null default 0 check (wins >= 0),
  losses integer not null default 0 check (losses >= 0),
  draws integer not null default 0 check (draws >= 0),
  updated_at timestamptz not null default now(),
  primary key (season_id, mode, entity_kind, entity_id),
  check ((mode = '1v1' and entity_kind = 'player') or
         (mode = '4v4' and entity_kind = 'team'))
);

create table public.matches (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.seasons(id),
  mode public.ranking_mode not null,
  status public.match_status not null default 'pending',
  winner_side smallint not null check (winner_side in (1,2)),
  submitted_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  notes text
);

create table public.match_participants (
  match_id uuid not null references public.matches(id) on delete cascade,
  side smallint not null check (side in (1,2)),
  entity_kind public.entity_kind not null,
  entity_id uuid not null,
  primary key (match_id, side),
  check ((entity_kind = 'player') or (entity_kind = 'team'))
);

create table public.match_confirmations (
  match_id uuid not null references public.matches(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  confirmed boolean not null,
  responded_at timestamptz not null default now(),
  primary key (match_id, user_id)
);

create table public.rating_history (
  id bigint generated always as identity primary key,
  match_id uuid not null references public.matches(id),
  season_id uuid not null references public.seasons(id),
  mode public.ranking_mode not null,
  entity_kind public.entity_kind not null,
  entity_id uuid not null,
  old_elo integer not null,
  new_elo integer not null,
  delta integer not null,
  recorded_at timestamptz not null default now(),
  unique(match_id, entity_kind, entity_id)
);

create index ratings_leaderboard_idx on public.ratings(season_id, mode, elo desc);
create index matches_season_idx on public.matches(season_id, created_at desc);
create index history_entity_idx on public.rating_history(entity_kind, entity_id, recorded_at desc);

-- Helper: current user may represent a player or be a member of a team.
create function public.is_entity_member(p_kind public.entity_kind, p_entity_id uuid, p_user_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select case
    when p_kind = 'player' then p_entity_id = p_user_id
    when p_kind = 'team' then exists (
      select 1 from public.team_members tm
      where tm.team_id = p_entity_id and tm.user_id = p_user_id
    )
    else false
  end;
$$;

-- Create a pending match. Side A must be represented by the logged-in user.
-- winner_side is a claimed result, not accepted until all participants confirm.
create function public.create_ranking_match(
  p_season_id uuid,
  p_mode public.ranking_mode,
  p_side_a_entity_id uuid,
  p_side_b_entity_id uuid,
  p_winner_side smallint,
  p_notes text default null
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_match_id uuid;
  v_kind public.entity_kind;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  if p_winner_side not in (1,2) then raise exception 'winner_side must be 1 or 2'; end if;
  if p_side_a_entity_id = p_side_b_entity_id then raise exception 'Sides must be different'; end if;

  if not exists (
    select 1 from public.seasons s
    where s.id = p_season_id and s.is_active = true
      and s.starts_at <= now() and (s.ends_at is null or s.ends_at > now())
  ) then raise exception 'Season is not active'; end if;

  if p_mode = '1v1' then
    v_kind := 'player';
    if p_side_a_entity_id <> auth.uid() then
      raise exception 'For 1v1, you must submit a match for your own player account';
    end if;
    if not exists (select 1 from public.profiles p where p.id = p_side_b_entity_id) then
      raise exception 'Opponent profile not found';
    end if;
  else
    v_kind := 'team';
    if not public.is_entity_member('team', p_side_a_entity_id, auth.uid()) then
      raise exception 'You must be a member of side A team';
    end if;
    if not exists (select 1 from public.teams t where t.id = p_side_b_entity_id) then
      raise exception 'Opponent team not found';
    end if;
    if (select count(*) from public.team_members where team_id = p_side_a_entity_id) <> 4
       or (select count(*) from public.team_members where team_id = p_side_b_entity_id) <> 4 then
      raise exception 'Both teams must have exactly 4 members';
    end if;
  end if;

  insert into public.matches(season_id, mode, winner_side, submitted_by, notes)
  values (p_season_id, p_mode, p_winner_side, auth.uid(), left(p_notes, 500))
  returning id into v_match_id;

  insert into public.match_participants(match_id, side, entity_kind, entity_id)
  values (v_match_id, 1, v_kind, p_side_a_entity_id),
         (v_match_id, 2, v_kind, p_side_b_entity_id);

  insert into public.ratings(season_id, mode, entity_kind, entity_id)
  values (p_season_id, p_mode, v_kind, p_side_a_entity_id),
         (p_season_id, p_mode, v_kind, p_side_b_entity_id)
  on conflict do nothing;

  return v_match_id;
end;
$$;

-- Every player on both sides must confirm the reported winner before ELO changes.
-- If any participant disagrees, the match becomes disputed and ELO does not change.
create function public.respond_to_match(p_match_id uuid, p_confirm boolean)
returns public.match_status language plpgsql security definer set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
  v_required integer;
  v_yes integer;
  v_no integer;
  v_a public.match_participants%rowtype;
  v_b public.match_participants%rowtype;
  v_ra integer;
  v_rb integer;
  v_ea numeric;
  v_sa numeric;
  v_delta_a integer;
  v_delta_b integer;
  v_new_a integer;
  v_new_b integer;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;

  select * into v_match from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_match.status <> 'pending' then raise exception 'Match is not pending'; end if;

  if not exists (
    select 1 from public.match_participants mp
    where mp.match_id = p_match_id
      and public.is_entity_member(mp.entity_kind, mp.entity_id, auth.uid())
  ) then raise exception 'You are not a participant in this match'; end if;

  insert into public.match_confirmations(match_id, user_id, confirmed)
  values (p_match_id, auth.uid(), p_confirm)
  on conflict (match_id, user_id) do update
    set confirmed = excluded.confirmed, responded_at = now();

  if not p_confirm then
    update public.matches set status = 'disputed' where id = p_match_id;
    return 'disputed';
  end if;

  select count(*) into v_required
  from public.match_participants mp
  where mp.match_id = p_match_id and (
    (mp.entity_kind = 'player' and exists (
      select 1 from public.profiles p where p.id = mp.entity_id
    )) or
    (mp.entity_kind = 'team' and exists (
      select 1 from public.team_members tm where tm.team_id = mp.entity_id
    ))
  );

  -- Count actual human participants required to confirm.
  select coalesce(sum(case
    when mp.entity_kind = 'player' then 1
    when mp.entity_kind = 'team' then (
      select count(*) from public.team_members tm where tm.team_id = mp.entity_id
    )
  end), 0) into v_required
  from public.match_participants mp where mp.match_id = p_match_id;

  select count(*) into v_yes
  from public.match_confirmations mc
  where mc.match_id = p_match_id and mc.confirmed = true
    and exists (
      select 1 from public.match_participants mp
      where mp.match_id = p_match_id
        and public.is_entity_member(mp.entity_kind, mp.entity_id, mc.user_id)
    );

  select count(*) into v_no
  from public.match_confirmations mc
  where mc.match_id = p_match_id and mc.confirmed = false;

  if v_no > 0 then
    update public.matches set status = 'disputed' where id = p_match_id;
    return 'disputed';
  end if;

  if v_yes < v_required then return 'pending'; end if;

  select * into v_a from public.match_participants
    where match_id = p_match_id and side = 1;
  select * into v_b from public.match_participants
    where match_id = p_match_id and side = 2;

  select elo into v_ra from public.ratings
    where season_id = v_match.season_id and mode = v_match.mode
      and entity_kind = v_a.entity_kind and entity_id = v_a.entity_id for update;
  select elo into v_rb from public.ratings
    where season_id = v_match.season_id and mode = v_match.mode
      and entity_kind = v_b.entity_kind and entity_id = v_b.entity_id for update;

  v_ea := 1 / (1 + power(10::numeric, (v_rb - v_ra)::numeric / 400));
  v_sa := case when v_match.winner_side = 1 then 1 else 0 end;
  v_delta_a := round(32 * (v_sa - v_ea))::integer;
  v_delta_b := -v_delta_a;
  v_new_a := greatest(0, v_ra + v_delta_a);
  v_new_b := greatest(0, v_rb + v_delta_b);

  update public.ratings set elo = v_new_a,
    wins = wins + case when v_match.winner_side = 1 then 1 else 0 end,
    losses = losses + case when v_match.winner_side = 2 then 1 else 0 end,
    updated_at = now()
  where season_id = v_match.season_id and mode = v_match.mode
    and entity_kind = v_a.entity_kind and entity_id = v_a.entity_id;

  update public.ratings set elo = v_new_b,
    wins = wins + case when v_match.winner_side = 2 then 1 else 0 end,
    losses = losses + case when v_match.winner_side = 1 then 1 else 0 end,
    updated_at = now()
  where season_id = v_match.season_id and mode = v_match.mode
    and entity_kind = v_b.entity_kind and entity_id = v_b.entity_id;

  insert into public.rating_history(match_id, season_id, mode, entity_kind, entity_id, old_elo, new_elo, delta)
  values
    (p_match_id, v_match.season_id, v_match.mode, v_a.entity_kind, v_a.entity_id, v_ra, v_new_a, v_new_a-v_ra),
    (p_match_id, v_match.season_id, v_match.mode, v_b.entity_kind, v_b.entity_id, v_rb, v_new_b, v_new_b-v_rb);

  update public.matches set status = 'confirmed', confirmed_at = now()
  where id = p_match_id;
  return 'confirmed';
end;
$$;

-- RLS: users can read public ranking data. Sensitive writes happen through RPC only.
alter table public.profiles enable row level security;
alter table public.seasons enable row level security;
alter table public.teams enable row level security;
alter table public.team_members enable row level security;
alter table public.ratings enable row level security;
alter table public.matches enable row level security;
alter table public.match_participants enable row level security;
alter table public.match_confirmations enable row level security;
alter table public.rating_history enable row level security;

create policy "profiles are readable" on public.profiles for select using (true);
create policy "users update own profile" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);
create policy "seasons are readable" on public.seasons for select using (true);
create policy "teams are readable" on public.teams for select using (true);
create policy "team membership is readable" on public.team_members for select using (true);
create policy "ratings are readable" on public.ratings for select using (true);
create policy "matches are readable" on public.matches for select using (true);
create policy "participants are readable" on public.match_participants for select using (true);
create policy "confirmations readable by self" on public.match_confirmations for select using (auth.uid() = user_id);
create policy "rating history is readable" on public.rating_history for select using (true);

-- Do not grant direct client writes to ratings, matches, participants, confirmations or history.
revoke insert, update, delete on public.ratings from anon, authenticated;
revoke insert, update, delete on public.matches from anon, authenticated;
revoke insert, update, delete on public.match_participants from anon, authenticated;
revoke insert, update, delete on public.match_confirmations from anon, authenticated;
revoke insert, update, delete on public.rating_history from anon, authenticated;
revoke insert, delete on public.profiles from anon, authenticated;
revoke insert, update, delete on public.seasons from anon, authenticated;
revoke insert, update, delete on public.teams from anon, authenticated;
revoke insert, update, delete on public.team_members from anon, authenticated;

grant execute on function public.create_ranking_match(uuid, public.ranking_mode, uuid, uuid, smallint, text) to authenticated;
grant execute on function public.respond_to_match(uuid, boolean) to authenticated;
grant execute on function public.is_entity_member(public.entity_kind, uuid, uuid) to authenticated;
