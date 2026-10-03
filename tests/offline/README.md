# Offline tests

The mod's real Lua runs on a fake Civ VI engine in lupa's Lua 5.1, so gameplay rules get tested without the game.

```
python tests\offline\run_tests.py              # syntax check of TX\, TX_Dev\ and the tests, then every test_*.lua
python tests\offline\run_tests.py -k vote -v   # only matching tests, with logs of failures
python tests\offline\run_tests.py --list
```

Needs `pip install lupa`. Exit code 0 when nothing failed. Must be green before any commit.

## Files

- `lib\fake_engine.lua`: Game properties (copy semantics, storage-rule checks, empty values dropped like in game), GameEvents / Events / LuaEvents, Players with team IDs, `IsHuman` / `IsAlive` / `IsMajor`, PlayerConfigurations (`GetTeam` / `SetTeam`), PlayerManager, diplomacy getters, `Network.BroadcastPlayerInfo` (recorded in `FAKE.broadcasts`), NotificationManager (captured in `FAKE.notifications`), `Game.GetCurrentGameTurn`, `Game.GetRandNum`, Locale with plural forms, `include()`.
- `lib\fake_ui.lua`: `FAKE_UI.Enable()` turns on the UI context: Controls, ContextPtr, InstanceManager, PopupDialogInGame, UIManager. `UI.RequestPlayerOperation` with `EXECUTE_SCRIPT` reaches `GameEvents[OnStart]` as gameplay, at once or, with `FAKE_UI.deferRequests = true`, on `FAKE_UI.DeliverRequests()`.
- `lib\harness.lua`: `test(name, fn, opts)`, assertions (`H.eq`, `H.deq`, `H.ok`, ...), `H.world{ teams = {...} }`, `H.load("TX/Scripts/TX_Gameplay.lua")`, `H.reload(...)`, `H.endTurn()` in the measured in-game order, `H.request(pid, params)`, `H.notifs`, `H.lines`, `H.clean()`.
- `test_harness_selftest.lua`: tests of the fake engine itself. If these fail, every other result is suspect.

## Team models

How a team change behaves in game is what the spike finds out, so the fake has switches instead of answers:

- `FAKE.teamModel = "config"` (default): `PlayerConfigurations[i]:SetTeam` changes only the config team. `Players[i]:GetTeam()` changes on `FAKE.ApplyConfigTeams()` or `H.reload(files, globals, { applyConfigTeams = true })` (Mode B). `"live"` changes both at once (Mode A).
- `FAKE.teamWars = true` (default): war is shared by team members.

Set these to what the spike proved once it is done.

## Results

PASS, FAIL, SKIP, XFAIL (marked `xfail("Phase 2: ...")`, the reason must name a phase or `WPx.y`) and XPASS. A test also fails when the mod logs `[TX][...] ERROR` lines, an event handler errors, or a `LOC_TX_*` text gets too few arguments, unless it passes `{ allowErrors = true }`.

## Game data

GameInfo rows come from the game's cached DB, exported to `data\gameinfo_data.lua` (gitignored, rebuilt when the DB is newer, `--regen` forces it). Without the game the file is missing: GameInfo then only has the mod's own notification types, read from its SQL. A test that needs more calls `H.needGameInfo()`, or a test file starts with `-- @needs gameinfo`; both SKIP cleanly without the data.
