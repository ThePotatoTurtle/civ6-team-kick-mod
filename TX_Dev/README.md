# Team Expulsion Dev Tools (TX_Dev)

The spike panel for Team Expulsion. Mod id `813c09c2-7476-4882-b8d6-7a0708b0891d`, version 0.0.1.1, built for the TX 0.0.1 spike. It needs Gathering Storm and nothing else. Never enable it in a real game: it changes teams, declares wars and spawns units. Every result goes to Lua.log as `[TX][SPIKE]` and `[TX][CHECK]` lines. Read them with `python tools\summarize_log.py`.

## Install and open

- Close the game. Run `powershell -ExecutionPolicy Bypass -File tools\install.ps1 -DevOnly`.
- In Additional Content, enable Gathering Storm and Team Expulsion Dev Tools. Nothing else.
- Open the panel with Ctrl+Shift+D or the DEV button on the launch bar. Esc closes it.

The panel has three rows above the buttons:
- Target: the player the S3 and S2 buttons change. Only living majors. Default P1.
- New team: the team ID to move the target to. S1 Team map fills it in. You can type another one.
- S2 setter: the setter S2 CALL uses. S2 Probe setters fills the list.

The roles line shows keeper, target and other. The keeper is the target's lowest teammate, the other is the lowest major on another team. With the Session 1 setup that is keeper P0, target P1, other P2.

## Files

| File | What |
|---|---|
| `TX_Dev.modinfo` | the mod |
| `Scripts/TX_Dev_Lib.lua` | shared helpers: the probe, the key dumper, log lines, verdicts. Loaded by both scripts. |
| `Scripts/TX_Dev_Gameplay.lua` | gameplay side: button commands and the turn start snapshot |
| `UI/TX_Dev_Panel.xml`, `UI/TX_Dev_Panel.lua` | the panel |

## Buttons

Context: UI runs in the panel, G runs in the gameplay script (sent as a request). Check IDs look like `V1-G.S3LIVE`: item, context, then the phase (`BASE`, `S3LIVE`, `S3RELOAD1`, ... with `MP-` in network games).

| Button | cmd | Context | What it does | Check IDs | TP item |
|---|---|---|---|---|---|
| S1 Dump (UI) | | UI | lists every key of the 14 S1 objects, team keys and setter-like keys first | `S1-UI` | 1.1 |
| S1 Dump (G) | `s1_dump` | G | the same in gameplay | `S1-G` | 1.1 |
| S1 Team map | `s1_map` | UI + G | team of every slot, live and config, and the lowest unused team ID. Fills New team. | `S1TEAM-UI`, `S1TEAM-G` | 1.1, 1.2 |
| S2 Probe setters (no calls) | `s2_probe` | UI + G | checks which candidate team setters exist. Calls nothing. | `S2-UI`, `S2-G` | 1.2 |
| S2 CALL selected setter (!) | `s2_call` | UI or G | calls the selected setter once on the Target with the New team, then snapshots | `S2-*`, `V1-*.S2LIVE` | 1.2, 1.4 |
| S3 Set Target's team | `changed` | UI (+ G read) | config team change: `PlayerConfigurations[t]:SetTeam`, then `Network.BroadcastPlayerInfo` | `S3-UI.*`, `S4-G.*` | 1.3, 1.4 |
| S3 Set MY team | `changed` | UI (+ G read) | the same for your own player | `S3-UI.*`, `S4-G.*` | 1.3 |
| S3 Undo (Target) | | UI | puts the Target's config team back to its value at Arm BASE | | 1.3 |
| Arm BASE + snapshot | `arm` | G + UI | records roles, teams, capitals and the "before" values | `V*-G.BASE`, `V*-UI.BASE` | 1.5 |
| Snapshot now | `snap` | G + UI | all checks right now | `V*-*` | 1.5 |
| V4 Boost (keeper) | `v4_boost` | UI + G | spawns the units of an "own X units" tech boost for the keeper | `V4-UI.*` | V4 |
| V5 Marker (keeper) | `v5_marker` | G | a keeper Warrior on the free plot farthest from the target | `V5-UI.*`, `V5-G.*` | V5 |
| V6 Other declares war on keeper | `v6_war` | G | the other declares war on the keeper. Refused before the change. | `V6-G.*` | V6 |
| V9 Deals target-other | `v9_deals` | G | open borders both ways plus 1 gold per turn, target to other | `V9-G.*`, `V9-UI.*` | V9 |
| V10 Friends target-other | `v10_friend` | G | declared friendship target and other | `V10-G.*`, `V10-UI.*` | V10 |
| V3 Domination: keeper | `v3_setup` | G | war, 3 Tanks and a weakened capital next to every enemy capital, for the keeper | `V3-*` | V3 |
| V3 Domination: target | `v3_setup` | G | the same for the target. Not used in the sessions: V10 makes the target and the other declared friends, so the target can't go to war with them | `V3-*` | V3 |
| V8 War allowed? | | UI | may keeper and target declare war on each other? | `V8-UI.*` | V8 |
| Diplo matrix | `diplo` | G | war, alliance, friendship, open borders, met and team per pair | | V7 |
| Clear spike state | `clear` | G | forgets the arm and the S1/S2 lists | | |

V2, V3, V8, V11 and V12 also need your eyes. The steps below say what to look at.

## Saves in this spike

- The spike has to save and reload the game it tests: `TX_baseline`, `TX_s3`, `TX_s3r1`, `TX_s2`, `TX_mp`.
- That's fine, and it's the one exception to "never load old saves". All of them come from the same new game in the same session, with the same mod set.
- Never load a save from any other game, and don't change Additional Content between saving and loading.

## Session 1: Hotseat (about 20 min)

Setup:
- Multiplayer, Hotseat, Create Game. Gathering Storm rules, Tiny map, Quick speed.
- Players: P0, P1 and P2 human, P3 AI. Teams: P0 and P1 on Team 1, P2 and P3 on Team 2.
- The fewest city-states the setup allows.

1. Turn 1: found the capital with P0, P1 and P2. End turns until turn 3.
   - Why: the setup buttons need capitals.
   - Expect: the DEV button on the launch bar.
   - Result:
2. As P0, open the panel. Press S1 Dump (UI), S1 Dump (G), then S1 Team map.
   - Why: find team setters in both contexts, and how team IDs are numbered.
   - Expect: the panel shows a suggested New team.
   - Result:
3. Press S2 Probe setters (no calls).
   - Why: which candidate setters exist.
   - Expect: the S2 setter row lists the hits, if any.
   - Result:
4. Press V10 Friends target-other, V9 Deals target-other, V5 Marker (keeper), V4 Boost (keeper). Put the marker Warrior to sleep. Don't move it.
   - Why: build the "before" state.
   - Expect: SPIKE lines with ok=true, a P0 Warrior far from P1, new P0 units near P0's capital.
   - Result:
5. End turn with all three humans. As P0, press Arm BASE + snapshot.
   - Why: record the "before" column.
   - Expect: `V4-UI.BASE` says P1 got the boost too, and `V5-UI.BASE` says P1 sees the marker.
   - Result:
6. Save as `TX_baseline`.
   - Why: S2 and the lobby test start from here.
   - Expect: -
   - Result:
7. Target P1, New team as suggested. Press S3 Set Target's team.
   - Why: the config level change (TP 1.3).
   - Expect: `S3-UI.S3LIVE PASS`. The live team probably doesn't change yet.
   - Result:
8. Open World Rankings and look at the leader ribbon. Press Snapshot now.
   - Why: V2 and the "after, live" column.
   - Expect: write down what the screens show.
   - Result:
9. Save as `TX_s3`. Exit to the main menu and load `TX_s3`.
   - Why: does the config team apply on reload (Mode B)?
   - Expect: `V1-G.S3RELOAD1` PASS if it does.
   - Result:
10. End turn once (all players). Then save as `TX_s3r1`.
    - Why: the turn start checks after the reload. The new save carries the reload count for step 14.
    - Expect: V1 and V5 PASS, V9 and V10 PASS.
    - Result:

Stop here if V1 still fails and S2 found nothing. Then the lobby test (S3b) is next, else Mode C. Quit to the desktop and send Lua.log.

## Session 1b: Hotseat, continued

The same day, from `TX_s3`. Only if V1 passed after the reload or S2 found a setter.

11. Press V4 Boost (keeper) again, then V6 Other declares war on keeper. End turn.
    - Why: V4 and V6.
    - Expect: V4 PASS (P0 boosted, P1 not), V6 PASS (P1 not at war).
    - Result:
12. Press V8 War allowed?, then as P0 open diplomacy with P1.
    - Why: V8.
    - Expect: write down whether war is offered.
    - Result:
13. Press V3 Domination: keeper. As P0, take both enemy capitals with the Tanks. End turn.
    - Why: V3, shared victory.
    - Expect: no victory screen. P1 still holds its own capital as a rival.
    - Result:
14. Load `TX_s3r1` and end turn once.
    - Why: V11, the second reload. The reload count is stored in the save, so loading `TX_s3` again would only give `S3RELOAD1` again.
    - Expect: the `S3RELOAD2` lines match `RELOAD1`.
    - Result:
15. Only if S2 listed a setter: load `TX_baseline`. The panel forgets New team and the S2 setter row on every load, so press S1 Team map, S1 Dump (UI) and S2 Probe setters (no calls) again. Pick the setter in the S2 setter row, press S2 CALL selected setter (!). Then Snapshot now, save `TX_s2`, reload, end turn.
    - Why: Mode A.
    - Expect: `V1-G.S2LIVE` PASS. If the game crashes, write that down.
    - Result:

## Session 2: network MP (about 20 min)

Run it only if Session 1 shows that S3 or S2 changes the team.

Setup:
- Two PCs, both with the same TX_Dev, LAN or Internet.
- Host = Leon = P0, client = P1, AI = P2. Teams: P0 and P1 against P2. Tiny map, Quick speed.

1. Found the capitals. On turn 2, press S1 Team map on both PCs.
   - Why: the same IDs on both machines.
   - Expect: the same suggestion on both.
   - Result:
2. Host: V5 Marker (keeper). End turn. Host: Arm BASE + snapshot.
   - Why: the "before" column in MP.
   - Expect: `V*-*.MP-BASE` INFO lines.
   - Result:
3. Client: Target P0, S3 Set Target's team. Both: Snapshot now.
   - Why: can a client set another player's config (Q1)?
   - Expect: compare the `S3` and `V1` lines on both PCs. Watch for a desync or a "player info mismatch" (Q3).
   - Result:
4. Client: S3 Undo (Target), then S3 Set MY team. Both: Snapshot now.
   - Why: can a client set its own config?
   - Expect: as step 3.
   - Result:
5. Client: Target P1 (the client itself), then S3 Undo (Target). Host: Target P1, S3 Set Target's team. Both: Snapshot now.
   - Why: can only the host set it (Q2)?
   - Expect: as step 3.
   - Result:
6. Host saves `TX_mp`. Both exit to the main menu. Host loads `TX_mp` from the multiplayer menu and the client rejoins.
   - Why: Q4, the change survives a host reload for everyone.
   - Expect: the `MP-S3RELOAD1` lines on both PCs agree, with the same `fp`.
   - Result:
7. Host: V6 Other declares war on keeper. Play 10 turns.
   - Why: V6 in MP, and V12.
   - Expect: no desync, the same `V12` fp every turn in both logs.
   - Result:

## Afterwards

- Quit to the desktop. Lua.log is buffered until the game exits.
- Send Lua.log from `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs`. In Session 2, send it from both PCs.
- Run `python tools\summarize_log.py` (or `--log <path>` for a copied log). It prints one line per check ID with its latest verdict, then the spike lines by section.
