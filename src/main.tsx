import React, { useEffect, useMemo, useState } from 'react';
import type { FormEvent } from 'react';
import { createRoot } from 'react-dom/client';
import type { Session } from '@supabase/supabase-js';
import { Trophy, Swords, Users, CalendarDays, ShieldCheck, Activity, ChevronRight, UserCircle2, LogOut, X, LockKeyhole, Mail, UserRound, Save } from 'lucide-react';
import { supabase } from './supabaseClient';
import { MatchmakingCenter } from './matchmaking';
import './style.css';

type Mode = '1v1' | '4v4';
type Season = { id: string; name: string; starts_at: string; ends_at: string | null; is_active: boolean };
type Rating = { entity_id: string; entity_kind: 'player'; mode: Mode; elo: number; wins: number; losses: number };
type Profile = {
  id: string;
  username: string;
  display_name: string;
  in_game_name: string;
  platform: string;
  discord_tag: string;
  avatar_url: string;
  bio: string;
};
type AuthMode = 'login' | 'register';

const emptyProfile = (id: string): Profile => ({
  id, username: '', display_name: '', in_game_name: '', platform: 'PC', discord_tag: '', avatar_url: '', bio: ''
});

function App() {
  const [mode, setMode] = useState<Mode>('1v1');
  const [season, setSeason] = useState<Season | null>(null);
  const [ratings, setRatings] = useState<Rating[]>([]);
  const [names, setNames] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [status, setStatus] = useState('Checking database connection…');
  const [session, setSession] = useState<Session | null>(null);
  const [authOpen, setAuthOpen] = useState(false);
  const [authMode, setAuthMode] = useState<AuthMode>('login');
  const [authBusy, setAuthBusy] = useState(false);
  const [authMessage, setAuthMessage] = useState('');
  const [authError, setAuthError] = useState('');
  const [profile, setProfile] = useState<Profile | null>(null);
  const [profileBusy, setProfileBusy] = useState(false);
  const [profileMessage, setProfileMessage] = useState('');
  const [profileError, setProfileError] = useState('');
  const configured = Boolean(supabase);
  const user = session?.user ?? null;

  useEffect(() => {
    if (!supabase) return;
    let alive = true;
    void supabase.auth.getSession().then(({ data, error }) => {
      if (!alive) return;
      if (error) setAuthError(error.message);
      setSession(data.session);
    });
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession);
      setAuthMessage('');
      setAuthError('');
    });
    return () => { alive = false; subscription.unsubscribe(); };
  }, []);

  useEffect(() => {
    if (!supabase || !user) { setProfile(null); return; }
    let alive = true;
    async function loadProfile() {
      setProfileBusy(true);
      setProfileError('');
      const { data, error } = await supabase!
        .from('profiles')
        .select('id,username,display_name,in_game_name,platform,discord_tag,avatar_url,bio')
        .eq('id', user!.id)
        .maybeSingle();
      if (!alive) return;
      if (error) {
        setProfileError(`Could not load profile: ${error.message}. Please run migration 002 in Supabase.`);
        setProfile(emptyProfile(user!.id));
      } else if (data) {
        setProfile(data as Profile);
      } else {
        setProfileError('Profile row not found. Check that the profile creation trigger is installed.');
        setProfile(emptyProfile(user!.id));
      }
      setProfileBusy(false);
    }
    void loadProfile();
    return () => { alive = false; };
  }, [user?.id]);

  useEffect(() => {
    if (!supabase) {
      setLoading(false);
      setStatus('Connect Supabase to load live ranking data.');
      return;
    }
    let alive = true;
    async function loadRankings() {
      setLoading(true);
      const { data: seasons, error: seasonError } = await supabase!
        .from('seasons').select('id,name,starts_at,ends_at,is_active')
        .eq('is_active', true).limit(1);
      if (!alive) return;
      if (seasonError) { setStatus(`Database: ${seasonError.message}`); setLoading(false); return; }
      const active = seasons?.[0] as Season | undefined;
      if (!active) { setSeason(null); setRatings([]); setNames({}); setStatus('No active season. Create Season 1 in Supabase.'); setLoading(false); return; }
      const { data, error } = await supabase!
        .from('ratings').select('entity_id,entity_kind,mode,elo,wins,losses')
        .eq('season_id', active.id).eq('mode', mode).eq('entity_kind', 'player').order('elo', { ascending: false }).limit(100);
      if (!alive) return;
      if (error) { setStatus(`Database: ${error.message}`); setLoading(false); return; }
      setSeason(active);
      const rows = (data ?? []) as Rating[];
      setRatings(rows);
      if (rows.length) {
        const ids = rows.map(row => row.entity_id);
        const { data: users } = await supabase!.from('profiles').select('id,username,display_name,in_game_name').in('id', ids);
        if (alive && users) setNames(Object.fromEntries(users.map((p: {id:string;username:string;display_name:string;in_game_name:string}) => [p.id, p.in_game_name || p.display_name || p.username])));
      } else setNames({});
      if (alive) { setStatus('Live ranking data loaded.'); setLoading(false); }
    }
    void loadRankings();
    const channel = supabase.channel(`ranking-live-${mode}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'ratings' }, () => { void loadRankings(); })
      .subscribe();
    return () => { alive = false; void supabase!.removeChannel(channel); };
  }, [mode]);

  const average = useMemo(() => ratings.length ? Math.round(ratings.reduce((sum, row) => sum + row.elo, 0) / ratings.length) : 0, [ratings]);

  async function handleAuthSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!supabase) return;
    setAuthBusy(true); setAuthError(''); setAuthMessage('');
    const form = new FormData(event.currentTarget);
    const email = String(form.get('email') ?? '').trim();
    const password = String(form.get('password') ?? '');
    try {
      if (authMode === 'register') {
        const username = String(form.get('username') ?? '').trim();
        if (!/^[a-zA-Z0-9_]{3,20}$/.test(username)) throw new Error('Username must be 3–20 characters and use only letters, numbers, or _.');
        if (password.length < 8) throw new Error('Password must contain at least 8 characters.');
        const { data, error } = await supabase.auth.signUp({
          email, password, options: { data: { username, display_name: username } }
        });
        if (error) throw error;
        if (data.session) {
          setAuthMessage('Account created. You are now signed in.');
          setAuthOpen(false);
        } else {
          setAuthMessage('Registration successful. Check your email to confirm your account, then sign in.');
        }
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
        setAuthOpen(false);
      }
    } catch (error) {
      setAuthError(error instanceof Error ? error.message : 'Authentication failed. Please try again.');
    } finally { setAuthBusy(false); }
  }

  async function handleSignOut() {
    if (!supabase) return;
    const { error } = await supabase.auth.signOut();
    if (error) setAuthError(error.message);
    else { setProfile(null); setProfileMessage(''); window.scrollTo({ top: 0, behavior: 'smooth' }); }
  }

  async function handleProfileSave(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!supabase || !user || !profile) return;
    setProfileBusy(true); setProfileError(''); setProfileMessage('');
    const form = new FormData(event.currentTarget);
    const patch = {
      username: String(form.get('username') ?? '').trim(),
      display_name: String(form.get('display_name') ?? '').trim(),
      in_game_name: String(form.get('in_game_name') ?? '').trim(),
      platform: String(form.get('platform') ?? 'PC'),
      discord_tag: String(form.get('discord_tag') ?? '').trim(),
      avatar_url: String(form.get('avatar_url') ?? '').trim(),
      bio: String(form.get('bio') ?? '').trim()
    };
    if (!/^[a-zA-Z0-9_]{3,20}$/.test(patch.username)) {
      setProfileError('Username must be 3–20 characters and use only letters, numbers, or _.');
      setProfileBusy(false); return;
    }
    if (patch.avatar_url && !/^https:\/\//i.test(patch.avatar_url)) {
      setProfileError('Avatar URL must start with https://'); setProfileBusy(false); return;
    }
    const { data, error } = await supabase.from('profiles').update(patch)
      .eq('id', user.id)
      .select('id,username,display_name,in_game_name,platform,discord_tag,avatar_url,bio')
      .single();
    if (error) setProfileError(error.message);
    else { setProfile(data as Profile); setProfileMessage('Profile saved successfully.'); }
    setProfileBusy(false);
  }

  return <main className="shell">
    <header className="topbar">
      <a className="brand" href="#top"><span className="brand-icon"><Swords size={20}/></span><span>DBD<span className="violet">RANK</span><small>COMPETITIVE LADDER</small></span></a>
      <nav><a href="#leaderboard">Leaderboard</a><a href="#how">How it works</a>{user && <><a href="#profile">My Profile</a><a href="#matches">Matchmaking</a></>}</nav>
      <div className="header-account">
        {user ? <><span className="signed-in"><span className="dot"/>{profile?.display_name || profile?.username || user.email}</span><button className="account-btn" onClick={handleSignOut} title="Sign out"><LogOut size={15}/> Sign out</button></>
          : <button className="account-btn" onClick={() => { setAuthMode('login'); setAuthMessage(''); setAuthError(''); setAuthOpen(true); }}><UserCircle2 size={16}/> Login / Register</button>}
      </div>
    </header>

    <section id="top" className="hero">
      <div className="eyebrow"><span className="dot"/> THE FOG NEVER FORGETS</div>
      <h1>PROVE YOUR<br/><span>DOMINANCE.</span></h1>
      <p>A competitive ranking system built for the Dead by Daylight community. Every match matters. Every point is earned.</p>
      <div className="hero-actions"><a className="primary" href="#leaderboard"><Trophy size={17}/> View Rankings <ChevronRight size={17}/></a>{!user ? <button className="secondary secondary-button" onClick={() => { setAuthMode('register'); setAuthMessage(''); setAuthError(''); setAuthOpen(true); }}>Create your player account</button> : <a className="secondary" href="#profile">View player profile</a>}</div>
      <div className="hero-art"><div className="ring ring1"/><div className="ring ring2"/><div className="sigil"><Swords size={66}/></div><span className="art-label">RANKED // APAC</span></div>
    </section>

    <section className="stats">
      <Stat icon={<Users/>} label="RANKED ENTRIES" value={String(ratings.length).padStart(2,'0')} />
      <Stat icon={<Activity/>} label="AVERAGE ELO" value={average ? average.toLocaleString() : '—'} />
      <Stat icon={<CalendarDays/>} label="CURRENT SEASON" value={season?.name ?? 'Season 01'} />
      <Stat icon={<ShieldCheck/>} label="RATING SYSTEM" value="ELO / K32" />
    </section>

    {user && <section id="profile" className="section profile-section">
      <div className="section-heading"><div><div className="eyebrow">YOUR COMPETITIVE IDENTITY</div><h2>PLAYER PROFILE</h2></div><span className="profile-id">ACCOUNT VERIFIED BY SUPABASE AUTH</span></div>
      {profileBusy && !profile ? <p className="empty">Loading your profile…</p> : profile && <div className="profile-card">
        <div className="profile-summary">
          {profile.avatar_url ? <img className="profile-avatar" src={profile.avatar_url} alt="Player avatar" onError={event => { event.currentTarget.style.display = 'none'; }}/> : <div className="profile-avatar profile-avatar-placeholder"><UserRound size={34}/></div>}
          <div><h3>{profile.display_name || profile.username || 'New Player'}</h3><p>@{profile.username || 'set-your-username'}</p><span className="platform-chip">{profile.platform || 'PC'}</span></div>
        </div>
        <form className="profile-form" onSubmit={handleProfileSave}>
          <label>Username<input name="username" minLength={3} maxLength={20} pattern="[A-Za-z0-9_]+" defaultValue={profile.username} required/></label>
          <label>Display name<input name="display_name" maxLength={40} defaultValue={profile.display_name}/></label>
          <label>In-game name<input name="in_game_name" maxLength={40} defaultValue={profile.in_game_name} placeholder="Your DBD display name"/></label>
          <label>Platform<select name="platform" defaultValue={profile.platform || 'PC'}><option>PC</option><option>PlayStation</option><option>Xbox</option><option>Other</option></select></label>
          <label>Discord tag<input name="discord_tag" maxLength={50} defaultValue={profile.discord_tag} placeholder="username or username#0000"/></label>
          <label>Avatar image URL<input name="avatar_url" type="url" defaultValue={profile.avatar_url} placeholder="https://…"/></label>
          <label className="full-field">Bio<textarea name="bio" rows={3} maxLength={240} defaultValue={profile.bio} placeholder="Tell the community about your playstyle…"/></label>
          <div className="profile-actions"><button className="primary save-button" type="submit" disabled={profileBusy}><Save size={16}/>{profileBusy ? 'Saving…' : 'Save Profile'}</button><span className="profile-email"><Mail size={13}/>{user.email}</span></div>
        </form>
        {profileError && <p className="form-error profile-feedback">{profileError}</p>}{profileMessage && <p className="form-success profile-feedback">{profileMessage}</p>}
      </div>}
    </section>}

    {user && <>
      <MatchmakingCenter userId={user.id} seasonId={season?.id ?? null}/>
    </>}

    <section id="leaderboard" className="section">
      <div className="section-heading"><div><div className="eyebrow">THE CLIMB STARTS HERE</div><h2>LEADERBOARD</h2></div><div className="mode-switch"><button className={mode==='1v1'?'selected':''} onClick={()=>setMode('1v1')}>1v1 PLAYERS</button><button className={mode==='4v4'?'selected':''} onClick={()=>setMode('4v4')}>4v4 PLAYERS</button></div></div>
      <div className="table-wrap"><table><thead><tr><th>RANK</th><th>PLAYER</th><th>W</th><th>L</th><th>WIN RATE</th><th>ELO RATING</th></tr></thead><tbody>
        {loading ? <tr><td colSpan={6} className="empty">Loading rankings…</td></tr> :
         ratings.length ? ratings.map((row,i) => <tr key={row.entity_id}><td><span className={`rank rank-${i+1}`}>{String(i+1).padStart(2,'0')}</span></td><td><div className="player"><span className="avatar">{(names[row.entity_id] ?? '??').slice(0,2).toUpperCase()}</span><span>{names[row.entity_id] ?? `Player ${row.entity_id.slice(0,8)}`}</span></div></td><td className="good">{row.wins}</td><td className="bad">{row.losses}</td><td>{row.wins+row.losses ? `${Math.round(row.wins/(row.wins+row.losses)*100)}%` : '—'}</td><td><strong className="elo">{row.elo.toLocaleString()} <small>ELO</small></strong></td></tr>) :
         <tr><td colSpan={6} className="empty">{configured ? 'No ranked entries yet. Ratings appear after a match is created.' : 'Connect Supabase to show live rankings.'}</td></tr>}
      </tbody></table></div>
      <p className="connection"><span className={`dot ${configured?'':'muted'}`}/>{status}</p>
    </section>

    <section id="how" className="section lower">
      <div className="eyebrow">BUILT FOR COMPETITION</div><h2>EVERY MATCH COUNTS.</h2>
      <div className="steps"><Step n="01" title="JOIN THE QUEUE" text="Choose 1v1 or 4v4 and let the system find players near your ELO."/><Step n="02" title="PLAY YOUR MATCH" text="For 4v4, eight solo players are balanced into Blue and Red sides automatically."/><Step n="03" title="CONFIRM THE RESULT" text="Every participant confirms the reported result before ratings and match history update."/></div>
    </section>
    <section id="security" className="notice"><ShieldCheck/><div><strong>FAIR PLAY BY DESIGN</strong><p>Client-side users cannot directly write ratings. Match results are applied by a database function only after required confirmations.</p></div></section>
    <footer><a className="brand" href="#top"><span className="brand-icon"><Swords size={16}/></span><span>DBD<span className="violet">RANK</span></span></a><span>UNOFFICIAL COMMUNITY PROJECT · NOT AFFILIATED WITH BEHAVIOUR INTERACTIVE</span></footer>

    {authOpen && <div className="modal-backdrop" role="presentation" onMouseDown={event => { if (event.target === event.currentTarget) setAuthOpen(false); }}>
      <section className="auth-modal" role="dialog" aria-modal="true" aria-labelledby="auth-title">
        <button className="modal-close" onClick={() => setAuthOpen(false)} aria-label="Close"><X size={18}/></button>
        <div className="auth-mark"><LockKeyhole size={22}/></div>
        <div className="eyebrow">JOIN THE COMPETITIVE LADDER</div>
        <h2 id="auth-title">{authMode === 'login' ? 'WELCOME BACK.' : 'CREATE ACCOUNT.'}</h2>
        <p className="auth-description">{authMode === 'login' ? 'Sign in to manage your player profile and track your ranking.' : 'Create an account to claim your player identity in DBD Rank.'}</p>
        <div className="auth-tabs"><button className={authMode==='login'?'active':''} onClick={() => { setAuthMode('login'); setAuthError(''); setAuthMessage(''); }}>LOGIN</button><button className={authMode==='register'?'active':''} onClick={() => { setAuthMode('register'); setAuthError(''); setAuthMessage(''); }}>REGISTER</button></div>
        <form className="auth-form" onSubmit={handleAuthSubmit}>
          {authMode === 'register' && <label>Username<input name="username" minLength={3} maxLength={20} pattern="[A-Za-z0-9_]+" placeholder="e.g. MAX_SSS" autoComplete="username" required/></label>}
          <label>Email address<input name="email" type="email" placeholder="you@example.com" autoComplete="email" required/></label>
          <label>Password<input name="password" type="password" minLength={8} placeholder="At least 8 characters" autoComplete={authMode==='login'?'current-password':'new-password'} required/></label>
          {authError && <p className="form-error">{authError}</p>}{authMessage && <p className="form-success">{authMessage}</p>}
          <button className="primary auth-submit" type="submit" disabled={authBusy || !configured}>{authBusy ? 'PLEASE WAIT…' : authMode==='login'?'SIGN IN':'CREATE ACCOUNT'} <ChevronRight size={16}/></button>
          {!configured && <p className="form-error">Supabase is not configured. Add your project URL and publishable/anon key to .env.local.</p>}
        </form>
        <p className="auth-foot"><ShieldCheck size={13}/> Your password is handled securely by Supabase Auth.</p>
      </section>
    </div>}
  </main>;
}

function Stat({icon,label,value}:{icon:React.ReactNode;label:string;value:string}) { return <div className="stat"><span className="stat-icon">{icon}</span><span className="stat-label">{label}</span><strong>{value}</strong></div>; }
function Step({n,title,text}:{n:string;title:string;text:string}) { return <article className="step"><span>{n}</span><h3>{title}</h3><p>{text}</p></article>; }

createRoot(document.getElementById('root')!).render(<React.StrictMode><App/></React.StrictMode>);
