# Team Kick (Civ VI mod)

Vote a teammate off your team in the middle of a game. Made for team games where a player left and the AI took over their civ, or where a teammate just isn't one anymore.

The kicked player plays on alone. They no longer share victory or wars with the team.

Requires Gathering Storm. Version 1.0.0.

## Features

- **Team button:** on the launch bar (top left). Shows your teammates, the open vote and past votes. Only shows for human players on a team with 2 or more living members.
- **Votes:** pick a teammate (human or AI) and press Kick. Every other human teammate has to vote yes within 5 turns. One no ends the vote. AI teammates don't vote. One open vote per team at a time, and a new one can start as soon as the last one ends.
- **Secret until it passes:** the player being voted on never sees the vote. Voters get a notification and vote from it or from the Team window. Everyone hears about it only if the kick passes.
- **Soft or hard kick:** the player who starts the vote picks one.
  - Soft: the kicked player leaves the team but stays allied with it. Good for kicking the AI that took over a player who left.
  - Hard: the alliance is ended too. The kicked player declares war on their old teammates and makes peace at once, so the grievances fall on them.
- **Two-player teams:** no vote needed. One confirmation dissolves the team.

## How a kick goes

1. A teammate opens the Team window, presses Kick on a player and picks Soft or Hard.
2. The other human teammates vote yes within 5 turns.
3. The host gets an Apply banner and presses Apply. The game saves itself under a name like `TeamKick_<civ>_T42_1830`.
4. Load that new save (a popup says where to load it from). The new teams show after the load. A hard kick ends the alliance right after the load.

Until the save is loaded, the leader portraits at the top can look wrong. Don't click them.

## Known limitations

- The new teams only show after loading the save the mod makes.
- Ex-teammates still see each other's map.
- After a soft kick they stay allied for good: they can't go to war with each other.
- A kicked player keeps any war they were already in.
- A team victory before the kick is applied cancels the kick.

## Install

Copy the `TX` folder into `Documents\My Games\Sid Meier's Civilization VI\Mods`, or run `powershell -ExecutionPolicy Bypass -File tools\install.ps1`. Then enable Team Kick under Additional Content.

## What's in this repo

- `TX`: the mod.
- `TX_Dev`: dev tools used to test whether the mod was possible at all. Never enable them in a real game.
- `tools`: install script, static checks and a log summarizer.
- `tests/offline`: tests that run the mod's scripts against a fake game engine.
- `docs/TESTING.md`: the in-game test steps.

## Changelog

- 1.0.0: First release. Team button and window, secret votes, soft and hard kicks, automatic save after a kick.
