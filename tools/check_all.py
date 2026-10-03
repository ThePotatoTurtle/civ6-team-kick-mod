#!/usr/bin/env python3
"""check_all.py - run every TX static check and exit non-zero on failure.

Usage:
    python tools/check_all.py [<root> ...] [--strict] [--info] [--basic] [--db PATH] [--no-checklist]

<root> defaults to TX/ and TX_Dev/; a default folder that does not exist yet is skipped with a note
(the spike phase only has TX_Dev/). A root given on the command line must exist. A root can be a mod
folder or a folder that contains mod folders. Runs, in order:
    1. check_lua.py      Lua 5.1 syntax + undefined/accidental globals (+ luacheck if installed)
    2. validate_data.py  XML / modinfo / SQL (against a copy of the game DB when it exists) / text keys
    3. api_audit.py      allowlist of engine calls, contexts, multiplayer rules
Exit code: 0 = no errors, 1 = errors (or warnings with --strict), 2 = bad arguments.
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import txlib as L  # noqa: E402
import check_lua  # noqa: E402
import validate_data  # noqa: E402
import api_audit  # noqa: E402


def run(roots, strict=False, info=False, basic=False, db=None, checklist=True, out=None, loc_db=None):
    out = out or sys.stdout
    total_err = total_warn = 0
    results = []
    for root in roots:
        out.write("=" * 78 + "\n%s\n" % os.path.abspath(root) + "=" * 78 + "\n")
        r1 = check_lua.check(root, basic=basic)
        out.write("--- check_lua (%s)\n" % ("basic scan" if basic or check_lua.lua_runtime() is None else "Lua 5.1 via lupa"))
        r1.print(show_info=info, stream=out)
        dbp = db or L.GAMEPLAY_DB
        out.write("--- validate_data (DB: %s%s)\n" % (dbp, "" if os.path.exists(dbp) else ", not found"))
        r2 = validate_data.validate(root, db=db or L.GAMEPLAY_DB, loc_db=loc_db or L.LOCALIZATION_DB)
        r2.print(show_info=info, stream=out)
        out.write("--- api_audit\n")
        r3, auditor = api_audit.audit(root, db=db)
        r3.print(show_info=info, stream=out)
        if checklist:
            auditor.print_checklist(stream=out)
        for r in (r1, r2, r3):
            total_err += r.count("ERROR")
            total_warn += r.count("WARN")
            results.append(r)
    status = "FAIL" if total_err or (strict and total_warn) else "PASS"
    out.write("\ncheck_all: %s - %d error(s), %d warning(s) in %d root(s)\n" % (status, total_err, total_warn, len(roots)))
    return (1 if status == "FAIL" else 0), results


def main(argv=None):
    L.configure_stdout()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("roots", nargs="*")
    ap.add_argument("--strict", action="store_true", help="warnings fail too")
    ap.add_argument("--info", action="store_true", help="print INFO lines")
    ap.add_argument("--basic", action="store_true", help="no Lua runtime: weak block-balance scan only")
    ap.add_argument("--db", default=None, help="gameplay DB to copy for SQL checks")
    ap.add_argument("--no-checklist", action="store_true")
    a = ap.parse_args(argv)
    roots = a.roots
    if not roots:
        roots = []
        for name in L.MOD_FOLDERS:
            p = os.path.join(L.PROJECT_DIR, name)
            if os.path.isdir(p):
                roots.append(p)
            else:
                print("check_all: note: %s/ does not exist yet, skipped" % name)
        if not roots:
            print("check_all: nothing to check (no %s folder yet)" % " or ".join(n + "/" for n in L.MOD_FOLDERS))
            return 0
    for r in roots:
        if not os.path.exists(r):
            print("check_all: root not found: %s" % r)
            return 2
    code, _ = run(roots, strict=a.strict, info=a.info, basic=a.basic, db=a.db, checklist=not a.no_checklist)
    return code


if __name__ == "__main__":
    sys.exit(main())
