-- DBD Ranking: automatic Solo Queue matchmaking for 1v1 and 4v4.
-- Run AFTER 001_initial_schema.sql and 002_profiles_and_permissions.sql.
-- Migration 003 (team management) is optional; this ranked queue does not require pre-made teams.

-- 4v4 ranked is now an individual rating mode. Keep legacy team ratings readable,
-- but the live 4v4 leaderboard and queue use entity_kind='player'.
alter table public.ratings drop constraint if exists ratings_check;
alter table public.ratings
  add constraint ratings_mode_entity_kind_check
  check (
    (mode = '1v1' and entity_kind = 'player')
    or (mode = '4v4' and entity_kind in ('player','team'))
  );

-- A match is first created as a ready-to-play match (winner_side NULL).
-- After playing, any participant reports the winner; all participants then confirm.
alter table public.matches alter column winner_side drop not null;

-- Multiple players can participate on each side of a 4v4 match.
alter table public.match_participants drop constraint if exists match_participants_pkey;
alter table public.match_participants
  add constraint match_participants_pkey
  primary key (match_id, side, entity_kind, entity_id);
create unique index if not exists match_participants_entity_once_idx
  on public.match_participants(match_id, entity_kind, entity_id);
create index if not exists match_participants_entity_idx
  on public.match_participants(entity_kind, entity_id, match_id);

-- Seed both individual modes for all existing users in the active season.
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
    select new.id, v.mode, 'player'::public.entity_kind, p.id
    from public.profiles p
    cross join (values ('1v1'::public.ranking_mode), ('4v4'::public.ranking_mode)) as v(mode)
    on conflict (season_id, mode, entity_kind, entity_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists seed_player_ratings_for_active_season on public.seasons;
create trigger seed_player_ratings_for_active_season
after insert or update of is_active, starts_at, ends_at on public.seasons
for each row execute function public.seed_active_season_player_ratings();

-- Existing users receive a 1000 ELO player rating in both modes for the active season.
insert into public.ratings(season_id, mode, entity_kind, entity_id)
select s.id, v.mode, 'player'::public.entity_kind, p.id
from public.seasons s
cross join public.profiles p
cross join (values ('1v1'::public.ranking_mode), ('4v4'::public.ranking_mode)) as v(mode)
where s.is_active = true
  and s.starts_at <= now()
  and (s.ends_at is null or s.ends_at > now())
on conflict (season_id, mode, entity_kind, entity_id) do nothing;

-- Newly registered users receive both individual ratings in the active season.
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
  select s.id, v.mode, 'player'::public.entity_kind, new.id
  from public.seasons s
  cross join (values ('1v1'::public.ranking_mode), ('4v4'::public.ranking_mode)) as v(mode)
  where s.is_active = true
    and s.starts_at <= now()
    and (s.ends_at is null or s.ends_at > now())
  on conflict (season_id, mode, entity_kind, entity_id) do nothing;

  return new;
end;
$$;

create table if not exists public.matchmaking_queue (
  season_id uuid not null references public.seasons(id) on delete cascade,
  mode public.ranking_mode not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  elo_at_join integer not null check (elo_at_join >= 0),
  joined_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (season_id, mode, user_id)
);
create index if not exists matchmaking_queue_search_idx
  on public.matchmaking_queue(season_id, mode, elo_at_join, joined_at);

alter table public.matchmaking_queue enable row level security;
drop policy if exists "players can view own queue entry" on public.matchmaking_queue;
create policy "players can view own queue entry"
  on public.matchmaking_queue for select to authenticated
  using (auth.uid() = user_id);
revoke all on public.matchmaking_queue from anon, authenticated;
grant select on public.matchmaking_queue to authenticated;

-- Join (or continue searching in) the queue. The call attempts to form a match
-- atomically; the last player needed to complete a lobby creates the match.
-- Matchmaking range: starts at +/-100 ELO and expands by 50 every 30 seconds,
-- up to +/-400 ELO. For 4v4, the 8 selected players are split to minimize the
-- difference between the two team-average ELO ratings; tied splits are randomized.
create or replace function public.join_matchmaking_queue(p_mode public.ranking_mode)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_season_id uuid;
  v_my_elo integer;
  v_joined_at timestamptz;
  v_wait_seconds integer;
  v_range integer;
  v_candidate record;
  v_candidates_found integer := 0;
  v_player_ids uuid[] := array[]::uuid[];
  v_player_elos integer[] := array[]::integer[];
  v_total_elo integer := 0;
  v_best_mask integer := 0;
  v_best_diff integer := 2147483647;
  v_tie_count integer := 0;
  v_candidate_diff integer;
  v_mask integer;
  v_idx integer;
  v_count integer;
  v_sum integer;
  v_side smallint;
  v_match_id uuid;
  v_i integer;
  v_existing_match uuid;
begin
  if v_user_id is null then raise exception 'Login required'; end if;
  if p_mode not in ('1v1'::public.ranking_mode, '4v4'::public.ranking_mode) then
    raise exception 'Unsupported ranked mode';
  end if;

  select s.id into v_season_id
  from public.seasons s
  where s.is_active = true and s.starts_at <= now()
    and (s.ends_at is null or s.ends_at > now())
  order by s.starts_at desc
  limit 1;
  if v_season_id is null then raise exception 'There is no active season'; end if;

  if not exists (select 1 from public.profiles p where p.id = v_user_id) then
    raise exception 'Player profile not found';
  end if;

  -- Remove abandoned queue entries and ignore clients that stopped heartbeating.
  delete from public.matchmaking_queue q
  where q.last_seen_at < now() - interval '2 minutes';

  select m.id into v_existing_match
  from public.matches m
  join public.match_participants mp on mp.match_id = m.id
  where m.season_id = v_season_id and m.mode = p_mode and m.status = 'pending'
    and public.is_entity_member(mp.entity_kind, mp.entity_id, v_user_id)
  order by m.created_at desc
  limit 1;
  if v_existing_match is not null then
    return jsonb_build_object('state','matched','match_id',v_existing_match,'mode',p_mode);
  end if;

  insert into public.ratings(season_id, mode, entity_kind, entity_id)
  values (v_season_id, p_mode, 'player', v_user_id)
  on conflict (season_id, mode, entity_kind, entity_id) do nothing;

  select r.elo into v_my_elo
  from public.ratings r
  where r.season_id = v_season_id and r.mode = p_mode
    and r.entity_kind = 'player' and r.entity_id = v_user_id;

  insert into public.matchmaking_queue(season_id, mode, user_id, elo_at_join)
  values (v_season_id, p_mode, v_user_id, v_my_elo)
  on conflict (season_id, mode, user_id) do update
    set last_seen_at = now();

  select q.elo_at_join, q.joined_at
  into v_my_elo, v_joined_at
  from public.matchmaking_queue q
  where q.season_id = v_season_id and q.mode = p_mode and q.user_id = v_user_id
  for update;

  -- If another concurrent queue request already matched this player, return that match.
  if not found then
    select mp.match_id into v_existing_match
    from public.match_participants mp
    join public.matches m on m.id = mp.match_id
    where mp.entity_kind = 'player' and mp.entity_id = v_user_id
      and m.season_id = v_season_id and m.mode = p_mode
    order by m.created_at desc limit 1;
    if v_existing_match is not null then
      return jsonb_build_object('state','matched','match_id',v_existing_match,'mode',p_mode);
    end if;
    raise exception 'Queue entry was not found. Please search again';
  end if;

  v_wait_seconds := greatest(0, floor(extract(epoch from (now() - v_joined_at)))::integer);
  v_range := least(400, 100 + (floor(v_wait_seconds / 30.0)::integer * 50));

  if p_mode = '1v1' then
    for v_candidate in
      select q.user_id, q.elo_at_join, q.joined_at
      from public.matchmaking_queue q
      where q.season_id = v_season_id and q.mode = p_mode
        and q.user_id <> v_user_id
        and q.last_seen_at > now() - interval '20 seconds'
        and abs(q.elo_at_join - v_my_elo) <= least(
          400,
          100 + floor(extract(epoch from (now() - least(q.joined_at, v_joined_at))) / 30.0)::integer * 50
        )
      order by abs(q.elo_at_join - v_my_elo), random(), q.joined_at
      limit 1
      for update skip locked
    loop
      insert into public.matches(season_id, mode, status, winner_side, submitted_by)
      values (v_season_id, p_mode, 'pending', null, v_user_id)
      returning id into v_match_id;

      insert into public.match_participants(match_id, side, entity_kind, entity_id)
      values
        (v_match_id, 1, 'player', v_user_id),
        (v_match_id, 2, 'player', v_candidate.user_id);

      delete from public.matchmaking_queue q
      where q.season_id = v_season_id and q.mode = p_mode
        and q.user_id in (v_user_id, v_candidate.user_id);

      return jsonb_build_object('state','matched','match_id',v_match_id,'mode',p_mode,
        'range_elo',v_range,'wait_seconds',v_wait_seconds);
    end loop;

    return jsonb_build_object('state','queued','mode',p_mode,'elo',v_my_elo,
      'range_elo',v_range,'wait_seconds',v_wait_seconds);
  end if;

  -- Solo 4v4: collect seven other players near the caller's ELO.
  v_player_ids := array_append(v_player_ids, v_user_id);
  v_player_elos := array_append(v_player_elos, v_my_elo);
  for v_candidate in
    select q.user_id, q.elo_at_join, q.joined_at
    from public.matchmaking_queue q
    where q.season_id = v_season_id and q.mode = p_mode
      and q.user_id <> v_user_id
      and q.last_seen_at > now() - interval '20 seconds'
      and abs(q.elo_at_join - v_my_elo) <= least(
        400,
        100 + floor(extract(epoch from (now() - least(q.joined_at, v_joined_at))) / 30.0)::integer * 50
      )
    order by abs(q.elo_at_join - v_my_elo), random(), q.joined_at
    limit 7
    for update skip locked
  loop
    v_player_ids := array_append(v_player_ids, v_candidate.user_id);
    v_player_elos := array_append(v_player_elos, v_candidate.elo_at_join);
    v_candidates_found := v_candidates_found + 1;
  end loop;

  if v_candidates_found < 7 then
    return jsonb_build_object('state','queued','mode',p_mode,'elo',v_my_elo,
      'range_elo',v_range,'wait_seconds',v_wait_seconds,'players_found',v_candidates_found + 1,
      'players_needed',8);
  end if;

  for v_i in 1..8 loop v_total_elo := v_total_elo + v_player_elos[v_i]; end loop;

  -- Enumerate all 4-vs-4 splits (70 possibilities) and choose the closest average.
  for v_mask in 0..255 loop
    v_count := 0; v_sum := 0;
    for v_idx in 0..7 loop
      if ((v_mask >> v_idx) & 1) = 1 then
        v_count := v_count + 1;
        v_sum := v_sum + v_player_elos[v_idx + 1];
      end if;
    end loop;
    if v_count = 4 then
      v_candidate_diff := abs((2 * v_sum) - v_total_elo);
      if v_candidate_diff < v_best_diff then
        v_best_diff := v_candidate_diff;
        v_best_mask := v_mask;
        v_tie_count := 1;
      elsif v_candidate_diff = v_best_diff then
        v_tie_count := v_tie_count + 1;
        -- Reservoir sampling makes equally balanced splits random.
        if random() < (1.0 / v_tie_count) then v_best_mask := v_mask; end if;
      end if;
    end if;
  end loop;

  insert into public.matches(season_id, mode, status, winner_side, submitted_by)
  values (v_season_id, p_mode, 'pending', null, v_user_id)
  returning id into v_match_id;

  for v_i in 1..8 loop
    v_side := case when ((v_best_mask >> (v_i - 1)) & 1) = 1 then 1 else 2 end;
    insert into public.match_participants(match_id, side, entity_kind, entity_id)
    values (v_match_id, v_side, 'player', v_player_ids[v_i]);
  end loop;

  delete from public.matchmaking_queue q
  where q.season_id = v_season_id and q.mode = p_mode
    and q.user_id = any(v_player_ids);

  return jsonb_build_object('state','matched','match_id',v_match_id,'mode',p_mode,
    'range_elo',v_range,'wait_seconds',v_wait_seconds,
    'team_average_elo_difference',ceil(v_best_diff / 4.0));
end;
$$;

create or replace function public.cancel_matchmaking_queue(p_mode public.ranking_mode)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  delete from public.matchmaking_queue q
  where q.user_id = auth.uid() and q.mode = p_mode;
  return found;
end;
$$;

-- A participant reports the winner after the game. This changes a ready match
-- (pending with winner_side NULL) into a result-awaiting-confirmation match.
create or replace function public.submit_ranked_result(
  p_match_id uuid,
  p_winner_side smallint,
  p_notes text default null
)
returns public.match_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
  v_side1 integer;
  v_side2 integer;
  v_player_count integer;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  if p_winner_side not in (1,2) then raise exception 'Winner side must be 1 or 2'; end if;

  select * into v_match from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_match.status <> 'pending' or v_match.winner_side is not null then
    raise exception 'This match is not waiting for a result';
  end if;
  if not exists (
    select 1 from public.match_participants mp
    where mp.match_id = p_match_id
      and public.is_entity_member(mp.entity_kind, mp.entity_id, auth.uid())
  ) then raise exception 'You are not a participant in this match'; end if;

  select count(*) filter (where side = 1), count(*) filter (where side = 2),
         count(*) filter (where entity_kind = 'player')
  into v_side1, v_side2, v_player_count
  from public.match_participants where match_id = p_match_id;

  if v_match.mode = '1v1' and (v_side1 <> 1 or v_side2 <> 1 or v_player_count <> 2) then
    raise exception 'Invalid 1v1 match roster';
  end if;
  if v_match.mode = '4v4' and (v_side1 <> 4 or v_side2 <> 4 or v_player_count <> 8
      or exists (select 1 from public.match_participants where match_id = p_match_id and entity_kind <> 'player')) then
    raise exception 'Invalid 4v4 match roster. Both sides must have four solo players';
  end if;

  update public.matches
  set winner_side = p_winner_side,
      submitted_by = auth.uid(),
      notes = left(coalesce(p_notes, ''), 500)
  where id = p_match_id;
  return 'pending';
end;
$$;

-- Replace the legacy 2-entity rating handler with one that supports 1v1 and
-- eight-player 4v4 matches. All individual players on a 4v4 side receive the
-- same delta, calculated from the two teams' average ELO.
create or replace function public.respond_to_match(p_match_id uuid, p_confirm boolean)
returns public.match_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
  v_required integer;
  v_yes integer;
  v_no integer;
  v_avg_a numeric;
  v_avg_b numeric;
  v_expected_a numeric;
  v_actual_a numeric;
  v_delta_a integer;
  v_delta_b integer;
  v_participant record;
  v_new_elo integer;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;

  select * into v_match from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_match.status <> 'pending' or v_match.winner_side is null then
    raise exception 'This match is not awaiting confirmations';
  end if;

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

  select coalesce(sum(case
    when mp.entity_kind = 'player' then 1
    when mp.entity_kind = 'team' then (
      select count(*) from public.team_members tm where tm.team_id = mp.entity_id
    )
  end), 0)::integer
  into v_required
  from public.match_participants mp where mp.match_id = p_match_id;

  select count(distinct mc.user_id)::integer into v_yes
  from public.match_confirmations mc
  where mc.match_id = p_match_id and mc.confirmed = true
    and exists (
      select 1 from public.match_participants mp
      where mp.match_id = p_match_id
        and public.is_entity_member(mp.entity_kind, mp.entity_id, mc.user_id)
    );

  select count(distinct mc.user_id)::integer into v_no
  from public.match_confirmations mc
  where mc.match_id = p_match_id and mc.confirmed = false;

  if v_no > 0 then
    update public.matches set status = 'disputed' where id = p_match_id;
    return 'disputed';
  end if;
  if v_yes < v_required then return 'pending'; end if;

  select avg(r.elo)::numeric into v_avg_a
  from public.match_participants mp
  join public.ratings r on r.season_id = v_match.season_id
    and r.mode = v_match.mode and r.entity_kind = mp.entity_kind and r.entity_id = mp.entity_id
  where mp.match_id = p_match_id and mp.side = 1;

  select avg(r.elo)::numeric into v_avg_b
  from public.match_participants mp
  join public.ratings r on r.season_id = v_match.season_id
    and r.mode = v_match.mode and r.entity_kind = mp.entity_kind and r.entity_id = mp.entity_id
  where mp.match_id = p_match_id and mp.side = 2;

  if v_avg_a is null or v_avg_b is null then
    raise exception 'Rating rows are missing for one or more participants';
  end if;

  v_expected_a := 1 / (1 + power(10::numeric, (v_avg_b - v_avg_a) / 400));
  v_actual_a := case when v_match.winner_side = 1 then 1 else 0 end;
  v_delta_a := round(32 * (v_actual_a - v_expected_a))::integer;
  v_delta_b := -v_delta_a;

  for v_participant in
    select mp.side, mp.entity_kind, mp.entity_id, r.elo as old_elo
    from public.match_participants mp
    join public.ratings r on r.season_id = v_match.season_id
      and r.mode = v_match.mode and r.entity_kind = mp.entity_kind and r.entity_id = mp.entity_id
    where mp.match_id = p_match_id
    order by mp.side, mp.entity_id
    for update of r
  loop
    v_new_elo := greatest(0, v_participant.old_elo + case when v_participant.side = 1 then v_delta_a else v_delta_b end);

    update public.ratings
    set elo = v_new_elo,
        wins = wins + case when v_participant.side = v_match.winner_side then 1 else 0 end,
        losses = losses + case when v_participant.side <> v_match.winner_side then 1 else 0 end,
        updated_at = now()
    where season_id = v_match.season_id and mode = v_match.mode
      and entity_kind = v_participant.entity_kind and entity_id = v_participant.entity_id;

    insert into public.rating_history(match_id, season_id, mode, entity_kind, entity_id, old_elo, new_elo, delta)
    values (p_match_id, v_match.season_id, v_match.mode, v_participant.entity_kind,
      v_participant.entity_id, v_participant.old_elo, v_new_elo, v_new_elo - v_participant.old_elo);
  end loop;

  update public.matches set status = 'confirmed', confirmed_at = now()
  where id = p_match_id;
  return 'confirmed';
end;
$$;

revoke all on function public.create_ranking_match(uuid, public.ranking_mode, uuid, uuid, smallint, text) from public, anon, authenticated;
revoke all on function public.join_matchmaking_queue(public.ranking_mode) from public, anon;
revoke all on function public.cancel_matchmaking_queue(public.ranking_mode) from public, anon;
revoke all on function public.submit_ranked_result(uuid, smallint, text) from public, anon;
revoke all on function public.respond_to_match(uuid, boolean) from public, anon;
grant execute on function public.join_matchmaking_queue(public.ranking_mode) to authenticated;
grant execute on function public.cancel_matchmaking_queue(public.ranking_mode) to authenticated;
grant execute on function public.submit_ranked_result(uuid, smallint, text) to authenticated;
grant execute on function public.respond_to_match(uuid, boolean) to authenticated;

-- Queue rows can only be read by their owner; all queue mutations happen in RPCs.
