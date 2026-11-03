-- Ready check before killer draft. New matches have 60 seconds for every player to ready up.
alter table public.matches
  add column if not exists ready_status text not null default 'waiting'
    check (ready_status in ('waiting','ready')),
  add column if not exists ready_deadline timestamptz;

-- Existing matches predate ready checks; allow them to continue as before.
update public.matches set ready_status = 'ready' where ready_status = 'waiting';

create table if not exists public.match_ready_confirmations (
  match_id uuid not null references public.matches(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  ready boolean not null default false,
  responded_at timestamptz not null default now(),
  primary key (match_id, user_id)
);
alter table public.match_ready_confirmations enable row level security;
revoke all on public.match_ready_confirmations from anon, authenticated;

create or replace function public.initialize_match_ready_check()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.ready_status := 'waiting';
  new.ready_deadline := coalesce(new.ready_deadline, now() + interval '60 seconds');
  return new;
end;
$$;
drop trigger if exists initialize_match_ready_check on public.matches;
create trigger initialize_match_ready_check before insert on public.matches
for each row when (new.status = 'pending' and new.winner_side is null)
execute function public.initialize_match_ready_check();

create or replace function public.get_match_ready_state(p_match_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_match public.matches%rowtype;
  v_total integer;
  v_ready integer;
  v_ready_ids uuid[];
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  if not exists (select 1 from public.match_participants mp where mp.match_id = p_match_id
    and mp.entity_kind = 'player'::public.entity_kind and mp.entity_id = auth.uid()) then
    raise exception 'You are not a participant in this match';
  end if;
  select * into v_match from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;

  select count(*) into v_total from public.match_participants mp
    where mp.match_id = p_match_id and mp.entity_kind = 'player'::public.entity_kind;
  select count(*), coalesce(array_agg(user_id) filter (where ready), array[]::uuid[])
    into v_ready, v_ready_ids from public.match_ready_confirmations where match_id = p_match_id and ready;

  if v_match.ready_status = 'waiting' and v_match.ready_deadline <= now() and v_ready < v_total then
    update public.matches set status = 'cancelled' where id = p_match_id and status = 'pending' and winner_side is null;
    return jsonb_build_object('status','cancelled','deadline',v_match.ready_deadline,'ready_ids',to_jsonb(v_ready_ids),'ready_count',v_ready,'total_count',v_total);
  end if;
  return jsonb_build_object('status',v_match.ready_status,'deadline',v_match.ready_deadline,'ready_ids',to_jsonb(v_ready_ids),'ready_count',v_ready,'total_count',v_total);
end;
$$;

create or replace function public.confirm_match_ready(p_match_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_match public.matches%rowtype;
  v_total integer;
  v_ready integer;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  select * into v_match from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if not exists (select 1 from public.match_participants mp where mp.match_id = p_match_id
    and mp.entity_kind = 'player'::public.entity_kind and mp.entity_id = auth.uid()) then
    raise exception 'You are not a participant in this match';
  end if;
  if v_match.status <> 'pending' or v_match.winner_side is not null then raise exception 'This match is no longer available'; end if;
  if v_match.ready_status = 'ready' then return public.get_match_ready_state(p_match_id); end if;
  if v_match.ready_deadline <= now() then
    update public.matches set status = 'cancelled' where id = p_match_id;
    return public.get_match_ready_state(p_match_id);
  end if;
  insert into public.match_ready_confirmations(match_id,user_id,ready,responded_at)
    values (p_match_id,auth.uid(),true,now())
    on conflict (match_id,user_id) do update set ready = true, responded_at = now();
  select count(*) into v_total from public.match_participants mp where mp.match_id = p_match_id and mp.entity_kind = 'player'::public.entity_kind;
  select count(*) into v_ready from public.match_ready_confirmations where match_id = p_match_id and ready;
  if v_total > 0 and v_ready >= v_total then
    update public.matches set ready_status = 'ready' where id = p_match_id;
  end if;
  return public.get_match_ready_state(p_match_id);
end;
$$;

revoke all on function public.get_match_ready_state(uuid) from public, anon;
revoke all on function public.confirm_match_ready(uuid) from public, anon;
grant execute on function public.get_match_ready_state(uuid) to authenticated;
grant execute on function public.confirm_match_ready(uuid) to authenticated;

-- Killer selection is not available until all participants have accepted the match.
create or replace function public.get_match_killer_draft(p_match_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_match public.matches%rowtype;
  v_draft public.match_killer_drafts%rowtype;
  v_pool text[];
  v_captain_1 uuid;
  v_captain_2 uuid;
  v_actions jsonb;
  v_expected_side smallint;
  v_random_killer text;
  v_remaining text[];
  v_picker uuid;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  select * into v_match from public.matches where id = p_match_id;
  if not found then raise exception 'Match not found'; end if;
  if not exists (select 1 from public.match_participants mp where mp.match_id = p_match_id and mp.entity_kind = 'player'::public.entity_kind and mp.entity_id = auth.uid()) then
    raise exception 'You are not a participant in this match';
  end if;
  if v_match.ready_status <> 'ready' then return null; end if;

  select * into v_draft from public.match_killer_drafts where match_id = p_match_id for update;
  if not found then
    if v_match.status <> 'pending' or v_match.winner_side is not null then return null; end if;
    select array_agg(killer_name order by sort_order) into v_pool from public.ranked_killer_pool where mode = v_match.mode and is_active = true;
    if v_match.mode = '1v1' and coalesce(cardinality(v_pool),0) <> 10 then raise exception 'The 1v1 killer pool must contain exactly 10 active killers';
    elsif v_match.mode = '4v4' and coalesce(cardinality(v_pool),0) <> 24 then raise exception 'The 4v4 killer pool must contain exactly 24 active killers'; end if;
    select mp.entity_id into v_captain_1 from public.match_participants mp left join public.ratings r on r.season_id = v_match.season_id and r.mode = v_match.mode and r.entity_kind = 'player'::public.entity_kind and r.entity_id = mp.entity_id where mp.match_id = p_match_id and mp.side = 1 and mp.entity_kind = 'player'::public.entity_kind order by coalesce(r.elo,1000) desc, mp.entity_id limit 1;
    select mp.entity_id into v_captain_2 from public.match_participants mp left join public.ratings r on r.season_id = v_match.season_id and r.mode = v_match.mode and r.entity_kind = 'player'::public.entity_kind and r.entity_id = mp.entity_id where mp.match_id = p_match_id and mp.side = 2 and mp.entity_kind = 'player'::public.entity_kind order by coalesce(r.elo,1000) desc, mp.entity_id limit 1;
    if v_captain_1 is null or v_captain_2 is null then raise exception 'Match participant list is incomplete'; end if;
    insert into public.match_killer_drafts(match_id,mode,killer_pool,side1_captain_id,side2_captain_id) values (p_match_id,v_match.mode,v_pool,v_captain_1,v_captain_2) on conflict (match_id) do nothing;
    select * into v_draft from public.match_killer_drafts where match_id = p_match_id;
  end if;

  -- 1v1: if the active player has not picked within 30 seconds, automatically pick a remaining Killer.
  if v_draft.mode = '1v1' and v_draft.status = 'open' and v_draft.updated_at <= now() - interval '30 seconds' then
    v_expected_side := case when v_draft.side1_pick is null then 1 else 2 end;
    select array_agg(k) into v_remaining from unnest(v_draft.killer_pool) k where k is distinct from v_draft.side1_pick and k is distinct from v_draft.side2_pick;
    if coalesce(cardinality(v_remaining),0) > 0 then
      v_random_killer := v_remaining[1 + floor(random() * cardinality(v_remaining))::integer];
      select entity_id into v_picker from public.match_participants where match_id = p_match_id and side = v_expected_side and entity_kind = 'player'::public.entity_kind limit 1;
      insert into public.match_killer_draft_actions(match_id,turn_no,side,action_type,killer_name,user_id)
      select p_match_id, coalesce(max(turn_no),0)+1, v_expected_side, 'pick', v_random_killer, coalesce(v_picker,auth.uid()) from public.match_killer_draft_actions where match_id = p_match_id;
      if v_expected_side = 1 then update public.match_killer_drafts set side1_pick = v_random_killer, updated_at = now() where match_id = p_match_id;
      else update public.match_killer_drafts set side2_pick = v_random_killer, updated_at = now() where match_id = p_match_id; end if;
      select * into v_draft from public.match_killer_drafts where match_id = p_match_id;
      if v_draft.side1_pick is not null and v_draft.side2_pick is not null then
        select k into v_random_killer from unnest(v_draft.killer_pool) k where k <> v_draft.side1_pick and k <> v_draft.side2_pick order by random() limit 1;
        update public.match_killer_drafts set third_killer = v_random_killer, status = 'complete', updated_at = now() where match_id = p_match_id;
        select * into v_draft from public.match_killer_drafts where match_id = p_match_id;
      end if;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('turn_no',a.turn_no,'side',a.side,'action_type',a.action_type,'killer_name',a.killer_name,'user_id',a.user_id,'created_at',a.created_at) order by a.turn_no),'[]'::jsonb) into v_actions from public.match_killer_draft_actions a where a.match_id = p_match_id;
  return jsonb_build_object('match_id',v_draft.match_id,'mode',v_draft.mode,'pool',to_jsonb(v_draft.killer_pool),'side1_captain_id',v_draft.side1_captain_id,'side2_captain_id',v_draft.side2_captain_id,'side1_pick',v_draft.side1_pick,'side2_pick',v_draft.side2_pick,'third_killer',v_draft.third_killer,'status',v_draft.status,'updated_at',v_draft.updated_at,'actions',v_actions);
end;
$$;
revoke all on function public.get_match_killer_draft(uuid) from public, anon;
grant execute on function public.get_match_killer_draft(uuid) to authenticated;
