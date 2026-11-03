-- DBD Ranking: match chat + killer pick/draft
-- Run once AFTER migrations 001, 002 and 004.

-- ---------------------------------------------------------------------------
-- Match lobby chat
-- ---------------------------------------------------------------------------
create table if not exists public.match_chat_messages (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  message text not null check (char_length(btrim(message)) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists match_chat_messages_match_created_idx
  on public.match_chat_messages(match_id, created_at);

alter table public.match_chat_messages enable row level security;
drop policy if exists "match participants can read chat" on public.match_chat_messages;
create policy "match participants can read chat"
  on public.match_chat_messages for select to authenticated
  using (exists (
    select 1 from public.match_participants mp
    where mp.match_id = match_chat_messages.match_id
      and mp.entity_kind = 'player'::public.entity_kind
      and mp.entity_id = auth.uid()
  ));
drop policy if exists "match participants can send chat" on public.match_chat_messages;
create policy "match participants can send chat"
  on public.match_chat_messages for insert to authenticated
  with check (
    user_id = auth.uid()
    and char_length(btrim(message)) between 1 and 500
    and exists (
      select 1 from public.match_participants mp
      where mp.match_id = match_chat_messages.match_id
        and mp.entity_kind = 'player'::public.entity_kind
        and mp.entity_id = auth.uid()
    )
  );
revoke insert, update, delete on public.match_chat_messages from anon, authenticated;
grant select on public.match_chat_messages to authenticated;
grant insert (match_id, user_id, message) on public.match_chat_messages to authenticated;

-- Enable Supabase Realtime for match chat when the publication is available.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'match_chat_messages'
     ) then
    execute 'alter publication supabase_realtime add table public.match_chat_messages';
  end if;
exception when duplicate_object then
  null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Configurable killer pools. These are initial defaults and can be edited by
-- an administrator in SQL before opening the ladder to the public.
-- ---------------------------------------------------------------------------
create table if not exists public.ranked_killer_pool (
  mode public.ranking_mode not null,
  killer_name text not null,
  sort_order integer not null,
  is_active boolean not null default true,
  primary key (mode, killer_name),
  unique (mode, sort_order),
  check (char_length(btrim(killer_name)) between 1 and 60)
);
alter table public.ranked_killer_pool enable row level security;
drop policy if exists "killer pools are readable" on public.ranked_killer_pool;
create policy "killer pools are readable"
  on public.ranked_killer_pool for select to authenticated using (true);
revoke insert, update, delete on public.ranked_killer_pool from anon, authenticated;
grant select on public.ranked_killer_pool to authenticated;

insert into public.ranked_killer_pool(mode, killer_name, sort_order) values
  ('1v1','Nurse',1),
  ('1v1','Blight',2),
  ('1v1','Spirit',3),
  ('1v1','Hillbilly',4),
  ('1v1','Wesker',5),
  ('1v1','Huntress',6),
  ('1v1','Oni',7),
  ('1v1','Artist',8),
  ('1v1','Dracula',9),
  ('1v1','Ghoul',10),
  ('4v4','Trapper',1),
  ('4v4','Wraith',2),
  ('4v4','Hillbilly',3),
  ('4v4','Nurse',4),
  ('4v4','Shape',5),
  ('4v4','Hag',6),
  ('4v4','Doctor',7),
  ('4v4','Huntress',8),
  ('4v4','Cannibal',9),
  ('4v4','Nightmare',10),
  ('4v4','Pig',11),
  ('4v4','Clown',12),
  ('4v4','Spirit',13),
  ('4v4','Legion',14),
  ('4v4','Plague',15),
  ('4v4','Ghost Face',16),
  ('4v4','Demogorgon',17),
  ('4v4','Oni',18),
  ('4v4','Deathslinger',19),
  ('4v4','Executioner',20),
  ('4v4','Blight',21),
  ('4v4','Twins',22),
  ('4v4','Trickster',23),
  ('4v4','Nemesis',24)
on conflict (mode, killer_name) do nothing;

-- ---------------------------------------------------------------------------
-- Killer draft state. The pool is snapshotted when the match draft is opened,
-- so editing the roster later will not change an existing match.
-- ---------------------------------------------------------------------------
create table if not exists public.match_killer_drafts (
  match_id uuid primary key references public.matches(id) on delete cascade,
  mode public.ranking_mode not null,
  killer_pool text[] not null,
  side1_captain_id uuid not null references auth.users(id),
  side2_captain_id uuid not null references auth.users(id),
  side1_pick text,
  side2_pick text,
  third_killer text,
  status text not null default 'open' check (status in ('open','complete')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.match_killer_draft_actions (
  match_id uuid not null references public.match_killer_drafts(match_id) on delete cascade,
  turn_no integer not null,
  side smallint not null check (side in (1,2)),
  action_type text not null check (action_type in ('ban','pick')),
  killer_name text not null,
  user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (match_id, turn_no),
  unique (match_id, killer_name)
);

alter table public.match_killer_drafts enable row level security;
alter table public.match_killer_draft_actions enable row level security;
revoke all on public.match_killer_drafts from anon, authenticated;
revoke all on public.match_killer_draft_actions from anon, authenticated;

-- Return draft state and create its initial snapshot the first time a match
-- participant opens it. In 4v4, the highest-ELO player on each side is captain.
create or replace function public.get_match_killer_draft(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
  v_draft public.match_killer_drafts%rowtype;
  v_pool text[];
  v_captain_1 uuid;
  v_captain_2 uuid;
  v_actions jsonb;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;

  select * into v_match from public.matches where id = p_match_id;
  if not found then raise exception 'Match not found'; end if;
  if not exists (
    select 1 from public.match_participants mp
    where mp.match_id = p_match_id
      and mp.entity_kind = 'player'::public.entity_kind
      and mp.entity_id = auth.uid()
  ) then raise exception 'You are not a participant in this match'; end if;

  select * into v_draft from public.match_killer_drafts where match_id = p_match_id for update;
  if not found then
    -- Do not create a new draft for historical or already-reported matches.
    if v_match.status <> 'pending' or v_match.winner_side is not null then
      return null;
    end if;
    select array_agg(killer_name order by sort_order)
      into v_pool
    from public.ranked_killer_pool
    where mode = v_match.mode and is_active = true;

    if v_match.mode = '1v1' and coalesce(cardinality(v_pool),0) <> 10 then
      raise exception 'The 1v1 killer pool must contain exactly 10 active killers';
    elsif v_match.mode = '4v4' and coalesce(cardinality(v_pool),0) <> 24 then
      raise exception 'The 4v4 killer pool must contain exactly 24 active killers';
    end if;

    select mp.entity_id into v_captain_1
    from public.match_participants mp
    left join public.ratings r on r.season_id = v_match.season_id
      and r.mode = v_match.mode and r.entity_kind = 'player'::public.entity_kind
      and r.entity_id = mp.entity_id
    where mp.match_id = p_match_id and mp.side = 1
      and mp.entity_kind = 'player'::public.entity_kind
    order by coalesce(r.elo,1000) desc, mp.entity_id
    limit 1;

    select mp.entity_id into v_captain_2
    from public.match_participants mp
    left join public.ratings r on r.season_id = v_match.season_id
      and r.mode = v_match.mode and r.entity_kind = 'player'::public.entity_kind
      and r.entity_id = mp.entity_id
    where mp.match_id = p_match_id and mp.side = 2
      and mp.entity_kind = 'player'::public.entity_kind
    order by coalesce(r.elo,1000) desc, mp.entity_id
    limit 1;

    if v_captain_1 is null or v_captain_2 is null then
      raise exception 'Match participant list is incomplete';
    end if;

    insert into public.match_killer_drafts(
      match_id, mode, killer_pool, side1_captain_id, side2_captain_id
    ) values (
      p_match_id, v_match.mode, v_pool, v_captain_1, v_captain_2
    ) on conflict (match_id) do nothing;

    select * into v_draft from public.match_killer_drafts where match_id = p_match_id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'turn_no', a.turn_no,
    'side', a.side,
    'action_type', a.action_type,
    'killer_name', a.killer_name,
    'user_id', a.user_id,
    'created_at', a.created_at
  ) order by a.turn_no), '[]'::jsonb)
  into v_actions
  from public.match_killer_draft_actions a
  where a.match_id = p_match_id;

  return jsonb_build_object(
    'match_id', v_draft.match_id,
    'mode', v_draft.mode,
    'pool', to_jsonb(v_draft.killer_pool),
    'side1_captain_id', v_draft.side1_captain_id,
    'side2_captain_id', v_draft.side2_captain_id,
    'side1_pick', v_draft.side1_pick,
    'side2_pick', v_draft.side2_pick,
    'third_killer', v_draft.third_killer,
    'status', v_draft.status,
    'actions', v_actions
  );
end;
$$;

-- Submit one captain/player draft action.
-- 1v1: each player picks one; the third killer is randomly selected from the
-- remaining eight. 4v4: captains alternate bans until three remain, then Blue
-- picks one, Red picks one, and the last unpicked killer becomes the third.
create or replace function public.submit_match_killer_draft_action(
  p_match_id uuid,
  p_action text,
  p_killer_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft public.match_killer_drafts%rowtype;
  v_match public.matches%rowtype;
  v_side smallint;
  v_expected_side smallint;
  v_expected_action text;
  v_captain uuid;
  v_action_count integer;
  v_remaining_count integer;
  v_turn integer;
  v_third text;
  v_actions jsonb;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;

  perform public.get_match_killer_draft(p_match_id);
  select * into v_match from public.matches where id = p_match_id;
  select * into v_draft from public.match_killer_drafts where match_id = p_match_id for update;
  if not found then raise exception 'Killer draft is not open for this match'; end if;

  select mp.side into v_side
  from public.match_participants mp
  where mp.match_id = p_match_id
    and mp.entity_kind = 'player'::public.entity_kind
    and mp.entity_id = auth.uid()
  limit 1;
  if v_side is null then raise exception 'You are not a participant in this match'; end if;
  if v_draft.status = 'complete' then raise exception 'Killer draft is already complete'; end if;
  if not (p_killer_name = any(v_draft.killer_pool)) then raise exception 'Killer is not in this match pool'; end if;
  if exists (select 1 from public.match_killer_draft_actions a where a.match_id = p_match_id and a.killer_name = p_killer_name) then
    raise exception 'That killer has already been picked or banned';
  end if;

  select count(*) into v_action_count
  from public.match_killer_draft_actions a where a.match_id = p_match_id;
  v_turn := v_action_count + 1;

  if v_match.mode = '1v1' then
    v_expected_action := 'pick';
    v_expected_side := case when v_draft.side1_pick is null then 1 else 2 end;
    if p_action <> 'pick' then raise exception 'In 1v1, each player selects one killer'; end if;
    if v_side <> v_expected_side then raise exception 'Wait for the other player to make their pick first'; end if;
    if (v_side = 1 and auth.uid() <> v_draft.side1_captain_id)
       or (v_side = 2 and auth.uid() <> v_draft.side2_captain_id) then
      raise exception 'Only the player assigned to this side can pick';
    end if;
  else
    select cardinality(v_draft.killer_pool) - count(*) into v_remaining_count
    from public.match_killer_draft_actions a where a.match_id = p_match_id;

    if v_remaining_count > 3 then
      v_expected_action := 'ban';
      v_expected_side := case when v_action_count % 2 = 0 then 1 else 2 end;
    elsif v_draft.side1_pick is null then
      v_expected_action := 'pick'; v_expected_side := 1;
    elsif v_draft.side2_pick is null then
      v_expected_action := 'pick'; v_expected_side := 2;
    else
      raise exception 'Killer draft is already complete';
    end if;

    if p_action <> v_expected_action then
      raise exception 'Current draft action is %, not %', v_expected_action, p_action;
    end if;
    if v_side <> v_expected_side then
      raise exception 'It is the other captain side turn';
    end if;

    v_captain := case when v_expected_side = 1 then v_draft.side1_captain_id else v_draft.side2_captain_id end;
    if auth.uid() <> v_captain then
      raise exception 'Only your side captain can make this draft action';
    end if;
  end if;

  insert into public.match_killer_draft_actions(match_id, turn_no, side, action_type, killer_name, user_id)
  values (p_match_id, v_turn, v_expected_side, v_expected_action, p_killer_name, auth.uid());

  if v_expected_action = 'pick' and v_expected_side = 1 then
    update public.match_killer_drafts set side1_pick = p_killer_name, updated_at = now()
    where match_id = p_match_id;
  elsif v_expected_action = 'pick' and v_expected_side = 2 then
    update public.match_killer_drafts set side2_pick = p_killer_name, updated_at = now()
    where match_id = p_match_id;
  end if;

  select * into v_draft from public.match_killer_drafts where match_id = p_match_id;

  if v_match.mode = '1v1' and v_draft.side1_pick is not null and v_draft.side2_pick is not null then
    select k.killer_name into v_third
    from unnest(v_draft.killer_pool) as k(killer_name)
    where k.killer_name <> v_draft.side1_pick
      and k.killer_name <> v_draft.side2_pick
    order by random()
    limit 1;
    update public.match_killer_drafts set third_killer = v_third, status = 'complete', updated_at = now()
    where match_id = p_match_id;
  elsif v_match.mode = '4v4' and v_draft.side1_pick is not null and v_draft.side2_pick is not null then
    select k.killer_name into v_third
    from unnest(v_draft.killer_pool) as k(killer_name)
    where not exists (
      select 1 from public.match_killer_draft_actions a
      where a.match_id = p_match_id and a.killer_name = k.killer_name
    )
    limit 1;
    update public.match_killer_drafts set third_killer = v_third, status = 'complete', updated_at = now()
    where match_id = p_match_id;
  end if;

  return public.get_match_killer_draft(p_match_id);
end;
$$;

revoke all on function public.get_match_killer_draft(uuid) from public, anon;
revoke all on function public.submit_match_killer_draft_action(uuid, text, text) from public, anon;
grant execute on function public.get_match_killer_draft(uuid) to authenticated;
grant execute on function public.submit_match_killer_draft_action(uuid, text, text) to authenticated;


-- Do not let a match result be reported until its Killer draft is completed.
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
  if not exists (
    select 1 from public.match_killer_drafts kd
    where kd.match_id = p_match_id and kd.status = 'complete'
  ) then raise exception 'Complete the Killer Draft before reporting the result'; end if;

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

revoke all on function public.submit_ranked_result(uuid, smallint, text) from public, anon;
grant execute on function public.submit_ranked_result(uuid, smallint, text) to authenticated;
