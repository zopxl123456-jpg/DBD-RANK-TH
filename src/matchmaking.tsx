import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { CheckCircle2, Clock3, LoaderCircle, Search, ShieldAlert, Swords, Users, XCircle, RefreshCw, Trophy, MessageCircle, Send, Crown, Ban, Sparkles } from 'lucide-react';
import { supabase } from './supabaseClient';
import { FourVFourLobby } from './fourVFour';

type Mode = '1v1' | '4v4';
type QueueResponse = {
  state: 'queued' | 'matched';
  mode: Mode;
  match_id?: string;
  elo?: number;
  range_elo?: number;
  wait_seconds?: number;
  players_found?: number;
  players_needed?: number;
  team_average_elo_difference?: number;
};
type ReadyState = { status: 'waiting' | 'ready' | 'cancelled'; deadline: string | null; ready_ids: string[]; ready_count: number; total_count: number };
type MatchRow = {
  id: string;
  mode: Mode;
  status: 'pending' | 'confirmed' | 'disputed' | 'cancelled';
  winner_side: number | null;
  created_at: string;
  confirmed_at: string | null;
  notes: string | null;
  ready_status: 'waiting' | 'ready';
  ready_deadline: string | null;
};
type ParticipantRow = { match_id: string; side: number; entity_kind: 'player' | 'team'; entity_id: string };
type MatchCard = MatchRow & {
  sides: { 1: string[]; 2: string[] };
  myConfirmation: boolean | null;
  mySide: number;
  readyState: ReadyState | null;
};
type ChatMessage = { id: string; match_id: string; user_id: string; message: string; created_at: string; sender_name?: string };
type DraftAction = { turn_no: number; side: 1 | 2; action_type: 'ban' | 'pick'; killer_name: string; user_id: string; created_at: string };
type KillerDraft = {
  match_id: string;
  mode: Mode;
  pool: string[];
  side1_captain_id: string;
  side2_captain_id: string;
  side1_pick: string | null;
  side2_pick: string | null;
  third_killer: string | null;
  status: 'open' | 'complete';
  updated_at?: string;
  actions: DraftAction[];
};

// Portraits used by the 1v1 visual Killer picker.
const killerPortraits: Record<string, string> = {
  'The Trapper': '/killer-images/trapper.png',
  'The Doctor': '/killer-images/doctor.png',
  'The Oni': '/killer-images/oni.png',
  'The Mastermind': '/killer-images/mastermind.png',
  'The Demogorgon': '/killer-images/demogorgon.png',
  'The Wraith': '/killer-images/wraith.png',
  'The Pig': '/killer-images/pig.png',
  'The Clown': '/killer-images/clown.png',
  'The Cannibal': '/killer-images/cannibal.png',
  'The Nightmare': '/killer-images/nightmare.png',
};

const killerPortraitUrl = (killer: string) =>
  killerPortraits[killer] ?? '';


const formatDuration = (seconds: number) => {
  const minutes = Math.floor(seconds / 60);
  const remaining = seconds % 60;
  return `${String(minutes).padStart(2, '0')}:${String(remaining).padStart(2, '0')}`;
};

export function MatchmakingCenter({ userId, seasonId }: { userId: string; seasonId: string | null }) {
  const [mode, setMode] = useState<Mode>('1v1');
  const [searching, setSearching] = useState(false);
  const [queueInfo, setQueueInfo] = useState<QueueResponse | null>(null);
  const [queueBusy, setQueueBusy] = useState(false);
  const [queueMessage, setQueueMessage] = useState('');
  const [queueError, setQueueError] = useState('');
  const [myElo, setMyElo] = useState<number | null>(null);
  const [matches, setMatches] = useState<MatchCard[]>([]);
  const [loadingMatches, setLoadingMatches] = useState(false);
  const [busyMatchId, setBusyMatchId] = useState<string | null>(null);
  const [notesByMatch, setNotesByMatch] = useState<Record<string, string>>({});
  const [matchMessage, setMatchMessage] = useState('');
  const [matchError, setMatchError] = useState('');
  const [chatByMatch, setChatByMatch] = useState<Record<string, ChatMessage[]>>({});
  const [chatDrafts, setChatDrafts] = useState<Record<string, string>>({});
  const [chatBusy, setChatBusy] = useState<Record<string, boolean>>({});
  const [killerDrafts, setKillerDrafts] = useState<Record<string, KillerDraft>>({});
  const [killerSelections, setKillerSelections] = useState<Record<string, string>>({});
  const [draftBusy, setDraftBusy] = useState<Record<string, boolean>>({});
  const [draftErrors, setDraftErrors] = useState<Record<string, string>>({});
  const [playerNames, setPlayerNames] = useState<Record<string, string>>({});
  const [clockNow, setClockNow] = useState(Date.now());
  const [readyBusy, setReadyBusy] = useState<Record<string, boolean>>({});
  const [fourVFourPhases, setFourVFourPhases] = useState<Record<string, string>>({});
  const handleFourVFourPhase = useCallback((matchId: string, phase: string) => {
    setFourVFourPhases(current => current[matchId] === phase ? current : { ...current, [matchId]: phase });
  }, []);
  // Smooth local queue clock: server wait time is only synchronized during the 5s queue poll.
  const queueWaitBaseRef = useRef(0);
  const queueWaitAnchorRef = useRef(Date.now());
  // Keep the history panel mounted during background refreshes.
  const hasLoadedMatches = useRef(false);
  const loadingMatchesRef = useRef(false);

  const loadMyElo = useCallback(async () => {
    if (!supabase || !seasonId) { setMyElo(null); return; }
    const { data, error } = await supabase.from('ratings')
      .select('elo')
      .eq('season_id', seasonId)
      .eq('mode', mode)
      .eq('entity_kind', 'player')
      .eq('entity_id', userId)
      .maybeSingle();
    if (!error) setMyElo(data?.elo ?? null);
  }, [mode, seasonId, userId]);

  const loadMatches = useCallback(async () => {
    if (!supabase || loadingMatchesRef.current) return;
    loadingMatchesRef.current = true;
    if (!hasLoadedMatches.current) setLoadingMatches(true);
    const { data: ownRows, error: ownError } = await supabase.from('match_participants')
      .select('match_id,side,entity_kind,entity_id')
      .eq('entity_kind', 'player').eq('entity_id', userId);
    if (ownError) { setMatchError(ownError.message); hasLoadedMatches.current = true; setLoadingMatches(false); loadingMatchesRef.current = false; return; }
    const allOwn = (ownRows ?? []) as ParticipantRow[];
    const ids = [...new Set(allOwn.map(row => row.match_id))];
    if (!ids.length) { setMatches([]); setChatByMatch({}); setKillerDrafts({}); setPlayerNames({}); hasLoadedMatches.current = true; setLoadingMatches(false); loadingMatchesRef.current = false; return; }

    const [{ data: matchRows, error: matchErrorLocal }, { data: participantRows, error: participantError }, { data: confirmationRows }] = await Promise.all([
      supabase.from('matches').select('id,mode,status,winner_side,created_at,confirmed_at,notes,ready_status,ready_deadline')
        .in('id', ids).eq('mode', mode).order('created_at', { ascending: false }).limit(30),
      supabase.from('match_participants').select('match_id,side,entity_kind,entity_id').in('match_id', ids),
      supabase.from('match_confirmations').select('match_id,confirmed').eq('user_id', userId).in('match_id', ids)
    ]);
    if (matchErrorLocal || participantError) {
      setMatchError(matchErrorLocal?.message ?? participantError?.message ?? 'Could not load match history');
      hasLoadedMatches.current = true; setLoadingMatches(false); loadingMatchesRef.current = false; return;
    }
    const rows = (participantRows ?? []) as ParticipantRow[];
    const playerIds = [...new Set(rows.filter(row => row.entity_kind === 'player').map(row => row.entity_id))];
    const { data: profileRows } = playerIds.length
      ? await supabase.from('profiles').select('id,username,display_name,in_game_name').in('id', playerIds)
      : { data: [] as { id: string; username: string; display_name: string; in_game_name: string }[] };
    const labels = new Map<string, string>();
    (profileRows ?? []).forEach((profile: { id: string; username: string; display_name: string; in_game_name: string }) => {
      labels.set(profile.id, profile.in_game_name || profile.display_name || profile.username || 'Player');
    });
    const confirmationMap = new Map<string, boolean>((confirmationRows ?? []).map((row: { match_id: string; confirmed: boolean }) => [row.match_id, row.confirmed] as [string, boolean]));
    const baseCards = ((matchRows ?? []) as MatchRow[]).map(match => {
      const parts = rows.filter(row => row.match_id === match.id);
      const myPart = parts.find(row => row.entity_kind === 'player' && row.entity_id === userId);
      const sideOne = parts.filter(row => row.side === 1).map(row => labels.get(row.entity_id) ?? 'Player');
      const sideTwo = parts.filter(row => row.side === 2).map(row => labels.get(row.entity_id) ?? 'Player');
      return {
        ...match,
        sides: { 1: sideOne, 2: sideTwo },
        myConfirmation: confirmationMap.has(match.id) ? confirmationMap.get(match.id)! : null,
        mySide: myPart?.side ?? 0,
        readyState: null
      } as MatchCard;
    });
    const readyStates = await Promise.all(baseCards.map(async match => {
      const { data } = await supabase!.rpc('get_match_ready_state', { p_match_id: match.id });
      return [match.id, data as ReadyState | null] as const;
    }));
    const readyMap = new Map<string, ReadyState | null>(readyStates);
    const cards = baseCards.map(match => ({ ...match, readyState: readyMap.get(match.id) ?? null }));

    const namesRecord: Record<string, string> = {};
    labels.forEach((name, id) => { namesRecord[id] = name; });
    setPlayerNames(namesRecord);

    const { data: chatRows } = await supabase.from('match_chat_messages')
      .select('id,match_id,user_id,message,created_at')
      .in('match_id', ids).order('created_at', { ascending: true }).limit(600);
    const nextChat: Record<string, ChatMessage[]> = {};
    ((chatRows ?? []) as Omit<ChatMessage, 'sender_name'>[]).forEach(row => {
      if (!nextChat[row.match_id]) nextChat[row.match_id] = [];
      nextChat[row.match_id].push({ ...row, sender_name: labels.get(row.user_id) ?? (row.user_id === userId ? 'You' : 'Player') });
    });
    setChatByMatch(nextChat);

    // The legacy Killer draft remains exclusive to 1v1. 4v4 uses its own
    // captain/team-draft state machine and never initializes the old draft.
    const draftResponses = await Promise.all(cards.filter(match => match.mode === '1v1').map(async match => {
      const { data, error } = await supabase!.rpc('get_match_killer_draft', { p_match_id: match.id });
      return { matchId: match.id, data: data as KillerDraft | null, error };
    }));
    const nextDrafts: Record<string, KillerDraft> = {};
    draftResponses.forEach(result => {
      if (result.data && !result.error) {
        nextDrafts[result.matchId] = result.data;
        setDraftErrors(current => { const next = { ...current }; delete next[result.matchId]; return next; });
      }
      if (result.error) setDraftErrors(current => ({ ...current, [result.matchId]: result.error.message }));
    });
    setKillerDrafts(nextDrafts);
    setMatches(cards);
    hasLoadedMatches.current = true;
    setLoadingMatches(false);
    loadingMatchesRef.current = false;
  }, [mode, userId]);

  const runQueueSearch = useCallback(async (silent = false) => {
    if (!supabase || !seasonId) {
      setQueueError('There is no active season. Please ask an administrator to activate one.');
      return;
    }
    if (!silent) {
      setQueueBusy(true); setQueueError(''); setQueueMessage('');
      queueWaitBaseRef.current = 0;
      queueWaitAnchorRef.current = Date.now();
    }
    const { data, error } = await supabase.rpc('join_matchmaking_queue', { p_mode: mode });
    if (error) {
      setSearching(false); setQueueInfo(null); setQueueError(error.message);
      queueWaitBaseRef.current = 0;
      queueWaitAnchorRef.current = Date.now();
      if (!silent) setQueueBusy(false);
      return;
    }
    const response = data as QueueResponse;
    if (response?.state === 'matched') {
      setSearching(false); setQueueInfo(null);
      queueWaitBaseRef.current = 0;
      queueWaitAnchorRef.current = Date.now();
      setQueueMessage(`Match found! Match ID: ${response.match_id?.slice(0, 8) ?? 'created'}. Go to Match History below.`);
      await loadMatches();
    } else {
      // Keep the clock moving smoothly between server polls, and never let a stale
      // server sample make the displayed wait time move backwards.
      const now = Date.now();
      const estimatedWait = queueWaitBaseRef.current + Math.max(0, Math.floor((now - queueWaitAnchorRef.current) / 1000));
      queueWaitBaseRef.current = typeof response?.wait_seconds === 'number'
        ? Math.max(response.wait_seconds, estimatedWait)
        : estimatedWait;
      queueWaitAnchorRef.current = now;
      setSearching(true); setQueueInfo(response);
      if (!silent) setQueueMessage(mode === '1v1'
        ? 'You are in the 1v1 queue. We will find the closest available ELO opponent.'
        : `You are in the 4v4 queue. ${response.players_found ?? 1}/8 players found.`);
    }
    if (!silent) setQueueBusy(false);
  }, [mode, seasonId, loadMatches]);

  useEffect(() => { void loadMyElo(); void loadMatches(); }, [loadMyElo, loadMatches]);

  useEffect(() => {
    const timer = window.setInterval(() => { void loadMatches(); }, 8000);
    return () => window.clearInterval(timer);
  }, [loadMatches]);

  useEffect(() => {
    const clock = window.setInterval(() => setClockNow(Date.now()), 1000);
    return () => window.clearInterval(clock);
  }, []);

  // Refresh Ready Check and 1v1 draft timers without reloading the whole history panel.
  useEffect(() => {
    if (!supabase || !matches.length) return;
    const refresh = async () => {
      const active = matches.filter(match => match.status === 'pending' && match.winner_side === null);
      await Promise.all(active.map(async match => {
        const { data: readyData } = await supabase!.rpc('get_match_ready_state', { p_match_id: match.id });
        if (readyData) {
          const readyState = readyData as ReadyState;
          setMatches(current => current.map(item => item.id === match.id ? { ...item, status: readyState.status === 'cancelled' ? 'cancelled' : item.status, readyState } : item));
          if (readyState.status === 'ready' && match.mode === '1v1') {
            const { data: draftData } = await supabase!.rpc('get_match_killer_draft', { p_match_id: match.id });
            if (draftData) setKillerDrafts(current => ({ ...current, [match.id]: draftData as KillerDraft }));
          }
        }
      }));
    };
    const timer = window.setInterval(() => { void refresh(); }, 1000);
    return () => window.clearInterval(timer);
  }, [matches.map(match => `${match.id}:${match.status}:${match.readyState?.status}:${match.readyState?.deadline}`).join('|')]);


  useEffect(() => {
    if (!supabase) return;
    const channel = supabase.channel(`match-chat-${userId}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'match_chat_messages' }, () => {
        void loadMatches();
      })
      .subscribe();
    return () => { void supabase!.removeChannel(channel); };
  }, [userId, loadMatches]);

  // Poll while queued. The RPC is idempotent for an existing queue entry and
  // attempts matching again if enough players have arrived since the last poll.
  useEffect(() => {
    if (!searching) return;
    const timer = window.setInterval(() => { void runQueueSearch(true); }, 5000);
    return () => window.clearInterval(timer);
  }, [searching, runQueueSearch]);

  async function cancelSearch() {
    if (!supabase) return;
    setQueueBusy(true); setQueueError('');
    const { error } = await supabase.rpc('cancel_matchmaking_queue', { p_mode: mode });
    if (error) setQueueError(error.message);
    else {
      setSearching(false); setQueueInfo(null);
      queueWaitBaseRef.current = 0;
      queueWaitAnchorRef.current = Date.now();
      setQueueMessage('Search cancelled.');
    }
    setQueueBusy(false);
  }

  async function confirmReady(matchId: string) {
    if (!supabase || readyBusy[matchId]) return;
    setReadyBusy(current => ({ ...current, [matchId]: true }));
    const { data, error } = await supabase.rpc('confirm_match_ready', { p_match_id: matchId });
    if (error) setMatchError(error.message);
    else {
      const state = data as ReadyState;
      setMatches(current => current.map(match => match.id === matchId ? { ...match, status: state.status === 'cancelled' ? 'cancelled' : match.status, readyState: state } : match));
      if (state.status === 'ready') setMatchMessage('Everyone is ready. The next lobby phase is now open!');
      else if (state.status === 'cancelled') setMatchMessage('Match cancelled because the Ready Check expired.');
    }
    setReadyBusy(current => ({ ...current, [matchId]: false }));
  }

  async function sendChat(matchId: string) {
    if (!supabase) return;
    const message = (chatDrafts[matchId] ?? '').trim();
    if (!message || chatBusy[matchId]) return;
    setChatBusy(current => ({ ...current, [matchId]: true }));
    const { error } = await supabase.from('match_chat_messages').insert({
      match_id: matchId,
      user_id: userId,
      message
    });
    if (error) {
      setMatchError(`Chat: ${error.message}`);
    } else {
      setChatDrafts(current => ({ ...current, [matchId]: '' }));
      await loadMatches();
    }
    setChatBusy(current => ({ ...current, [matchId]: false }));
  }

  async function submitKillerDraftAction(matchId: string, action: 'ban' | 'pick', forcedKiller?: string) {
    if (!supabase) return;
    const killerName = forcedKiller ?? killerSelections[matchId];
    if (!killerName) {
      setDraftErrors(current => ({ ...current, [matchId]: 'Choose a Killer first.' }));
      return;
    }
    setDraftBusy(current => ({ ...current, [matchId]: true }));
    setDraftErrors(current => ({ ...current, [matchId]: '' }));
    const { data, error } = await supabase.rpc('submit_match_killer_draft_action', {
      p_match_id: matchId,
      p_action: action,
      p_killer_name: killerName
    });
    if (error) {
      setDraftErrors(current => ({ ...current, [matchId]: error.message }));
    } else {
      setKillerDrafts(current => ({ ...current, [matchId]: data as KillerDraft }));
      setKillerSelections(current => ({ ...current, [matchId]: '' }));
    }
    setDraftBusy(current => ({ ...current, [matchId]: false }));
  }

  async function submitResult(matchId: string, winnerSide: 1 | 2) {
    if (!supabase) return;
    setBusyMatchId(matchId); setMatchError(''); setMatchMessage('');
    const { error } = await supabase.rpc('submit_ranked_result', {
      p_match_id: matchId,
      p_winner_side: winnerSide,
      p_notes: notesByMatch[matchId]?.trim() || null
    });
    if (error) setMatchError(error.message);
    else { setMatchMessage('Result submitted. All players in the match must confirm before ELO changes.'); setNotesByMatch(current => ({ ...current, [matchId]: '' })); }
    await loadMatches(); setBusyMatchId(null);
  }

  async function respond(matchId: string, confirm: boolean) {
    if (!supabase) return;
    setBusyMatchId(matchId); setMatchError(''); setMatchMessage('');
    const { data, error } = await supabase.rpc('respond_to_match', { p_match_id: matchId, p_confirm: confirm });
    if (error) setMatchError(error.message);
    else if (data === 'confirmed') setMatchMessage('All players confirmed. ELO ratings have been updated!');
    else if (data === 'disputed') setMatchMessage('The result was disputed. ELO has not changed.');
    else setMatchMessage('Your confirmation was recorded. Waiting for the remaining players.');
    await loadMatches(); await loadMyElo(); setBusyMatchId(null);
  }

  const currentQueueWait = searching
    ? queueWaitBaseRef.current + Math.max(0, Math.floor((clockNow - queueWaitAnchorRef.current) / 1000))
    : queueInfo?.wait_seconds ?? 0;
  const queueRange = queueInfo?.range_elo ?? 100;
  const queuePlayers = queueInfo?.players_found ?? (mode === '1v1' ? 1 : 1);
  const queueNeed = queueInfo?.players_needed ?? (mode === '1v1' ? 2 : 8);
  const groupedMatches = useMemo(() => matches.filter(match => match.mode === mode), [matches, mode]);

  return <section id="matches" className="section competition-section matchmaking-section">
    <div className="section-heading">
      <div><div className="eyebrow">QUEUE · MATCH · CONFIRM · RANK UP</div><h2>RANKED MATCHMAKING</h2></div>
      <span className="profile-id">ELO UPDATES AFTER ALL CONFIRMATIONS</span>
    </div>

    <div className="competition-panel matchmaking-panel">
      <div className="matchmaking-topline"><div className="panel-kicker"><Search size={18}/> AUTOMATIC MATCHMAKING</div>
        <div className="mode-switch"><button type="button" className={mode === '1v1' ? 'selected' : ''} onClick={() => { if (!searching) { setMode('1v1'); setQueueError(''); setQueueMessage(''); setMatchError(''); setMatchMessage(''); } }} disabled={searching}>1v1</button><button type="button" className={mode === '4v4' ? 'selected' : ''} onClick={() => { if (!searching) { setMode('4v4'); setQueueError(''); setQueueMessage(''); setMatchError(''); setMatchMessage(''); } }} disabled={searching}>4v4</button></div>
      </div>
      <div className="queue-intro">
        <div><h3>{mode === '1v1' ? 'FIND YOUR OPPONENT.' : 'FIND SEVEN MORE PLAYERS.'}</h3><p>{mode === '1v1' ? 'We match you with one available player near your ELO.' : 'Eight solo players enter the lobby, ready up, vote for two captains, and let the captains draft the Blue and Red teams.'}</p></div>
        <div className="queue-rating"><span>YOUR CURRENT ELO</span><strong>{myElo === null ? '—' : myElo.toLocaleString()}</strong><small>{mode} RANKED · K32</small></div>
      </div>

      {!searching ? <button className="primary find-match-button" onClick={() => void runQueueSearch(false)} disabled={queueBusy || !seasonId}>
        {queueBusy ? <LoaderCircle className="spin" size={17}/> : mode === '1v1' ? <Swords size={17}/> : <Users size={17}/>}
        {queueBusy ? 'SEARCHING…' : 'FIND MATCH'}
      </button> : <div className="queue-live-card">
        <div className="queue-live-head"><span className="search-pulse"><Search size={18}/></span><div><strong>SEARCHING FOR PLAYERS</strong><small>{mode} RANKED · ELO RANGE ±{queueRange}</small></div><span className="queue-timer"><Clock3 size={14}/>{formatDuration(currentQueueWait)}</span></div>
        <div className="queue-progress"><div className="queue-progress-fill" style={{ width: `${Math.max(8, (queuePlayers / queueNeed) * 100)}%` }}/></div>
        <div className="queue-live-foot"><span>{queuePlayers}/{queueNeed} PLAYERS FOUND</span><button className="secondary-outline" onClick={() => void cancelSearch()} disabled={queueBusy}><XCircle size={14}/> CANCEL SEARCH</button></div>
      </div>}
      {queueError && <p className="form-error profile-feedback">{queueError}</p>}
      {queueMessage && <p className="form-success profile-feedback">{queueMessage}</p>}
      <div className="matchmaking-rules"><span><ShieldAlert size={15}/> MATCHMAKING RULES</span><p>Search starts at ±100 ELO and expands by 50 every 30 seconds, up to ±400. For 4v4, eight solo players enter one lobby. After Ready Check, all players vote for captains; captains are elected randomly when votes are tied, then alternate player picks. Queueing is solo; no pre-made team is required.</p></div>
    </div>

    <div className="history-heading"><div><div className="eyebrow">YOUR RECENT GAMES</div><h3>MATCH HISTORY</h3></div><button className="refresh-link" onClick={() => void loadMatches()} disabled={loadingMatches}><RefreshCw size={13}/> Refresh</button></div>
    {matchError && <p className="form-error profile-feedback">{matchError}</p>}
    {matchMessage && <p className="form-success profile-feedback">{matchMessage}</p>}
    {loadingMatches ? <p className="empty">Loading your matches…</p> : groupedMatches.length ? <div className="ranked-match-list">
      {groupedMatches.map(match => {
        const isReady = match.status === 'pending' && match.winner_side === null && match.readyState?.status === 'ready';
        const inReadyCheck = match.status === 'pending' && match.winner_side === null && match.readyState?.status === 'waiting';
        const readyState = match.readyState;
        const secondsLeft = readyState?.deadline ? Math.max(0, Math.ceil((new Date(readyState.deadline).getTime() - clockNow) / 1000)) : 60;
        const alreadyReady = Boolean(readyState?.ready_ids?.includes(userId));
        const awaitingConfirm = match.status === 'pending' && match.winner_side !== null;
        const statusClass = match.status === 'confirmed' ? 'status-confirmed' : match.status === 'disputed' ? 'status-disputed' : 'status-pending';
        const lobbyPhaseLabel = fourVFourPhases[match.id]?.replace('_', ' ').toUpperCase();
        const matchStatusLabel = inReadyCheck ? 'READY CHECK' : isReady && match.mode === '4v4' ? (lobbyPhaseLabel === 'COMPLETE' ? 'READY TO PLAY' : lobbyPhaseLabel || '4V4 LOBBY') : isReady ? 'READY TO PLAY' : match.status;
        return <article className="ranked-match-card" key={match.id}>
          <div className="ranked-match-head"><div><span className="match-id">MATCH {match.id.slice(0, 8).toUpperCase()}</span><strong>{match.mode} RANKED</strong><small>{new Date(match.created_at).toLocaleString()}</small></div><span className={`match-status ${isReady ? 'status-ready' : statusClass}`}>{matchStatusLabel}</span></div>
          {(match.mode === '1v1' || awaitingConfirm || (match.status !== 'pending' && match.status !== 'cancelled')) && <div className="match-sides-grid">
            <div className={`match-side-panel blue-side ${match.winner_side === 1 ? 'winner-side' : ''}`}><span>BLUE SIDE</span>{match.sides[1].map((name, index) => <strong key={index}>{name}</strong>)}</div>
            <div className="versus-mark">VS</div>
            <div className={`match-side-panel red-side ${match.winner_side === 2 ? 'winner-side' : ''}`}><span>RED SIDE</span>{match.sides[2].map((name, index) => <strong key={index}>{name}</strong>)}</div>
          </div>}
          {inReadyCheck && <div className="ready-check-panel"><div className="ready-check-copy"><strong><Clock3 size={16}/> MATCH FOUND — CONFIRM READY</strong><span className="ready-countdown">{formatDuration(secondsLeft)}</span></div><p>Everyone must press READY before the timer expires. If someone does not respond in time, this match will be cancelled.</p><div className="ready-progress"><span style={{ width: `${readyState?.total_count ? (readyState.ready_count / readyState.total_count) * 100 : 0}%` }}/></div><div className="ready-check-foot"><span>{readyState?.ready_count ?? 0}/{readyState?.total_count ?? (match.mode === '1v1' ? 2 : 8)} PLAYERS READY</span><button className="primary ready-button" onClick={() => void confirmReady(match.id)} disabled={alreadyReady || readyBusy[match.id] || secondsLeft <= 0}>{alreadyReady ? <><CheckCircle2 size={14}/> READY</> : readyBusy[match.id] ? 'CONFIRMING…' : <><CheckCircle2 size={14}/> READY</>}</button></div></div>}
          {match.status === 'cancelled' && match.readyState?.status === 'cancelled' && <p className="match-disputed">MATCH CANCELLED — READY CHECK TIMED OUT</p>}
          {isReady && match.mode === '4v4' && <FourVFourLobby matchId={match.id} userId={userId} onPhaseChange={handleFourVFourPhase}/>}
          {isReady && match.mode === '1v1' && !killerDrafts[match.id] && <p className="form-error profile-feedback">{draftErrors[match.id] || 'Preparing Killer draft…'}</p>}
          {match.mode === '1v1' && killerDrafts[match.id] && (() => {
            const draft = killerDrafts[match.id];
            const usedKillers = new Set(draft.actions.map(action => action.killer_name));
            const remainingKillers = draft.pool.filter(killer => !usedKillers.has(killer));
            let nextSide: 1 | 2 = 1;
            let nextAction: 'ban' | 'pick' = 'pick';
            if (draft.mode === '4v4' && remainingKillers.length > 3) {
              nextSide = draft.actions.length % 2 === 0 ? 1 : 2;
              nextAction = 'ban';
            } else if (draft.side1_pick === null) {
              nextSide = 1; nextAction = 'pick';
            } else if (draft.side2_pick === null) {
              nextSide = 2; nextAction = 'pick';
            }
            const captainId = nextSide === 1 ? draft.side1_captain_id : draft.side2_captain_id;
            const canAct = draft.mode === '1v1'
              ? match.mySide === nextSide
              : match.mySide === nextSide && userId === captainId;
            const hasSelection = Boolean(killerSelections[match.id]);
            return <div className="killer-draft-panel">
              <div className="killer-draft-heading"><div><span className="eyebrow">MATCH LOADOUT · KILLER SELECTION</span><h4><Swords size={16}/> KILLER DRAFT</h4></div><span className={`draft-state ${draft.status === 'complete' ? 'draft-complete' : ''}`}>{draft.status === 'complete' ? 'DRAFT COMPLETE' : 'DRAFT IN PROGRESS'}</span></div>
              {draft.mode === '1v1' ? <>
                <p className="draft-help">Both players choose one Killer from the 10-character pool. Each pick has 30 seconds; if time expires, the system randomly selects an available Killer. After both picks, the third Killer is randomly selected from the remaining eight.</p>
                {draft.status !== 'complete' && <p className="draft-timer"><Clock3 size={14}/> {Math.max(0, 30 - Math.floor((clockNow - new Date(draft.updated_at ?? new Date().toISOString()).getTime()) / 1000))} SECONDS TO PICK</p>}
                <div className="draft-picks-grid">
                  <div className="draft-pick blue-pick"><span>{match.mySide === 1 ? 'YOUR SIDE · BLUE' : 'OPPONENT · BLUE'}</span><strong>{draft.side1_pick ?? 'Waiting for pick'}</strong></div>
                  <div className="draft-pick red-pick"><span>{match.mySide === 2 ? 'YOUR SIDE · RED' : 'OPPONENT · RED'}</span><strong>{draft.side2_pick ?? 'Waiting for pick'}</strong></div>
                </div>
                {draft.third_killer && <div className="third-killer"><Sparkles size={16}/><span>RANDOM THIRD KILLER</span><strong>{draft.third_killer}</strong></div>}
                {draft.status !== 'complete' && canAct && <>
                  <p className="killer-picker-label">SELECT YOUR KILLER · CLICK A PORTRAIT</p>
                  <div className="killer-portrait-grid">
                    {draft.pool.map(killer => {
                      const unavailable = usedKillers.has(killer);
                      const selected = killerSelections[match.id] === killer;
                      return <button type="button" key={killer} className={`killer-portrait-card${selected ? ' selected' : ''}${unavailable ? ' unavailable' : ''}`} onClick={() => !unavailable && setKillerSelections(current => ({ ...current, [match.id]: killer }))} disabled={unavailable || Boolean(draftBusy[match.id])} aria-pressed={selected} title={unavailable ? `${killer} already selected` : `Select ${killer}`}>
                        <img src={killerPortraitUrl(killer)} alt={killer} loading="lazy" onError={event => { event.currentTarget.style.visibility = 'hidden'; }} />
                        <span>{killer}</span>
                        {selected && <i><CheckCircle2 size={15}/> SELECTED</i>}
                        {unavailable && <i>TAKEN</i>}
                      </button>;
                    })}
                  </div>
                  <div className="draft-action-row"><span className="draft-selected-name">{killerSelections[match.id] ? `Selected: ${killerSelections[match.id]}` : 'Choose a portrait above'}</span><button className="draft-action-button" onClick={() => void submitKillerDraftAction(match.id, 'pick')} disabled={!hasSelection || draftBusy[match.id]}><CheckCircle2 size={14}/> LOCK KILLER</button></div>
                </>}
                {draft.status !== 'complete' && !canAct && <p className="draft-waiting">Waiting for {draft.side1_pick === null ? 'Blue side' : 'Red side'} to choose a Killer.</p>}
              </> : <>
                <p className="draft-help">Captain Draft: the captains alternate bans. After each side has made at least four bans, the ban phase continues until three Killers remain. Blue captain picks one, Red captain picks one, and the final unpicked Killer becomes the third. The highest-ELO player on each side is captain.</p>
                <div className="captain-strip"><span><Crown size={13}/> BLUE CAPTAIN: {playerNames[draft.side1_captain_id] ?? 'Player'}</span><span><Crown size={13}/> RED CAPTAIN: {playerNames[draft.side2_captain_id] ?? 'Player'}</span></div>
                <div className="draft-picks-grid">
                  <div className="draft-pick blue-pick"><span>BLUE PICK</span><strong>{draft.side1_pick ?? 'Not picked yet'}</strong></div>
                  <div className="draft-pick red-pick"><span>RED PICK</span><strong>{draft.side2_pick ?? 'Not picked yet'}</strong></div>
                </div>
                {draft.third_killer && <div className="third-killer"><Sparkles size={16}/><span>THIRD KILLER · LAST REMAINING</span><strong>{draft.third_killer}</strong></div>}
                {draft.status !== 'complete' && <>
                  <div className="draft-progress-line"><span>{draft.actions.filter(action => action.action_type === 'ban').length}/21 BANS</span><span>{remainingKillers.length} KILLERS REMAINING</span><span>TURN {draft.actions.length + 1}</span></div>
                  <div className="draft-roster-grid">{draft.pool.map(killer => <span key={killer} className={usedKillers.has(killer) ? 'killer-chip eliminated' : 'killer-chip'}>{killer}</span>)}</div>
                  {canAct ? <div className="draft-action-row"><select value={killerSelections[match.id] ?? ''} onChange={event => setKillerSelections(current => ({ ...current, [match.id]: event.target.value }))}><option value="">Choose a Killer…</option>{remainingKillers.map(killer => <option key={killer} value={killer}>{killer}</option>)}</select><button className="draft-action-button" onClick={() => void submitKillerDraftAction(match.id, nextAction)} disabled={!hasSelection || draftBusy[match.id]}>{nextAction === 'ban' ? <><Ban size={14}/> BAN KILLER</> : <><CheckCircle2 size={14}/> LOCK PICK</>}</button></div> : <p className="draft-waiting">Waiting for {nextSide === 1 ? 'Blue' : 'Red'} captain to {nextAction === 'ban' ? 'ban' : 'pick'} the next Killer.</p>}
                </>}
                {draft.actions.length > 0 && <div className="draft-action-log"><strong>DRAFT LOG</strong>{draft.actions.slice(-8).reverse().map(action => <span key={action.turn_no}>#{action.turn_no} · {action.side === 1 ? 'BLUE' : 'RED'} {action.action_type.toUpperCase()} · {action.killer_name}</span>)}</div>}
              </>}
              {draftErrors[match.id] && <p className="form-error">{draftErrors[match.id]}</p>}
            </div>;
          })()}
          {isReady && match.mode === '1v1' && killerDrafts[match.id]?.status !== 'complete' && <p className="draft-waiting">Complete the Killer Draft before reporting the match result.</p>}
          {isReady && match.mode === '4v4' && fourVFourPhases[match.id] !== 'complete' && <p className="draft-waiting">Complete the Captain Draft and all 23 Killer Pick/Ban actions before reporting the match result.</p>}
          {isReady && <div className="match-result-entry"><p>After the game, any participant can report the winning side. Everyone must then confirm.</p><label>Match notes (optional)<textarea rows={2} maxLength={500} value={notesByMatch[match.id] ?? ''} onChange={event => setNotesByMatch(current => ({ ...current, [match.id]: event.target.value }))} placeholder="Set scores or details (no map selection in 4v4 yet)"/></label><div className="winner-buttons"><button onClick={() => void submitResult(match.id, 1)} disabled={busyMatchId === match.id || (match.mode === '1v1' ? killerDrafts[match.id]?.status !== 'complete' : fourVFourPhases[match.id] !== 'complete')}>BLUE SIDE WON</button><button onClick={() => void submitResult(match.id, 2)} disabled={busyMatchId === match.id || (match.mode === '1v1' ? killerDrafts[match.id]?.status !== 'complete' : fourVFourPhases[match.id] !== 'complete')}>RED SIDE WON</button></div></div>}
          {awaitingConfirm && <div className="match-confirm-panel"><p>Reported winner: <strong>{match.winner_side === 1 ? 'BLUE SIDE' : 'RED SIDE'}</strong>. Your confirmation: <strong>{match.myConfirmation === true ? 'CONFIRMED' : match.myConfirmation === false ? 'DISAGREED' : 'NOT YET SENT'}</strong></p>{match.myConfirmation === null && <div className="confirmation-buttons"><button className="confirm-button" onClick={() => void respond(match.id, true)} disabled={busyMatchId === match.id}><CheckCircle2 size={14}/> CONFIRM RESULT</button><button className="dispute-button" onClick={() => void respond(match.id, false)} disabled={busyMatchId === match.id}><XCircle size={14}/> DISPUTE</button></div>}{match.myConfirmation === true && <small>Waiting for the other players to confirm. ELO has not changed yet.</small>}</div>}
          {match.status === 'confirmed' && <div className="match-complete"><Trophy size={15}/> {match.winner_side === 1 ? 'BLUE SIDE' : 'RED SIDE'} WON · ELO UPDATED</div>}
          {match.status === 'disputed' && <div className="match-disputed"><ShieldAlert size={15}/> RESULT DISPUTED · ELO WAS NOT CHANGED</div>}
          {match.status === 'cancelled' && <div className="match-disputed">MATCH CANCELLED</div>}
          <div className="match-chat-panel">
            <div className="match-chat-heading"><span><MessageCircle size={15}/> MATCH CHAT</span><small>ENTER TO SEND · SHIFT+ENTER FOR NEW LINE</small></div>
            <div className="match-chat-messages">
              {(chatByMatch[match.id] ?? []).length ? (chatByMatch[match.id] ?? []).slice(-40).map(message => <div className={`chat-message ${message.user_id === userId ? 'chat-message-own' : ''}`} key={message.id}><div className="chat-message-meta"><strong>{message.user_id === userId ? 'YOU' : message.sender_name ?? 'PLAYER'}</strong><time>{new Date(message.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</time></div><p>{message.message}</p></div>) : <p className="chat-empty">No messages yet. Say hello to the lobby.</p>}
            </div>
            <div className="match-chat-entry"><textarea rows={2} maxLength={500} value={chatDrafts[match.id] ?? ''} onChange={event => setChatDrafts(current => ({ ...current, [match.id]: event.target.value }))} onKeyDown={event => { if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); void sendChat(match.id); } }} placeholder="Write a message…"/><button type="button" className="chat-send-button" onClick={() => void sendChat(match.id)} disabled={chatBusy[match.id] || !(chatDrafts[match.id] ?? '').trim()} aria-label="Send chat message"><Send size={15}/></button></div>
            {chatBusy[match.id] && <small className="chat-sending">Sending…</small>}
          </div>
        </article>;
      })}
    </div> : <div className="empty history-empty">No {mode} matches yet. Find a match to enter the ranked queue.</div>}
  </section>;
}
