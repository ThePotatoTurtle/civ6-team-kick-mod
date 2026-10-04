# Team Kick Dev Tools (TX_Dev)

Spike panel for Team Kick. Version 0.0.1.5, mod id `813c09c2-7476-4882-b8d6-7a0708b0891d`. Needs Gathering Storm only. Never enable it in a real game: it changes teams, declares wars and spawns units. Results go to Lua.log as `[TX][SPIKE]` and `[TX][CHECK]` lines. Read them with `python tools\summarize_log.py`.

All sessions are hotseat (one copy of the game).

## Install

- Close Civ.
- `git pull`
- `powershell -ExecutionPolicy Bypass -File tools\install.ps1 -DevOnly`
- Additional Content: enable Team Kick Dev Tools (TX Dev Tools) and Gathering Storm. Nothing else.
- In game: Ctrl+Shift+D or the DEV button on the launch bar. Esc closes.

Panel rows:
- Target: the player S3 changes. Default P1.
- New team: the team ID for the Target. S1 Team map fills it. You can type another.
- S2 setter: the setter S2 CALL uses.

Roles: keeper = the Target's lowest teammate, other = the lowest major on another team. Session 1 setup: keeper P0, target P1, other P2.

Check IDs: `V1-G.S3LIVE` = item, context (G gameplay, UI panel), phase. Phases: `BASE` (armed, before the change), `S3LIVE` (after the change, no load yet), `S3RELOAD<n>` (after the n-th load since the change). AL, VIS and K IDs add a stage: `AL3-G.S3RELOAD1.after` (`before`, `after`, `turn` = every later turn start). `VIS<n>` and `Kvis` lines are the vision read-out, `AL0fx` / `AL3fx` / `AL3bfx` / `AL3Tfx` the war side effects. `AL3T` adds the stage `war` and judges every pair target-keeper in one line. S3n uses the path `S3n` (`S3nLIVE`, `S3nRELOAD1`). R lines are `R-UI.<step>` (`RK-UI.<step>`), steps `prep`, `apply`, `save`, `query`, `load`.

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
| AL0 Read state (UI+G) | read only: diplo state both ways, HasAllied, friendship, met, war, vision (`VIS0`), side effects (`AL0fx`) |
| AL1 Friendship off (!) | keeper-target friendship off, both ways |
| AL2 Probe APIs (no calls) | which alliance and peace calls exist |
| AL3 War then peace (!) | keeper declares war on target, then makes peace |
| AL3b War(false) then peace (!) | AL3 with DeclareWarOn's third argument false, to compare penalties |
| AL3T Target declares then peace (!) | HARD kick war step: the target declares war on each remaining teammate, then makes peace with each |
| AL4 Alliance deal 1 turn (!) | a research alliance keeper-target for 1 turn, so it can expire |
| AL4L Alliance, friends off (!) | AL4, then AL1 at once. For the run to the alliance's expiry |
| AL5 SetHasAllied toggle (!) | alliance flag on, then off. May stick for good |
| AL6 War/denounce valid? (UI) | read only: does the game allow war or denounce? |
| AL7 Vision OFF (all teams!) / AL7 Vision ON (restore) | GLOBAL team vision flag. Affects every team. Always press ON after OFF |
| AL8 Unmeet both ways (!) | clean break probe: keeper and target "unmeet" each other |
| AL9 Unmeet then meet (!) | clean break probe: unmeet, then meet again |
| VIS1 Remove outgoing vis (!) | keeper and target stop sending vision to each other |
| VIS2 Recheck visibility (!) | asks the game to recompute keeper's and target's visibility |
| VIS3 SetVisibilityOn 0 (!) | diplomatic visibility level 0, both ways |
| K Full kick (S3+VIS1) (!) | the real kick: S3 Set Target's team, then VIS1. No war. Only at BASE |
| S3n Set team, no broadcast (!) | S3 Set Target's team without the broadcast |
| P-Teams read | read only: the panel's own `Teams` table for the Target's old and new team |
| P-Teams WRITE panel copy (!) | after S3: moves the Target to its new team in the panel's own `Teams`, then a broadcast. May change only the panel's copy |
| R Apply + reload (hotseat) (!) | at BASE, on your turn: S3 Set Target's team, saves `TX_autoreload_<date>_<time>` (a new name each run), loads it by itself. Not in network MP |
| RK Kick + VIS1 + reload (!) | the same with K (S3 + VIS1) |
| Diplo matrix | war, allied, friend, open borders, met, team per pair |
| Clear spike state | forgets the arm |

The (!) AL and VIS buttons are refused before the split (AL3T also when the target has no living teammate left). Each logs a `before` and `after` line, and a `turn` line at every later turn start. AL PASS = keeper and target have met and are no longer `DIPLO_STATE_ALLIED` either way. AL3T PASS = no pair target-keeper is ALLIED or at war. VIS PASS = the target no longer sees the keeper's marker or far city, while the keeper does ("marker missing" when the keeper doesn't see its own marker: no verdict).

## Saves

The spike saves and reloads its own game (`TX_*`, `TX2_*`, `TX3_*`, `TX3b_*`, `TX3c*`). That is the one exception to "never load old saves". Never load a save from another game. Don't change Additional Content between saving and loading.

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

## Session 3 (hotseat, new game)

Done 2026-10-04. TX_Dev 0.0.1.3. Leon's order for ending the leftover alliance: a clean break, then a real alliance that truly ends, then war and peace as the last resort.

**a) Setup**

1. Setup as Session 1: Hotseat, GS rules, Tiny, Quick. P0, P1, P2 human, P3 AI. Teams {P0,P1} {P2,P3}. Found capitals, end turns to turn 3.
2. As P0: S1 Team map. Q Setup Session 2. End turn (all). Arm BASE + snapshot. Save as `TX3_base`.
   - Expect: New team filled (10), phase BASE.
   - Result: New team filled (10), phase BASE.
3. S3 Set Target's team. Save as `TX3_split`. Load `TX3_split`.
   - Expect: phase S3RELOAD1, `V1-*.S3RELOAD1 PASS`.
   - Result: phase S3RELOAD1

**b) Vision tests.** For each of VIS1, VIS2, VIS3: load `TX3_split`, V5 Marker (keeper), end turn (all), AL0, the VIS button, end turn (all), AL0. As P1, also look at P0's land.

4. VIS1 Remove outgoing vis (!).
   - Expect: `VIS1-*.after` or `.turn` PASS: P1 no longer sees P0's marker and far city.
   - Result: as P1, still see P0's lands. (Log: `RemoveOutgoingVisibility` returned false both ways: nothing to remove.)
5. VIS2 Recheck visibility (!).
   - Expect: write down what P1 sees.
   - Result: P1 still sees P0's lands and units
6. VIS3 SetVisibilityOn 0 (!).
   - Expect: write down what P1 sees.
   - Result: P1 still sees P0's lands and units

**c) Clean break probes.** Each: load `TX3_split`, AL0, the button, end turn (all), AL0. Look at the diplomacy screen and the ribbon.

7. AL8 Unmeet both ways (!).
   - Expect: while P0 and P1 are unmet, `AL8-*` is INFO "INCONCLUSIVE: not met" (an unmet pair is no exit; the state is still logged). PASS only if they meet again on their own and are not ALLIED. Do P0 and P1 still know each other?
   - Result: from both P0 and P1 perspectives, still appear allied to each other on both ribbon and diplo (no expiry date). (Log: `SetHasMet(x,false)` returned false, still met both ways.)
8. AL9 Unmeet then meet (!).
   - Expect: `AL9-*` PASS if meeting again starts them fresh (NEUTRAL). Any first-meeting popup?
   - Result: from both P0 and P1 perspectives, still appear allied to each other on both ribbon and diplo (no expiry date).

**d) Alliance expiry run**

9. Load `TX3_split`. AL0. AL4L Alliance, friends off (!). End turns (all) until the alliance's TurnsUntilExpiration (diplomacy screen, or the `AL4L-UI.*.turn` lines) reaches 0, then 2 more turns. AL0.
   - Expect: after the expiry the state is FRIENDLY or NEUTRAL (`AL4L-*.turn PASS`), not back to the timeless ALLIED. Note any historic moment.
   - Result: both P0 and P1 get the historic moment. after 20 turns, alliance goes to "Expires in 0 turns". After one more end turn, reverts to the timeless ALLIED. Forgot to AL0 at the end.
10. Only if time: the same with AL4 Alliance deal 1 turn (!), for comparison.
    - Result: both P0 and P1 get the historic moment. right after AL4, turns into normal 20 turn alliance. once again, turns into "Expires in 0 turns" and upon endturn back to timeless ALLIED.

**e) Full kick**

11. Load `TX3_base`. K Full kick (S3+VIS1) (!). Wait for the `[K] UI done. NOW save` line (a `WARNING ... do NOT save` line means load `TX3_base` again). Save as `TX3_kick`. Load `TX3_kick`. V6 Other declares war on keeper. End turn (all). AL0.
    - Expect: separate teams, P1 not at war with P2, still ALLIED with P0 (no war step), and no shared vision if VIS1 worked (`Kvis-*.turn PASS`).
    - Result: didnt get this [K] UI line. I clicked P1's banner portrait and got the UI glitch, before I saved, closed game and reloaded. Upon reload, we were timeless allied again. Clicked V6, P0 at war with P2 and P3; P1 not at war with either. For logging: I tried 11 again, loading from TX3_base then K Full kick. Indeed, after reload the timeless alliance returns! (Log: the `[K] UI done` line is there; it only goes to Lua.log, not the screen. K works as built; it has no war step, so the alliance stays.)

**f) War then peace side effects (last resort)**

12. Load `TX3_split`. AL0. AL3 War then peace (!). Look at notifications, historic moments, grievances in the diplomacy screen. End turn (all). AL0.
    - Expect: `AL3-*.after PASS`. `AL3fx` lines: grievances, warmonger, war turn, peace allowed, open borders, deals, era score.
    - Result: got declaration of war and then negotiated peace notifications. I see P1 has 90 grievances towards P0. (Log `AL3fx`: grievances 100 right after, 90 next turn; warmonger level None; era score unchanged; no new war allowed for 8 turns on Quick; open borders kept.)
13. Load `TX3_split`. AL3b War(false) then peace (!). Same as 12.
    - Expect: compare with 12.
    - Result: got peace notificaton, but P0 and P1 are still timeless allies (Log: `DeclareWarOn(...,false)` did not start a war.)

**g) Team shapes (optional if time).** After each S3: save, load, end turn (all).

14. Three-player team: P0, P1, P2 human on one team, P3 on the other. Target P2. Arm BASE. S3 Set Target's team. V6. Diplo matrix.
    - Expect: `V1` PASS. P0 and P1 at war with P3, P2 not.
    - Result: P3 is AI. I settled capital and skipped to Turn 3 before the Arming. Entered 10 in "new team" before S3, then V6 and diplo matrix. I only saved, reloaded, and ended turn (all) after diplo matix! After reload, P0 at war with P3 and allied with the other two. P1 also at war with P3 and allied with the other two. P2 allied with P0 and P1, haven't met P3.
15. Second kick in that game: S1 Team map, Target P1, Arm BASE, S3 Set Target's team.
    - Expect: New team 11. Every player on its own team.
    - Result: reloaded after S3. P0 at war with P3 and P2, allied with P1. P1 at war with P3, allied with P0 and P2. P2 at war with P0, allied with P1, haven't met P3. (Log: V6 was pressed again after this kick, so P2 declared on P0. P1 kept its old war with P3 from when it was still P0's teammate.)
16. AI teammate: P0 human, P1 AI on one team; P2 human, P3 AI. Target P1. Arm BASE. S3 Set Target's team. V6.
    - Expect: `V1` PASS, the AI keeps playing, P2 at war with P0 only.
    - Result: No human capitals settled. Entered 10 in "new team" before S3. Save and reload (in lobby P0 and P1 arent teams anymore, as was for the other cases). Again, P0 and P1 in timeless alliance. After V6, P0 at war with P2 and P3. P2 at war with P0, haven't met P1.

Then quit to the desktop and send the raw Lua.log.

Summary: no clean break exists with the calls we have. Vision calls, un-meeting and SetHasAllied do nothing, and a real alliance always falls back to the timeless ALLIED state when it ends. Only war then peace (AL3) ends it, at the cost of public war and peace notifications, 100 grievances (falling 10 a turn) and an 8-turn peace on Quick. Shared vision survives everything. Team shapes work: a 3-player team keeps its 2 remaining members together, a second kick works, an AI teammate can be kicked. A kicked player keeps any war it was already in.

## Session 3b (hotseat, new game)

TX_Dev 0.0.1.4. Can the broken ribbon be avoided, and can one button do the save and reload?

1. Setup as Session 1, turn 3. As P0: S1 Team map. Arm BASE + snapshot. Save as `TX3b_base`.
   - Expect: New team filled (10), phase BASE.
   - Result:
2. S3n Set team, no broadcast (!). End turn (all). Look at the ribbon as P0, P1 and P2.
   - Expect: `S3n-UI.S3nLIVE PASS`. Does `V1-G.S3nLIVE` say the teams differ? Any `LeaderIcon` error or broken ribbon?
   - Result:
3. Save as `TX3b_s3n`. Load `TX3b_s3n`.
   - Expect: does P1 have the new team after the load (`V1-*.S3nRELOAD1 PASS`)?
   - Result:
4. Load `TX3b_base`. S1 Team map. S3 Set Target's team. P-Teams read. P-Teams WRITE panel copy (!). Click P1's portrait.
   - Expect: `PTeams-UI.*.write` says changed=yes. Does the ribbon still break (a new `LeaderIcon.lua:143` error after the `ribbon refresh` line)?
   - Result:
5. Load `TX3b_base`. R Apply + reload (hotseat) (!).
   - Expect: the game reloads by itself into `TX_autoreload_<date>_<time>` (the `R-UI.prep` line names it), then `V1-*.S3RELOAD1 PASS`, no ribbon errors. A `MANUAL` line means: load the save it names from Menu > Load Game by hand.
   - Result:
6. Optional: load `TX3b_base`. RK Kick + VIS1 + reload (!). End turn (all). AL0.
   - Expect: as 5, plus `Kvis-*.turn PASS`.
   - Result:

Then quit to the desktop and send the raw Lua.log.

## Session 3c (hotseat, new games)

TX_Dev 0.0.1.5. HARD kick war step: the kicked player (target) declares war on each remaining teammate, then makes peace, so the grievances fall on the target. Open: does the target's war work (AL3 was keeper on target), and with 2 keepers is a war on one a war on both, and peace with one peace with both?

`[TX]` lines (`[K]`, `[AL3T]`, every CHECK line) go to Lua.log only, never to the screen.

**a) 2-person team**

1. Setup as Session 1: Hotseat, GS rules, Tiny, Quick. P0, P1, P2 human, P3 AI. Teams {P0,P1} {P2,P3}. Found capitals, end turns to turn 3.
2. As P0: S1 Team map. Q Setup Session 2. End turn (all). Arm BASE + snapshot.
   - Expect: New team filled (10), phase BASE.
   - Result:
3. Target P1. S3 Set Target's team. Save as `TX3c_split`. Load `TX3c_split`.
   - Expect: phase S3RELOAD1.
   - Result:
4. AL0. AL3T Target declares then peace (!). Look at the notifications, and at the grievances in the diplomacy screen as P0 and as P1. End turn (all). AL0.
   - Expect: P0 and P1 no longer ALLIED, not at war (`AL3T-*.after` and `.turn` PASS). Grievances held by P0 against P1, not the other way (`AL3Tfx`: "P0 holds against P1" > 0, "P1 holds against P0" = 0).
   - Result:

**b) 3-person team**

5. New game: P0, P1, P2 human on one team, P3 AI on the other. Found capitals, end turns to turn 3.
6. As P0: S1 Team map. Target P2 (the > arrow). Q Setup Session 2. End turn (all). Arm BASE + snapshot.
   - Expect: roles keeper P0, target P2. New team filled.
   - Result:
7. S3 Set Target's team. Save as `TX3c3_split`. Load `TX3c3_split`.
   - Expect: phase S3RELOAD1.
   - Result:
8. AL0. AL3T Target declares then peace (!). End turn (all). AL0. Diplo matrix.
   - Expect: P2 neither ALLIED nor at war with P0 or P1 (`AL3T-*` "2/2 pairs clear" PASS). P0 and P1 still one team, still allied with each other (Diplo matrix: `T` and `A` between them). Grievances held by P0 and by P1 against P2. Leon: how many war and peace notifications?
   - Result:

**c) AI target**

9. New game: P0 human + P1 AI on one team, P2 human + P3 AI on the other. Found capitals, end turns to turn 3.
10. As P0: S1 Team map. Target P1. Q Setup Session 2. End turn (all). Arm BASE + snapshot. S3 Set Target's team. Save as `TX3cAI_split`. Load `TX3cAI_split`.
    - Expect: phase S3RELOAD1.
    - Result:
11. AL0. AL3T Target declares then peace (!). End turn (all). AL0. End turn (all) 3 more times, AL0 after each.
    - Expect: as a): no longer ALLIED, not at war, grievances held by P0 against P1. The AI does not declare war again on its own in the next 3 turns (`AL3T-G.*.turn` PASS each turn, no war notification).
    - Result:

Then quit to the desktop and send the raw Lua.log file (not only the summary).

## Afterwards

- Quit to the desktop. Lua.log is buffered until the game exits.
- Send `Lua.log` from `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs`.
- `python tools\summarize_log.py` prints one line per check ID (latest verdict) and the spike lines by section.
