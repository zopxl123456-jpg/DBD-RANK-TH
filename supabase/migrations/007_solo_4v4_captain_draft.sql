-- DBD Ranking 4v4 Solo Queue: captain vote, team draft, per-set Killer player,
-- and the agreed 23-step Killer ban/pick order. This migration does not alter 1v1.

create table if not exists public.match_4v4_lobbies (
  match_id uuid primary key references public.matches(id) on delete cascade,
  phase text not null default 'captain_vote'
    check (phase in ('captain_vote','team_draft','killer_draft','complete')),
  phase_deadline timestamptz not null,
  captain_blue_id uuid references auth.users(id),
  captain_red_id uuid references auth.users(id),
  first_pick_side smallint check (first_pick_side in (1,2)),
  current_pick_side smallint check (current_pick_side in (1,2)),
  current_killer_turn integer not null default 1 check (current_killer_turn between 1 and 24),
  killer_pool text[] not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.match_4v4_captain_votes (
  match_id uuid not null references public.match_4v4_lobbies(match_id) on delete cascade,
  voter_id uuid not null references auth.users(id) on delete cascade,
  target_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (match_id, voter_id),
  check (voter_id <> target_id)
);

create table if not exists public.match_4v4_team_draft_picks (
  match_id uuid not null references public.match_4v4_lobbies(match_id) on delete cascade,
  pick_no smallint not null check (pick_no between 1 and 6),
  side smallint not null check (side in (1,2)),
  player_id uuid not null references auth.users(id),
  picked_by uuid not null references auth.users(id),
  auto_picked boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (match_id, pick_no),
  unique (match_id, player_id)
);

create table if not exists public.match_4v4_killer_players (
  match_id uuid not null references public.match_4v4_lobbies(match_id) on delete cascade,
  set_no smallint not null check (set_no between 1 and 3),
  side smallint not null check (side in (1,2)),
  player_id uuid not null references auth.users(id),
  selected_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (match_id, set_no, side)
);

create table if not exists public.match_4v4_killer_actions (
  match_id uuid not null references public.match_4v4_lobbies(match_id) on delete cascade,
  turn_no smallint not null check (turn_no between 1 and 23),
  side smallint not null check (side in (1,2)),
  action_type text not null check (action_type in ('ban','pick')),
  set_no smallint check (set_no between 1 and 3),
  killer_name text not null,
  user_id uuid not null references auth.users(id),
  auto_selected boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (match_id, turn_no),
  unique (match_id, killer_name),
  check ((action_type = 'ban' and set_no is null) or (action_type = 'pick' and set_no is not null))
);

create index if not exists match_4v4_votes_target_idx
  on public.match_4v4_captain_votes(match_id, target_id);

alter table public.match_4v4_lobbies enable row level security;
alter table public.match_4v4_captain_votes enable row level security;
alter table public.match_4v4_team_draft_picks enable row level security;
alter table public.match_4v4_killer_players enable row level security;
alter table public.match_4v4_killer_actions enable row level security;
revoke all on public.match_4v4_lobbies, public.match_4v4_captain_votes,
  public.match_4v4_team_draft_picks, public.match_4v4_killer_players,
  public.match_4v4_killer_actions from anon, authenticated;

-- The 23-character 4v4 pool is snapshotted into each lobby below. The
-- legacy ranked_killer_pool remains untouched to avoid changing older clients.

-- Return the 4v4 lobby state. Calls also advance expired timers atomically:
-- random captains on vote timeout, random player on missed draft pick, and
-- random Killer / Killer-player assignments on a missed pick/ban deadline.
create or replace function public.get_match_4v4_lobby_state(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
  v_lobby public.match_4v4_lobbies%rowtype;
  v_blue uuid;
  v_red uuid;
  v_pick_no integer;
  v_pick_player uuid;
  v_turn_side smallint;
  v_action text;
  v_set_no smallint;
  v_killer text;
  v_actor uuid;
  v_votes jsonb;
  v_players jsonb;
  v_picks jsonb;
  v_killer_players jsonb;
  v_actions jsonb;
  v_my_vote uuid;
  v_my_side integer;
  v_ready jsonb;
  v_pool text[] := array[
    'The Hillbilly','The Twins','The Plague','The Spirit','The Oni','The Ghoul',
    'The Blight','The Slasher','The Artist','The Clown','The Mastermind','The Dredge',
    'The Dark Lord','The Nightmare','The Deathslinger','The Nurse','The Ghostface',
    'The Demogorgon','The Unknown','The Wraith','The Doctor','The Lich','The Cenobite'
  ];
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  select * into v_match from public.matches where id = p_match_id;
  if not found then raise exception 'Match not found'; end if;
  if v_match.mode <> '4v4' then raise exception 'This is not a 4v4 match'; end if;
  if not exists (select 1 from public.match_participants mp where mp.match_id = p_match_id
    and mp.entity_kind = 'player'::public.entity_kind and mp.entity_id = auth.uid()) then
    raise exception 'You are not a participant in this match';
  end if;

  if v_match.status = 'cancelled' then
    return jsonb_build_object('phase','cancelled');
  end if;
  if v_match.status <> 'pending' or v_match.winner_side is not null then
    raise exception 'This match is no longer in the 4v4 lobby phase';
  end if;
  if v_match.ready_status <> 'ready' then
    v_ready := public.get_match_ready_state(p_match_id);
    return jsonb_build_object('phase','ready_check','ready_state',v_ready);
  end if;

  if (select count(*) from public.match_participants mp where mp.match_id=p_match_id and mp.entity_kind='player'::public.entity_kind) <> 8 then
    raise exception 'The 4v4 lobby must contain exactly eight solo players';
  end if;
  if coalesce(cardinality(v_pool),0) <> 23 then raise exception 'The 4v4 Killer pool must contain exactly 23 Killers'; end if;

  insert into public.match_4v4_lobbies(match_id, phase, phase_deadline, killer_pool)
  values (p_match_id, 'captain_vote', now() + interval '30 seconds', v_pool)
  on conflict (match_id) do nothing;

  select * into v_lobby from public.match_4v4_lobbies where match_id = p_match_id for update;

  if v_lobby.phase = 'captain_vote' and v_lobby.phase_deadline <= now() then
    -- Random tie-break at every score boundary; if all votes are tied, two random captains are chosen.
    select mp.entity_id into v_blue
    from public.match_participants mp
    where mp.match_id = p_match_id and mp.entity_kind = 'player'::public.entity_kind
    order by (select count(*) from public.match_4v4_captain_votes v
              where v.match_id = p_match_id and v.target_id = mp.entity_id) desc,
             random()
    limit 1;
    select mp.entity_id into v_red
    from public.match_participants mp
    where mp.match_id = p_match_id and mp.entity_kind = 'player'::public.entity_kind
      and mp.entity_id <> v_blue
    order by (select count(*) from public.match_4v4_captain_votes v
              where v.match_id = p_match_id and v.target_id = mp.entity_id) desc,
             random()
    limit 1;
    if v_blue is null or v_red is null then raise exception 'Eight-player lobby is incomplete'; end if;
    update public.match_4v4_lobbies
      set phase = 'team_draft', captain_blue_id = v_blue, captain_red_id = v_red,
          first_pick_side = case when random() < 0.5 then 1 else 2 end,
          current_pick_side = case when random() < 0.5 then 1 else 2 end,
          phase_deadline = now() + interval '30 seconds', updated_at = now()
      where match_id = p_match_id;
    select * into v_lobby from public.match_4v4_lobbies where match_id = p_match_id;
    -- Fix current side to the same randomly selected side as first_pick_side.
    update public.match_4v4_lobbies set current_pick_side = first_pick_side where match_id = p_match_id;
    select * into v_lobby from public.match_4v4_lobbies where match_id = p_match_id;
    update public.match_participants set side = case when entity_id = v_blue then 1 else 2 end
      where match_id = p_match_id and entity_kind = 'player'::public.entity_kind
        and entity_id in (v_blue, v_red);
  end if;

  if v_lobby.phase = 'team_draft' and v_lobby.phase_deadline <= now() then
    select count(*) into v_pick_no from public.match_4v4_team_draft_picks where match_id = p_match_id;
    v_pick_no := v_pick_no + 1;
    select mp.entity_id into v_pick_player
    from public.match_participants mp
    where mp.match_id = p_match_id and mp.entity_kind = 'player'::public.entity_kind
      and mp.entity_id not in (v_lobby.captain_blue_id, v_lobby.captain_red_id)
      and not exists (select 1 from public.match_4v4_team_draft_picks p
                      where p.match_id = p_match_id and p.player_id = mp.entity_id)
    order by random() limit 1;
    if v_pick_player is not null then
      v_actor := case when v_lobby.current_pick_side = 1 then v_lobby.captain_blue_id else v_lobby.captain_red_id end;
      insert into public.match_4v4_team_draft_picks(match_id,pick_no,side,player_id,picked_by,auto_picked)
      values (p_match_id,v_pick_no,v_lobby.current_pick_side,v_pick_player,v_actor,true)
      on conflict do nothing;
      update public.match_participants set side = v_lobby.current_pick_side
        where match_id = p_match_id and entity_kind = 'player'::public.entity_kind and entity_id = v_pick_player;
    end if;
    if v_pick_no >= 6 then
      update public.match_4v4_lobbies set phase='killer_draft',current_killer_turn=1,
        phase_deadline=now()+interval '30 seconds',updated_at=now() where match_id=p_match_id;
    else
      update public.match_4v4_lobbies set current_pick_side=3-current_pick_side,
        phase_deadline=now()+interval '30 seconds',updated_at=now() where match_id=p_match_id;
    end if;
  end if;

  select * into v_lobby from public.match_4v4_lobbies where match_id = p_match_id;
  if v_lobby.phase = 'killer_draft' and v_lobby.phase_deadline <= now() then
    v_turn_side := case v_lobby.current_killer_turn
      when 1 then 1 when 2 then 1 when 3 then 2 when 4 then 2
      when 5 then 1 when 6 then 1 when 7 then 2 when 8 then 2
      when 9 then 1 when 10 then 2 when 11 then 1 when 12 then 2
      when 13 then 2 when 14 then 2 when 15 then 1 when 16 then 1
      when 17 then 2 when 18 then 2 when 19 then 1 when 20 then 1
      when 21 then 2 when 22 then 2 when 23 then 1 end;
    v_action := case when v_lobby.current_killer_turn in (11,12,23) then 'pick' else 'ban' end;
    v_set_no := case v_lobby.current_killer_turn when 11 then 1 when 12 then 2 when 23 then 3 else null end;
    if v_action = 'pick' then
      for v_my_side in 1..2 loop
        if not exists (select 1 from public.match_4v4_killer_players kp
          where kp.match_id=p_match_id and kp.set_no=v_set_no and kp.side=v_my_side) then
          select mp.entity_id into v_pick_player from public.match_participants mp
          where mp.match_id=p_match_id and mp.entity_kind='player'::public.entity_kind and mp.side=v_my_side
          order by random() limit 1;
          if v_pick_player is not null then
            v_actor := case when v_my_side=1 then v_lobby.captain_blue_id else v_lobby.captain_red_id end;
            insert into public.match_4v4_killer_players(match_id,set_no,side,player_id,selected_by)
              values (p_match_id,v_set_no,v_my_side,v_pick_player,v_actor)
              on conflict (match_id,set_no,side) do nothing;
          end if;
        end if;
      end loop;
    end if;
    select available.killer_name into v_killer
      from unnest(v_lobby.killer_pool) as available(killer_name)
      where not exists (select 1 from public.match_4v4_killer_actions a
        where a.match_id=p_match_id and a.killer_name=available.killer_name)
      order by random() limit 1;
    if v_killer is not null then
      v_actor := case when v_turn_side=1 then v_lobby.captain_blue_id else v_lobby.captain_red_id end;
      insert into public.match_4v4_killer_actions(match_id,turn_no,side,action_type,set_no,killer_name,user_id,auto_selected)
      values (p_match_id,v_lobby.current_killer_turn,v_turn_side,v_action,v_set_no,v_killer,v_actor,true)
      on conflict do nothing;
    end if;
    if v_lobby.current_killer_turn >= 23 then
      update public.match_4v4_lobbies set phase='complete',current_killer_turn=24,updated_at=now()
        where match_id=p_match_id;
    else
      update public.match_4v4_lobbies set current_killer_turn=current_killer_turn+1,
        phase_deadline=now()+interval '30 seconds',updated_at=now() where match_id=p_match_id;
    end if;
  end if;

  select * into v_lobby from public.match_4v4_lobbies where match_id=p_match_id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', mp.entity_id,
    'name', coalesce(nullif(p.in_game_name,''),nullif(p.display_name,''),p.username,'Player'),
    'side', case when mp.entity_id=v_lobby.captain_blue_id then 1
                 when mp.entity_id=v_lobby.captain_red_id then 2
                 else (select dp.side from public.match_4v4_team_draft_picks dp
                       where dp.match_id=p_match_id and dp.player_id=mp.entity_id) end,
    'is_captain', mp.entity_id in (v_lobby.captain_blue_id,v_lobby.captain_red_id)
  ) order by coalesce(nullif(p.in_game_name,''),nullif(p.display_name,''),p.username,'Player')),'[]'::jsonb)
  into v_players
  from public.match_participants mp left join public.profiles p on p.id=mp.entity_id
  where mp.match_id=p_match_id and mp.entity_kind='player'::public.entity_kind;

  select coalesce(jsonb_agg(jsonb_build_object('id',mp.entity_id,'name',coalesce(nullif(p.in_game_name,''),nullif(p.display_name,''),p.username,'Player'),
    'votes',(select count(*) from public.match_4v4_captain_votes v where v.match_id=p_match_id and v.target_id=mp.entity_id))),'[]'::jsonb)
  into v_votes from public.match_participants mp left join public.profiles p on p.id=mp.entity_id
  where mp.match_id=p_match_id and mp.entity_kind='player'::public.entity_kind;

  select coalesce(jsonb_agg(jsonb_build_object('pick_no',dp.pick_no,'side',dp.side,'player_id',dp.player_id,
    'player_name',coalesce(nullif(p.in_game_name,''),nullif(p.display_name,''),p.username,'Player'),
    'picked_by',dp.picked_by,'auto_picked',dp.auto_picked) order by dp.pick_no),'[]'::jsonb)
  into v_picks from public.match_4v4_team_draft_picks dp left join public.profiles p on p.id=dp.player_id
  where dp.match_id=p_match_id;

  select coalesce(jsonb_agg(jsonb_build_object('set_no',kp.set_no,'side',kp.side,'player_id',kp.player_id,
    'player_name',coalesce(nullif(p.in_game_name,''),nullif(p.display_name,''),p.username,'Player')) order by kp.set_no,kp.side),'[]'::jsonb)
  into v_killer_players from public.match_4v4_killer_players kp left join public.profiles p on p.id=kp.player_id
  where kp.match_id=p_match_id;

  select coalesce(jsonb_agg(jsonb_build_object('turn_no',a.turn_no,'side',a.side,'action_type',a.action_type,
    'set_no',a.set_no,'killer_name',a.killer_name,'auto_selected',a.auto_selected,'user_id',a.user_id) order by a.turn_no),'[]'::jsonb)
  into v_actions from public.match_4v4_killer_actions a where a.match_id=p_match_id;

  select target_id into v_my_vote from public.match_4v4_captain_votes where match_id=p_match_id and voter_id=auth.uid();
  v_my_side := case when auth.uid()=v_lobby.captain_blue_id then 1 when auth.uid()=v_lobby.captain_red_id then 2
    else (select side from public.match_participants where match_id=p_match_id and entity_kind='player'::public.entity_kind and entity_id=auth.uid()) end;

  return jsonb_build_object(
    'phase',v_lobby.phase,'deadline',v_lobby.phase_deadline,'captain_blue_id',v_lobby.captain_blue_id,
    'captain_red_id',v_lobby.captain_red_id,'first_pick_side',v_lobby.first_pick_side,
    'current_pick_side',v_lobby.current_pick_side,'current_killer_turn',v_lobby.current_killer_turn,
    'players',v_players,'votes',v_votes,'my_vote',v_my_vote,'my_side',v_my_side,
    'team_picks',v_picks,'killer_players',v_killer_players,'killer_pool',to_jsonb(v_lobby.killer_pool),
    'killer_actions',v_actions);
end;
$$;

create or replace function public.submit_4v4_captain_vote(p_match_id uuid, p_target_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_state jsonb;
begin
  v_state := public.get_match_4v4_lobby_state(p_match_id);
  if v_state->>'phase' <> 'captain_vote' then raise exception 'Captain voting is closed'; end if;
  if p_target_id = auth.uid() then raise exception 'You cannot vote for yourself'; end if;
  if not exists (select 1 from public.match_participants mp where mp.match_id=p_match_id
    and mp.entity_kind='player'::public.entity_kind and mp.entity_id=p_target_id) then
    raise exception 'You can only vote for a player in this lobby';
  end if;
  if (v_state->>'deadline')::timestamptz <= now() then raise exception 'Captain voting has ended'; end if;
  insert into public.match_4v4_captain_votes(match_id,voter_id,target_id)
    values (p_match_id,auth.uid(),p_target_id)
    on conflict (match_id,voter_id) do update set target_id=excluded.target_id,created_at=now();
  return public.get_match_4v4_lobby_state(p_match_id);
end;
$$;

create or replace function public.submit_4v4_team_draft_pick(p_match_id uuid, p_player_id uuid, p_expected_pick_no integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state jsonb;
  v_lobby public.match_4v4_lobbies%rowtype;
  v_pick_no integer;
  v_captain uuid;
begin
  v_state := public.get_match_4v4_lobby_state(p_match_id);
  select * into v_lobby from public.match_4v4_lobbies where match_id=p_match_id for update;
  if v_lobby.phase <> 'team_draft' then raise exception 'Team draft is not active'; end if;
  if v_lobby.phase_deadline <= now() then raise exception 'Draft timer expired'; end if;
  v_captain := case when v_lobby.current_pick_side=1 then v_lobby.captain_blue_id else v_lobby.captain_red_id end;
  if auth.uid() <> v_captain then raise exception 'It is not your captain turn'; end if;
  if p_player_id in (v_lobby.captain_blue_id,v_lobby.captain_red_id) then raise exception 'Captains are already assigned to their own teams'; end if;
  if not exists (select 1 from public.match_participants mp where mp.match_id=p_match_id
    and mp.entity_kind='player'::public.entity_kind and mp.entity_id=p_player_id) then
    raise exception 'Player is not in this lobby';
  end if;
  if exists (select 1 from public.match_4v4_team_draft_picks dp where dp.match_id=p_match_id and dp.player_id=p_player_id) then
    raise exception 'This player has already been drafted';
  end if;
  select count(*)+1 into v_pick_no from public.match_4v4_team_draft_picks where match_id=p_match_id;
  if p_expected_pick_no is distinct from v_pick_no then raise exception 'The team draft turn has changed. Refresh and try again'; end if;
  insert into public.match_4v4_team_draft_picks(match_id,pick_no,side,player_id,picked_by,auto_picked)
    values (p_match_id,v_pick_no,v_lobby.current_pick_side,p_player_id,auth.uid(),false);
  update public.match_participants set side=v_lobby.current_pick_side
    where match_id=p_match_id and entity_kind='player'::public.entity_kind and entity_id=p_player_id;
  if v_pick_no >= 6 then
    update public.match_4v4_lobbies set phase='killer_draft',current_killer_turn=1,
      phase_deadline=now()+interval '30 seconds',updated_at=now() where match_id=p_match_id;
  else
    update public.match_4v4_lobbies set current_pick_side=3-current_pick_side,
      phase_deadline=now()+interval '30 seconds',updated_at=now() where match_id=p_match_id;
  end if;
  return public.get_match_4v4_lobby_state(p_match_id);
end;
$$;

create or replace function public.select_4v4_killer_player(p_match_id uuid, p_set_no smallint, p_player_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state jsonb;
  v_lobby public.match_4v4_lobbies%rowtype;
  v_turn_set smallint;
  v_turn_side smallint;
  v_current_side smallint;
  v_captain uuid;
begin
  v_state := public.get_match_4v4_lobby_state(p_match_id);
  select * into v_lobby from public.match_4v4_lobbies where match_id=p_match_id for update;
  if v_lobby.phase <> 'killer_draft' or v_lobby.phase_deadline <= now() then raise exception 'Killer selection is not open'; end if;
  v_turn_set := case v_lobby.current_killer_turn when 11 then 1 when 12 then 2 when 23 then 3 else null end;
  if v_turn_set is null or p_set_no <> v_turn_set then raise exception 'Killer-player selection is not open for this Set'; end if;
  select side into v_current_side from public.match_participants where match_id=p_match_id
    and entity_kind='player'::public.entity_kind and entity_id=p_player_id;
  if v_current_side not in (1,2) then raise exception 'Player is not on a drafted team'; end if;
  v_captain := case when v_current_side=1 then v_lobby.captain_blue_id else v_lobby.captain_red_id end;
  if auth.uid() <> v_captain then raise exception 'Only your team captain can choose your Killer player'; end if;
  if not exists (select 1 from public.match_participants where match_id=p_match_id
    and entity_kind='player'::public.entity_kind and entity_id=p_player_id and side=v_current_side) then
    raise exception 'Selected player is not on your team';
  end if;
  insert into public.match_4v4_killer_players(match_id,set_no,side,player_id,selected_by)
    values (p_match_id,p_set_no,v_current_side,p_player_id,auth.uid())
    on conflict (match_id,set_no,side) do update set player_id=excluded.player_id,selected_by=excluded.selected_by,created_at=now();
  return public.get_match_4v4_lobby_state(p_match_id);
end;
$$;

create or replace function public.submit_4v4_killer_action(p_match_id uuid, p_killer_name text, p_expected_turn integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state jsonb;
  v_lobby public.match_4v4_lobbies%rowtype;
  v_turn_side smallint;
  v_action text;
  v_set_no smallint;
  v_captain uuid;
begin
  v_state := public.get_match_4v4_lobby_state(p_match_id);
  select * into v_lobby from public.match_4v4_lobbies where match_id=p_match_id for update;
  if v_lobby.phase <> 'killer_draft' then raise exception 'Killer draft is not active'; end if;
  if v_lobby.phase_deadline <= now() then raise exception 'Killer draft timer expired'; end if;
  if p_expected_turn is distinct from v_lobby.current_killer_turn then raise exception 'The Killer draft turn has changed. Refresh and try again'; end if;
  v_turn_side := case v_lobby.current_killer_turn
      when 1 then 1 when 2 then 1 when 3 then 2 when 4 then 2
      when 5 then 1 when 6 then 1 when 7 then 2 when 8 then 2
      when 9 then 1 when 10 then 2 when 11 then 1 when 12 then 2
      when 13 then 2 when 14 then 2 when 15 then 1 when 16 then 1
      when 17 then 2 when 18 then 2 when 19 then 1 when 20 then 1
      when 21 then 2 when 22 then 2 when 23 then 1 end;
  v_action := case when v_lobby.current_killer_turn in (11,12,23) then 'pick' else 'ban' end;
  v_set_no := case v_lobby.current_killer_turn when 11 then 1 when 12 then 2 when 23 then 3 else null end;
  v_captain := case when v_turn_side=1 then v_lobby.captain_blue_id else v_lobby.captain_red_id end;
  if auth.uid() <> v_captain then raise exception 'It is the other captain turn'; end if;
  if p_killer_name is null or not (p_killer_name = any(v_lobby.killer_pool)) then raise exception 'Killer is not in the 4v4 pool'; end if;
  if exists (select 1 from public.match_4v4_killer_actions where match_id=p_match_id and killer_name=p_killer_name) then
    raise exception 'That Killer has already been banned or picked';
  end if;
  if v_action='pick' and (
      (select count(*) from public.match_4v4_killer_players where match_id=p_match_id and set_no=v_set_no) <> 2
    ) then raise exception 'Both captains must assign a Killer player for this Set first'; end if;
  insert into public.match_4v4_killer_actions(match_id,turn_no,side,action_type,set_no,killer_name,user_id,auto_selected)
    values (p_match_id,v_lobby.current_killer_turn,v_turn_side,v_action,v_set_no,p_killer_name,auth.uid(),false);
  if v_lobby.current_killer_turn >= 23 then
    update public.match_4v4_lobbies set phase='complete',current_killer_turn=24,updated_at=now() where match_id=p_match_id;
  else
    update public.match_4v4_lobbies set current_killer_turn=current_killer_turn+1,
      phase_deadline=now()+interval '30 seconds',updated_at=now() where match_id=p_match_id;
  end if;
  return public.get_match_4v4_lobby_state(p_match_id);
end;
$$;

-- Results are permitted only after the mode-specific draft is complete.
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
  select * into v_match from public.matches where id=p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_match.status <> 'pending' or v_match.winner_side is not null then
    raise exception 'This match is not waiting for a result';
  end if;
  if not exists (select 1 from public.match_participants mp where mp.match_id=p_match_id
    and public.is_entity_member(mp.entity_kind,mp.entity_id,auth.uid())) then
    raise exception 'You are not a participant in this match';
  end if;
  select count(*) filter (where side=1),count(*) filter (where side=2),
    count(*) filter (where entity_kind='player')
    into v_side1,v_side2,v_player_count from public.match_participants where match_id=p_match_id;
  if v_match.mode='1v1' and (v_side1<>1 or v_side2<>1 or v_player_count<>2) then raise exception 'Invalid 1v1 match roster'; end if;
  if v_match.mode='4v4' and (v_side1<>4 or v_side2<>4 or v_player_count<>8
      or exists (select 1 from public.match_participants where match_id=p_match_id and entity_kind<>'player')) then
    raise exception 'Invalid 4v4 match roster. Both sides must have four solo players';
  end if;
  if v_match.mode='1v1' and not exists (select 1 from public.match_killer_drafts kd where kd.match_id=p_match_id and kd.status='complete') then
    raise exception 'Complete the Killer Draft before reporting the result';
  end if;
  if v_match.mode='4v4' and not exists (select 1 from public.match_4v4_lobbies l where l.match_id=p_match_id and l.phase='complete') then
    raise exception 'Complete the 4v4 Captain Draft and Killer Pick/Ban before reporting the result';
  end if;
  update public.matches set winner_side=p_winner_side,submitted_by=auth.uid(),notes=left(coalesce(p_notes,''),500)
    where id=p_match_id;
  return 'pending';
end;
$$;

revoke all on function public.get_match_4v4_lobby_state(uuid) from public,anon;
revoke all on function public.submit_4v4_captain_vote(uuid,uuid) from public,anon;
revoke all on function public.submit_4v4_team_draft_pick(uuid,uuid,integer) from public,anon;
revoke all on function public.select_4v4_killer_player(uuid,smallint,uuid) from public,anon;
revoke all on function public.submit_4v4_killer_action(uuid,text,integer) from public,anon;
grant execute on function public.get_match_4v4_lobby_state(uuid) to authenticated;
grant execute on function public.submit_4v4_captain_vote(uuid,uuid) to authenticated;
grant execute on function public.submit_4v4_team_draft_pick(uuid,uuid,integer) to authenticated;
grant execute on function public.select_4v4_killer_player(uuid,smallint,uuid) to authenticated;
grant execute on function public.submit_4v4_killer_action(uuid,text,integer) to authenticated;
