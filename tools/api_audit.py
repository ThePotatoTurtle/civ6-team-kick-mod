#!/usr/bin/env python3
"""api_audit.py - engine API usage audit for TX.

Usage:
    python tools/api_audit.py <root> [--strict] [--info] [--no-checklist] [--allowlist PATH] [--db PATH]

Allowlist:
    tools/api_allowlist.json  kept by hand. Every engine call the mod may use, per context (G = gameplay,
                              UI), with its status ("level") and evidence ("refs", "note", "source").
                              Levels: C = verified in game. L (likely), NV (new, verify), PENDING and
                              VERIFY are not verified yet: every use prints a WARN and goes on the
                              checklist printed at the end. "only_paths": ["TX_Dev/"] limits a call to
                              files whose path contains one of the strings (dev-only calls). A context
                              entry may carry its own "only_paths" (and "source", "refs"): it then
                              limits only that context, e.g. a TX_Dev G context added to a UI entry.

Per Lua file the context is G (gameplay), UI or both (shared), from the modinfo actions + include graph
(fallback: Scripts/ = G, UI/ = UI, TX_Config/TX_Util/TX_Rules = both; a "-- TX:CONTEXT G|UI|both" comment
overrides). Inside `-- TX:G-ONLY begin/end` and `-- TX:UI-ONLY begin/end` regions the region's context applies.

Spike probes: a call to a function named TX_Probe or Probe (also X.Probe / X:Probe) is a probe. Its whole
argument list is not audited, so a probe can name a call that is not on the allowlist yet, by string:
    TX_Probe("S2 SetTeam", "PlayerConfigurations", 1, "SetTeam", 5)
The probe function itself (defined in the dev mod) must look the call up by name and run it under pcall.
Each probe call is listed as INFO (--info) with the string arguments, so the spike calls stay visible.

Reports:
  ERROR  engine call / member / event not in the allowlist; call in a context it is not listed for, or
         outside its only_paths; forbidden pattern (math.random, os.* in gameplay, Game.GetLocalPlayer in
         gameplay, pairs() in gameplay outside a *SortedKeys helper, table.unpack, ExposedMembers, ...);
         state change reachable from an Events.* handler registered in gameplay; unknown function on a
         project module table (TX_Util.Foo); a UI request (OnStart) without a GameEvents handler.
  WARN   call not verified in game yet (also printed as the checklist); GameInfo table not on the
         allowlist; handler registration inside a function in gameplay; GameEvents.TX_* handler that no
         UI file sends; pairs() over records in UI.
Exit code 1 on any ERROR (or WARN with --strict).
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import txlib as L  # noqa: E402

ALLOWLIST_PATH = L.ALLOWLIST_PATH
SECTIONS = ("globals", "static", "methods", "events", "gameinfo")

# Status levels. Only C counts as verified; anything else prints a WARN and goes on the checklist.
LEVEL_DESC = {"C": "verified", "L": "LIKELY", "NV": "NEW-VERIFY", "PENDING": "pending in-game test", "VERIFY": "VERIFY"}
EVENT_ROOTS = {"GameEvents", "Events", "LuaEvents"}
PROBE_FUNCS = {"TX_Probe", "Probe"}
PREFIX = L.PREFIX

LUA_STD = {
    "string": {"byte", "char", "find", "format", "gmatch", "gsub", "len", "lower", "match", "rep", "reverse", "sub", "upper"},
    "table": {"concat", "insert", "maxn", "remove", "sort"},
    "math": {"abs", "acos", "asin", "atan", "atan2", "ceil", "cos", "cosh", "deg", "exp", "floor", "fmod", "frexp",
             "huge", "ldexp", "log", "log10", "max", "min", "modf", "pi", "pow", "rad", "sin", "sinh", "sqrt", "tan", "tanh"},
    "coroutine": {"create", "resume", "running", "status", "wrap", "yield"},
    "os": set(),
}
STRING_METHODS = LUA_STD["string"]
LUA_BUILTIN_FUNCS = {"assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "print", "rawequal", "rawget",
                     "rawset", "select", "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall", "collectgarbage"}

# Calls that change synchronised state: never reachable from an Events.* handler in gameplay
# (Events.* fire per machine, GameEvents.* are synced). Names only, matched on any receiver.
ASYNC_FORBIDDEN = {
    "GetRandNum": "synced RNG", "Create": "unit creation", "Destroy": "unit removal", "ChangeGoldBalance": "gold change",
    "SetProperty": "property write", "InitUnit": "unit creation", "Kill": "unit removal", "TransferCity": "city transfer",
    "SetDamage": "unit change", "ChangeDamage": "unit change", "ChangeExperience": "unit change",
    "SetPromotion": "unit change", "ChangeResourceAmount": "resource change", "FinishMoves": "unit change",
    "SetVeteranName": "unit change", "SetMilitaryFormation": "unit change", "SendNotification": "notification",
    "SetTeam": "team change", "BroadcastPlayerInfo": "player info broadcast", "DeclareWarOn": "war declaration",
}

# Identifiers that must never appear (name -> why). More can be added in api_allowlist.json "forbidden".
FORBIDDEN_NAMES = {
    "ExposedMembers": "the UI never shares state through ExposedMembers; requests go through EXECUTE_SCRIPT",
    "TerrainBuilder": "map-script only",
}


# ===========================================================================
# Allowlist
# ===========================================================================
def _norm_ctx(v):
    if isinstance(v, str):
        return {"level": v, "tests": []}
    out = dict(v)
    out.setdefault("level", "C")
    out.setdefault("tests", [])
    return out


def load_allowlist(path=None, regen=False, quiet=False):
    """Reads the hand-kept allowlist. regen is accepted for old command lines and does nothing."""
    path = path or ALLOWLIST_PATH
    if regen and not quiet:
        print("api_audit: --regen does nothing in TX: tools/api_allowlist.json is kept by hand")
    raw = L.load_json(path, None)
    if raw is None:
        raise SystemExit("api_audit: allowlist not found: %s" % path)
    al = {s: {} for s in SECTIONS}
    for sect in SECTIONS:
        for key, e in raw.get(sect, {}).items():
            if key.startswith("_"):
                continue
            ent = {k: v for k, v in e.items() if k != "ctx"}
            ent["ctx"] = {c: _norm_ctx(v) for c, v in e.get("ctx", {}).items()}
            ent.setdefault("refs", [])
            al[sect][key] = ent
    al["_forbidden_extra"] = raw.get("forbidden", [])
    return al


def lookup(table, key):
    if key in table:
        return table[key]
    for k, v in table.items():
        if "*" in k and fnmatch.fnmatchcase(key, k):
            return v
    return None


# ===========================================================================
# Audit
# ===========================================================================
class Auditor:
    def __init__(self, root, al, rep, db=None):
        self.root = os.path.abspath(root)
        self.al = al
        self.rep = rep
        self.proj = L.LuaProject(self.root)
        self.checklist = {}   # (kind, key, ctx, desc, tests) -> [locations]
        self.probes = []      # (file, line, [string args])
        self.db_tables = self._db_tables(L.GAMEPLAY_DB if db is None else db)
        self.parsed = {}
        for f in self.proj.files:
            try:
                toks, comments = L.lex(self.proj.src[f])
            except L.LexError as e:
                rep.error(f, e.line, "lex", "cannot tokenize (%s); run check_lua.py" % e.msg)
                continue
            funcs = L.scan_functions(toks)
            self.parsed[f] = {
                "toks": toks, "comments": comments, "funcs": funcs,
                "chains": L.scan_chains(toks), "methods": L.scan_method_calls(toks),
                "locals": L.local_names(toks),
                "top": L.top_level_global_assignments(toks, funcs),
                "probe": self._probe_ranges(f, toks),
            }
        # every real engine global (harvested) is audited, so non-allowlisted ones are reported
        self.engine_roots = set(al["globals"]) | set(L.BASE_ENGINE_GLOBALS) | L.harvested_engine_globals()
        self.project_methods = set()
        self.module_members = {}
        self._index_project()

    def _db_tables(self, db):
        if not db or not os.path.exists(db):
            return None
        try:
            con = sqlite3.connect("file:%s?mode=ro" % db.replace("\\", "/"), uri=True)
            names = {r[0] for r in con.execute("select name from sqlite_master where type in ('table','view')")}
            con.close()
            return names
        except sqlite3.Error:
            return None

    def _probe_ranges(self, f, toks):
        """Token ranges (open paren, close paren) of the argument lists of probe calls."""
        out = []
        n = len(toks)
        for i, t in enumerate(toks):
            if t.kind != "name" or t.val not in PROBE_FUNCS:
                continue
            if i > 0 and toks[i - 1].kind == "kw" and toks[i - 1].val == "function":
                continue   # the definition: function TX_Probe(...)
            if i > 1 and toks[i - 1].val in (".", ":") and toks[i - 2].kind == "kw" and toks[i - 2].val == "function":
                continue
            if i + 1 < n and toks[i + 1].kind == "op" and toks[i + 1].val == "(":
                end = L.skip_balanced(toks, i + 1)
                out.append((i + 1, end - 1))
                args = toks[i + 2:end - 1]
                strs = [x.val for x in args if x.kind == "str"]
                text = "".join(('"%s"' % x.val if x.kind == "str" else x.val) + (" " if x.val == "," else "") for x in args)
                self.probes.append((f, t.line, strs))
                self.rep.info(f, t.line, "probe", "%s(%s): spike probe, arguments not audited" % (t.val, text))
        return out

    @staticmethod
    def _in_probe(p, idx):
        return any(a < idx < b for a, b in p["probe"])

    def _index_project(self):
        for f, p in self.parsed.items():
            toks = p["toks"]
            for fd in p["funcs"]:
                if fd.name and ":" in fd.name:
                    self.project_methods.add(fd.name.split(":")[-1])
                if fd.name and "." in fd.name.replace(":", "."):
                    root, member = re.split(r"[.:]", fd.name, 1)
                    self.module_members.setdefault(root, set()).add(member.split(".")[0].split(":")[0])
            for ch in p["chains"]:
                # X.Y = ... assignments anywhere
                if len(ch.parts) >= 2 and ch.parts[1].startswith("."):
                    end = ch.idx + 1 + 2 * (len(ch.parts) - 1)
                    if end < len(toks) and toks[end].kind == "op" and toks[end].val == "=" and len(ch.parts) == 2:
                        self.module_members.setdefault(ch.head, set()).add(ch.parts[1][1:])
            # X = { key = ..., key2 = ... } at any level (top-level keys only)
            for i in range(len(toks) - 2):
                if toks[i].kind == "name" and toks[i + 1].kind == "op" and toks[i + 1].val == "=" and \
                        toks[i + 2].kind == "op" and toks[i + 2].val == "{" and \
                        not (i > 0 and toks[i - 1].kind == "op" and toks[i - 1].val in (".", ":")):
                    end = L.skip_balanced(toks, i + 2)
                    depth = 0
                    keys = set()
                    for j in range(i + 3, end - 1):
                        t = toks[j]
                        if t.kind == "op" and t.val in "({[":
                            depth += 1
                        elif t.kind == "op" and t.val in ")}]":
                            depth -= 1
                        elif depth == 0 and t.kind == "name" and j + 1 < end and toks[j + 1].kind == "op" and toks[j + 1].val == "=":
                            keys.add(t.val)
                    self.module_members.setdefault(toks[i].val, set()).update(keys)
            # methods assigned as X.Name = function(self
            for i in range(len(toks) - 4):
                if toks[i].kind == "op" and toks[i].val == "." and toks[i + 1].kind == "name" and \
                        toks[i + 2].val == "=" and toks[i + 3].val == "function" and toks[i + 4].val == "(" and \
                        i + 5 < len(toks) and toks[i + 5].val == "self":
                    self.project_methods.add(toks[i + 1].val)
        self.project_globals = set()
        for p in self.parsed.values():
            self.project_globals |= set(p["top"])

    # ------------------------------------------------------------------
    def _ctx_ok(self, entry, ctx, key, f, line, kind):
        if entry.get("only_paths") and not any(s.lower() in f.replace("\\", "/").lower() for s in entry["only_paths"]):
            self.rep.error(f, line, "api-scope", "%s '%s' is allowed only in %s" % (kind, key, ", ".join(entry["only_paths"])))
            return
        c = entry["ctx"].get(ctx)
        if c is None:
            allowed = "/".join(sorted(entry["ctx"])) or "none"
            self.rep.error(f, line, "api-context", "%s '%s' used in %s context; allowlist permits: %s (refs %s)" % (
                kind, key, ctx, allowed, ",".join(entry.get("refs", [])) or "-"))
            return
        # a context added to an existing entry may carry its own only_paths (e.g. a TX_Dev-only G context)
        if c.get("only_paths") and not any(s.lower() in f.replace("\\", "/").lower() for s in c["only_paths"]):
            self.rep.error(f, line, "api-scope", "%s '%s' in %s is allowed only in %s" % (kind, key, ctx, ", ".join(c["only_paths"])))
            return
        lvl, tests = c["level"], c.get("tests", [])
        if lvl != "C":
            desc = LEVEL_DESC.get(lvl, lvl)
            refs = c.get("refs") or entry.get("refs", [])
            self.rep.warn(f, line, "api-unverified", "%s '%s' in %s is %s, not verified in game%s (refs %s)" % (
                kind, key, ctx, desc, (" [" + ",".join(tests) + "]") if tests else "", ",".join(refs) or "-"))
            self.checklist.setdefault((kind, key, ctx, desc, tuple(tests)), []).append((f, line))

    def audit(self):
        for f in self.proj.files:
            if f in self.parsed:
                self.audit_file(f)
        self.cross_checks()

    def audit_file(self, f):
        p = self.parsed[f]
        toks = p["toks"]
        fctx = self.proj.ctx[f]
        regions, problems = L.region_map(p["comments"])
        for ln, msg in problems:
            self.rep.error(f, ln, "region-marker", msg)
        for a, b, c in regions:
            if c not in fctx:
                self.rep.error(f, a, "region-marker", "TX:%s-ONLY region in a file that only runs in %s" % (c, "/".join(sorted(fctx))))
        is_g_file = "G" in fctx
        locals_ = p["locals"]

        def ctxs_at(line):
            return sorted(L.line_context(fctx, regions, line))

        funcs = p["funcs"]

        def enclosing(idx):
            return [fd for fd in funcs if fd.start <= idx <= fd.end]

        # ---- forbidden tokens anywhere
        forbidden_names = dict(FORBIDDEN_NAMES)
        for extra in self.al.get("_forbidden_extra", []):
            forbidden_names[extra["name"]] = extra.get("why", "api_allowlist.json forbidden")
        for i, t in enumerate(toks):
            if t.kind == "name" and t.val in forbidden_names:
                self.rep.error(f, t.line, "forbidden", "'%s' is forbidden: %s" % (t.val, forbidden_names[t.val]))
            if t.kind == "op" and t.val == ":" and i + 1 < len(toks) and toks[i + 1].val == "Kill":
                self.rep.error(f, t.line, "forbidden", "':Kill(' is forbidden (use UnitManager.Kill(unit))")

        # ---- chains starting at global names
        for ch in p["chains"]:
            head, parts, line = ch.head, ch.parts, ch.line
            if self._in_probe(p, ch.idx) or head in PROBE_FUNCS:
                continue
            # skip definitions: function X.Y(  and table keys { X = }
            if ch.idx > 0 and toks[ch.idx - 1].kind == "kw" and toks[ch.idx - 1].val == "function":
                continue
            nxt = ch.idx + 1
            if len(parts) == 1 and nxt < len(toks) and toks[nxt].kind == "op" and toks[nxt].val == "=" and \
                    ch.idx > 0 and toks[ch.idx - 1].kind == "op" and toks[ch.idx - 1].val in ("{", ","):
                continue
            if head in locals_ and head not in ("UI",):
                continue
            for ctx in ctxs_at(line):
                self.check_chain(f, ch, ctx, enclosing)

        # ---- method calls
        for name, line, idx in p["methods"]:
            if self._in_probe(p, idx) or name in PROBE_FUNCS:
                continue
            recv = self._receiver_head(toks, idx)
            for ctx in ctxs_at(line):
                self.check_method(f, name, line, ctx, recv, locals_)

        # ---- registration inside functions (G)
        if is_g_file:
            for ch in p["chains"]:
                if ch.head in ("GameEvents", "Events") and len(ch.parts) >= 4 and ch.parts[2] == ".Add":
                    if "G" in ctxs_at(ch.line) and any(fd.depth >= 0 for fd in enclosing(ch.idx)):
                        self.rep.warn(f, ch.line, "conditional-registration",
                                      "%s%s.Add inside a function: register gameplay handlers when the file loads" % (ch.head, ch.parts[1]))

        # ---- Events.* handlers in gameplay must not change state
        if is_g_file:
            self.check_async_handlers(f)

    def _receiver_head(self, toks, idx):
        # idx = index of method name; toks[idx-1] == ':'
        j = idx - 2
        if j >= 0 and toks[j].kind == "name":
            text, _ = L._name_chain_back(toks, j)
            return text
        return None

    def check_chain(self, f, ch, ctx, enclosing):
        head, parts, line = ch.head, ch.parts, ch.line
        # Lua builtins
        if head in LUA_STD and len(parts) >= 2 and parts[1].startswith("."):
            member = parts[1][1:]
            key = head + "." + member
            if head == "math" and member in ("random", "randomseed"):
                self.rep.error(f, line, "forbidden", "%s is forbidden (not synced in multiplayer; use Game.GetRandNum in gameplay)" % key)
            elif head == "os":
                if ctx == "G":
                    self.rep.error(f, line, "forbidden", "%s in gameplay is not deterministic in multiplayer" % key)
                else:
                    self.rep.warn(f, line, "os-call", "%s in UI: not deterministic, avoid" % key)
            elif member not in LUA_STD[head]:
                if head == "table" and member in ("unpack", "pack"):
                    self.rep.error(f, line, "lua52", "%s is Lua 5.2+; use unpack()" % key)
                else:
                    self.rep.error(f, line, "unknown-std", "%s is not a Lua 5.1 standard function" % key)
            return
        if head in ("io", "debug", "require", "dofile", "loadfile", "package", "bit32", "utf8"):
            self.rep.error(f, line, "forbidden", "'%s' is not available / not allowed in Civ VI mods" % head)
            return
        if head == "pairs" and len(parts) >= 2 and parts[1] == "()":
            fds = enclosing(ch.idx)
            in_sorted = any(fd.name and fd.name.endswith("SortedKeys") for fd in fds)
            if ctx == "G" and not in_sorted:
                self.rep.error(f, line, "forbidden-pairs",
                               "pairs() in gameplay outside a *SortedKeys helper (iteration order differs between machines)")
            elif ctx == "UI":
                toks = self.parsed[f]["toks"]
                end = L.skip_balanced(toks, ch.idx + 1) if ch.idx + 1 < len(toks) else ch.idx
                arg = " ".join(t.val for t in toks[ch.idx + 2:end - 1])
                if re.search(r"rec|store|%s_" % PREFIX, arg, re.I):
                    self.rep.warn(f, line, "pairs-records", "pairs() over '%s' in UI: display order is not deterministic; iterate sorted ids" % arg)
            return
        if head in LUA_BUILTIN_FUNCS or head in L.LUA51_GLOBALS and head not in self.engine_roots:
            return
        if head in self.engine_roots:
            self.check_engine_chain(f, ch, ctx)
            return
        if head in self.project_globals or head in self.module_members:
            members = self.module_members.get(head, set())
            if len(parts) >= 2 and parts[1].startswith(".") and members:
                m = parts[1][1:]
                if m not in members:
                    is_call = len(parts) >= 3 and parts[2] == "()"
                    toks = self.parsed[f]["toks"]
                    end = ch.idx + 3
                    assigned = end < len(toks) and toks[end].kind == "op" and toks[end].val == "=" and len(parts) == 2
                    if not assigned:
                        (self.rep.error if is_call else self.rep.warn)(
                            f, line, "unknown-member", "%s '%s.%s' is not defined anywhere in the project (typo?)" % (
                                "function" if is_call else "field", head, m))

    def check_engine_chain(self, f, ch, ctx):
        head, parts, line = ch.head, ch.parts, ch.line
        al = self.al
        g = al["globals"].get(head)
        if head == "UI" and len(parts) == 1:
            return  # `UI == nil` context test
        if head == "Controls":
            if ctx != "UI":
                self.rep.error(f, line, "api-context", "Controls used in %s context" % ctx)
            return
        if head == "Game" and len(parts) >= 2 and parts[1] == ".GetLocalPlayer" and ctx == "G":
            self.rep.error(f, line, "forbidden", "Game.GetLocalPlayer in gameplay: every machine gets a different answer "
                           "(gameplay gets the player from the request or the event)")
            return
        if head in EVENT_ROOTS:
            if len(parts) < 2 or not parts[1].startswith("."):
                return
            key = head + parts[1]
            e = lookup(al["events"], key)
            if e is None:
                self.rep.error(f, line, "unknown-event", "event '%s' is not in the allowlist (misspelt events fail silently)" % key)
                return
            self._ctx_ok(e, ctx, key, f, line, "event")
            # Member after the event name: .Add / .Remove or a direct call (LuaEvents.X(...), GameEvents.X(...)).
            if len(parts) >= 3 and parts[2].startswith(".") and parts[2] not in (".Add", ".Remove"):
                self.rep.error(f, line, "unknown-event-member", "'%s%s' is not an event member (use .Add / .Remove)" % (key, parts[2]))
            return
        if head == "GameInfo":
            if len(parts) < 2 or not parts[1].startswith("."):
                if g:
                    self._ctx_ok(g, ctx, head, f, line, "global")
                return
            tbl = parts[1][1:]
            e = lookup(al["gameinfo"], tbl)
            if e is not None:
                self._ctx_ok(e, ctx, "GameInfo." + tbl, f, line, "GameInfo table")
            elif self.db_tables is not None and tbl not in self.db_tables:
                self.rep.error(f, line, "gameinfo-unknown", "GameInfo.%s: no such table in DebugGameplay.sqlite" % tbl)
            else:
                self.rep.warn(f, line, "gameinfo-unlisted", "GameInfo.%s is not on the allowlist; add it to api_allowlist.json gameinfo if intended" % tbl)
            return
        if len(parts) == 1 or parts[1] == "[]":
            if g is None:
                self.rep.error(f, line, "unknown-global", "'%s' is not an allowlisted engine global" % head)
            else:
                self._ctx_ok(g, ctx, head, f, line, "global")
            return
        if parts[1] == "()":
            e = lookup(al["static"], head)
            if e is None:
                e = g
            if e is None:
                self.rep.error(f, line, "unknown-api", "global function '%s' is not in the allowlist" % head)
            else:
                self._ctx_ok(e, ctx, head, f, line, "function")
            return
        key = head + parts[1]
        e = lookup(al["static"], key)
        if e is None:
            kind = "method" if parts[1].startswith(":") else ("call" if len(parts) > 2 and parts[2] == "()" else "member")
            self.rep.error(f, line, "unknown-api", "%s '%s' is not in api_allowlist.json" % (kind, key))
            return
        self._ctx_ok(e, ctx, key, f, line, "call" if len(parts) > 2 and parts[2] == "()" else "member")

    def check_method(self, f, name, line, ctx, recv, locals_):
        al = self.al
        recv_root = recv.split(".")[0].split(":")[0] if recv else None
        if recv_root in self.engine_roots and recv and "." not in recv and ":" not in recv and recv_root not in locals_:
            # Root:Method -> handled as static key by check_engine_chain
            return
        e = lookup(al["methods"], name)
        if e is not None:
            self._ctx_ok(e, ctx, ":" + name, f, line, "method")
            return
        if name in self.project_methods or name in STRING_METHODS:
            return
        self.rep.error(f, line, "unknown-method", "method ':%s' (receiver %s) is not in api_allowlist.json" % (name, recv or "?"))

    # ------------------------------------------------------------------
    def _function_index(self, comp):
        idx = {}
        for f in comp:
            p = self.parsed.get(f)
            if not p:
                continue
            for fd in p["funcs"]:
                if fd.name:
                    key = fd.name.replace(":", ".")
                    if fd.is_local:
                        idx.setdefault(("local", f, key), (f, fd))
                    else:
                        idx.setdefault(("global", key), (f, fd))
        return idx

    def check_async_handlers(self, f):
        p = self.parsed[f]
        toks = p["toks"]
        comp = self.proj.component(f)
        fidx = self._function_index(comp)
        for ch in p["chains"]:
            if ch.head != "Events" or len(ch.parts) < 4 or ch.parts[2] != ".Add":
                continue
            if "G" not in L.line_context(self.proj.ctx[f], L.region_map(p["comments"])[0], ch.line):
                continue
            evname = "Events" + ch.parts[1]
            a = ch.first_arg
            if a is None or a >= len(toks):
                continue
            target = None
            if toks[a].kind == "kw" and toks[a].val == "function":
                fd = next((fd for fd in p["funcs"] if fd.start == a), None)
                if fd:
                    target = (f, fd, "<inline handler>")
            elif toks[a].kind == "name":
                j = a
                parts = [toks[a].val]
                while j + 2 < len(toks) and toks[j + 1].val in (".", ":") and toks[j + 2].kind == "name":
                    parts.append(toks[j + 2].val)
                    j += 2
                name = ".".join(parts)
                hit = fidx.get(("local", f, name)) or fidx.get(("global", name))
                if hit:
                    target = (hit[0], hit[1], name)
                else:
                    self.rep.warn(f, ch.line, "async-handler-unresolved", "%s handler '%s' not found; cannot check it for state changes" % (evname, name))
            if target:
                self._walk_handler(evname, target, fidx)

    def _walk_handler(self, evname, target, fidx):
        root_name = target[2]
        seen = set()
        stack = [(target[0], target[1], [root_name])]
        while stack:
            f, fd, path = stack.pop()
            key = (f, fd.start)
            if key in seen or len(path) > 10:
                continue
            seen.add(key)
            p = self.parsed[f]
            for name, line, idx in p["methods"]:
                if fd.start <= idx <= fd.end and name in ASYNC_FORBIDDEN and not self._in_probe(p, idx):
                    self._async_hit(evname, name, f, line, path)
            for ch in p["chains"]:
                if not (fd.start < ch.idx <= fd.end) or self._in_probe(p, ch.idx):
                    continue
                # static calls: Game.GetRandNum, UnitManager.InitUnit, Network.BroadcastPlayerInfo, ...
                for part in ch.parts[1:]:
                    nm = part[1:] if part[:1] in ".:" else None
                    if nm in ASYNC_FORBIDDEN and part.startswith("."):
                        self._async_hit(evname, nm, f, ch.line, path)
                # follow calls to project functions
                if len(ch.parts) >= 2:
                    names = []
                    cur = ch.head
                    for part in ch.parts[1:]:
                        if part == "()":
                            names.append(cur)
                            break
                        if part.startswith("."):
                            cur += part
                        else:
                            break
                    for nm in names:
                        hit = fidx.get(("local", f, nm)) or fidx.get(("global", nm))
                        if hit:
                            stack.append((hit[0], hit[1], path + [nm]))

    def _async_hit(self, evname, call, f, line, path):
        via = " -> ".join(path)
        self.rep.error(f, line, "async-mutation", "%s (%s) reached from gameplay %s handler via %s: Events.* are not synced, "
                       "state changes belong in GameEvents handlers" % (call, ASYNC_FORBIDDEN[call], evname, via))

    # ------------------------------------------------------------------
    def cross_checks(self):
        sent = {}      # name -> (file, line)
        handled = {}
        name_re = re.compile(r"%s_\w+" % PREFIX)
        # string constants such as TX_Config.REQ_VOTE = "TX_Vote" / { REQ_VOTE = "TX_Vote" }
        consts = {}
        for f, p in self.parsed.items():
            toks = p["toks"]
            for i in range(len(toks) - 2):
                if toks[i].kind == "name" and toks[i + 1].val == "=" and toks[i + 2].kind == "str" and \
                        name_re.fullmatch(toks[i + 2].val):
                    consts.setdefault(toks[i].val, toks[i + 2].val)
        for f, p in self.parsed.items():
            toks = p["toks"]
            fctx = self.proj.ctx[f]
            for i, t in enumerate(toks):
                if t.kind == "name" and t.val == "OnStart" and i + 2 < len(toks) and toks[i + 1].val == "=":
                    a = toks[i + 2]
                    val = a.val if a.kind == "str" else None
                    if a.kind == "name":
                        j = i + 2
                        while j + 2 < len(toks) and toks[j + 1].val == "." and toks[j + 2].kind == "name":
                            j += 2
                        val = consts.get(toks[j].val)
                    if val and "UI" in fctx:
                        sent.setdefault(val, (f, t.line))
                # helpers named ...Request("TX_Name", ...) in UI
                if t.kind == "name" and re.search(r"Request$", t.val) and t.val != "RequestPlayerOperation" and \
                        i + 2 < len(toks) and toks[i + 1].val == "(" and "UI" in fctx:
                    a = toks[i + 2]
                    val = None
                    if a.kind == "str" and name_re.fullmatch(a.val):
                        val = a.val
                    elif a.kind == "name":
                        j = i + 2
                        while j + 2 < len(toks) and toks[j + 1].val == "." and toks[j + 2].kind == "name":
                            j += 2
                        val = consts.get(toks[j].val)
                    if val:
                        sent.setdefault(val, (f, t.line))
            for ch in p["chains"]:
                if ch.head == "GameEvents" and len(ch.parts) >= 3 and ch.parts[2] == ".Add" and "G" in fctx:
                    handled.setdefault(ch.parts[1][1:], (f, ch.line))
        for name, (f, line) in sorted(sent.items()):
            if name not in handled:
                self.rep.error(f, line, "onstart-unhandled", "UI sends OnStart='%s' but no gameplay file registers GameEvents.%s.Add" % (name, name))
        for name, (f, line) in sorted(handled.items()):
            if name.startswith(PREFIX + "_") and name not in sent:
                self.rep.warn(f, line, "handler-unused", "GameEvents.%s has a handler but no UI file sends OnStart='%s'" % (name, name))

    def print_checklist(self, stream=None):
        stream = stream or sys.stdout
        if not self.checklist:
            return
        stream.write("\nIn-game verification checklist (calls used before they were verified in game):\n")
        rows = {}
        for (kind, key, ctx, desc, tests), locs in self.checklist.items():
            r = rows.setdefault((key, ctx), {"desc": desc, "tests": set(tests), "uses": 0, "files": set()})
            r["uses"] += len(locs)
            r["files"] |= {os.path.basename(x[0]) for x in locs}
        for (key, ctx), r in sorted(rows.items()):
            tests = (" [" + ",".join(sorted(r["tests"])) + "]") if r["tests"] else ""
            stream.write("  [ ] %s (%s, %s%s): %d use(s) in %s\n" % (
                key, ctx, r["desc"], tests, r["uses"], ", ".join(sorted(r["files"]))))


def audit(root, rep=None, regen=False, allowlist=None, db=None):
    rep = rep or L.Report("api_audit", base=L.PROJECT_DIR)
    al = load_allowlist(path=allowlist, regen=regen, quiet=True)
    a = Auditor(root, al, rep, db=db)
    a.audit()
    return rep, a


def main(argv=None):
    L.configure_stdout()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", nargs="?")
    ap.add_argument("--regen", action="store_true", help="does nothing: the TX allowlist is kept by hand")
    ap.add_argument("--allowlist", default=None, help="another allowlist file (default tools/api_allowlist.json)")
    ap.add_argument("--db", default=None, help="gameplay DB for the GameInfo table check (default: the game's cache)")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--info", action="store_true")
    ap.add_argument("--no-checklist", action="store_true")
    a = ap.parse_args(argv)
    if a.regen:
        print("api_audit: --regen does nothing in TX: tools/api_allowlist.json is kept by hand")
        if a.root is None:
            return 0
    if a.root is None:
        a.root = os.path.join(L.PROJECT_DIR, "TX")
    if not os.path.exists(a.root):
        print("api_audit: root not found: %s" % a.root)
        return 2
    rep, auditor = audit(a.root, allowlist=a.allowlist, db=a.db)
    rep.print(show_info=a.info)
    if not a.no_checklist:
        auditor.print_checklist()
    return rep.exit_code(a.strict)


if __name__ == "__main__":
    sys.exit(main())
