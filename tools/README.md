# Tools: static checks, install and logs

Offline checks for Team Kick (internal prefix `TX_`, mod folder `TX\`, dev tools `TX_Dev\`), plus the install script and log readers. Ported from the Expeditionary mod's tools. Everything runs from the project folder with Python 3.11 or newer, on Windows and Linux. Only `check_lua.py` and the offline tests need an extra package: `pip install lupa`.

## Quick start

```
python tools\check_all.py                   # TX\ and TX_Dev\ (a folder that does not exist yet is skipped)
python tools\check_all.py TX_Dev            # explicit folders (a mod folder or a folder of mods)
python tools\check_all.py TX --strict       # warnings fail too
python tools\test_tools.py                  # the tools test themselves on tools\fixtures
```

`check_all.py` runs `check_lua.py`, `validate_data.py` and `api_audit.py` and exits non-zero on any error. Findings look like `path:line: LEVEL [code] message`. At the end it prints a per-tool summary and the checklist of engine calls not verified in game yet. `--info` shows INFO lines, `--basic` skips the Lua runtime, `--db PATH` picks another gameplay database.

Without the game on the machine there is no cached database. Then `validate_data.py` prints one warning, "game DB not found, SQL run skipped", and still runs every check that needs no database. `check_all.py` passes with that warning (`--strict` fails on it).

## check_lua.py: Lua syntax and globals

```
python tools\check_lua.py TX [--basic] [--no-globals] [--luacheck auto|on|off] [--strict]
```

- Syntax: every file is compiled (never run) with the real Lua 5.1 parser from `lupa`. Firaxis type annotations (`local x:number`), `goto`, `//`, bit operators and unclosed blocks all fail with a line number.
- Globals: the compiled bytecode is read for global reads and writes. Each modinfo entry point (gameplay script, UI context, replaced UI script) plus everything it includes counts as one Lua state. A global that is read must be defined in every state the file runs in. Unknown reads are errors. A global assigned only inside a function is a warning (missing `local`?). Overwriting an engine global is an error.
- `-- TX:GLOBALS Name1 Name2` declares extra globals for one file.
- Code between `-- TX:G-ONLY begin` / `-- TX:G-ONLY end` (or `TX:UI-ONLY`) counts only for that context. `-- TX:CONTEXT G|UI|both` near the top of a file sets its context by hand.
- luacheck is used when it is on the PATH or in `tools\bin\`. Its config is written to a temp folder on each run from the same engine globals.

## validate_data.py: XML, modinfo, SQL and text

```
python tools\validate_data.py TX [--db PATH] [--loc-db PATH]
```

- Every `.xml`, `.modinfo` and `.artdef` file is well formed.
- modinfo: valid ids, every action has criteria, every listed file exists with the exact case (also on a case-sensitive disk) and every file on disk is listed (except `.md` and `.txt`), the Gathering Storm dependency, `AffectsSavedGames=1`, complete `ReplaceUIScript` and `AddUserInterfaces` entries.
- SQL with the game DB: the cached gameplay database is copied to a temp folder (the original is only read), leftover `TX*` rows from a previous game are removed from the copy, then every database file of the mod runs there in load order with the game's own hash function. Unknown tables or columns, constraint failures and foreign keys fail like they do in game.
- SQL without the game DB: the files run against an empty stub instead. That still catches syntax errors, duplicate `Types` rows and the notification pairing. Unknown tables and columns are not checked.
- Notifications: `KIND_NOTIFICATION` Types rows and Notifications rows must pair up. Every type needs its message and summary text (the keys in its `Message` / `Summary` columns, or `LOC_<type>_MESSAGE` / `_SUMMARY`). With an `UpdateIcons` file, every type needs an `ICON_<type>` alias.
- Text: no duplicate keys, no `<Row>` for a key the base game already has (needs the localization DB), every `LOC_*` key used in Lua, SQL, UI XML or the modinfo exists, placeholders get enough arguments, plural forms are written correctly, unused keys are warnings, no en or em dashes. A `LOC_TX_*` key that is missing is an error. A base-game key is checked against the localization DB, or listed as INFO without it.
- TX_Dev can use TX's text keys when its modinfo has a `<Dependency>` on TX's mod id (both folders in the project).
- Reason codes: if a Lua file has `X.ALL_REASON_CODES = { ... }`, every code needs `LOC_TX_REASON_<CODE>`.
- Internal words: `INTERNAL_WORDS` at the top of the file lists words players must never see. It is empty, because the public name may also be TX. Add the internal name once the public name differs.
- Lua cross references: notification type literals (`NOTIFICATION_TX_*`, `TX_NOTIF_*`) exist in the SQL, `Controls.X` exists in the paired XML, instance names match.

Database paths: the newest of `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Cache\` and `Documents\My Games\...\Cache\`. Override with `--db` / `--loc-db` or the `TX_CIV6_DB` / `TX_CIV6_LOC_DB` environment variables.

## api_audit.py: engine calls and multiplayer rules

```
python tools\api_audit.py TX [--strict] [--no-checklist] [--allowlist PATH]
```

- `api_allowlist.json` lists every engine call the mod may use, per context (gameplay `G` or `UI`), with its status and evidence. It is kept by hand; `--regen` is accepted and does nothing.
- Status (`level`): `C` means verified in game. `L`, `NV`, `PENDING` and `VERIFY` mean not verified yet: every use is a warning and shows up in the checklist printed at the end.
- `only_paths: ["TX_Dev/"]` limits a call to files whose path contains `TX_Dev/` (dev-only calls).
- Each entry keeps its evidence in `refs` and `note`, and says where it came from in `source`. The seed came from the Expeditionary mod (`source: "EFV"`): only calls EFV's own code used, only the contexts where EFV had them verified. Their `refs` point into EFV's plan and test sessions. New TX entries get `source: "TX"` and evidence from the game files or a spike result.
- `engine_globals.json` lists every global the game's own Lua reads but never defines (enums like `YieldTypes`). It is engine-wide and copied from EFV. Rebuild it with `python tools\harvest_engine_globals.py [--game PATH]`.
- Errors: a call that is not on the list, used in the wrong context or outside its `only_paths`, unknown project functions, `math.random`, `os.*` in gameplay, `Game.GetLocalPlayer` in gameplay, `pairs(` in gameplay outside a `*SortedKeys` helper, `table.unpack`, `ExposedMembers`, any state change reachable from an `Events.*` handler registered in gameplay (property writes, notifications, `SetTeam`, `BroadcastPlayerInfo`, RNG and more), and a UI request (`OnStart`) without a `GameEvents` handler.
- Warnings: calls not verified in game, GameInfo tables not on the list, handler registration inside a function in gameplay, a `GameEvents.TX_*` handler no UI file sends, `pairs()` over records in UI.

### Spike probes

A call to a function named `TX_Probe` or `Probe` (also `X.Probe` / `X:Probe`) is a spike probe. Its argument list is not audited, so a probe can try a call that is not on the allowlist yet. Name the call by string and let the probe look it up and run it under `pcall`:

```lua
TX_Probe("S3 set team", "PlayerConfigurations", 1, "SetTeam", 5)
```

The probe function itself lives in the dev mod and is audited like any other code. Every probe call is listed as INFO (`--info`). Once a spike proves a call, add it to the allowlist and call it directly. Pass names as strings: a bare unknown global in the arguments (`Teams`) still fails `check_lua.py`.

## install.ps1: install and follow the log

```
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -DevOnly        # checks, then copy only TX_Dev\ (spike phase)
powershell -ExecutionPolicy Bypass -File tools\install.ps1                # checks, then copy TX\
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Dev -Watch     # also TX_Dev\, then follow Lua.log
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -CheckLogs      # only scan the last run's logs
```

- Stops at once while a `CivilizationVI*` process is running.
- `-DevOnly` checks and copies only `TX_Dev`. `TX\` does not have to exist. A leftover `Mods\TX` is not touched; a note says so.
- Runs `check_all.py` on the folders it installs first. Errors stop the install unless you pass `-Force` (`-SkipChecks` skips the checks, `-Strict` also stops on warnings).
- Mirrors the folders into `S:\Libraries\Documents\My Games\Sid Meier's Civilization VI\Mods\TX` (and `TX_Dev`); change it with `-ModsDir`. It refuses folders not named `TX*` and targets outside the Mods folder. Files deleted in the source are deleted in the copy too.
- `-Watch` / `-WatchOnly` follow `Lua.log`, filtered by `-Pattern` (default `TX|Runtime Error|Syntax Error|stack traceback`), and pick the file up again when the game recreates it.
- `-CheckLogs` runs `check_logs.py` on Database.log, Modding.log, Lua.log and UserInterface.log. Exit code 1 on errors that involve the mod.
- Logs: `-LogsDir` defaults to `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs`. The copy under `Documents\My Games` is stale. `Lua.log` is buffered while you play, so read it after quitting to the desktop.

## check_logs.py: errors of the last run

```
python tools\check_logs.py [--logs DIR] [--match REGEX] [--all-errors] [--tail N]
```

Scans the four logs for errors that mention the mod (pattern `\bTX` by default, so `TX_...`, `[TX]` and `Mods\TX\` match but not words like CONTEXT). Database errors come with their context lines, a failed foreign key validation is always reported, Lua errors come with their stack traceback. Exit code 1 on any match. `TX_CIV6_LOGS` overrides the log folder.

## summarize_log.py: checks and spike results from Lua.log

```
python tools\summarize_log.py [--log PATH] [--max-lines N] [-v]
```

Reads the lines the dev mod writes and prints:

- one line per `[TX][CHECK] <ID> PASS|FAIL|INFO|CHECK <text>` ID, in order of first appearance. The latest PASS/FAIL/CHECK wins (a later INFO line does not hide it), plus "(+n earlier)".
- `[TX][SPIKE] S1 ...` or `[TX][SPIKE][S1] ...` lines grouped by section: S1 to S4, V1 to V12, then other names, then lines without a section. Up to `--max-lines` per section (default 10, the last ones); `-v` prints all.
- the number of `Runtime Error`, `Syntax Error` and `stack traceback` lines.

Exit code 1 when a check ends in FAIL or CHECK or there are error lines, 2 when the log is missing. Quit the game before running it.

## Fixtures

- `fixtures\good\TX_Fixture`: a small mod shaped like TX (request bridge, teams, notification, Team panel, a spike probe). 0 errors; without the game DB the only warning is "game DB not found".
- `fixtures\bad\TX_Broken`: one planted mistake per rule, each marked with a comment.
- `fixtures\logs\check_good`, `check_bad`: made-up logs for `check_logs.py`, stored as `*.log.txt` because the repo ignores `*.log`. The tests copy them to a temp folder.
- `fixtures\logs\summarize_good.txt`, `summarize_bad.txt`: made-up Lua.log files for `summarize_log.py`.
- The SQL tests build a small fake gameplay and localization DB in a temp folder, so they run without the game.

## Limits

- Method calls are matched by name only, so a method used on the wrong kind of object passes if the name is on the list.
- Code built at runtime (`GameEvents[name].Add`, keys built from strings, `include(variable)`, probe arguments) is not followed. Text key prefixes built at runtime are only checked for "matches at least one key".
- The check for state changes in `Events` handlers follows calls by name within one Lua state. Calls through tables of functions or `pcall(f, ...)` are not followed.
- Without the game DB, unknown tables and columns, constraints, foreign keys, base-game key collisions and unknown GameInfo tables are not checked. Run the tools once on a machine with the game before a release.
- The cached database reflects the last game's rules and mods, so rows from other mods can still collide. The icon check uses a stub table, and UI XML is checked for ids, not for layout.
