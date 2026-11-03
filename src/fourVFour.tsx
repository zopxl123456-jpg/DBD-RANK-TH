import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Ban, CheckCircle2, Clock3, Crown, LoaderCircle, RefreshCw, Swords, Users } from 'lucide-react';
import { supabase } from './supabaseClient';

type LobbyPhase = 'ready_check' | 'captain_vote' | 'team_draft' | 'killer_draft' | 'complete' | 'cancelled';
type LobbyPlayer = { id: string; name: string; side: 1 | 2 | null; is_captain: boolean };
type VoteTally = { id: string; name: string; votes: number };
type TeamPick = { pick_no: number; side: 1 | 2; player_id: string; player_name: string; picked_by: string; auto_picked: boolean };
type KillerPlayer = { set_no: 1 | 2 | 3; side: 1 | 2; player_id: string; player_name: string };
type KillerAction = { turn_no: number; side: 1 | 2; action_type: 'ban' | 'pick'; set_no: 1 | 2 | 3 | null; killer_name: string; auto_selected: boolean; user_id: string };
type FourVFourState = {
  phase: LobbyPhase;
  deadline?: string;
  captain_blue_id?: string | null;
  captain_red_id?: string | null;
  first_pick_side?: 1 | 2 | null;
  current_pick_side?: 1 | 2 | null;
  current_killer_turn?: number;
  players?: LobbyPlayer[];
  votes?: VoteTally[];
  my_vote?: string | null;
  my_side?: 1 | 2 | null;
  team_picks?: TeamPick[];
  killer_players?: KillerPlayer[];
  killer_pool?: string[];
  killer_actions?: KillerAction[];
  ready_state?: { ready_count: number; total_count: number; deadline: string | null; ready_ids: string[]; status: string };
};

// Reuse the same Dead by Daylight Wiki portrait pattern as the 1v1 picker.
// Explicit filenames cover this 4v4 pool; the fallback handles future pool additions.
const fourVFourKillerPortraits: Record<string, string> = {
  'The Hillbilly': '/killer-images/hillbilly.png',
  'The Twins': '/killer-images/twins.png',
  'The Plague': '/killer-images/plague.png',
  'The Spirit': '/killer-images/spirit.png',
  'The Oni': '/killer-images/oni.png',
  'The Ghoul': '/killer-images/ghoul.png',
  'The Blight': '/killer-images/blight.png',
  'The Slasher': '/killer-images/slasher.png',
  'The Artist': '/killer-images/artist.png',
  'The Clown': '/killer-images/clown.png',
  'The Mastermind': '/killer-images/mastermind.png',
  'The Dredge': '/killer-images/dredge.png',
  'The Dark Lord': '/killer-images/darklord.png',
  'The Nightmare': '/killer-images/nightmare.png',
  'The Deathslinger': '/killer-images/deathslinger.png',
  'The Nurse': '/killer-images/nurse.png',
  'The Ghostface': '/killer-images/ghostface.png',
  'The Demogorgon': '/killer-images/demogorgon.png',
  'The Unknown': '/killer-images/unknown.png',
  'The Wraith': '/killer-images/wraith.png',
  'The Doctor': '/killer-images/doctor.png',
  'The Lich': '/killer-images/lich.png',
  'The Cenobite': '/killer-images/cenobite.png',
};

const fourVFourKillerPortraitUrl = (killer: string) => {
  const filename = fourVFourKillerPortraits[killer];
  return filename
    ? `${import.meta.env.BASE_URL}killer-images/${filename}`
    : '';
};
const turnPlan: Array<{ side: 1 | 2; action: 'ban' | 'pick'; setNo: 1 | 2 | 3 | null }> = [
  { side: 1, action: 'ban', setNo: null },
  { side: 1, action: 'ban', setNo: null },
  { side: 2, action: 'ban', setNo: null },
  { side: 2, action: 'ban', setNo: null },
  { side: 1, action: 'ban', setNo: null },
  { side: 1, action: 'ban', setNo: null },
  { side: 2, action: 'ban', setNo: null },
  { side: 2, action: 'ban', setNo: null },
  { side: 1, action: 'ban', setNo: null },
  { side: 2, action: 'ban', setNo: null },
  { side: 1, action: 'pick', setNo: 1 },
  { side: 2, action: 'pick', setNo: 2 },
  { side: 2, action: 'ban', setNo: null },
  { side: 2, action: 'ban', setNo: null },
  { side: 1, action: 'ban', setNo: null },
  { side: 1, action: 'ban', setNo: null },
  { side: 2, action: 'ban', setNo: null },
  { side: 2, action: 'ban', setNo: null },
  { side: 1, action: 'ban', setNo: null },
  { side: 1, action: 'ban', setNo: null },
  { side: 2, action: 'ban', setNo: null },
  { side: 2, action: 'ban', setNo: null },
  { side: 1, action: 'pick', setNo: 3 },
];

function remainingSeconds(deadline?: string) {
  if (!deadline) return 0;
  return Math.max(0, Math.ceil((new Date(deadline).getTime() - Date.now()) / 1000));
}

function Clock({ deadline, label = 'TIME REMAINING' }: { deadline?: string; label?: string }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 250);
    return () => window.clearInterval(id);
  }, []);
  const seconds = deadline ? Math.max(0, Math.ceil((new Date(deadline).getTime() - now) / 1000)) : 0;
  return <span className="v4v-countdown"><Clock3 size={16}/><span><small>{label}</small><strong>{String(seconds).padStart(2, '0')}s</strong></span></span>;
}

export function FourVFourLobby({ matchId, userId, onPhaseChange }: { matchId: string; userId: string; onPhaseChange: (matchId: string, phase: string) => void }) {
  const [lobby, setLobby] = useState<FourVFourState | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [selectedVote, setSelectedVote] = useState('');
  const [selectedPlayer, setSelectedPlayer] = useState('');
  const [selectedKiller, setSelectedKiller] = useState('');
  const [selectedKillerPlayer, setSelectedKillerPlayer] = useState<Record<number, string>>({});
  const refreshing = useRef(false);
  const lastPhase = useRef<string>('');
  const lastTurnToken = useRef<string>('');

  const refresh = useCallback(async () => {
    if (!supabase || refreshing.current) return;
    refreshing.current = true;
    const { data, error: rpcError } = await supabase.rpc('get_match_4v4_lobby_state', { p_match_id: matchId });
    if (rpcError) setError(rpcError.message);
    else {
      const next = data as FourVFourState;
      setLobby(next);
      if (lastPhase.current !== next.phase) { lastPhase.current = next.phase; onPhaseChange(matchId, next.phase); }
      const turnToken = `${next.phase}:${next.current_pick_side ?? ''}:${next.current_killer_turn ?? ''}`;
      if (lastTurnToken.current && lastTurnToken.current !== turnToken) { setSelectedPlayer(''); setSelectedKiller(''); }
      lastTurnToken.current = turnToken;
      if (next.my_vote) setSelectedVote(next.my_vote);
      setError('');
    }
    refreshing.current = false;
  }, [matchId, onPhaseChange]);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => { void refresh(); }, 1500);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const runAction = useCallback(async (rpc: string, args: Record<string, unknown>) => {
    if (!supabase || busy) return;
    setBusy(true);
    setError('');
    const { data, error: rpcError } = await supabase.rpc(rpc, args);
    if (rpcError) setError(rpcError.message);
    else {
      if (data && typeof data === 'object' && 'phase' in data) {
        const next = data as FourVFourState;
        setLobby(next);
        if (lastPhase.current !== next.phase) { lastPhase.current = next.phase; onPhaseChange(matchId, next.phase); }
        const turnToken = `${next.phase}:${next.current_pick_side ?? ''}:${next.current_killer_turn ?? ''}`;
        lastTurnToken.current = turnToken;
      } else await refresh();
      setSelectedPlayer('');
      setSelectedKiller('');
    }
    setBusy(false);
  }, [busy, matchId, onPhaseChange, refresh]);

  const players = lobby?.players ?? [];
  const picks = lobby?.team_picks ?? [];
  const killerPlayers = lobby?.killer_players ?? [];
  const actions = lobby?.killer_actions ?? [];
  const usedKillers = useMemo(() => new Set(actions.map(action => action.killer_name)), [actions]);
  const killerActionByName = useMemo(() => new Map(actions.map(action => [action.killer_name, action])), [actions]);
  const remainingKillers = (lobby?.killer_pool ?? []).filter(killer => !usedKillers.has(killer));
  const currentTurn = lobby?.current_killer_turn ?? 1;
  const currentStep = turnPlan[currentTurn - 1];
  const blueCaptain = lobby?.captain_blue_id ?? '';
  const redCaptain = lobby?.captain_red_id ?? '';
  const myIsBlueCaptain = userId === blueCaptain;
  const myIsRedCaptain = userId === redCaptain;
  const myCaptainSide: 1 | 2 | null = myIsBlueCaptain ? 1 : myIsRedCaptain ? 2 : null;
  const isCurrentPickCaptain = Boolean(currentStep && ((currentStep.side === 1 && myIsBlueCaptain) || (currentStep.side === 2 && myIsRedCaptain)));
  const setKillerPlayerBySide = (setNo: number, side: 1 | 2) => killerPlayers.find(item => item.set_no === setNo && item.side === side);
  const availableDraftPlayers = players.filter(player => !player.is_captain && !picks.some(pick => pick.player_id === player.id));

  async function submitVote(targetId: string) {
    setSelectedVote(targetId);
    await runAction('submit_4v4_captain_vote', { p_match_id: matchId, p_target_id: targetId });
  }

  async function pickTeamPlayer(playerId: string) {
    await runAction('submit_4v4_team_draft_pick', { p_match_id: matchId, p_player_id: playerId, p_expected_pick_no: picks.length + 1 });
  }

  async function chooseKillerPlayer(setNo: number) {
    const playerId = selectedKillerPlayer[setNo];
    if (!playerId) { setError('Choose a player to play Killer for this Set first.'); return; }
    await runAction('select_4v4_killer_player', { p_match_id: matchId, p_set_no: setNo, p_player_id: playerId });
  }

  async function submitKillerAction() {
    if (!selectedKiller) { setError('Choose a Killer first.'); return; }
    await runAction('submit_4v4_killer_action', { p_match_id: matchId, p_killer_name: selectedKiller, p_expected_turn: currentTurn });
  }

  if (!lobby || lobby.phase === 'ready_check') {
    return <div className="v4v-panel"><div className="v4v-heading"><Users size={18}/> 4v4 LOBBY</div><p className="draft-waiting">{lobby?.ready_state ? `READY CHECK · ${lobby.ready_state.ready_count}/${lobby.ready_state.total_count} PLAYERS READY` : 'Preparing the 4v4 captain lobby…'}</p>{error && <p className="form-error">{error}</p>}</div>;
  }

  const renderTeams = () => <div className="v4v-teams">
    {[1, 2].map(side => {
      const team = players.filter(player => player.side === side);
      const captainId = side === 1 ? blueCaptain : redCaptain;
      return <div className={`v4v-team ${side === 1 ? 'v4v-blue' : 'v4v-red'}`} key={side}>
        <div className="v4v-team-title"><strong>{side === 1 ? 'BLUE TEAM' : 'RED TEAM'}</strong><span>{team.length}/4</span></div>
        {team.map(player => <div className="v4v-player" key={player.id}><span>{player.name}</span>{player.id === captainId && <small><Crown size={12}/> CAPTAIN</small>}</div>)}
        {team.length === 0 && <p className="v4v-muted">Captain not elected yet</p>}
      </div>;
    })}
  </div>;

  return <section className="v4v-panel">
    <header className="v4v-header"><div><span className="eyebrow">SOLO QUEUE · 8 PLAYERS</span><h4><Swords size={18}/> 4v4 CAPTAIN LOBBY</h4></div><span className={`v4v-phase-tag phase-${lobby.phase}`}>{lobby.phase.replace('_', ' ').toUpperCase()}</span></header>

    {lobby.phase === 'captain_vote' && <>
      <div className="v4v-phase-copy"><div><strong>CAPTAIN ELECTION</strong><p>Vote for any one player except yourself. The two players with the most votes become captains. Ties are decided randomly.</p></div><Clock deadline={lobby.deadline} label="VOTING ENDS IN"/></div>
      <div className="v4v-vote-grid">{(lobby.votes ?? []).filter(player => player.id !== userId).map(player => <button type="button" key={player.id} className={`v4v-vote-card${selectedVote === player.id ? ' selected' : ''}`} onClick={() => void submitVote(player.id)} disabled={busy || remainingSeconds(lobby.deadline) <= 0}><span>{player.name}</span><strong>{player.votes} VOTES</strong>{selectedVote === player.id && <small><CheckCircle2 size={13}/> YOUR VOTE</small>}</button>)}</div>
      <p className="v4v-muted">You can change your vote before the timer ends. {selectedVote ? 'Your vote has been recorded.' : 'You have not voted yet.'}</p>
    </>}

    {lobby.phase === 'team_draft' && <>
      <div className="v4v-phase-copy"><div><strong>CAPTAIN TEAM DRAFT</strong><p>Captains pick alternately. The first captain was selected at random. If a captain misses the timer, the system picks a remaining player randomly.</p></div><Clock deadline={lobby.deadline} label="PICK ENDS IN"/></div>
      <div className="v4v-captains"><span><Crown size={14}/> BLUE: {players.find(player => player.id === blueCaptain)?.name ?? '—'}</span><span><Crown size={14}/> RED: {players.find(player => player.id === redCaptain)?.name ?? '—'}</span><span>FIRST PICK: {lobby.first_pick_side === 1 ? 'BLUE' : 'RED'}</span></div>
      {renderTeams()}
      <div className="v4v-current-turn"><strong>{lobby.current_pick_side === 1 ? 'BLUE CAPTAIN' : 'RED CAPTAIN'} PICKING</strong><small>PICK {picks.length + 1} OF 6</small></div>
      {lobby.current_pick_side === myCaptainSide && myCaptainSide !== null ? <div className="v4v-candidates">{availableDraftPlayers.map(player => <button type="button" key={player.id} onClick={() => setSelectedPlayer(player.id)} className={selectedPlayer === player.id ? 'selected' : ''}>{player.name}{selectedPlayer === player.id && <CheckCircle2 size={14}/>}</button>)}<button className="v4v-confirm-button" type="button" onClick={() => void pickTeamPlayer(selectedPlayer)} disabled={!selectedPlayer || busy}><CheckCircle2 size={15}/> DRAFT PLAYER</button></div> : <p className="v4v-muted">Waiting for the current captain to choose a teammate.</p>}
      {picks.length > 0 && <div className="v4v-action-log"><strong>TEAM DRAFT PICKS</strong>{picks.map(pick => <span key={pick.pick_no}>#{pick.pick_no} · {pick.side === 1 ? 'BLUE' : 'RED'} picked <b>{pick.player_name}</b>{pick.auto_picked ? ' · AUTO' : ''}</span>)}</div>}
    </>}

    {lobby.phase === 'killer_draft' && currentStep && <>
      <div className="v4v-phase-copy"><div><strong>KILLER PICK / BAN</strong><p>23 fixed turns · 30 seconds each · if the turn expires, the system selects a random available Killer.</p></div><Clock deadline={lobby.deadline} label="ACTION ENDS IN"/></div>
      {renderTeams()}
      <div className="v4v-action-now"><span>TURN {currentTurn} / 23</span><strong>{currentStep.side === 1 ? 'BLUE' : 'RED'} TEAM · {currentStep.action.toUpperCase()}{currentStep.setNo ? ` · SET ${currentStep.setNo}` : ''}</strong><small>{currentStep.side === 1 ? (myIsBlueCaptain ? 'YOUR ACTION' : 'WAITING FOR BLUE CAPTAIN') : (myIsRedCaptain ? 'YOUR ACTION' : 'WAITING FOR RED CAPTAIN')}</small></div>
      {currentStep.action === 'pick' && currentStep.setNo && <div className="v4v-set-player-panel">
        <strong>SET {currentStep.setNo} · CHOOSE KILLER PLAYERS</strong>
        <p>Each captain assigns one player from their own team to play Killer for this Set. The assignments can change between Sets.</p>
        <div className="v4v-set-assignments">
          {[1, 2].map(side => {
            const assigned = setKillerPlayerBySide(currentStep.setNo!, side as 1 | 2);
            const isMine = myCaptainSide === side;
            const roster = players.filter(player => player.side === side);
            return <div className={`v4v-set-assignment ${side === 1 ? 'v4v-blue' : 'v4v-red'}`} key={side}>
              <span>{side === 1 ? 'BLUE KILLER PLAYER' : 'RED KILLER PLAYER'}</span>
              {assigned ? <b>{assigned.player_name}</b> : <b className="v4v-muted">Not assigned</b>}
              {isMine && <div className="v4v-inline-select"><select value={selectedKillerPlayer[currentStep.setNo!] ?? ''} onChange={event => setSelectedKillerPlayer(current => ({ ...current, [currentStep.setNo!]: event.target.value }))}><option value="">Select teammate…</option>{roster.map(player => <option key={player.id} value={player.id}>{player.name}</option>)}</select><button type="button" onClick={() => void chooseKillerPlayer(currentStep.setNo!)} disabled={!selectedKillerPlayer[currentStep.setNo!] || busy}>LOCK</button></div>}
            </div>;
          })}
        </div>
        {killerPlayers.filter(item => item.set_no === currentStep.setNo).length < 2 && <p className="v4v-muted">Both captains must assign their Killer player before the Set's Killer pick can be locked. Missing assignments are randomized when the timer expires.</p>}
      </div>}
      <div className="v4v-killer-picker">
        <div className="v4v-killer-picker-heading">
          <div>
            <strong>{currentStep.action === 'ban' ? 'SELECT KILLER TO BAN' : `SELECT KILLER FOR SET ${currentStep.setNo}`}</strong>
            <p>Click a Killer portrait to select it. Used Killers remain visible but are locked.</p>
          </div>
          <span>{remainingKillers.length} AVAILABLE / {(lobby?.killer_pool ?? []).length} TOTAL</span>
        </div>
        <div className="v4v-killer-portrait-grid">
          {(lobby?.killer_pool ?? []).map(killer => {
            const usedAction = killerActionByName.get(killer);
            const unavailable = Boolean(usedAction);
            const selected = selectedKiller === killer;
            const unavailableLabel = usedAction?.action_type === 'ban'
              ? 'BANNED'
              : usedAction?.set_no ? `SET ${usedAction.set_no} PICK` : 'PICKED';
            return <button
              type="button"
              key={killer}
              className={`v4v-killer-portrait-card${selected ? ' selected' : ''}${unavailable ? ' unavailable' : ''}`}
              onClick={() => { if (!unavailable && isCurrentPickCaptain && !busy) setSelectedKiller(killer); }}
              disabled={unavailable || !isCurrentPickCaptain || busy}
              aria-pressed={selected}
              title={unavailable ? `${killer} — ${unavailableLabel}` : isCurrentPickCaptain ? `Select ${killer}` : `${killer} — waiting for captain`}
            >
              <div className="v4v-killer-art">
                <img
                  src={fourVFourKillerPortraitUrl(killer)}
                  alt={killer}
                  loading="lazy"
                  onError={event => {
                    event.currentTarget.style.display = 'none';
                    const fallback = event.currentTarget.nextElementSibling as HTMLElement | null;
                    if (fallback) fallback.classList.add('visible');
                  }}
                />
                <div className="v4v-killer-art-fallback" aria-hidden="true">{killer.replace(/^The\s+/i, '').slice(0, 2).toUpperCase()}</div>
                {selected && <span className="v4v-killer-selected-mark"><CheckCircle2 size={18}/></span>}
                {unavailable && <span className="v4v-killer-used-mark">{unavailableLabel}</span>}
              </div>
              <span className="v4v-killer-card-name">{killer}</span>
              {usedAction && <small className="v4v-killer-card-meta">{usedAction.side === 1 ? 'BLUE' : 'RED'} · {usedAction.action_type.toUpperCase()}{usedAction.auto_selected ? ' · AUTO' : ''}</small>}
              {!unavailable && selected && <small className="v4v-killer-card-meta selected-meta">SELECTED</small>}
            </button>;
          })}
        </div>
        {isCurrentPickCaptain ? <div className="v4v-killer-confirm-row">
          <span>{selectedKiller ? `SELECTED: ${selectedKiller}` : 'Choose a portrait above'}</span>
          <button type="button" onClick={() => void submitKillerAction()} disabled={!selectedKiller || busy || (currentStep.action === 'pick' && killerPlayers.filter(item => item.set_no === currentStep.setNo).length < 2)}>
            {currentStep.action === 'ban' ? <><Ban size={15}/> CONFIRM BAN</> : <><CheckCircle2 size={15}/> CONFIRM PICK</>}
          </button>
        </div> : <p className="v4v-muted">Only the captain whose turn is active can select and lock a Killer.</p>}
      </div>
      <div className="v4v-killer-status"><div><span>AVAILABLE</span><strong>{remainingKillers.length}</strong></div><div><span>BANNED / PICKED</span><strong>{actions.length}</strong></div><div><span>ACTIONS LEFT</span><strong>{23 - actions.length}</strong></div></div>
      {actions.length > 0 && <div className="v4v-action-log"><strong>KILLER PICK / BAN LOG</strong>{actions.slice(-8).reverse().map(action => <span key={action.turn_no}>#{action.turn_no} · {action.side === 1 ? 'BLUE' : 'RED'} {action.action_type.toUpperCase()}{action.set_no ? ` · SET ${action.set_no}` : ''} · <b>{action.killer_name}</b>{action.auto_selected ? ' · AUTO RANDOM' : ''}</span>)}</div>}
    </>}

    {lobby.phase === 'complete' && <>
      <div className="v4v-complete-banner"><CheckCircle2 size={22}/><div><strong>KILLER PICK / BAN COMPLETE</strong><p>All 23 actions have been resolved. The match is ready for play.</p></div></div>
      {renderTeams()}
      <div className="v4v-set-results">{[1, 2, 3].map(setNo => {
        const picked = actions.find(action => action.set_no === setNo);
        return <div key={setNo}><strong>SET {setNo}</strong><span>{picked?.killer_name ?? '—'}</span><small>{killerPlayers.filter(item => item.set_no === setNo).map(item => `${item.side === 1 ? 'BLUE' : 'RED'}: ${item.player_name}`).join(' · ') || 'Killer players not assigned'}</small></div>;
      })}</div>
      {actions.length > 0 && <div className="v4v-action-log"><strong>FULL DRAFT LOG</strong>{actions.map(action => <span key={action.turn_no}>#{action.turn_no} · {action.side === 1 ? 'BLUE' : 'RED'} {action.action_type.toUpperCase()}{action.set_no ? ` · SET ${action.set_no}` : ''} · <b>{action.killer_name}</b>{action.auto_selected ? ' · AUTO RANDOM' : ''}</span>)}</div>}
    </>}

    {lobby.phase === 'cancelled' && <p className="match-disputed">MATCH CANCELLED</p>}
    {busy && <p className="v4v-loading"><LoaderCircle className="spin" size={14}/> Saving action…</p>}
    {error && <p className="form-error">{error}</p>}
    <button type="button" className="v4v-refresh" onClick={() => void refresh()} disabled={busy}><RefreshCw size={13}/> REFRESH LOBBY</button>
  </section>;
}
