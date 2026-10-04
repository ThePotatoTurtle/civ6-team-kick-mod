#!/usr/bin/env python3
"""test_tools.py - self-test for the TX static tools, using tools/fixtures.

    python tools/test_tools.py            (exit 0 = all tests pass)

fixtures/good/TX_Fixture   mini mod shaped like TX: every tool must report 0 errors.
fixtures/bad/TX_Broken     one planted defect per check: every expected finding must be reported.
fixtures/logs/check_*      synthetic game logs for check_logs.py (stored as *.log.txt because the repo
                           ignores *.log; the tests copy them to a temp folder without the .txt).
fixtures/logs/summarize_*  synthetic Lua.log files for summarize_log.py.

The game DB is not needed. The tests that cover the SQL run build a small fake gameplay and
localization DB in a temp folder (made-up tables shaped like the game's, not game data).
"""
from __future__ import annotations

import io
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import txlib as L  # noqa: E402
import check_lua  # noqa: E402
import validate_data  # noqa: E402
import api_audit  # noqa: E402
import check_logs  # noqa: E402
import check_all  # noqa: E402
import summarize_log  # noqa: E402

FIX = os.path.join(L.TOOLS_DIR, "fixtures")
GOOD = os.path.join(FIX, "good")
BAD = os.path.join(FIX, "bad")
LOGS = os.path.join(FIX, "logs")
NO_DB = os.path.join(FIX, "no_such_dir", "DebugGameplay.sqlite")
NO_LOC_DB = os.path.join(FIX, "no_such_dir", "DebugLocalization.sqlite")


def found(rep, level=None):
    return {(os.path.basename(f.path), f.line, f.code) for f in rep.items if level is None or f.level == level}


def codes(rep, level="ERROR"):
    return {f.code for f in rep.items if f.level == level}


def msgs(rep):
    return " | ".join(f.msg for f in rep.items)


def make_fake_dbs(folder):
    """A tiny gameplay DB and localization DB with the tables the checks touch (made up for the tests)."""
    gp = os.path.join(folder, "DebugGameplay.sqlite")
    con = sqlite3.connect(gp)
    con.executescript("""
        CREATE TABLE Kinds(Kind TEXT NOT NULL PRIMARY KEY);
        INSERT INTO Kinds VALUES ('KIND_NOTIFICATION');
        CREATE TABLE Types(Type TEXT NOT NULL PRIMARY KEY, Hash INTEGER NOT NULL DEFAULT 0,
                           Kind TEXT NOT NULL REFERENCES Kinds(Kind));
        CREATE TABLE Notifications(NotificationType TEXT NOT NULL PRIMARY KEY REFERENCES Types(Type),
                           Message TEXT, Summary TEXT, SeverityType TEXT,
                           ExpiresEndOfTurn BOOLEAN NOT NULL DEFAULT 0 CHECK (ExpiresEndOfTurn IN (0, 1)), Icon TEXT);
        CREATE TABLE Buildings(BuildingType TEXT NOT NULL PRIMARY KEY);
        CREATE TABLE DiplomaticStates(StateType TEXT NOT NULL PRIMARY KEY);
    """)
    con.commit()
    con.close()
    loc = os.path.join(folder, "DebugLocalization.sqlite")
    con = sqlite3.connect(loc)
    con.executescript("""
        CREATE TABLE LocalizedText(Language TEXT NOT NULL, Tag TEXT NOT NULL, Text TEXT, PRIMARY KEY(Language, Tag));
        INSERT INTO LocalizedText VALUES ('en_US', 'LOC_UNIT_WARRIOR_NAME', 'Warrior');
    """)
    con.commit()
    con.close()
    return gp, loc


class FakeDBCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="tx_tooltest_")
        cls.db, cls.loc = make_fake_dbs(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)


class TestCheckLua(unittest.TestCase):
    def test_runtime_is_lua51(self):
        self.assertIsNotNone(check_lua.lua_runtime(), "lupa Lua 5.1 runtime missing: pip install lupa")

    def test_good_clean(self):
        rep = check_lua.check(GOOD, luacheck="off")
        self.assertEqual(rep.count("ERROR"), 0, [vars(f) for f in rep.items])
        self.assertEqual(rep.count("WARN"), 0, [vars(f) for f in rep.items])

    def test_bad_detected(self):
        rep = check_lua.check(BAD, luacheck="off")
        f = found(rep)
        for exp in [("TX_Gameplay.lua", 26, "undefined-global"),      # Plyers typo
                    ("TX_Gameplay.lua", 28, "undefined-global"),      # pUnit
                    ("TX_Gameplay.lua", 48, "undefined-global"),      # defined only in the UI state
                    ("TX_Syntax.lua", 6, "syntax"),                   # missing end
                    ("TX_Havok.lua", 2, "syntax"),                    # local x:number
                    ("TX_Havok.lua", 2, "type-annotation"),
                    ("TX_Gameplay.lua", 22, "global-assign-in-function")]:
            self.assertIn(exp, f)

    def test_basic_mode(self):
        rep = check_lua.check(BAD, basic=True, luacheck="off")
        f = found(rep)
        self.assertIn(("TX_Syntax.lua", 2, "syntax-basic"), f)   # 'function' block never closed
        self.assertIn(("TX_Havok.lua", 2, "type-annotation"), f)

    def test_syntax_variants(self):
        bad = {"goto x": "5.2 goto", "local a = 1 // 2": "floor div", "local a = 1 & 2": "bitwise",
               "if x then": "unclosed if", "local t = {1, 2": "unclosed table"}
        for src, why in bad.items():
            ok, _ = check_lua.compile_lua(src.encode(), "@t.lua")
            self.assertFalse(ok, why)
        ok, dump = check_lua.compile_lua(b"local x = Foo.Bar\nBaz = 1\nfunction f() Qux = 2 end", "@t.lua")
        self.assertTrue(ok)
        gl = {(op, n, d) for op, n, _l, d in check_lua.read_globals(dump)}
        self.assertEqual(gl, {("get", "Foo", 0), ("set", "Baz", 0), ("set", "f", 0), ("set", "Qux", 1)})

    def test_markers(self):
        tmp = tempfile.mkdtemp()
        try:
            d = Path(tmp) / "Scripts"
            d.mkdir()
            (d / "TX_A.lua").write_text("-- TX:GLOBALS Teams\nprint(Teams)\nprint(NotDeclared)\n", encoding="utf-8")
            rep = check_lua.check(tmp, luacheck="off")
            self.assertEqual({(f.line, f.code) for f in rep.items if f.level == "ERROR"}, {(3, "undefined-global")})
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        _t, comments = L.lex("-- TX:G-ONLY begin\nx = 1\n-- TX:G-ONLY end\n-- EFV:UI-ONLY begin\n")
        regions, problems = L.region_map(comments)
        self.assertEqual((regions, problems), ([(1, 3, "G")], []))

    def test_luacheckrc_written_at_run_time(self):
        tmp = tempfile.mkdtemp()
        try:
            path = os.path.join(tmp, ".luacheckrc")
            check_lua.write_luacheckrc(path)
            text = Path(path).read_text(encoding="utf-8")
            self.assertIn('std = "lua51"', text)
            self.assertIn('"PlayerConfigurations",', text)
            self.assertIn('"YieldTypes",', text)   # harvested engine global
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        self.assertFalse(os.path.exists(os.path.join(L.TOOLS_DIR, ".luacheckrc")), "no generated file in the repo")


class TestValidateData(FakeDBCase):
    def test_make_hash_matches_game(self):
        if not os.path.exists(L.GAMEPLAY_DB):
            self.skipTest("no game DB on this machine")
        con = sqlite3.connect("file:%s?mode=ro" % L.GAMEPLAY_DB.replace("\\", "/"), uri=True)
        rows = con.execute("SELECT Type, Hash FROM Types LIMIT 500").fetchall()
        con.close()
        for t, h in rows:
            self.assertEqual(validate_data.make_hash(t), h, t)

    def test_good_without_db_warns_once(self):
        rep = validate_data.validate(GOOD, db=NO_DB, loc_db=NO_LOC_DB)
        self.assertEqual(rep.count("ERROR"), 0, [vars(f) for f in rep.items if f.level == "ERROR"])
        warns = [f for f in rep.items if f.level == "WARN"]
        self.assertEqual([f.code for f in warns], ["sql-nodb"], [vars(f) for f in warns])
        self.assertIn("game DB not found", warns[0].msg)
        self.assertIn("SQL run skipped", warns[0].msg)

    def test_good_clean_with_db(self):
        rep = validate_data.validate(GOOD, db=self.db, loc_db=self.loc)
        self.assertEqual(rep.count("ERROR"), 0, [vars(f) for f in rep.items if f.level == "ERROR"])
        self.assertEqual(rep.count("WARN"), 0, [vars(f) for f in rep.items if f.level == "WARN"])

    def test_original_db_untouched(self):
        before = (os.path.getmtime(self.db), os.path.getsize(self.db))
        validate_data.validate(BAD, db=self.db, loc_db=self.loc)
        self.assertEqual(before, (os.path.getmtime(self.db), os.path.getsize(self.db)))

    def _check_db_free(self, rep):
        f = found(rep)
        c = codes(rep)
        for exp in [("TX_Bad.sql", 18, "sql"),           # syntax error (missing comma)
                    ("TX_Icons.sql", 2, "sql-icons"),
                    ("TX_Malformed.xml", 5, "xml"),
                    ("TX_Gameplay.lua", 34, "text-args"),
                    ("TX_Gameplay.lua", 35, "text-missing"),
                    ("TX_Gameplay.lua", 37, "notification-missing"),
                    ("TX_Panel.lua", 4, "ui-instance"),
                    ("TX_Panel.lua", 10, "ui-control"),
                    ("TX_Panel.lua", 23, "text-args"),       # L(key, ...) wrapper
                    ("TX_Text.xml", 0, "text-plural")]:
            self.assertIn(exp, f)
        for code in ["sql-notification", "text-duplicate", "text-dash", "text-reason", "ui-id", "modinfo-action",
                     "modinfo-deps", "modinfo-files", "modinfo-props", "modinfo-replace", "modinfo-ui",
                     "modinfo-unlisted", "notification-icon"]:
            self.assertIn(code, c)
        self.assertIn("notification-text", codes(rep, "WARN"))
        m = msgs(rep)
        for frag in ["Data/TX_Missing.sql does not exist", "TX_Missing.sql is not listed in <Files>",
                     "UpdateText id=TX_Text has no criteria", "undefined criteria 'TX_NOPE'",
                     "action id TX_Gameplay used twice", "UI/TX_Gone.lua does not exist",
                     "Scripts/tx_havok.lua differs in case", "Scripts/TX_Unlisted.lua exists on disk",
                     "AffectsSavedGames must be 1", "LuaReplace missing", "no Dependency on Gathering Storm",
                     "Types row NOTIFICATION_TX_ORPHAN (KIND_NOTIFICATION) has no Notifications row",
                     "LOC_TX_REASON_NO_TEXT_FOR_THIS", "malformed plural form", "fixed noun after a number",
                     "LOC_TX_NEVER_USED is defined but never referenced"]:
            self.assertIn(frag, m)
        self.assertNotIn("LOC_TX_REASON_NOT_HUMAN is defined but never referenced", m, "codes count as used")

    def test_bad_detected_without_db(self):
        rep = validate_data.validate(BAD, db=NO_DB, loc_db=NO_LOC_DB)
        self._check_db_free(rep)
        self.assertIn("sql-nodb", codes(rep, "WARN"))
        self.assertNotIn("sql-fk", codes(rep))
        self.assertNotIn("text-collision", codes(rep))

    def test_bad_detected_with_db(self):
        rep = validate_data.validate(BAD, db=self.db, loc_db=self.loc)
        self._check_db_free(rep)
        f = found(rep)
        for exp in [("TX_Bad.sql", 9, "sql"),     # unknown column
                    ("TX_Bad.sql", 12, "sql"),    # unknown table
                    ("TX_Bad.sql", 15, "sql")]:   # CHECK constraint
            self.assertIn(exp, f)
        self.assertIn("sql-fk", codes(rep))
        self.assertIn("text-collision", codes(rep))
        self.assertNotIn("sql-nodb", codes(rep, "WARN"))
        m = msgs(rep)
        for frag in ["no column named NoSuchColumn", "no such table: NoSuchTable", "CHECK constraint failed", "KIND_NOPE"]:
            self.assertIn(frag, m)

    def test_internal_words(self):
        tmp = tempfile.mkdtemp()
        old = list(validate_data.INTERNAL_WORDS)
        try:
            dst = os.path.join(tmp, "TX_Fixture")
            shutil.copytree(os.path.join(GOOD, "TX_Fixture"), dst)
            txt = os.path.join(dst, "Data", "TX_Text.xml")
            src = Path(txt).read_text(encoding="utf-8")
            self.assertIn("<Text>Team</Text>", src)
            Path(txt).write_text(src.replace("<Text>Team</Text>", "<Text>TX team</Text>"), encoding="utf-8")
            self.assertEqual(validate_data.INTERNAL_WORDS, [], "empty by default: the public name may be TX")
            rep = validate_data.validate(tmp, db=NO_DB, loc_db=NO_LOC_DB)
            self.assertNotIn("text-internal-name", codes(rep))
            validate_data.INTERNAL_WORDS[:] = ["TX"]
            rep = validate_data.validate(tmp, db=NO_DB, loc_db=NO_LOC_DB)
            hits = [f for f in rep.items if f.code == "text-internal-name"]
            self.assertEqual(len(hits), 1, [vars(f) for f in hits])   # LOC_TX_* keys never match
            self.assertIn("LOC_TX_TEAM_TAB", hits[0].msg)
        finally:
            validate_data.INTERNAL_WORDS[:] = old
            shutil.rmtree(tmp, ignore_errors=True)

    def test_text_keys_across_tx_and_dev(self):
        """TX_Dev may use TX's text keys when its modinfo depends on TX (both in the project folder)."""
        tmp = tempfile.mkdtemp()
        old = L.PROJECT_DIR
        try:
            shutil.copytree(os.path.join(GOOD, "TX_Fixture"), os.path.join(tmp, "TX"))
            dev = Path(tmp) / "TX_Dev"
            (dev / "Scripts").mkdir(parents=True)
            (dev / "Scripts" / "TX_Dev_Gameplay.lua").write_text('print(Locale.Lookup("LOC_TX_TEAM_TAB"))\n', encoding="utf-8")
            modinfo = Path(GOOD, "TX_Fixture", "TX_Fixture.modinfo").read_text(encoding="utf-8")
            dep = '<Mod id="7d0c5f3a-2b1e-4c6d-9a8f-1e2d3c4b5a61" title="TX" />'
            dev_modinfo = (
                '<?xml version="1.0" encoding="utf-8"?>\n<Mod id="11111111-2222-4333-8444-555555555555" version="1">\n'
                '  <Properties><Name>TX Dev</Name><Description>dev</Description><AffectsSavedGames>1</AffectsSavedGames></Properties>\n'
                '  <Dependencies><Mod id="4873eb62-8ccc-4574-b784-dda455e74e68" title="Expansion: Gathering Storm" />%s</Dependencies>\n'
                '  <ActionCriteria><Criteria id="TX_Dev_XP2"><GameCoreInUse>Expansion2</GameCoreInUse></Criteria></ActionCriteria>\n'
                '  <InGameActions><AddGameplayScripts id="TX_Dev_Gameplay" criteria="TX_Dev_XP2"><File>Scripts/TX_Dev_Gameplay.lua</File></AddGameplayScripts></InGameActions>\n'
                '  <Files><File>Scripts/TX_Dev_Gameplay.lua</File></Files>\n</Mod>\n')
            self.assertIn("7d0c5f3a-2b1e-4c6d-9a8f-1e2d3c4b5a61", modinfo)
            L.PROJECT_DIR = tmp
            (dev / "TX_Dev.modinfo").write_text(dev_modinfo % dep, encoding="utf-8")
            rep = validate_data.validate(str(dev), db=NO_DB, loc_db=NO_LOC_DB)
            self.assertEqual(rep.count("ERROR"), 0, [vars(f) for f in rep.items if f.level == "ERROR"])
            self.assertIn("text-dependency", codes(rep, "INFO"))
            (dev / "TX_Dev.modinfo").write_text(dev_modinfo % "", encoding="utf-8")
            rep = validate_data.validate(str(dev), db=NO_DB, loc_db=NO_LOC_DB)
            self.assertIn(("TX_Dev_Gameplay.lua", 1, "text-missing"), found(rep))
        finally:
            L.PROJECT_DIR = old
            shutil.rmtree(tmp, ignore_errors=True)


class TestApiAudit(FakeDBCase):
    def test_allowlist_seed(self):
        al = api_audit.load_allowlist()
        s, m, e = al["static"], al["methods"], al["events"]
        self.assertEqual(set(s["Game:SetProperty"]["ctx"]), {"G"})
        self.assertEqual(set(s["Game:GetProperty"]["ctx"]), {"G", "UI"})
        self.assertEqual(set(s["Game.GetLocalPlayer"]["ctx"]), {"UI"})
        self.assertEqual(set(s["UI.RequestPlayerOperation"]["ctx"]), {"UI"})
        self.assertEqual(set(m["GetTeam"]["ctx"]), {"G", "UI"})
        self.assertIn("GameEvents.TX_*", e)
        self.assertIn("LuaEvents.TX_*", e)
        self.assertNotIn("GameEvents.EFV_*", e)
        self.assertEqual(s["UnitManager.PlaceUnit"]["only_paths"], ["TX_Dev/"])
        for sect in api_audit.SECTIONS:
            for key, ent in al[sect].items():
                self.assertIn(ent.get("source"), ("EFV", "TX"), "%s needs a source" % key)
                self.assertTrue(ent["refs"] or ent.get("note"), "evidence for %s" % key)
                for ctx, v in ent["ctx"].items():
                    self.assertIn(v["level"], api_audit.LEVEL_DESC, "%s %s: unknown level" % (key, ctx))
                    src = v.get("source", ent.get("source"))
                    self.assertIn(src, ("EFV", "TX"), "%s %s needs a source" % (key, ctx))
                    if src == "EFV":
                        self.assertEqual(v["level"], "C", "%s %s: the EFV seed is verified in game" % (key, ctx))
                    else:
                        self.assertTrue(v.get("refs") or ent["refs"], "evidence for %s %s" % (key, ctx))
                if ent.get("source") == "EFV":
                    for p in ent.get("only_paths", []):
                        self.assertEqual(p, "TX_Dev/", key)
        self.assertIn("instancemanager", L.base_include_exports())

    def test_regen_is_a_noop(self):
        before = Path(api_audit.ALLOWLIST_PATH).read_bytes()
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(api_audit.main(["--regen"]), 0)
        self.assertIn("does nothing", out.getvalue())
        self.assertEqual(before, Path(api_audit.ALLOWLIST_PATH).read_bytes())

    def test_good_clean(self):
        rep, auditor = api_audit.audit(GOOD, db=NO_DB)
        self.assertEqual(rep.count("ERROR"), 0, [vars(f) for f in rep.items if f.level == "ERROR"])
        self.assertEqual(rep.count("WARN"), 0, [vars(f) for f in rep.items if f.level == "WARN"])
        probes = [f for f in rep.items if f.code == "probe"]
        self.assertEqual([(os.path.basename(f.path), f.line) for f in probes],
                         [("TX_Spike.lua", 19), ("TX_Spike.lua", 20), ("TX_Spike.lua", 21)])
        self.assertIn('"PlayerConfigurations", 1, "SetTeam", 5', probes[1].msg)
        out = io.StringIO()
        auditor.print_checklist(stream=out)
        self.assertEqual(out.getvalue(), "")

    def test_bad_detected(self):
        rep, _ = api_audit.audit(BAD, db=NO_DB)
        f = found(rep)
        for exp in [("TX_Gameplay.lua", 10, "async-mutation"),      # ChangeGoldBalance via helper
                    ("TX_Gameplay.lua", 11, "async-mutation"),      # GetRandNum via helper
                    ("TX_Gameplay.lua", 19, "forbidden-pairs"),
                    ("TX_Gameplay.lua", 23, "forbidden"),          # math.random
                    ("TX_Gameplay.lua", 24, "forbidden"),          # os.time
                    ("TX_Gameplay.lua", 25, "forbidden"),          # Game.GetLocalPlayer in G
                    ("TX_Gameplay.lua", 27, "lua52"),
                    ("TX_Gameplay.lua", 28, "unknown-method"),
                    ("TX_Gameplay.lua", 29, "api-context"),        # UI.RequestPlayerOperation in G
                    ("TX_Gameplay.lua", 30, "forbidden"),          # ExposedMembers
                    ("TX_Gameplay.lua", 31, "unknown-member"),
                    ("TX_Gameplay.lua", 33, "forbidden"),          # :Kill(
                    ("TX_Gameplay.lua", 36, "api-scope"),          # TX_Dev/ only
                    ("TX_Gameplay.lua", 40, "unknown-api"),        # MapLayers.ANYY
                    ("TX_Gameplay.lua", 45, "unknown-event"),      # OnGameTurnStartd
                    ("TX_Gameplay.lua", 47, "api-context"),        # UI event in G
                    ("TX_Util.lua", 8, "region-marker"),
                    ("TX_Panel.lua", 7, "onstart-unhandled"),
                    ("TX_Panel.lua", 9, "api-context"),            # Game.GetRandNum in UI
                    ("TX_Panel.lua", 17, "api-context"),           # GameEvents in UI
                    ("TX_Panel.lua", 19, "unknown-event")]:
            self.assertIn(exp, f)
        w = found(rep, "WARN")
        self.assertIn(("TX_Gameplay.lua", 38, "gameinfo-unlisted"), w)   # no DB: unknown table is only unlisted
        self.assertIn(("TX_Gameplay.lua", 39, "gameinfo-unlisted"), w)
        self.assertIn(("TX_Panel.lua", 12, "pairs-records"), w)
        # the probe line: its arguments are not audited (Game.NoSuchMember, "NoSuchCall")
        self.assertEqual({x[2] for x in f if x[:2] == ("TX_Gameplay.lua", 41)}, {"probe"})

    def test_gameinfo_with_db(self):
        rep, _ = api_audit.audit(BAD, db=self.db)
        self.assertIn(("TX_Gameplay.lua", 38, "gameinfo-unknown"), found(rep, "ERROR"))
        self.assertIn(("TX_Gameplay.lua", 39, "gameinfo-unlisted"), found(rep, "WARN"))

    def test_only_paths(self):
        tmp = tempfile.mkdtemp()
        try:
            for folder in ("TX", "TX_Dev"):
                d = Path(tmp) / folder / "Scripts"
                d.mkdir(parents=True)
                (d / "TX_Place.lua").write_text("local u = nil\nUnitManager.PlaceUnit(u, 1, 1)\n", encoding="utf-8")
            rep, _ = api_audit.audit(os.path.join(tmp, "TX_Dev"), db=NO_DB)
            self.assertEqual(rep.count("ERROR"), 0, [vars(f) for f in rep.items])
            rep, _ = api_audit.audit(os.path.join(tmp, "TX"), db=NO_DB)
            self.assertIn(("TX_Place.lua", 2, "api-scope"), found(rep, "ERROR"))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_only_paths_per_context(self):
        """A context added to an entry can be limited on its own (PlayerConfigurations: UI everywhere, G in TX_Dev/ only)."""
        tmp = tempfile.mkdtemp()
        try:
            data = json.loads(Path(api_audit.ALLOWLIST_PATH).read_text(encoding="utf-8"))
            data["globals"]["PlayerConfigurations"]["ctx"]["G"] = {"level": "NV", "tests": [], "only_paths": ["TX_Dev/"], "source": "TX"}
            path = os.path.join(tmp, "allowlist.json")
            Path(path).write_text(json.dumps(data), encoding="utf-8")
            for folder in ("TX", "TX_Dev"):
                d = Path(tmp) / folder / "Scripts"
                d.mkdir(parents=True)
                (d / "TX_Cfg.lua").write_text("local c = PlayerConfigurations[0]\n", encoding="utf-8")
                u = Path(tmp) / folder / "UI"
                u.mkdir(parents=True)
                (u / "TX_CfgPanel.lua").write_text("local c = PlayerConfigurations[0]\n", encoding="utf-8")
            rep, _ = api_audit.audit(os.path.join(tmp, "TX_Dev"), allowlist=path, db=NO_DB)
            self.assertEqual(rep.count("ERROR"), 0, [vars(f) for f in rep.items])
            self.assertIn(("TX_Cfg.lua", 1, "api-unverified"), found(rep, "WARN"))
            rep, _ = api_audit.audit(os.path.join(tmp, "TX"), allowlist=path, db=NO_DB)
            self.assertIn(("TX_Cfg.lua", 1, "api-scope"), found(rep, "ERROR"))
            self.assertNotIn(("TX_CfgPanel.lua", 1, "api-scope"), found(rep, "ERROR"))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_unverified_calls_make_the_checklist(self):
        tmp = tempfile.mkdtemp()
        try:
            data = json.loads(Path(api_audit.ALLOWLIST_PATH).read_text(encoding="utf-8"))
            data["static"]["Game:SetProperty"]["ctx"]["G"] = {"level": "PENDING", "tests": ["S3"]}
            data["methods"]["GetTeam"]["ctx"]["UI"] = "VERIFY"
            path = os.path.join(tmp, "allowlist.json")
            Path(path).write_text(json.dumps(data), encoding="utf-8")
            rep, auditor = api_audit.audit(GOOD, allowlist=path, db=NO_DB)
            self.assertEqual(rep.count("ERROR"), 0)
            self.assertIn(("TX_Gameplay.lua", 17, "api-unverified"), found(rep, "WARN"))
            out = io.StringIO()
            auditor.print_checklist(stream=out)
            text = out.getvalue()
            self.assertIn("In-game verification checklist", text)
            self.assertIn("[ ] Game:SetProperty (G, pending in-game test [S3]): 1 use(s) in TX_Gameplay.lua", text)
            self.assertIn("[ ] :GetTeam (UI, VERIFY)", text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class TestCheckLogsAndAll(FakeDBCase):
    def _logs(self, name):
        dst = os.path.join(self.tmp, name)
        os.makedirs(dst, exist_ok=True)
        for f in os.listdir(os.path.join(LOGS, name)):
            shutil.copyfile(os.path.join(LOGS, name, f), os.path.join(dst, f[:-4] if f.endswith(".txt") else f))
        return dst

    def test_logs(self):
        out = io.StringIO()
        with redirect_stdout(out):
            bad = check_logs.main(["--logs", self._logs("check_bad")])
            good = check_logs.main(["--logs", self._logs("check_good")])
        self.assertEqual(bad, 1)
        self.assertEqual(good, 0)
        text = out.getvalue()
        self.assertIn("TX_Gameplay.lua:42", text)
        self.assertIn("no column named NoSuchColumn", text)
        self.assertIn("TX_Text - Failed loading XML", text)
        self.assertIn("check_logs: FAIL - 3 TX-related error(s)", text)
        self.assertNotIn("something unrelated", text)

    def test_check_all_exit_codes(self):
        out = io.StringIO()
        self.assertEqual(check_all.run([GOOD], db=NO_DB, loc_db=NO_LOC_DB, out=out)[0], 0)
        self.assertEqual(check_all.run([BAD], db=NO_DB, loc_db=NO_LOC_DB, out=out)[0], 1)
        # without the game DB the good fixture has one warning ("game DB not found, SQL run skipped")
        self.assertEqual(check_all.run([GOOD], strict=True, db=NO_DB, loc_db=NO_LOC_DB, out=out)[0], 1)
        self.assertEqual(check_all.run([GOOD], strict=True, db=self.db, loc_db=self.loc, out=out)[0], 0)

    def test_check_all_default_folders(self):
        tmp = tempfile.mkdtemp()
        old = L.PROJECT_DIR
        try:
            L.PROJECT_DIR = tmp
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(check_all.main(["--db", NO_DB]), 0)
            self.assertIn("TX/ does not exist yet, skipped", out.getvalue())
            self.assertIn("TX_Dev/ does not exist yet, skipped", out.getvalue())
            shutil.copytree(os.path.join(GOOD, "TX_Fixture"), os.path.join(tmp, "TX_Dev"))
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(check_all.main(["--db", NO_DB]), 0)
            text = out.getvalue()
            self.assertIn("TX/ does not exist yet, skipped", text)
            self.assertNotIn("TX_Dev/ does not exist", text)
            self.assertIn("check_all: PASS", text)
            with redirect_stdout(io.StringIO()):
                self.assertEqual(check_all.main([os.path.join(tmp, "nope")]), 2)
        finally:
            L.PROJECT_DIR = old
            shutil.rmtree(tmp, ignore_errors=True)


class TestSummarizeLog(unittest.TestCase):
    def run_log(self, path, *args):
        out = io.StringIO()
        with redirect_stdout(out):
            code = summarize_log.main(["--log", path] + list(args))
        return code, out.getvalue()

    def run_lines(self, lines, *args):
        tmp = tempfile.mkdtemp()
        try:
            path = os.path.join(tmp, "Lua.log")
            Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
            return self.run_log(path, *args)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_good(self):
        code, text = self.run_log(os.path.join(LOGS, "summarize_good.txt"))
        self.assertEqual(code, 0, text)
        self.assertIn("V1    PASS   T6 P1 team 5 differs from P0 team 0  (+1 earlier)", text)
        self.assertIn("V7    INFO   T6 P0-P1: peace", text)
        order = [text.index("[%s]" % s) for s in ("S1", "S3", "V7", "V9", "other")]
        self.assertEqual(order, sorted(order), "sections S1..S4, V1..V12, then other")
        self.assertIn("[S1] 4 line(s)", text)   # "[TX][SPIKE] S1 ..." and "[TX][SPIKE][S1] ..."
        self.assertIn("Errors: none", text)
        self.assertIn("summarize_log: PASS - 3 check(s)", text)

    def test_bad(self):
        code, text = self.run_log(os.path.join(LOGS, "summarize_bad.txt"))
        self.assertEqual(code, 1)
        self.assertIn("V1    FAIL   T6 after reload: P1 team 0 again  (+1 earlier)", text)
        self.assertIn("V4    CHECK", text)
        self.assertIn("V5    PASS   T6 shared vision ended  (+1 earlier)", text)   # a later INFO keeps the verdict
        self.assertIn("Errors: 2 error line(s)", text)
        self.assertIn("TX_Dev_Panel.lua:42", text)

    def test_spike_lines_capped(self):
        lines = ["[TX][SPIKE] S1 key %d" % i for i in range(30)]
        code, text = self.run_lines(lines, "--max-lines", "5")
        self.assertEqual(code, 0)
        self.assertIn("[S1] 30 line(s)", text)
        self.assertIn("25 earlier line(s) hidden", text)
        self.assertIn("key 29", text)
        self.assertNotIn("key 3\n", text)
        code, text = self.run_lines(lines, "--max-lines", "5", "-v")
        self.assertIn("key 3\n", text)

    def test_tx_dev_shapes(self):
        """The TX_Dev spike kit shapes (PLAN I.2): IDs with context and phase, bracket sections incl. S3b."""
        lines = [
            "TX_Dev_Gameplay: [TX][CHECK] V1-G.BASE INFO T5 G target team 0, keeper team 0 (before the change)",
            "TX_Dev_Gameplay: [TX][CHECK] V1-G.S3LIVE FAIL T5 G target team 0, keeper team 0: still the same team",
            "TX_Dev_Gameplay: [TX][CHECK] V1-G.S3RELOAD1 PASS T6 G target team 2, keeper team 0: they differ",
            "TX_Dev_Panel: [TX][CHECK] V5-UI.S3RELOAD1 PASS T6 UI keeper sees=yes target sees=no",
            "TX_Dev_Panel: [TX][CHECK] V5-UI.S3RELOAD1 INFO T6 UI INCONCLUSIVE: visibility unreadable",
            "TX_Dev_Gameplay: [TX][SPIKE][S3b] G team changed outside the panel (lobby?): P1 team 0 -> 2",
            "TX_Dev_Panel: [TX][SPIKE][S2] UI PROBE S2 exist Players[1]?SetTeam exists=nil ok=true ret=() err=-",
            "TX_Dev_Gameplay: [TX][SPIKE][REQ] G got arm from P0 stamp=5001",
        ]
        code, text = self.run_lines(lines)
        self.assertEqual(code, 1, text)   # V1-G.S3LIVE ends in FAIL
        self.assertRegex(text, r"V1-G\.S3LIVE +FAIL ")
        self.assertRegex(text, r"V1-G\.S3RELOAD1 +PASS +T6 G target team 2")
        self.assertRegex(text, r"V5-UI\.S3RELOAD1 +PASS +T6 UI keeper sees=yes target sees=no  \(\+1 earlier\)")
        self.assertIn("[S3b] 1 line(s)", text)
        self.assertIn("    G team changed outside the panel", text)
        self.assertIn("[S2] 1 line(s)", text)
        self.assertIn("[REQ] 1 line(s)", text)

    def test_tx_dev_al_shapes(self):
        """TX_Dev 0.0.1.2 AL lines: IDs with a stage suffix, one ID per stage, sections AL3 / AL7."""
        lines = [
            "TX_Dev_Gameplay: [TX][CHECK] AL0-G.S3RELOAD1 INFO T7 G state now target->keeper=DIPLO_STATE_ALLIED keeper->target=DIPLO_STATE_ALLIED: still ALLIED",
            "TX_Dev_Gameplay: [TX][CHECK] AL3-G.S3RELOAD1.before INFO T7 G before: state now target->keeper=DIPLO_STATE_ALLIED",
            "TX_Dev_Gameplay: [TX][CHECK] AL3-G.S3RELOAD1.after PASS T7 G after: state now target->keeper=DIPLO_STATE_UNFRIENDLY",
            "TX_Dev_Panel: [TX][CHECK] AL3-UI.S3RELOAD1.turn INFO T8 UI turn: state now target->keeper=DIPLO_STATE_ALLIED: still ALLIED",
            "TX_Dev_Gameplay: [TX][SPIKE][AL3] G PROBE AL3 peace <userdata>:MakePeaceWith(1,true) exists=function ok=true ret=() err=-",
            "TX_Dev_Gameplay: [TX][SPIKE][AL7] G PROBE AL7 vis <userdata>:SetAlliesShareVisFlag(false) exists=function ok=true ret=() err=-",
        ]
        code, text = self.run_lines(lines)
        self.assertEqual(code, 0, text)
        self.assertRegex(text, r"AL3-G\.S3RELOAD1\.after +PASS +T7 G after:")
        self.assertRegex(text, r"AL3-UI\.S3RELOAD1\.turn +INFO +T8 UI turn:")
        self.assertIn("summarize_log: PASS - 4 check(s)", text)
        self.assertIn("[AL3] 1 line(s)", text)
        self.assertIn("[AL7] 1 line(s)", text)

    def test_tx_dev_vis_k_shapes(self):
        """TX_Dev 0.0.1.3 lines: VIS<n> / Kvis / K / AL3b / AL4L / AL8 IDs with stages, <item>fx IDs, sections VIS1 / K / AL3b."""
        lines = [
            "TX_Dev_Panel: [TX][CHECK] VIS1-UI.S3RELOAD1.before INFO T7 UI before: marker keeper sees=yes target sees=yes nearest target asset=12; city keeper sees=yes target sees=yes nearest target asset=9: vision still shared",
            "TX_Dev_Gameplay: [TX][CHECK] VIS1-G.S3RELOAD1.after PASS T7 G after: marker keeper sees=yes target sees=no",
            "TX_Dev_Gameplay: [TX][CHECK] VIS0-G.S3RELOAD1 INFO T7 G marker keeper sees=no target sees=no (marker missing: the keeper does not see it)",
            "TX_Dev_Panel: [TX][CHECK] AL3bfx-UI.S3RELOAD1.after INFO T7 UI after: keeper P0 target P1; grievances k->t=0 t->k=100",
            "TX_Dev_Gameplay: [TX][CHECK] AL3b-G.S3RELOAD1.after PASS T7 G after: state now target->keeper=DIPLO_STATE_UNFRIENDLY",
            "TX_Dev_Gameplay: [TX][CHECK] AL4L-G.S3RELOAD1.turn INFO T27 G turn: state now target->keeper=DIPLO_STATE_ALLIED",
            "TX_Dev_Gameplay: [TX][CHECK] AL8-G.S3RELOAD1.after INFO T7 G after: state now target->keeper=DIPLO_STATE_ALLIED",
            "TX_Dev_Gameplay: [TX][CHECK] K-G.S3LIVE.after INFO T4 G after: state now target->keeper=DIPLO_STATE_ALLIED",
            "TX_Dev_Panel: [TX][CHECK] Kvis-UI.S3RELOAD1.turn PASS T5 UI turn: marker keeper sees=yes target sees=no",
            "TX_Dev_Gameplay: [TX][SPIKE][VIS1] G PROBE VIS1 remove PlayersVisibility[0]:RemoveOutgoingVisibility(1) exists=function ok=true ret=() err=-",
            "TX_Dev_Gameplay: [TX][SPIKE][K] G done. NOW save the game as TX3_kick and load TX3_kick (the base UI is stale until a load).",
            "TX_Dev_Gameplay: [TX][SPIKE][AL3b] G P0 declares war on P1 (DeclareWarOn third arg false) at war=true",
        ]
        code, text = self.run_lines(lines)
        self.assertEqual(code, 0, text)
        self.assertRegex(text, r"VIS1-G\.S3RELOAD1\.after +PASS +T7 G after:")
        self.assertRegex(text, r"VIS0-G\.S3RELOAD1 +INFO +T7 G marker keeper sees=no")
        self.assertRegex(text, r"AL3bfx-UI\.S3RELOAD1\.after +INFO +T7 UI after:")
        self.assertRegex(text, r"Kvis-UI\.S3RELOAD1\.turn +PASS +T5 UI turn:")
        self.assertRegex(text, r"AL4L-G\.S3RELOAD1\.turn +INFO +T27 G turn:")
        self.assertIn("summarize_log: PASS - 9 check(s)", text)
        self.assertIn("[VIS1] 1 line(s)", text)
        self.assertIn("[K] 1 line(s)", text)
        self.assertIn("[AL3b] 1 line(s)", text)

    def test_tx_dev_al3t_shapes(self):
        """TX_Dev 0.0.1.5 AL3T lines: AL3T / AL3Tfx IDs with stages (before, war, after, turn), section AL3T."""
        lines = [
            "TX_Dev_Gameplay: [TX][CHECK] AL3T-G.S3RELOAD1.before INFO T4 G before: 0/2 pairs clear (not ALLIED, not at war); P0: state now target->keeper=DIPLO_STATE_ALLIED keeper->target=DIPLO_STATE_ALLIED: still ALLIED | P1: state now target->keeper=DIPLO_STATE_ALLIED keeper->target=DIPLO_STATE_ALLIED: still ALLIED; target P2 keepers P0,P1",
            "TX_Dev_Gameplay: [TX][CHECK] AL3T-G.S3RELOAD1.war INFO T4 G war: 0/2 pairs clear (not ALLIED, not at war); war matrix P0-P1=no P0-P2=yes P1-P2=yes",
            "TX_Dev_Gameplay: [TX][CHECK] AL3T-G.S3RELOAD1.after PASS T4 G after: 2/2 pairs clear (not ALLIED, not at war); target P2 keepers P0,P1",
            "TX_Dev_Panel: [TX][CHECK] AL3T-UI.S3RELOAD1.turn PASS T5 UI turn: 2/2 pairs clear (not ALLIED, not at war)",
            "TX_Dev_Panel: [TX][CHECK] AL3Tfx-UI.S3RELOAD1.after INFO T4 UI after: target P2; P0: grievances P0 holds against P2=100, P2 holds against P0=0",
            "TX_Dev_Gameplay: [TX][SPIKE][AL3T] G P2 declares war on P0 (DeclareWarOn(0,FORMAL_WAR,true)) ok=true at war=yes",
            "TX_Dev_Gameplay: [TX][SPIKE][AL3T] G PROBE AL3T peace <userdata>:MakePeaceWith(0,true) exists=function ok=true ret=() err=-",
        ]
        code, text = self.run_lines(lines)
        self.assertEqual(code, 0, text)
        self.assertRegex(text, r"AL3T-G\.S3RELOAD1\.war +INFO +T4 G war:")
        self.assertRegex(text, r"AL3T-G\.S3RELOAD1\.after +PASS +T4 G after: 2/2 pairs clear")
        self.assertRegex(text, r"AL3T-UI\.S3RELOAD1\.turn +PASS +T5 UI turn:")
        self.assertRegex(text, r"AL3Tfx-UI\.S3RELOAD1\.after +INFO +T4 UI after:")
        self.assertIn("summarize_log: PASS - 5 check(s)", text)
        self.assertIn("[AL3T] 2 line(s)", text)

    def test_missing_log(self):
        code, text = self.run_log(os.path.join(LOGS, "no_such_Lua.log"))
        self.assertEqual(code, 2)
        self.assertIn("cannot read", text)


class TestOfflineRunnerClassify(unittest.TestCase):
    """tests/offline/run_tests.py: XFAIL only for an explicit mark that names pending work."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, os.path.join(L.PROJECT_DIR, "tests", "offline"))
        import run_tests  # noqa: E402
        cls.rt = run_tests

    def test_explicit_mark(self):
        self.assertEqual(self.rt.classify(False, "x", "Phase 2: vote popup", [])[0], "XFAIL")
        self.assertEqual(self.rt.classify(True, "", "WP1.2 bridge", [])[0], "XPASS")
        self.assertEqual(self.rt.classify(True, "", None, [])[0], "PASS")

    def test_mark_must_name_pending_work(self):
        status, detail, xfail = self.rt.classify(False, "x", "flaky", [])
        self.assertEqual((status, xfail), ("FAIL", None))
        self.assertIn("names no pending work", detail)
        self.assertEqual(self.rt.classify(True, "", "someday", [])[0], "FAIL")

    def test_skip(self):
        self.assertEqual(self.rt.classify(False, "SKIP no gameinfo", None, [])[0], "SKIP")


if __name__ == "__main__":
    L.configure_stdout()
    unittest.main(verbosity=2)
