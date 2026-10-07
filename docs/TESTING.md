# Team Kick: hotseat test (Session 4)

Status: passed on 2026-10-07 (hotseat). Every step passed on 0.1.0 at 5a5d88d. The fixes it found (turn counts, kick dialog layout, wording) went into d83096b and Leon confirmed them, plus more runs with several votes and an open vote across a reload and an Apply. The steps below are the 1.0.0 expectations; use them as the regression test before a release.

Team Kick 1.0.0 (`TX`), the real mod. Two short new games, hotseat, about 25 minutes. Only load the saves made in this session. Load them from the main menu (Multiplayer > Hotseat > Load Game), never from the in-game menu: that makes a hotseat game single player.

P0, P1, P2 are the hotseat players in slot order (Player 1, Player 2, Player 3). A "turn" below means everyone ends their turn once.

## Install

- Close Civ.
- `git pull`
- `powershell -ExecutionPolicy Bypass -File tools\install.ps1`
- Additional Content: enable Gathering Storm and Team Kick v1.0.0. Turn Team Kick Dev Tools (TX_Dev) OFF. Nothing else.

## Part A: two-player teams

Setup: Hotseat, GS rules, Tiny, Quick, fewest city-states. P0, P1, P2 human, P3 AI. Teams {P0, P1} and {P2, P3}.

1. Found capitals. End turns to turn 3.
   - Expect: a Team button on the launch bar for P0, P1 and P2.
   - Result:
2. As P0: Team.
   - Expect: the window lists P0 (you) and P1 with a Kick button. History says "No votes yet."
   - Result:
3. As P0: Kick P1, then Cancel.
   - Expect: the confirm says the team dissolves right away, then the Soft kick line and the Hard kick line with a blank line between them, then "Once it passes, the host applies it and the game saves itself." Buttons: Soft kick and Hard kick on one row, Cancel on its own row below. Cancel closes it and nothing happens.
   - Result:
4. Soft kick. End P0's and P1's turns. As P2: Team, Kick P3, then Soft kick.
   - Expect: no vote. A "Kicked off a team" notification that says "soft kick", and a banner at the top with an Apply button.
   - Result:
5. As P2: Apply, then Yes.
   - Expect: the game saves itself (the banner says "Saving the game..." for a moment). Then a "Load the save to finish the kick" popup: "Saved as TeamKick_<P3's civ>_T<turn>_<time>" and the hotseat steps. Write the name down. The banner says "Kick applied and saved as" that name.
   - If you get "Save and reload now" instead, the automatic save failed: write that down, save by hand as `TX4_a`, and load that in step 6.
   - Lua.log: `[UIApply] kick save rec=1: saved as TeamKick_...`, no ERROR.
   - Result:
6. Menu > Exit to Main Menu. Main Menu > Multiplayer > Hotseat > Load Game, load the TeamKick save from step 5.
   - Expect: no error popups, a normal leader ribbon. A "Team changed" notification that says P3 stays allied. No war or peace notification. The banner is gone. P0 and P1 still have the Team button, P2 doesn't. Diplomacy screen: P2 and P3 still allied.
   - Result:

## Part B: a vote in a team of three

New game. Setup: Hotseat, GS rules, Tiny, Quick, fewest city-states. P0, P1, P2 human, P3 AI. Teams {P0, P1, P2} and {P3}.

7. Found capitals. End turns to turn 3.
   - Expect: a Team button for P0, P1 and P2.
   - Result:
8. As P0: Team, Kick P1, then Soft kick.
   - Expect: the confirm asks for a vote "within 5 turns" (a number, not #). The window shows the open vote "(soft kick)": P0 started it, P2 not voted yet. Kick buttons are disabled.
   - Result:
9. End P0's turn. As P1: Team.
   - Expect: no TX notification. "No open vote." Kick buttons disabled with "Your team can't start a new vote right now." No history.
   - Result:
10. End P1's turn. As P2: click the "Team vote" notification.
    - Expect: the notification text names P0's and P1's leaders (not "a teammate"), says "soft kick" and "Vote within <n> turns" with a number. The vote popup with the right names, the Soft kick line, "Every other human teammate has to vote yes." and "<n> turns left" (no "One no vote ends it."). If it doesn't open, write that down and use Team > Vote instead.
    - Result:
11. As P2: "No, keep them".
    - Expect: the vote fails. Nobody gets a notification. P2's history shows the failed vote, and its tooltip shows each vote.
    - Result:
12. End turn. As P0: Team, then Kick P1 again, Soft kick. Leave the vote open and end turns 5 times. P2 doesn't vote.
    - Expect: P2 gets the "Team vote" notification each turn, only one at a time, the turns left counting down as numbers ("1 turn" on the last one, never #). P0's window shows the same count. After 5 turns the vote is gone, history says it ran out of time, and nobody is notified.
    - Result:
13. Hard kick. As P0: Kick P1 again, then Hard kick. End P0's and P1's turns. As P2: Team > Vote > "Yes, kick them".
    - Expect: P2's notification, popup and window say "hard kick". Then a "Kicked off a team" notification that says "hard kick", and the banner with Apply.
    - Result:
14. As P2: Apply, then Yes.
    - Expect: the confirm says it's a hard kick (war and peace right after the reload). Then the game saves itself and the "Load the save to finish the kick" popup names the save (TeamKick_<P1's civ>_T<turn>_<time>). Write the name down. The banner names it too.
    - If you get "Save and reload now" instead: write that down, save by hand as `TX4_kick`, and load that in step 15.
    - Result:
15. Menu > Exit to Main Menu. Main Menu > Multiplayer > Hotseat > Load Game, load the TeamKick save from step 14. Play each player's turn.
    - Expect: no error popups, a normal ribbon. Right after the load: P1 declares war on P0 and P2 and makes peace at once (base-game war and peace notifications), then a "Hard kick" notification for P0, P1 and P2 saying the alliance has been ended. No "Team changed". No banner. P1 has no Team button. P0's window lists P0 and P2, and history says P1 was kicked (hard kick). World Rankings shows P1 apart. Diplomacy screen: P1 is not allied with P0 or P2, and P0 and P2 hold the grievances against P1 (not the other way round).
    - Lua.log: `[Apply] HARD rec=` lines, one war and one peace step per teammate or "already at war", and `done`, no ERROR.
    - Result:
16. As P0: Team, Kick P2, then Cancel.
    - Expect: the dissolve wording again (team of two now).
    - Result:
17. End turn twice.
    - Expect: no repeated "Kicked off a team", "Team changed" or "Hard kick", no new war. P1 is still not allied with P0 or P2.
    - Result:

Wording: write down any in-game text you'd change.

## Afterwards

Quit to the desktop and send the raw Lua.log from `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs`, not only a summary.
