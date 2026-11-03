# DBD Ranking Website — Solo Matchmaking, Match Chat & Killer Draft

React + TypeScript + Vite + Supabase starter for a Dead by Daylight community ranking ladder.

## What this update changes

This version also improves readability across the main interface and Matchmaking panels. The queue wait timer now advances locally every second while the queue RPC continues to poll Supabase every five seconds; this keeps the on-screen clock smooth without adding one database request per second.

This update adds a match-room chat and a Killer selection/draft stage before reporting results.

- Match chat is available to match participants only. **Enter sends**; **Shift+Enter** inserts a new line. Messages are limited to 500 characters and synced through Supabase Realtime (with the existing refresh as fallback).
- 1v1 has a default pool of 10 Killers. Each player picks one, then a third Killer is randomly selected from the remaining eight.
- The legacy 4v4 draft in migration 005 used a 24-Killer pool and ELO-based captains. The active 4v4 flow in migration 007 replaces that path with a 23-Killer pool, captain voting, player drafting, and the agreed 23-action sequence.
- A result cannot be submitted until the Killer draft is complete. The picks and draft log remain visible in match history.

**Killer pool note:** The 10-name pool in migration 005 remains the active 1v1 pool. The current 4v4 flow uses its separate 23-name pool snapshot defined in migration 007; it does not change the 1v1 pool.


The old Match Center let a player select an opponent or an opposing team manually. This update replaces that flow with automatic Solo Queue matchmaking:

- **1v1:** two solo players are matched by individual ELO.
- **4v4:** eight solo players are collected. After Ready Check, the players vote for two captains; those captains draft the remaining six players into Blue and Red teams. Any provisional queue-side assignment is replaced by the captain draft.
- No pre-made team or Team Management setup is required to enter 4v4 Ranked.
- Each player has a separate 1v1 and 4v4 individual rating, both starting at 1000 in the active season.
- Search starts at +/-100 ELO, widens by 50 every 30 seconds, and caps at +/-400 ELO.
- The browser checks the queue every five seconds while searching; inactive queue entries are ignored and later cleaned up.
- When a match is created, players play the game themselves. Any participant can report Blue or Red as the winner afterward.
- Both participants must confirm a 1v1 result. All eight players must confirm a 4v4 result. Any disagreement marks the match disputed and prevents ELO changes.
- ELO changes are applied in a database function, not by client-side code. 4v4 rating changes are calculated from the average ELO of each side, and every player on that side receives the same delta.

## Update an existing installation

1. Extract this ZIP into a **new folder**. Do not overwrite the old folder while the local server is running.
2. Copy your existing `.env.local` file from the previous folder into the new project root, beside `package.json` and `index.html`.
3. Do not rerun migrations `001_initial_schema.sql`, `002_profiles_and_permissions.sql`, or `004_solo_matchmaking.sql` if they are already installed.
4. Make sure migrations `005_match_chat_killer_draft.sql` and `006_match_ready_check.sql` have already been applied. If they are already part of your working 1v1/Ready Check setup, do not run them again.
5. In Supabase Dashboard → SQL Editor → New query, open `supabase/migrations/007_solo_4v4_captain_draft.sql`, copy all its contents, paste into SQL Editor, and click Run **once**.
6. The SQL Editor should show `Success. No rows returned`. If it shows an error, stop and copy the exact error text; do not keep rerunning the migration.
7. Open the new project folder and double-click `start-windows.bat`. It will install packages if `node_modules` is not present.
8. Sign in using your existing account. The 1v1 flow remains as before; choose 4v4 to test the new captain-vote and draft flow.

Migration `003_teams_match_center.sql` from the previous version is **not required** for Solo Queue. If you already ran it, that is okay; this update leaves existing team tables and legacy team ratings in place, but the ranked queue and 4v4 leaderboard now use individual player ratings.

## Environment variables

The `.env.local` file must contain your existing Supabase project URL and publishable/anon key:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY
```

Only the Supabase publishable/anon key belongs in the browser. Never put a secret/service-role key in this file or frontend code.

## ELO formula

For side A:

`ExpectedA = 1 / (1 + 10 ^ ((AverageELOB - AverageELOA) / 400))`

`DeltaA = round(32 * (ActualA - ExpectedA))`

Side B receives `-DeltaA`. For 1v1, each side has one player's ELO. For 4v4, each side's average is calculated from its four players; every player on the same side receives that side's delta.

## Important limitations before public launch

- Match results are reported by players after they play; the system does not read DBD game-server results or verify the game outcome independently.
- A match remains in the lobby/history until a participant reports a result. After that, all participants must confirm. Admin dispute resolution, match timeouts, evidence upload, rate limiting, CAPTCHA, abuse moderation, audit logs, and backup/restore workflows should be added before public launch.
- Queue matching is implemented as transactional PostgreSQL RPC functions. It has not yet been load-tested with a large concurrent player population. Test with separate accounts in a test season before using it for a public ladder.
- The frontend build could not be run in this environment because package installation from npm timed out. TypeScript/JSX syntax transpilation passed, but run `npm install` and `npm run build` locally after downloading.

## Project structure

- `src/main.tsx` — authentication, profile, leaderboard
- `src/matchmaking.tsx` — automatic queue, lobby chat, Killer selection/draft, result reporting, confirmations, match history
- `src/style.css` — dark purple esports theme
- `src/supabaseClient.ts` — Supabase browser client
- `supabase/migrations/004_solo_matchmaking.sql` — queue tables, RLS, matchmaking RPCs, result submission and ELO processing
- `supabase/migrations/005_match_chat_killer_draft.sql` — private match chat and the original 1v1 Killer draft (legacy 4v4 draft tables remain unused by the new flow)
- `supabase/migrations/006_match_ready_check.sql` — Ready Check before the lobby starts
- `supabase/migrations/007_solo_4v4_captain_draft.sql` — current 4v4 captain voting, team draft, per-Set Killer players, 23-action Killer Pick/Ban, and result gate
- `start-windows.bat` — install dependencies and start Vite on Windows

## 4v4 Solo Queue (migration 007)

After applying migrations `001`, `002`, `004`, `005`, and `006`, apply
`007_solo_4v4_captain_draft.sql` **once** in the Supabase SQL Editor. Do not
rerun the earlier migrations if they are already installed. This adds the
4v4-only captain/team draft and the fixed Killer Pick/Ban turn sequence. The
1v1 Killer picker and its pool are kept separate.

4v4 flow:

1. Eight solo players are matched and all eight complete the existing 60-second Ready Check.
2. Each player votes for one other lobby player for 30 seconds. The two highest vote-getters become Blue and Red captains; ties are randomized (including a fully tied ballot).
3. The system randomly selects which captain drafts first. Captains alternate six picks, 30 seconds per pick; a missed pick is randomized from the remaining players.
4. For Sets 1, 2, and 3, each captain assigns one member of their own team as that Set's Killer player. The assignment can change per Set. If not assigned before the relevant 30-second pick timer expires, the player is randomized.
5. Killer Pick/Ban uses the agreed fixed 23-turn schedule (20 bans and three Set picks), 30 seconds per action. A missed action is randomized from the unused Killer pool. Map selection is not part of this version.
6. Result reporting is unlocked only after the 4v4 lobby/draft reaches `complete`.

The 4v4 lobby timer transitions are advanced by the authenticated lobby-state RPC,
which the client polls while the match is active. All captain votes, picks, team
assignments, Killer-player assignments, and Killer actions are persisted in
Supabase tables; the browser is not the source of truth for turn ownership or
random timeout actions.
