# Team Expulsion Dev Tools (TX_Dev)

Spike panel for Team Expulsion. Version 0.0.1.2, mod id `813c09c2-7476-4882-b8d6-7a0708b0891d`. Needs Gathering Storm only. Never enable it in a real game: it changes teams, declares wars and spawns units. Results go to Lua.log as `[TX][SPIKE]` and `[TX][CHECK]` lines. Read them with `python tools\summarize_log.py`.

All sessions are hotseat (one copy of the game).

## Install

- Close Civ.
- `git pull`
- `powershell -ExecutionPolicy Bypass -File tools\install.ps1 -DevOnly`
- Additional Content: enable Team Expulsion Dev Tools (TX Dev Tools) and Gathering Storm. Nothing else.
- In game: Ctrl+Shift+D or the DEV button on the launch bar. Esc closes.

Panel rows:
- Target: the player S3 changes. Default P1.
- New team: the team ID for the Target. S1 Team map fills it. You can type another.
- S2 setter: the setter S2 CALL uses.

Roles: keeper = the Target's lowest teammate, other = the lowest major on another team. Session 1 setup: keeper P0, target P1, other P2.

Check IDs: `V1-G.S3LIVE` = item, context (G gameplay, UI panel), phase. Phases: `BASE` (armed, before the change), `S3LIVE` (after the change, no load yet), `S3RELOAD<n>` (after the n-th load since the change). AL IDs add a stage: `AL3-G.S3RELOAD1.after` (`before`, `after`, `turn` = next turn start).

## Buttons

| Button | What it does |
|---|---|
| S1 Dump (UI) / S1 Dump (G) | every key of the S1 objects, incl. the diplomacy object methods |
| S1 Team map | team of every slot, fills New team |
| S2 Probe setters (no calls) / S2 CALL selected setter (!) | engine team setters (none found) |
| S3 Set Target's team | config team of the Target = New team, then broadcast |
| S3 Set MY team / S3 Undo (Target) | the same for you / back to the BASE team |
| Q Setup Session 2 | V10 friends, V9 deals, V5 marker in one press |
| Arm BASE + snapshot | records roles and the "before" values |
| Snapshot now | all checks now |
| V4 Boost (keeper) | units for a tech boost (control failed in Session 1: skip) |
| V5 Marker (keeper) | a keeper Warrior far from the target |
| V6 Other declares war on keeper | refused at BASE |
| V9 Deals target-other / V10 Friends target-other | setups, also in Q Setup |
| V3 Domination: keeper | war, Tanks and weak capitals for the keeper. Needs V6 first |
| V3 Domination: target | not used (V10 friends block the war) |
| V8 War allowed? | may keeper and target declare war on each other? |
| AL0 Read state (UI+G) | read only: diplo state both ways, HasAllied, friendship, war, marker vision |
| AL1 Friendship off (!) | keeper-target friendship off, both ways |
| AL2 Probe APIs (no calls) | which alliance and peace calls exist |
| AL3 War then peace (!) | keeper declares war on target, then makes peace |
| AL4 Alliance deal 1 turn (!) | a research alliance keeper-target for 1 turn, so it can expire |
| AL5 SetHasAllied toggle (!) | alliance flag on, then off. May stick for good |
| AL6 War/denounce valid? (UI) | read only: does the game allow war or denounce? |
| AL7 Vision OFF (all teams!) / AL7 Vision ON (restore) | GLOBAL team vision flag. Affects every team. Always press ON after OFF |
| Diplo matrix | war, allied, friend, open borders, met, team per pair |
| Clear spike state | forgets the arm |

AL1, AL3, AL4, AL5 and AL7 are refused before the split. Each logs a `before` and `after` line, and a `turn` line at every next turn start. PASS = keeper and target are no longer `DIPLO_STATE_ALLIED` either way.

## Saves

The spike saves and reloads its own game (`TX_*`, `TX2_*`). That is the one exception to "never load old saves". Never load a save from another game. Don't change Additional Content between saving and loading.

## Session 1 (done 2026-10-03, 0.0.1.1)

Setup: Hotseat, GS rules, Tiny, Quick. P0, P1, P2 human, P3 AI. Teams {P0,P1} {P2,P3}.
- S1: only UI setter is `PlayerConfigurations:SetTeam`. No G setter. Solo players own team IDs. Unused team = 10.
- S2: no candidate setter exists.
- Setups: friends and deals P1-P2, marker 40 tiles from P1. V4 control failed (boost not shared even as teammates).
- S3 live: config 0 -> 10 ok. G reads team 10 at once. UI still reads 0 and `Teams[10]` is nil. `LeaderIcon.lua:143` error, P1 lost its team banner. World Rankings still grouped P1 with P0.
- After reload: G and UI read team 10, `Teams[10]={1}`. World Rankings splits them. V9, V10 PASS.
- V5 FAIL: P1 still sees the keeper's marker. V7: P0-P1 stay `DIPLO_STATE_ALLIED` both ways.

## Session 1b (done 2026-10-03)

Same game, after the reload.
- V6 PASS: P2 at war with P0 (and P3, its intact teammate). P1 not at war.
- V8: `CanDeclareWarOn` false both ways. Diplomacy screen: P0-P1 allied.
- V3 PASS: P0 took P2's and P3's capitals. No victory. Captures not pooled.
- V11 PASS: the second reload matches the first.
- Open: does the split work live (no reload)? The leftover alliance. Shared vision.

## Session 2 (hotseat, new game)

Done 2026-10-03 with TX_Dev 0.0.1.2.

Setup: same as Session 1. Hotseat, GS rules, Tiny, Quick. P0, P1, P2 human, P3 AI. Teams {P0,P1} {P2,P3}. Fewest city-states.

**Live split (no reload)**

1. Found capitals with P0, P1, P2. End turns to turn 3.
   - Expect: the DEV button.
   - Result: yes
2. As P0: S1 Dump (UI), S1 Dump (G), S1 Team map.
   - Expect: New team filled (10 in Session 1). The log lists the methods of `Players[0]:GetDiplomacy()`.
   - Result: yes "new team: 10"
3. Q Setup Session 2. Sleep the marker Warrior.
   - Expect: P1-P2 friends and deals, a P0 Warrior far from P1.
   - Result: yes
4. End turn (all). As P0: Arm BASE + snapshot.
   - Expect: phase BASE, `V5-UI.BASE`: P1 sees the marker.
   - Result: didnt notice if P1 saw the marker. didnt want to end turn and mess up the order again to check. (Log: `V5-UI.BASE` P1 sees it.)
5. Target P1, New team as suggested. S3 Set Target's team. Don't save or load.
   - Expect: phase S3LIVE. `V1-G.S3LIVE PASS`, `V1-UI.S3LIVE FAIL` (the UI lags until a load).
   - Result: phase S3LIVE
6. Save as `TX2_split`. Don't load it yet.
   - Expect: the alliance tests start from this save.
   - Result: saved
7. V6 Other declares war on keeper. End turn (all).
   - Expect: `V6-G.S3LIVE PASS`: P2 at war with P0, not with P1.
   - Result: the P1 banner was weird on the top left (cant see the yields and stuff). I clicked it and it removed my game's UI. I can only esc and see the menu, I can still move my units but can't even see their labels. I went back to main menu and reloaded TX2_split. Before clicking V6, UI banner is back for T1, and we are still allied. Clicking his banner/portrait went to diplomatic screen, nothing glitched out. Then, I clicked V6 again. Still, no glitched banner or diplo screen. Indeed, P0 a war with P2 and P3. P1 allied with P0 but not at war with anyone. P2 at war with P0. (Log: 18 `LeaderIcon.lua:143` errors before the reload. The V6 verdict came after the reload, `V6-G.S3RELOAD1 PASS`, so the live war split was not measured.)
8. V3 Domination: keeper. As P0, take both enemy capitals with the Tanks. End turn (all).
   - Expect: no victory screen. `V3-UI.S3LIVE PASS` at P0's next turn.
   - Result: defeat screen for P3. No victory screens. (`V3-UI.S3RELOAD1 PASS`, after the reload.)
9. Still no load: look at the leader ribbon, World Rankings (all pages), the P0-P1 diplomacy screen. Any error popups?
   - Expect: write down what you see.
   - Result: leader ribbon appears normal, with P0 alied with P2. In world rankings, both players are shown separate in overall and all categories. No error popups. In P0 diplo screen, shows "allied" for our relationship with P1, but no expiry date when hovering over the "allied". P1 screen towards P0 is the same.

**Alliance tests**

Every test starts by loading `TX2_split` (the split, before any war). The phase is then `S3RELOAD1`.

10. Load `TX2_split`. AL0 Read state (UI+G) ("AL0" below), AL2 Probe APIs (no calls), AL6 War/denounce valid? (UI).
    - Expect: AL0 says ALLIED both ways. AL2 and AL6 list what exists and what is allowed.
    - Result: see logs. AL0: ALLIED both ways, HasAllied no, GetAllianceType -1. AL6: war refused ("Some member of your team is a friend or ally"), denounce refused. AL2: G has `PlayersVisibility[p]:RemoveOutgoingVisibility`, `GetDiplomacy():SetVisibilityOn/RecheckVisibilityOnAll`, `SetHasMet`.
11. AL3: load `TX2_split`. AL0. AL3 War then peace (!). End turn (all). AL0.
    - Expect: `AL3-*.after` PASS (UNFRIENDLY both ways).
    - Result: see logs. `AL3 PASS`: ALLIED, then WAR, then UNFRIENDLY right after peace, NEUTRAL next turn. Vision still shared.
12. AL4: load `TX2_split`. AL0. AL4 Alliance deal 1 turn (!). End turn (all) twice. AL0.
    - Expect: the alliance starts, then expires to FRIENDLY (`AL4-*.turn` PASS). Note TurnsUntilExpiration.
    - Result: see logs. after AL4 I saw in diplo screen that alliance had 20 turns left. After 2 end turns, this was 18 turns. however AL4 brings up a historic moment because of the boost to diplomatic service by having an alliance with another civilization (not good). after the "20 turns" was over, the alliance went back to a no limit alliance (nothing when hovering). (FAIL: duration 1 ignored, a real 20-turn research alliance.)
13. AL5: load `TX2_split`. AL0. AL5 SetHasAllied toggle (!). End turn (all). AL0.
    - Expect: HasAllied stays yes after "off". State likely still ALLIED (INFO).
    - Result: after end turn once, see in diplo screen alliance has 20 turns left. (FAIL: SetHasAllied(true) made a real alliance and (false) did nothing.)
14. AL1: load `TX2_split`. AL0. AL1 Friendship off (!). End turn (all). AL0.
    - Expect: friends no both ways. State likely still ALLIED (INFO).
    - Result: after AL1, diplo screen "alliance" still has no expiry (nothing when hovering). (Friendship off works, state stays ALLIED.)
15. AL7: load `TX2_split`. AL0. AL7 Vision OFF (all teams!). End turn (all). AL0. AL7 Vision ON (restore). End turn (all). AL0.
    - Expect: if P1 loses the marker with the flag off, the shared vision is team vision. P3 probably loses P2's capital too (the flag is global).
    - Result: I kept testing after with multiple turns, and the shared vision stayed for all despite Al7 vision OFF! EVEN AFTER AL3 war then peace (now no relationships between P0 and P1, not even friendship) and then AL7, shared vision remained (but the other guy's unit badges were a bit translucent, but can still see around their units even far from capital). (FAIL: the flag changes nothing. Vision is not from the alliance either.)

Then quit to the desktop and send the raw Lua.log file, not only the summary.

Summary: before a reload the base UI breaks (`LeaderIcon.lua:143`, clicking P1's banner killed the UI), so a kick needs a save and reload right away. After it, war and victory are split. Only war then peace (AL3) ends the ALLIED state. Shared vision survives everything tried, including AL3 and AL7. V9/V10 FAIL at turn 35 is the normal 30-turn expiry of the deals and friendship made on turn 3, not the split.

## Session 3 outline (hotseat, other team shapes)

Same buttons. Set Target with the < > arrows and New team in its box. After each S3: save, load, end turn (all).

**3a. Three-player team.** Setup: P0, P1, P2 human on Team 1. P3 human or AI on Team 2.
1. Capitals, turn 3. S1 Team map. Target P2. Q Setup Session 2. End turn. Arm BASE.
2. S3 Set Target's team (New team as suggested). Save, load, end turn.
   - Expect: `V1` PASS. P0 and P1 still one team.
3. V6 Other declares war on keeper (P3 on P0). End turn. Diplo matrix.
   - Expect: P0 and P1 both at war with P3. P2 not.
4. Second kick: S1 Team map (suggests the next ID, 11 if the first was 10). Target P1, New team as suggested. Arm BASE. S3 Set Target's team. Save, load, end turn.
   - Expect: `V1` PASS, P1 alone on the new team. Every player on its own team.

**3b. AI teammate.** Setup: P0 human and P1 AI on Team 1. P2 human and P3 AI on Team 2.
1. Capitals, turn 3. Target P1. Q Setup Session 2. End turn. Arm BASE.
2. S3 Set Target's team (New team as suggested). Save, load, end turn.
   - Expect: `V1` PASS. The AI keeps playing, no errors.
3. V6 Other declares war on keeper. End turn. Diplo matrix.
   - Expect: P2 at war with P0, not with P1.

## Afterwards

- Quit to the desktop. Lua.log is buffered until the game exits.
- Send `Lua.log` from `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs`.
- `python tools\summarize_log.py` prints one line per check ID (latest verdict) and the spike lines by section.
