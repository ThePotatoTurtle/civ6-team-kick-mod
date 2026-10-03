#!/usr/bin/env python3
"""validate_data.py - XML / modinfo / SQL / text validation for TX. Stdlib only.

Usage:
    python tools/validate_data.py <root> [--db PATH] [--loc-db PATH] [--strict] [--info]

<root> is a mod folder (contains a .modinfo) or a folder containing mod folders (TX + TX_Dev).

Checks
  XML       every .xml / .modinfo / .artdef is well-formed.
  modinfo   Mod id is a GUID and unique; ids of actions/criteria unique; every action has a defined
            criteria; every action <File> exists (exact case) and is in <Files>; every <Files> entry exists;
            every file on disk is in <Files> (.md / .txt exempt); Gathering Storm dependency;
            AffectsSavedGames=1; ReplaceUIScript has LuaContext + LuaReplace; AddUserInterfaces has
            <Context> and a paired .lua.
  SQL       With the game's cached DebugGameplay.sqlite: the DB is COPIED to a temp dir (the original is
            never opened for writing), leftover TX* rows of a previous game are removed from the copy, and
            every UpdateDatabase .sql/.xml runs there in LoadOrder: unknown tables/columns, constraint and
            UNIQUE(Hash) violations fail; FK check at the end (like the game's "Validating Foreign Key
            Constraints"). Without the DB (no game on this machine): one WARNING "game DB not found, SQL
            run skipped", and the files run against an empty stub instead, which still catches syntax
            errors, duplicate Types rows and the notification pairing below.
            KIND_NOTIFICATION Types <-> Notifications rows must pair up. UpdateIcons files run against a
            stub IconDefinitions schema.
  Text      UpdateText rows parsed; duplicate (Language, Tag) = error; tag collision with the base game
            (needs DebugLocalization.sqlite); every LOC_ key referenced from Lua / SQL / UI XML / modinfo
            must exist (LOC_TX_* in the mod: error; other keys in DebugLocalization.sqlite: warning, or
            info when that DB is missing); dynamic prefixes ("LOC_TX_REASON_"..code) must match at least
            one key; Locale.Lookup(key, ...) and the UI wrappers L(key, ...) / SafeLookup(key, ...) pass at
            least as many args as {n_} placeholders; plural forms "{n_X : plural 1?a; other?b;}"
            well-formed, "{n_Num} turns" without a plural form = warning; unused keys = warning.
            Keys of a dependency mod of this project (a <Dependency> id that matches another .modinfo in
            the project folder, e.g. TX for TX_Dev) count as defined for the reference checks.
            A Lua table "<X>.ALL_REASON_CODES = { ... }" (if the mod has one) needs LOC_TX_REASON_<CODE>
            for every code.
            Internal words: any word of INTERNAL_WORDS in an en_US text value or a literal modinfo
            Name / Teaser / Description / Authors is an error. Empty by default (see the constant).
            No dashes: an en dash or em dash in any UpdateText text or modinfo <LocalizedText> = error.
  Notif.    every notification type the mod inserts has LOC_<type>_MESSAGE and LOC_<type>_SUMMARY (or the
            keys named in its Message / Summary columns); with an UpdateIcons file, an ICON_<type> alias.
  Lua refs  "NOTIFICATION_TX_*" / "TX_NOTIF_*" literals exist as inserted notification types; Controls.X in
            a UI .lua exists as an ID in its paired .xml; InstanceManager:new("Name") has an
            <Instance Name="Name">.
Exit code 1 on any ERROR (or WARN with --strict).
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import txlib as L  # noqa: E402

GUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
IGNORED_UNLISTED = re.compile(r"(\.md|\.txt|\.bak|\.orig|~|thumbs\.db|desktop\.ini|\.gitkeep|\.gitignore)$", re.I)
PLACEHOLDER_RE = re.compile(r"\{(\d+)_[^}]*\}")
LOC_FULL = re.compile(r"^LOC_[A-Z0-9_]+$")
LOC_PREFIX = re.compile(r"^LOC_[A-Z0-9_]*_$")
MOD_LOC_PREFIX = "LOC_" + L.PREFIX + "_"
REASON_PREFIX = "LOC_" + L.PREFIX + "_REASON_"
# Notification type names the mod's Lua may use as string literals.
NOTIF_LITERAL_RE = re.compile(r"(?:NOTIFICATION_%s|%s_NOTIF)_[A-Z0-9_]+" % (L.PREFIX, L.PREFIX))

# Words that must never show in player-visible English text (text values and modinfo display fields).
# Empty on purpose: the public name of this mod may itself be "TX", so the internal prefix is not a
# forbidden word. Add the internal name here once the public name differs (EFV used ["EFV"] because
# players saw "VEF"). Matched as a whole word: "TX_..." keys and identifiers never match.
INTERNAL_WORDS: list = []

# No dashes in player-visible text (Leon's style rule).
DASH_RE = re.compile("[\u2013\u2014]")
DASH_MSG = "%s: the text contains an en or em dash; use a plain hyphen or reword"

ICON_STUB_SCHEMA = """
CREATE TABLE IconTextureAtlases(Name TEXT NOT NULL, IconSize INTEGER NOT NULL DEFAULT 0, IconsPerRow INTEGER,
  IconsPerColumn INTEGER, Filename TEXT, Baseline INTEGER, PRIMARY KEY(Name, IconSize));
CREATE TABLE IconDefinitions(Name TEXT NOT NULL PRIMARY KEY, Atlas TEXT, "Index" INTEGER);
CREATE TABLE IconAliases(Name TEXT NOT NULL PRIMARY KEY, OtherName TEXT NOT NULL);
"""

# Without the game DB: only Types exists up front; other tables are created from the columns a
# statement names (so unknown tables/columns cannot be detected without the real DB).
SQL_STUB_SCHEMA = """
CREATE TABLE Types(Type TEXT NOT NULL PRIMARY KEY, Hash INTEGER, Kind TEXT);
"""

# Text keys defined ahead of the code that will use them: tag -> reason (INFO instead of text-unused).
RESERVED_TEXT: dict = {}

# UI wrappers of Locale.Lookup whose first argument is the key (arg check).
LOOKUP_WRAPPERS = ("L", "SafeLookup")

# Civ VI plural form (base-game syntax): {1_Num : plural 1?turn; other?turns;}
PLURAL_ANY_RE = re.compile(r"\{\d+_[^}]*:\s*plural[^}]*\}")
PLURAL_OK_RE = re.compile(r"^\{\d+_\w+ : plural (?:[0-9a-z]+\?[^;{}]*; )*other\?[^;{}]*;\}$")
PLURAL_NEEDED_RE = re.compile(r"\{(\d+)_\w+\} (turns?|units?|hexes|votes?|players?)\b")


def internal_word_re(words=None):
    words = INTERNAL_WORDS if words is None else words
    if not words:
        return None
    return re.compile(r"(?<![A-Za-z0-9_])(?:%s)(?![A-Za-z0-9_])" % "|".join(re.escape(w) for w in words))


def make_hash(s):
    """Civ VI Make_Hash() = CRC32 without the final xor, as signed 32-bit (verified against DebugGameplay Types)."""
    if s is None:
        return None
    h = zlib.crc32(str(s).encode("utf-8")) ^ 0xFFFFFFFF
    return h - (1 << 32) if h >= (1 << 31) else h


def xml_line(e):
    return getattr(e, "position", (0, 0))[0]


def rel_of(mi, full):
    return os.path.relpath(full, mi.root).replace("\\", "/")


def exact_case_exists(root, rel):
    """True if rel exists under root with exactly this case (Windows is case-insensitive, the game packer is not)."""
    cur = root
    for part in rel.replace("\\", "/").split("/"):
        if part in ("", "."):
            continue
        try:
            names = os.listdir(cur)
        except OSError:
            return False
        if part not in names:
            return False
        cur = os.path.join(cur, part)
    return True


def case_insensitive_match(root, rel):
    """The on-disk spelling of rel when it exists under root in another case (None otherwise). Lets a
    case-sensitive file system (Linux) report "differs in case" like Windows does."""
    cur, parts = root, []
    for part in rel.replace("\\", "/").split("/"):
        if part in ("", "."):
            continue
        try:
            names = os.listdir(cur)
        except OSError:
            return None
        hit = next((n for n in names if n.lower() == part.lower()), None)
        if hit is None:
            return None
        parts.append(hit)
        cur = os.path.join(cur, hit)
    return "/".join(parts) if os.path.isfile(cur) else None


def file_state(root, rel):
    """'ok', 'case' (exists with another case) or 'missing'."""
    if exact_case_exists(root, rel) and os.path.isfile(os.path.join(root, rel)):
        return "ok"
    return "case" if case_insensitive_match(root, rel) else "missing"


def split_sql(text):
    """Yields (line, statement) using sqlite3.complete_statement."""
    buf, start_line = [], None
    for i, line in enumerate(text.splitlines(True), start=1):
        if start_line is None:
            if not line.strip() or line.strip().startswith("--"):
                continue
            start_line = i
        buf.append(line)
        stmt = "".join(buf)
        if sqlite3.complete_statement(stmt):
            yield start_line, stmt
            buf, start_line = [], None
    if buf and "".join(buf).strip():
        yield start_line, "".join(buf)


def gamedata_ops(path):
    """Converts a GameData XML file into (line, sql, params, table, cols) operations."""
    tree = ET.parse(path)
    root = tree.getroot()
    ops = []
    if L._local(root.tag) not in ("GameData", "Database", "GameInfo"):
        return None
    for tbl in root:
        tname = L._local(tbl.tag)
        for op in tbl:
            kind = L._local(op.tag)
            if kind in ("Row", "Replace"):
                cols = dict(op.attrib)
                for ch in op:
                    cols[L._local(ch.tag)] = (ch.text or "")
                cols = {k: _xml_val(v) for k, v in cols.items()}
                sql = "INSERT %sINTO \"%s\" (%s) VALUES (%s)" % (
                    "OR REPLACE " if kind == "Replace" else "", tname,
                    ", ".join('"%s"' % c for c in cols), ", ".join("?" for _ in cols))
                ops.append((0, sql, list(cols.values()), tname, cols))
            elif kind == "Update":
                where = op.find("Where")
                sets = op.find("Set")
                w = dict(where.attrib) if where is not None else {}
                s = dict(sets.attrib) if sets is not None else {}
                if sets is not None:
                    for ch in sets:
                        s[L._local(ch.tag)] = ch.text or ""
                if not s:
                    continue
                sql = "UPDATE \"%s\" SET %s%s" % (tname, ", ".join('"%s" = ?' % k for k in s),
                                                  (" WHERE " + " AND ".join('"%s" = ?' % k for k in w)) if w else "")
                ops.append((0, sql, [_xml_val(v) for v in list(s.values()) + list(w.values())], tname, None))
            elif kind == "Delete":
                w = dict(op.attrib)
                sql = "DELETE FROM \"%s\"%s" % (tname, (" WHERE " + " AND ".join('"%s" = ?' % k for k in w)) if w else "")
                ops.append((0, sql, [_xml_val(v) for v in w.values()], tname, None))
    return ops


def _xml_val(v):
    if isinstance(v, str) and v.lower() in ("true", "false"):
        return 1 if v.lower() == "true" else 0
    return v


_WRITE_TARGET = re.compile(r"(?is)^\s*(?:INSERT(?:\s+OR\s+\w+)?\s+INTO|REPLACE\s+INTO|UPDATE(?:\s+OR\s+\w+)?|DELETE\s+FROM)\s+[\"\[`]?(\w+)")
_INSERT_COLS = re.compile(r"(?is)^\s*(?:INSERT(?:\s+OR\s+\w+)?|REPLACE)\s+INTO\s+[\"\[`]?(\w+)[\"\]`]?\s*\(([^)]*)\)")


def stub_execute(con, sql, params=None, cols_hint=None):
    """Runs one statement against the no-DB stub, creating the written table / missing columns on the
    fly. Returns None (ran), "skip" (needs a table the stub cannot invent) or the sqlite error text."""
    target = _WRITE_TARGET.match(sql)
    target = target.group(1) if target else None
    for _ in range(40):
        try:
            con.execute(sql, params or [])
            return None
        except sqlite3.OperationalError as e:
            msg = str(e)
            m = re.match(r"no such table: (?:main\.)?(\w+)", msg)
            if m:
                if m.group(1) != target:
                    return "skip"
                cols = list(cols_hint) if cols_hint else None
                if cols is None:
                    mc = _INSERT_COLS.match(sql)
                    if mc and mc.group(1) == target:
                        cols = [c.strip().strip('"[]`\'') for c in mc.group(2).split(",") if c.strip()]
                if not cols:
                    cols = ["_stub"]
                con.execute('CREATE TABLE "%s" (%s)' % (target, ", ".join('"%s"' % c for c in cols)))
                continue
            m = re.match(r"table (?:main\.)?(\w+) has no column named (\w+)", msg)
            if m:
                con.execute('ALTER TABLE "%s" ADD COLUMN "%s"' % (m.group(1), m.group(2)))
                continue
            m = re.match(r"no such column: (?:\w+\.)?(\w+)", msg)
            if m and target and re.match(r"(?is)^\s*(UPDATE|DELETE)", sql):
                try:
                    con.execute('ALTER TABLE "%s" ADD COLUMN "%s"' % (target, m.group(1)))
                except sqlite3.Error:
                    return msg
                continue
            if m:
                return "skip"
            return msg
        except sqlite3.Error as e:
            return str(e)
    return "too many stub adjustments"


class Validator:
    def __init__(self, root, rep, db_path=L.GAMEPLAY_DB, loc_db_path=L.LOCALIZATION_DB):
        self.root = os.path.abspath(root)
        self.rep = rep
        self.db_path = db_path
        self.loc_db_path = loc_db_path
        self.mods = [L.parse_modinfo(p) for p in L.find_modinfos(self.root)]
        self.text_defs = {}        # (lang, tag) -> (file, text)
        self.loc_refs = []         # (key, file, line)
        self.loc_prefix_refs = []  # (prefix, file, line)
        self.notif_types = set()   # inserted KIND_NOTIFICATION types
        self.notif_rows = set()
        self.notif_text = {}       # type -> {"Message": key, "Summary": key} from the Notifications row
        self.lua_notif_refs = []
        self.lookup_calls = []     # (key, nargs, file, line)
        self.icon_names = set()    # IconDefinitions / IconAliases names inserted by UpdateIcons files
        self.dep_text = None       # tag -> en_US text of dependency mods in the project (lazy)
        self.internal_re = internal_word_re()

    # ------------------------------------------------------------------
    def run(self):
        self.check_xml_wellformed()
        ids = {}
        for mi in self.mods:
            self.check_modinfo(mi)
            if mi.id:
                if mi.id.lower() in ids:
                    self.rep.error(mi.path, 0, "modinfo-id", "Mod id %s also used by %s" % (mi.id, ids[mi.id.lower()]))
                ids[mi.id.lower()] = mi.path
        self.check_text()
        self.check_sql()
        self.scan_lua_refs()
        self.scan_xml_refs()
        self.check_text_refs()
        self.check_notifications()
        self.check_ui_pairs()

    # ------------------------------------------------------------------
    def check_xml_wellformed(self):
        for f in L.iter_files(self.root, {".xml", ".modinfo", ".artdef"}):
            try:
                ET.parse(f)
            except ET.ParseError as e:
                self.rep.error(f, xml_line(e), "xml", "not well-formed: %s" % e)

    def _internal_word(self, text):
        return self.internal_re is not None and self.internal_re.search(text or "") is not None

    def check_modinfo(self, mi):
        rep, p = self.rep, mi.path
        if mi.parse_error:
            return  # reported by check_xml_wellformed
        if not mi.id or not GUID_RE.match(mi.id):
            rep.error(p, 0, "modinfo-id", "<Mod id> must be a GUID (got %r)" % mi.id)
        if not mi.version:
            rep.warn(p, 0, "modinfo-version", "<Mod version> missing")
        for key in ("Name", "Description"):
            if not mi.props.get(key):
                rep.error(p, 0, "modinfo-props", "Properties/%s missing" % key)
        if mi.props.get("AffectsSavedGames") != "1":
            rep.error(p, 0, "modinfo-props", "Properties/AffectsSavedGames must be 1, got %r" % mi.props.get("AffectsSavedGames"))
        for key, val in mi.props.items():
            if LOC_FULL.match(val or ""):
                self.loc_refs.append((val, p, 0))
            elif key in ("Name", "Teaser", "Description", "Authors") and self._internal_word(val):
                rep.error(p, 0, "text-internal-name", "Properties/%s shows an internal word (%s); use the public name"
                          % (key, ", ".join(INTERNAL_WORDS)))
        dep_ids = {(d[0] or "").lower() for d in mi.deps}
        if L.GS_GUID not in dep_ids:
            rep.error(p, 0, "modinfo-deps", "no Dependency on Gathering Storm (%s)" % L.GS_GUID)
        known_mod_ids = {(m.id or "").lower() for m in self.mods}
        for did, title in mi.deps:
            d = (did or "").lower()
            if not GUID_RE.match(did or ""):
                rep.error(p, 0, "modinfo-deps", "dependency id %r is not a GUID" % did)
            elif d not in L.OFFICIAL_GUIDS and d not in known_mod_ids:
                rep.info(p, 0, "modinfo-deps", "dependency %s (%s) is not a known DLC or a mod under this root" % (did, title))
        crit = [c for c in mi.criteria if c]
        for c in set(crit):
            if crit.count(c) > 1:
                rep.error(p, 0, "modinfo-criteria", "ActionCriteria id %r defined twice" % c)
        files_listed = [L.norm_rel(f) for f in mi.files]
        seen = set()
        for f in files_listed:
            if f.lower() in seen:
                rep.error(p, 0, "modinfo-files", "<Files> lists %s twice" % f)
            seen.add(f.lower())
            st = file_state(mi.root, f)
            if st == "missing":
                rep.error(p, 0, "modinfo-files", "<Files> entry %s does not exist" % f)
            elif st == "case":
                rep.error(p, 0, "modinfo-files", "<Files> entry %s differs in case from the file on disk (%s)"
                          % (f, case_insensitive_match(mi.root, f)))
        listed_lower = {f.lower() for f in files_listed}
        action_ids = {}
        for a in mi.actions:
            where = "%s %s id=%s" % (a.section, a.type, a.id)
            if not a.id:
                rep.error(p, 0, "modinfo-action", "%s has no id" % where)
            elif a.id in action_ids:
                rep.error(p, 0, "modinfo-action", "action id %s used twice" % a.id)
            action_ids[a.id] = a
            if not a.criteria:
                rep.error(p, 0, "modinfo-action", "%s has no criteria attribute" % where)
            elif a.criteria not in crit:
                rep.error(p, 0, "modinfo-action", "%s references undefined criteria %r" % (where, a.criteria))
            lo = a.props.get("LoadOrder")
            if lo is not None and not re.fullmatch(r"-?\d+", lo):
                rep.error(p, 0, "modinfo-action", "%s LoadOrder %r is not an integer" % (where, lo))
            if not a.files and a.type not in ("ReplaceUIScript",):
                rep.error(p, 0, "modinfo-action", "%s has no <File>" % where)
            for fr, _prio in a.files:
                fr = L.norm_rel(fr)
                st = file_state(mi.root, fr)
                if st == "missing":
                    rep.error(p, 0, "modinfo-action", "%s: file %s does not exist" % (where, fr))
                elif st == "case":
                    rep.error(p, 0, "modinfo-action", "%s: %s differs in case from the file on disk" % (where, fr))
                if fr.lower() not in listed_lower:
                    rep.error(p, 0, "modinfo-action", "%s: %s is not listed in <Files>" % (where, fr))
                ext = os.path.splitext(fr)[1].lower()
                expect = {"UpdateDatabase": (".sql", ".xml"), "UpdateText": (".xml", ".sql"), "UpdateIcons": (".xml", ".sql"),
                          "AddGameplayScripts": (".lua",), "AddUserInterfaces": (".xml",), "UpdateColors": (".xml", ".sql"),
                          "UpdateArt": (".artdef", ".xlp", ".dep"),}.get(a.type)
                if expect and ext not in expect:
                    rep.error(p, 0, "modinfo-action", "%s: %s has the wrong type for this action (expected %s)" % (where, fr, "/".join(expect)))
                if a.type == "AddUserInterfaces":
                    lua = os.path.splitext(fr)[0] + ".lua"
                    if not os.path.isfile(os.path.join(mi.root, lua)):
                        rep.warn(p, 0, "modinfo-ui", "%s: no paired %s next to the context XML" % (where, lua))
            if a.type == "AddUserInterfaces" and not a.props.get("Context"):
                rep.error(p, 0, "modinfo-ui", "%s: Properties/Context missing (InGame)" % where)
            if a.type == "ReplaceUIScript":
                for key in ("LuaContext", "LuaReplace"):
                    if not a.props.get(key):
                        rep.error(p, 0, "modinfo-replace", "%s: Properties/%s missing" % (where, key))
                rp = a.props.get("LuaReplace")
                if rp:
                    rp = L.norm_rel(rp)
                    st = file_state(mi.root, rp)
                    if st == "missing":
                        rep.error(p, 0, "modinfo-replace", "%s: LuaReplace %s does not exist" % (where, rp))
                    elif st == "case":
                        rep.error(p, 0, "modinfo-replace", "%s: LuaReplace %s differs in case from the file on disk" % (where, rp))
                    if rp.lower() not in listed_lower:
                        rep.error(p, 0, "modinfo-replace", "%s: LuaReplace %s is not listed in <Files>" % (where, rp))
        # every file on disk must be listed
        for full in L.iter_files(mi.root):
            if full.lower().endswith(".modinfo"):
                continue
            r = rel_of(mi, full)
            if r.lower() not in listed_lower and not IGNORED_UNLISTED.search(r):
                # files that belong to a nested mod are that mod's business
                if any(m is not mi and full.lower().startswith(m.root.lower() + os.sep) for m in self.mods):
                    continue
                rep.error(p, 0, "modinfo-unlisted", "%s exists on disk but is not listed in <Files> (the game skips it)" % r)

    # ------------------------------------------------------------------
    def _action_files(self, types):
        out = []
        for mi in self.mods:
            acts = [a for a in mi.actions if a.type in types]
            acts.sort(key=lambda a: int(a.props.get("LoadOrder", "0")) if re.fullmatch(r"-?\d+", a.props.get("LoadOrder", "0")) else 0)
            for a in acts:
                for fr, _ in a.files:
                    full = os.path.normpath(os.path.join(mi.root, L.norm_rel(fr)))
                    if os.path.isfile(full):
                        out.append((mi, a, full))
        return out

    def check_sql(self):
        db_files = self._action_files({"UpdateDatabase"})
        icon_files = self._action_files({"UpdateIcons"})
        referenced = {f.lower() for _, _, f in db_files + icon_files + self._action_files({"UpdateText", "UpdateColors"})}
        orphans = [f for f in L.iter_files(self.root, {".sql"}) if f.lower() not in referenced]
        for f in orphans:
            self.rep.warn(f, 0, "sql-unreferenced", "SQL file not used by any modinfo action; checked anyway")
        if db_files or orphans:
            tmpdir = None
            if self.db_path and os.path.exists(self.db_path):
                tmpdir = tempfile.mkdtemp(prefix="tx_validate_")
                copy = os.path.join(tmpdir, "DebugGameplay.copy.sqlite")
                shutil.copyfile(self.db_path, copy)
                con = sqlite3.connect(copy)
                gameplay = True
            else:
                self.rep.warn("", 0, "sql-nodb", "game DB not found (%s), SQL run skipped: unknown tables and columns, "
                              "constraints and foreign keys are not checked. SQL syntax and the notification pairing "
                              "are still checked against an empty stub. Use --db PATH or TX_CIV6_DB on a machine with the game."
                              % (self.db_path or "no path"))
                con = sqlite3.connect(":memory:")
                con.executescript(SQL_STUB_SCHEMA)
                gameplay = False
            self.stub_skipped = 0
            con.create_function("Make_Hash", 1, make_hash, deterministic=True)
            con.execute("PRAGMA foreign_keys = OFF")  # the game defers FK checks to the end of the load
            before, before_n = set(), set()
            if gameplay:
                # The live cache holds the DB of the last game played, including rows of mods that were
                # enabled (e.g. TX itself). Drop TX-prefixed rows from the COPY first.
                purged = 0
                like = "%s%%" % L.PREFIX
                for tbl, col in (("Notifications", "NotificationType"), ("Types", "Type")):
                    try:
                        purged += con.execute("DELETE FROM \"%s\" WHERE \"%s\" LIKE ? OR \"%s\" LIKE ?" % (tbl, col, col),
                                              (like, "NOTIFICATION_" + like)).rowcount
                    except sqlite3.Error:
                        pass
                if purged:
                    self.rep.info(self.db_path, 0, "sql-purge", "removed %d %s* rows left in the cached DB by a previous game (copy only)"
                                  % (purged, L.PREFIX))
                before = {r[0] for r in con.execute("SELECT Type FROM Types WHERE Kind = 'KIND_NOTIFICATION'")}
                try:
                    before_n = {r[0] for r in con.execute("SELECT NotificationType FROM Notifications")}
                except sqlite3.Error:
                    before_n = set()
            touched = set()
            for mi, a, f in db_files:
                self._exec_file(con, f, touched, gameplay)
            for f in orphans:
                self._exec_file(con, f, touched, gameplay)
            if gameplay:
                try:
                    rows = con.execute("PRAGMA foreign_key_check").fetchall()
                except sqlite3.Error as e:
                    rows = []
                    self.rep.warn("", 0, "sql-fk", "foreign_key_check failed: %s" % e)
                bad = [r for r in rows if r[0] in touched]
                for r in bad[:50]:
                    try:
                        cur = con.execute('SELECT * FROM "%s" WHERE rowid = ?' % r[0], (r[1],))
                        names = [d[0] for d in cur.description]
                        vals = cur.fetchone() or ()
                        row = ", ".join("%s=%r" % (n, v) for n, v in list(zip(names, vals))[:3])
                    except sqlite3.Error:
                        row = "rowid %s" % r[1]
                    self.rep.error("", 0, "sql-fk", "foreign key violation: %s(%s) -> %s (the game fails 'Validating Foreign Key Constraints' and drops the mod DB)" % (r[0], row, r[2]))
            elif self.stub_skipped:
                self.rep.info("", 0, "sql-nodb", "%d statement(s) read other tables and were not run without the game DB" % self.stub_skipped)
            after = {r[0] for r in con.execute("SELECT Type FROM Types WHERE Kind = 'KIND_NOTIFICATION'")}
            try:
                cur = con.execute("SELECT * FROM Notifications")
                cols = [d[0] for d in cur.description]
                after_rows = [dict(zip(cols, r)) for r in cur.fetchall()]
            except sqlite3.Error:
                after_rows = []
            after_n = {r.get("NotificationType") for r in after_rows} - {None}
            self.notif_types = after - before
            self.notif_rows = after_n - before_n
            for r in after_rows:
                t = r.get("NotificationType")
                if t in self.notif_rows:
                    self.notif_text[t] = {k: r.get(k) for k in ("Message", "Summary") if r.get(k)}
            for t in sorted(self.notif_types - self.notif_rows):
                self.rep.error("", 0, "sql-notification", "Types row %s (KIND_NOTIFICATION) has no Notifications row" % t)
            for t in sorted(self.notif_rows - self.notif_types):
                self.rep.error("", 0, "sql-notification", "Notifications row %s has no Types row with Kind KIND_NOTIFICATION" % t)
            for r in after_rows:
                t = r.get("NotificationType")
                if t in self.notif_rows and "Icon" in r and not (r.get("Icon") or "").strip():
                    self.rep.warn("", 0, "notification-icon", "%s has no Notifications.Icon (a type without a resolvable "
                                  "icon shows a stale icon)" % t)
            con.close()
            if tmpdir:
                shutil.rmtree(tmpdir, ignore_errors=True)
        if icon_files:
            con = sqlite3.connect(":memory:")
            con.executescript(ICON_STUB_SCHEMA)
            for mi, a, f in icon_files:
                self._exec_file(con, f, set(), True, stub=True)
            for tbl in ("IconDefinitions", "IconAliases"):
                try:
                    self.icon_names |= {r[0] for r in con.execute('SELECT Name FROM "%s"' % tbl)}
                except sqlite3.Error:
                    pass
            con.close()

    def _run(self, con, sql, params, gameplay, cols=None):
        """Returns the error text or None."""
        if gameplay:
            try:
                con.execute(sql, params or [])
            except (sqlite3.Error, sqlite3.Warning) as e:
                return str(e)
            return None
        res = stub_execute(con, sql, params, cols)
        if res == "skip":
            self.stub_skipped = getattr(self, "stub_skipped", 0) + 1
            return None
        return res

    def _exec_file(self, con, f, touched, gameplay, stub=False):
        tag = "sql-icons" if stub else "sql"
        note = " (stub icon schema: Name, Atlas, Index)" if stub else ""
        if f.lower().endswith(".xml"):
            try:
                ops = gamedata_ops(f)
            except ET.ParseError:
                return
            if ops is None:
                self.rep.warn(f, 0, tag, "XML root is not <GameData>/<Database>; not executed")
                return
            for line, sql, params, tname, cols in ops:
                touched.add(tname)
                err = self._run(con, sql, params, gameplay, list(cols) if cols else None)
                if err:
                    self.rep.error(f, line, tag, "%s: %s%s" % (tname, err, note))
            return
        text, bom = L.read_text(f)
        con.execute("SAVEPOINT tx_file")
        for line, stmt in split_sql(text):
            for m in re.finditer(r"(?is)\b(?:INSERT(?:\s+OR\s+\w+)?\s+INTO|UPDATE|DELETE\s+FROM|REPLACE\s+INTO)\s+\"?(\w+)", stmt):
                touched.add(m.group(1))
            for m in re.finditer(r"'(LOC_[A-Z0-9_]+)'", stmt):
                self.loc_refs.append((m.group(1), f, line))
            err = self._run(con, stmt, None, gameplay)
            if err:
                self.rep.error(f, line, tag, "%s%s" % (err, note))
        con.execute("RELEASE tx_file")

    # ------------------------------------------------------------------
    def check_text(self):
        text_files = [f for _, _, f in self._action_files({"UpdateText"})]
        listed = {f.lower() for f in text_files}
        # text-looking XML not referenced by any UpdateText action
        for f in L.iter_files(self.root, {".xml"}):
            if f.lower() in listed:
                continue
            try:
                r = ET.parse(f).getroot()
            except ET.ParseError:
                continue
            if any(L._local(c.tag) in ("LocalizedText", "BaseGameText", "EnglishText") for c in r):
                self.rep.warn(f, 0, "text-unreferenced", "localized text file not used by any UpdateText action")
                text_files.append(f)
        loc_stub = sqlite3.connect(":memory:")
        loc_stub.execute("CREATE TABLE LocalizedText(Language TEXT NOT NULL, Tag TEXT NOT NULL, Text TEXT, Gender TEXT, Plurality TEXT, PRIMARY KEY(Language, Tag))")
        base = self._loc_db()
        for f in text_files:
            if f.lower().endswith(".sql"):
                continue
            try:
                root = ET.parse(f).getroot()
            except ET.ParseError:
                continue
            for tbl in root:
                tname = L._local(tbl.tag)
                if tname not in ("LocalizedText", "BaseGameText", "EnglishText"):
                    self.rep.warn(f, 0, "text-table", "unexpected table <%s> in a text file" % tname)
                    continue
                for row in tbl:
                    kind = L._local(row.tag)
                    if kind not in ("Row", "Replace"):
                        continue
                    tag = row.get("Tag")
                    lang = row.get("Language") or ("en_US" if tname != "LocalizedText" else None)
                    txt = row.get("Text")
                    for ch in row:
                        cn = L._local(ch.tag)
                        if cn == "Text":
                            txt = ch.text or ""
                        elif cn == "Tag":
                            tag = ch.text
                        elif cn == "Language":
                            lang = ch.text
                    if not tag:
                        self.rep.error(f, 0, "text-row", "text row without Tag")
                        continue
                    if not lang:
                        self.rep.error(f, 0, "text-row", "%s: LocalizedText row without Language" % tag)
                        continue
                    if txt is None or not str(txt).strip():
                        self.rep.warn(f, 0, "text-empty", "%s (%s) has empty Text" % (tag, lang))
                    if not re.fullmatch(r"LOC_[A-Z0-9_]+", tag):
                        self.rep.warn(f, 0, "text-tag", "tag %r does not follow LOC_UPPER_CASE" % tag)
                    self._check_plurals(f, tag, txt or "")
                    if lang == "en_US" and self._internal_word(txt):
                        self.rep.error(f, 0, "text-internal-name", "%s: the text shows an internal word (%s); use the public name"
                                       % (tag, ", ".join(INTERNAL_WORDS)))
                    if DASH_RE.search(txt or ""):
                        self.rep.error(f, 0, "text-dash", DASH_MSG % tag)
                    key = (lang, tag)
                    if key in self.text_defs and kind == "Row":
                        self.rep.error(f, 0, "text-duplicate", "duplicate Tag %s (%s); first defined in %s" % (
                            tag, lang, self.rep.rel(self.text_defs[key][0])))
                    self.text_defs[key] = (f, txt or "")
                    if kind == "Row" and base is not None:
                        try:
                            hit = base.execute("SELECT 1 FROM LocalizedText WHERE Language = ? AND Tag = ?", key).fetchone()
                        except sqlite3.Error:
                            hit = None
                        if hit:
                            self.rep.error(f, 0, "text-collision", "%s (%s) already exists in the base game: <Row> insert fails; use <Replace>" % (tag, lang))
                    try:
                        loc_stub.execute("INSERT OR REPLACE INTO LocalizedText(Language, Tag, Text) VALUES (?,?,?)", (lang, tag, txt))
                    except sqlite3.Error as e:
                        self.rep.error(f, 0, "text-row", "%s: %s" % (tag, e))
        loc_stub.close()
        self._modinfo_text()

    def _check_plurals(self, f, tag, txt):
        """Plural forms must be well-formed ("{n_X : plural 1?a; other?b;}", the "other" form last) and a
        number placeholder followed by a countable noun ("{1_Num} turns") must use one."""
        for m in PLURAL_ANY_RE.finditer(txt):
            if not PLURAL_OK_RE.match(m.group(0)):
                self.rep.error(f, 0, "text-plural", "%s: malformed plural form %r (expected {n_Name : plural 1?one; other?many;})"
                               % (tag, m.group(0)))
        for m in PLURAL_NEEDED_RE.finditer(txt):
            self.rep.warn(f, 0, "text-plural", "%s: %r has a fixed noun after a number; use {%s_X : plural 1?..; other?..;}"
                          % (tag, m.group(0), m.group(1)))

    def _reason_codes(self):
        """Codes of a Lua table "<X>.ALL_REASON_CODES = { "A", "B" }" under the root (None if absent)."""
        for f in L.iter_files(self.root, {".lua"}):
            src, _ = L.read_text(f)
            m = re.search(r"\bALL_REASON_CODES\s*=\s*\{(.*?)\n\}", src, re.S)
            if not m:
                continue
            body = re.sub(r"--[^\n]*", "", m.group(1))
            return re.findall(r'"([A-Z][A-Z0-9_]*)"', body)
        return None

    def _modinfo_text(self):
        """Keys defined in a modinfo <LocalizedText> block (mod-browser text, e.g. LOC_TX_MOD_TITLE)."""
        for mi in L.find_modinfos(self.root):
            try:
                root = ET.parse(mi).getroot()
            except ET.ParseError:
                continue
            for lt in root.iter():
                if L._local(lt.tag) != "LocalizedText":
                    continue
                for t in lt:
                    if L._local(t.tag) != "Text":
                        continue
                    tag = t.get("id") or t.get("Tag")
                    if not tag:
                        self.rep.error(mi, 0, "text-row", "modinfo <LocalizedText><Text> without id")
                        continue
                    langs = [c for c in t if L._local(c.tag)]
                    if not langs:
                        self.rep.warn(mi, 0, "text-empty", "%s has no language entry in the modinfo" % tag)
                    for c in langs:
                        lang = L._local(c.tag)
                        if lang == "en_US" and self._internal_word(c.text):
                            self.rep.error(mi, 0, "text-internal-name", "%s: the text shows an internal word (%s); use the public name"
                                           % (tag, ", ".join(INTERNAL_WORDS)))
                        if DASH_RE.search(c.text or ""):
                            self.rep.error(mi, 0, "text-dash", DASH_MSG % tag)
                        key = (lang, tag)
                        if key in self.text_defs:
                            self.rep.error(mi, 0, "text-duplicate", "duplicate Tag %s (%s); also defined in %s" % (
                                tag, lang, self.rep.rel(self.text_defs[key][0])))
                        self.text_defs[key] = (mi, c.text or "")

    def _loc_db(self):
        if not hasattr(self, "_locdb"):
            self._locdb = None
            if self.loc_db_path and os.path.exists(self.loc_db_path):
                try:
                    self._locdb = sqlite3.connect("file:%s?mode=ro" % self.loc_db_path.replace("\\", "/"), uri=True)
                except sqlite3.Error:
                    self._locdb = None
        return self._locdb

    # ------------------------------------------------------------------
    def scan_lua_refs(self):
        for f in L.iter_files(self.root, {".lua"}):
            src, _ = L.read_text(f)
            try:
                toks, _c = L.lex(src)
            except L.LexError:
                continue
            n = len(toks)
            for i, t in enumerate(toks):
                if t.kind != "str":
                    continue
                v = t.val
                if LOC_PREFIX.match(v):
                    self.loc_prefix_refs.append((v, f, t.line))
                elif LOC_FULL.match(v):
                    self.loc_refs.append((v, f, t.line))
                if NOTIF_LITERAL_RE.fullmatch(v):
                    self.lua_notif_refs.append((v, f, t.line))
            # Locale.Lookup("LOC_X", a, b) / :LocalizeAndSetText("LOC_X", a) /
            # the UI wrappers L("LOC_X", a) and SafeLookup("LOC_X", a)
            for i in range(n - 3):
                is_lookup = (toks[i].val == "Locale" and toks[i + 1].val == "." and toks[i + 2].val == "Lookup")
                is_method = (toks[i].val == ":" and toks[i + 1].val in ("LocalizeAndSetText", "LocalizeAndSetToolTip"))
                is_wrapper = (toks[i].kind == "name" and toks[i].val in LOOKUP_WRAPPERS
                              and not (i > 0 and toks[i - 1].val in (".", ":", "function"))
                              and toks[i + 1].val == "(" and toks[i + 2].kind == "str")
                if not (is_lookup or is_method or is_wrapper):
                    continue
                j = i + 3 if is_lookup else (i + 1 if is_wrapper else i + 2)
                if j >= n or toks[j].val != "(" or j + 1 >= n or toks[j + 1].kind != "str":
                    continue
                key = toks[j + 1].val
                end = L.skip_balanced(toks, j)
                depth, args = 0, 1
                for k in range(j + 1, end - 1):
                    tv = toks[k]
                    if tv.kind == "op" and tv.val in "([{":
                        depth += 1
                    elif tv.kind == "op" and tv.val in ")]}":
                        depth -= 1
                    elif depth == 0 and tv.kind == "op" and tv.val == ",":
                        args += 1
                if LOC_FULL.match(key):
                    self.lookup_calls.append((key, args - 1, f, toks[i].line))

    def scan_xml_refs(self):
        for f in L.iter_files(self.root, {".xml"}):
            try:
                root = ET.parse(f).getroot()
            except ET.ParseError:
                continue
            if L._local(root.tag) in ("GameData", "Database"):
                for el in root.iter():
                    for v in list(el.attrib.values()) + [el.text or ""]:
                        v = (v or "").strip()
                        if LOC_FULL.match(v):
                            # text files define keys; only count values that are not the Tag itself
                            if el.get("Tag") == v or L._local(el.tag) == "Tag":
                                continue
                            self.loc_refs.append((v, f, 0))
                continue
            for el in root.iter():
                for k, v in el.attrib.items():
                    for m in re.finditer(r"LOC_[A-Z0-9_]+", v or ""):
                        self.loc_refs.append((m.group(0), f, 0))

    def dependency_text(self):
        """Tags (-> en_US text) of the UpdateText files of the mods this root depends on that live in the
        project folder (e.g. TX for TX_Dev). Keys a mod reads from its dependency are defined at run time."""
        if self.dep_text is not None:
            return self.dep_text
        self.dep_text = {}
        own = {os.path.normcase(os.path.abspath(m.path)) for m in self.mods}
        dep_ids = {(d[0] or "").lower() for m in self.mods for d in m.deps} - set(L.OFFICIAL_GUIDS)
        if not dep_ids:
            return self.dep_text
        # the mod folders at the top of the project (TX\, TX_Dev\); dist\ copies are not sources
        paths = sorted(glob.glob(os.path.join(L.PROJECT_DIR, "*", "*.modinfo")))
        for path in paths:
            if os.path.normcase(os.path.abspath(path)) in own:
                continue
            if os.path.basename(os.path.dirname(path)) in ("dist", "tests", "tools", "research", "spike", "workshop"):
                continue
            mi = L.parse_modinfo(path)
            if (mi.id or "").lower() not in dep_ids:
                continue
            for a in mi.actions:
                if a.type != "UpdateText":
                    continue
                for fr, _ in a.files:
                    full = os.path.normpath(os.path.join(mi.root, L.norm_rel(fr)))
                    try:
                        root = ET.parse(full).getroot()
                    except (ET.ParseError, OSError):
                        continue
                    for row in root.iter():
                        if L._local(row.tag) not in ("Row", "Replace"):
                            continue
                        tag, lang, txt = row.get("Tag"), row.get("Language") or "en_US", row.get("Text")
                        for ch in row:
                            cn = L._local(ch.tag)
                            if cn == "Text":
                                txt = ch.text or ""
                            elif cn == "Tag":
                                tag = ch.text
                            elif cn == "Language":
                                lang = ch.text
                        if tag and lang == "en_US":
                            self.dep_text[tag] = txt or ""
        return self.dep_text

    def check_text_refs(self):
        defined = {tag for (_lang, tag) in self.text_defs}
        en = {tag: txt for (lang, tag), (_f, txt) in self.text_defs.items() if lang == "en_US"}
        dep = self.dependency_text() if (self.loc_refs or self.loc_prefix_refs) else {}
        for tag, txt in dep.items():
            en.setdefault(tag, txt)
        base = self._loc_db()
        used = set()
        # Notification text is looked up by convention ("LOC_" .. type .. "_MESSAGE" / "_SUMMARY"),
        # so every inserted type's keys count as used, and so do variant keys "LOC_<type>_<X>_MESSAGE".
        for t in (self.notif_types | self.notif_rows):
            used.add("LOC_" + t + "_MESSAGE")
            used.add("LOC_" + t + "_SUMMARY")
            variant = re.compile(r"^LOC_" + re.escape(t) + r"_[A-Z0-9]+_(MESSAGE|SUMMARY)$")
            for tag in defined:
                if variant.match(tag):
                    used.add(tag)
        unchecked_base = []
        for key, f, line in self.loc_refs:
            used.add(key)
            if key in defined:
                continue
            if key in dep:
                self.rep.info(f, line, "text-dependency", "%s is defined by a dependency mod of this project" % key)
                continue
            if key.startswith(MOD_LOC_PREFIX):
                self.rep.error(f, line, "text-missing", "%s is referenced but not defined in any UpdateText file" % key)
            elif base is None:
                unchecked_base.append(key)
                self.rep.info(f, line, "text-missing-base", "%s is not defined by the mod; base-game keys are not checked "
                              "without DebugLocalization.sqlite" % key)
            else:
                try:
                    hit = base.execute("SELECT 1 FROM LocalizedText WHERE Tag = ? LIMIT 1", (key,)).fetchone()
                except sqlite3.Error:
                    hit = None
                if not hit:
                    self.rep.warn(f, line, "text-missing-base", "%s not defined by the mod and not found in DebugLocalization.sqlite" % key)
        prefixes = set()
        for pfx, f, line in self.loc_prefix_refs:
            prefixes.add(pfx)
            if not any(t.startswith(pfx) for t in defined) and not any(t.startswith(pfx) for t in dep):
                self.rep.error(f, line, "text-prefix", "dynamic key prefix %r matches no defined key" % pfx)
            else:
                self.rep.info(f, line, "text-prefix", "dynamic key prefix %r (keys built at runtime are not checked individually)" % pfx)
        for key, nargs, f, line in self.lookup_calls:
            txt = en.get(key)
            if txt is None:
                continue
            idxs = [int(x) for x in PLACEHOLDER_RE.findall(txt)]
            need = max(idxs) if idxs else 0
            if nargs < need:
                self.rep.error(f, line, "text-args", "%s uses {%d_...} but the call passes %d argument(s)" % (key, need, nargs))
            elif nargs > need:
                self.rep.warn(f, line, "text-args", "%s uses %d argument(s) but the call passes %d" % (key, need, nargs))
        # <X>.ALL_REASON_CODES <-> LOC_TX_REASON_* keys (the keys are built at runtime from the code, so
        # the dynamic prefix alone would hide missing and unused ones)
        codes = self._reason_codes()
        reason_unused = set()
        if codes is not None:
            for code in codes:
                if REASON_PREFIX + code not in defined and REASON_PREFIX + code not in dep:
                    self.rep.error("", 0, "text-reason", "ALL_REASON_CODES code %s has no %s%s" % (code, REASON_PREFIX, code))
            reason_unused = {t for t in defined if t.startswith(REASON_PREFIX) and t[len(REASON_PREFIX):] not in codes}
            used |= {REASON_PREFIX + c for c in codes}   # looked up at runtime from the code
        for (lang, tag), (f, _txt) in sorted(self.text_defs.items()):
            if lang != "en_US":
                continue
            if tag in reason_unused:
                self.rep.warn(f, 0, "text-unused", "%s: no reason code %s in ALL_REASON_CODES" % (tag, tag[len(REASON_PREFIX):]))
                continue
            if tag in used or any(tag.startswith(p) for p in prefixes):
                continue
            if tag in RESERVED_TEXT:
                self.rep.info(f, 0, "text-reserved", "%s not referenced yet: reserved for %s" % (tag, RESERVED_TEXT[tag]))
                continue
            self.rep.warn(f, 0, "text-unused", "%s is defined but never referenced (Lua/SQL/XML/modinfo)" % tag)

    def check_notifications(self):
        types = self.notif_types | self.notif_rows
        for v, f, line in self.lua_notif_refs:
            if types and v not in types:
                self.rep.error(f, line, "notification-missing", "notification type %s is not inserted by any UpdateDatabase SQL" % v)
            elif not types:
                self.rep.error(f, line, "notification-missing", "notification type %s used, but the mod inserts no notification types" % v)
        defined = {tag for (_l, tag) in self.text_defs} | set(self.dependency_text())
        has_icons = bool(self._action_files({"UpdateIcons"}))
        for t in sorted(types):
            # NotificationPanel falls back to "ICON_" .. type when the Icon column does not resolve
            if has_icons and ("ICON_" + t) not in self.icon_names:
                self.rep.error("", 0, "notification-icon", "%s has no ICON_%s alias in an UpdateIcons file" % (t, t))
            named = self.notif_text.get(t, {})
            for col, suffix in (("Message", "_MESSAGE"), ("Summary", "_SUMMARY")):
                k = named.get(col) or ("LOC_" + t + suffix)
                if k not in defined:
                    self.rep.warn("", 0, "notification-text", "notification %s has no text %s" % (t, k))
        if types:
            self.rep.info("", 0, "notification-count", "%d notification type(s) inserted" % len(types))

    # ------------------------------------------------------------------
    def check_ui_pairs(self):
        for xml in L.iter_files(self.root, {".xml"}):
            try:
                root = ET.parse(xml).getroot()
            except ET.ParseError:
                continue
            if L._local(root.tag) != "Context":
                continue
            ids_top, instances = {}, {}
            self._collect_ids(root, ids_top, xml, instances)
            lua = os.path.splitext(xml)[0] + ".lua"
            if not os.path.isfile(lua):
                continue
            src, _ = L.read_text(lua)
            try:
                toks, _c = L.lex(src)
            except L.LexError:
                continue
            for i in range(len(toks) - 2):
                if toks[i].val == "Controls" and toks[i].kind == "name" and toks[i + 1].val == "." and toks[i + 2].kind == "name":
                    cid = toks[i + 2].val
                    if cid not in ids_top:
                        self.rep.error(lua, toks[i].line, "ui-control", "Controls.%s: no element with ID=\"%s\" in %s (outside <Instance>)" % (
                            cid, cid, os.path.basename(xml)))
                if toks[i].val == "InstanceManager" and toks[i + 1].val == ":" and toks[i + 2].val == "new" and i + 4 < len(toks) \
                        and toks[i + 4].kind == "str":
                    name = toks[i + 4].val
                    if name not in instances:
                        self.rep.error(lua, toks[i].line, "ui-instance", "InstanceManager:new(\"%s\"): no <Instance Name=\"%s\"> in %s" % (
                            name, name, os.path.basename(xml)))
                    else:
                        root_ctl = toks[i + 6].val if i + 6 < len(toks) and toks[i + 6].kind == "str" else None
                        if root_ctl and root_ctl not in instances[name]:
                            self.rep.error(lua, toks[i].line, "ui-instance", "InstanceManager:new(\"%s\", \"%s\"): the instance has no ID=\"%s\"" % (
                                name, root_ctl, root_ctl))

    def _collect_ids(self, el, ids, xml, instances):
        for ch in el:
            tag = L._local(ch.tag)
            if tag == "Instance":
                name = ch.get("Name")
                sub = {}
                self._collect_ids(ch, sub, xml, instances)
                if name in instances:
                    self.rep.error(xml, 0, "ui-instance", "<Instance Name=\"%s\"> defined twice" % name)
                instances[name] = sub
                continue
            cid = ch.get("ID")
            if cid:
                if cid in ids:
                    self.rep.error(xml, 0, "ui-id", "duplicate ID=\"%s\" in the same scope" % cid)
                ids[cid] = True
            self._collect_ids(ch, ids, xml, instances)


def validate(root, rep=None, db=L.GAMEPLAY_DB, loc_db=L.LOCALIZATION_DB):
    rep = rep or L.Report("validate_data", base=L.PROJECT_DIR)
    Validator(root, rep, db_path=db, loc_db_path=loc_db).run()
    return rep


def main(argv=None):
    L.configure_stdout()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", nargs="?", default=os.path.join(L.PROJECT_DIR, "TX"))
    ap.add_argument("--db", default=L.GAMEPLAY_DB, help="gameplay DB to copy (default: the game's cache)")
    ap.add_argument("--loc-db", default=L.LOCALIZATION_DB, help="localization DB (default: the game's cache)")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--info", action="store_true")
    a = ap.parse_args(argv)
    if not os.path.exists(a.root):
        print("validate_data: root not found: %s" % a.root)
        return 2
    rep = validate(a.root, db=a.db, loc_db=a.loc_db)
    rep.print(show_info=a.info)
    return rep.exit_code(a.strict)


if __name__ == "__main__":
    sys.exit(main())
