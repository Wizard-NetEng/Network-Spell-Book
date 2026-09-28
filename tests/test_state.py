#!/usr/bin/env python3
"""Adversarial test suite for bin/spellbook-state.

Run: python3 tests/test_state.py

These cover the symlink / TOCTOU / unbounded-read class of bugs on the plugin's
UI state file and directory. Each hostile case asserts BOTH that the attack was
refused AND that the decoy target was left untouched.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATE = ROOT / "bin" / "spellbook-state"

results: list[tuple[bool, str, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append((ok, name, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  -- {detail}" if detail else ""))


def run(mode: str, home: Path, payload: str | None = None, timeout=30):
    env = dict(os.environ)
    env["HOME"] = str(home)
    return subprocess.run(
        [str(STATE), mode], env=env, capture_output=True, text=True,
        input=payload, timeout=timeout,
    )


def parse(proc):
    try:
        return json.loads(proc.stdout)
    except Exception:
        return None


def fresh_home():
    td = tempfile.mkdtemp()
    return Path(td)


def sdir(home: Path) -> Path:
    return home / ".config" / "omarchy" / "spellbook"


# --------------------------------------------------------------------------
# Happy path.
# --------------------------------------------------------------------------
home = fresh_home()
p = run("read", home)
d = parse(p)
check("read: absent state reports present=false, not an error",
      p.returncode == 0 and d and d["ok"] and d["present"] is False, p.stdout[:120])

p = run("write", home, json.dumps({"collapsed": ["DNS", "Firewall"]}))
d = parse(p)
check("write: succeeds", p.returncode == 0 and d and d["ok"], p.stderr[-160:])
check("write: state file created", (sdir(home) / "ui-state.json").exists())

p = run("read", home)
d = parse(p)
check("read: round-trips the written names",
      d and d["collapsed"] == ["DNS", "Firewall"], str(d))

st = (sdir(home) / "ui-state.json").stat()
check("write: file is 0600", not (st.st_mode & 0o177), oct(st.st_mode))
check("write: directory is 0700", not (sdir(home).stat().st_mode & 0o077),
      oct(sdir(home).stat().st_mode))
check("write: no temp files left behind",
      not [f for f in sdir(home).iterdir() if f.name.endswith(".tmp")])
shutil.rmtree(home)

# --------------------------------------------------------------------------
# The reviewer's finding #1: symlinked STATE FILE must not redirect the write.
# --------------------------------------------------------------------------
home = fresh_home()
sdir(home).mkdir(parents=True, mode=0o700)
victim = home / "victim.txt"
victim.write_text("ORIGINAL CONTENT\n")
(sdir(home) / "ui-state.json").symlink_to(victim)

p = run("read", home)
d = parse(p)
check("symlink file: read refuses to follow the link",
      p.returncode == 1 and d and "symlink" in d["error"].lower(),
      (d or {}).get("error", "")[:100])
check("symlink file: read left the victim untouched",
      victim.read_text() == "ORIGINAL CONTENT\n")

# The write path replaces the symlink with a real file via atomic rename,
# which is safe: rename() acts on the link itself, never on its target.
p = run("write", home, json.dumps({"collapsed": ["X"]}))
check("symlink file: write did not follow the link into the victim",
      victim.read_text() == "ORIGINAL CONTENT\n",
      f"victim now: {victim.read_text()[:60]!r}")
check("symlink file: state path is a regular file afterwards, not a link",
      (sdir(home) / "ui-state.json").is_file()
      and not (sdir(home) / "ui-state.json").is_symlink())
shutil.rmtree(home)

# --------------------------------------------------------------------------
# The reviewer's finding #2: symlinked STATE DIRECTORY must not be chmod'd.
# --------------------------------------------------------------------------
home = fresh_home()
(home / ".config" / "omarchy").mkdir(parents=True)
victim_dir = home / "unrelated"
victim_dir.mkdir(mode=0o755)
(victim_dir / "keep.txt").write_text("data\n")
sdir(home).symlink_to(victim_dir)

before = stat.S_IMODE(victim_dir.stat().st_mode)
p = run("write", home, json.dumps({"collapsed": ["X"]}))
after = stat.S_IMODE(victim_dir.stat().st_mode)
d = parse(p)
check("symlink dir: write refused", p.returncode == 1, p.stdout[:120])
check("symlink dir: error names the symlink",
      d and "symlink" in d["error"].lower(), (d or {}).get("error", "")[:100])
check("symlink dir: unrelated directory permissions UNCHANGED",
      before == after, f"{oct(before)} -> {oct(after)}")
check("symlink dir: unrelated directory contents untouched",
      (victim_dir / "keep.txt").read_text() == "data\n")
check("symlink dir: no state file written into the victim",
      not (victim_dir / "ui-state.json").exists())

p = run("read", home)
check("symlink dir: read also refused", p.returncode == 1, p.stdout[:120])
shutil.rmtree(home)

# --------------------------------------------------------------------------
# Unbounded / special-file reads.
# --------------------------------------------------------------------------
home = fresh_home()
sdir(home).mkdir(parents=True, mode=0o700)
(sdir(home) / "ui-state.json").write_text('{"collapsed":[' + ',' .join(
    f'"{i}"' for i in range(100)) + ']}')
p = run("read", home)
d = parse(p)
check("read: normal multi-entry file still parses",
      p.returncode == 0 and d and len(d["collapsed"]) == 100, str(d)[:80])

(sdir(home) / "ui-state.json").write_text('{"collapsed":["' + "A" * (300 * 1024) + '"]}')
p = run("read", home)
d = parse(p)
check("read: oversized state file rejected by byte cap",
      p.returncode == 1 and d and "exceeds" in d["error"], (d or {}).get("error", "")[:90])

(sdir(home) / "ui-state.json").unlink()
os.mkfifo(sdir(home) / "ui-state.json")
pid = os.fork()
if pid == 0:
    try:
        with open(sdir(home) / "ui-state.json", "w") as fh:
            while True:
                fh.write("A" * 65536)
    except Exception:
        pass
    os._exit(0)
try:
    p = run("read", home, timeout=20)
    d = parse(p)
    check("read: FIFO refused as a non-regular file",
          p.returncode == 1 and d and "regular file" in d["error"],
          (d or {}).get("error", "")[:90])
except subprocess.TimeoutExpired:
    check("read: FIFO refused as a non-regular file", False, "HUNG — unbounded")
finally:
    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except Exception:
        pass
shutil.rmtree(home)

# --------------------------------------------------------------------------
# Pre-existing loose directory permissions get tightened.
# --------------------------------------------------------------------------
home = fresh_home()
sdir(home).mkdir(parents=True, mode=0o755)
run("write", home, json.dumps({"collapsed": ["A"]}))
check("write: pre-existing 0755 state dir tightened to 0700",
      not (sdir(home).stat().st_mode & 0o077), oct(sdir(home).stat().st_mode))
shutil.rmtree(home)

# --------------------------------------------------------------------------
# Malformed and hostile payloads must not crash or write garbage.
# --------------------------------------------------------------------------
for label, payload in [
    ("not json", "{nope"),
    ("root is a list", "[]"),
    ("collapsed is a string", '{"collapsed":"nope"}'),
    ("collapsed has non-strings", '{"collapsed":[1,null,{},"ok"]}'),
    ("empty", ""),
    ("control chars", '{"collapsed":["a\\u0000b"]}'),
]:
    home = fresh_home()
    p = run("write", home, payload)
    ok = "Traceback" not in p.stderr and parse(p) is not None
    check(f"write malformed: {label} handled without traceback", ok,
          p.stderr.strip()[-90:])
    shutil.rmtree(home)

home = fresh_home()
run("write", home, json.dumps({"collapsed": ["ok", 5, None, {"x": 1}, "fine"]}))
d = parse(run("read", home))
check("write: non-string entries dropped, valid ones kept",
      d and d["collapsed"] == ["ok", "fine"], str(d))
shutil.rmtree(home)

home = fresh_home()
run("write", home, json.dumps({"collapsed": [f"n{i}" for i in range(9000)]}))
d = parse(run("read", home))
check("write: entry count capped", d and len(d["collapsed"]) <= 4096,
      str(len(d["collapsed"]) if d else None))
shutil.rmtree(home)

# --------------------------------------------------------------------------
# Corrupt state is recoverable, not fatal.
# --------------------------------------------------------------------------
home = fresh_home()
sdir(home).mkdir(parents=True, mode=0o700)
(sdir(home) / "ui-state.json").write_text("this is not json at all")
p = run("read", home)
d = parse(p)
check("read: corrupt state degrades to empty rather than failing",
      p.returncode == 0 and d and d["ok"] and d["collapsed"] == [], str(d)[:90])
shutil.rmtree(home)

# --------------------------------------------------------------------------
# Static posture.
# --------------------------------------------------------------------------
body = STATE.read_text()
banned = ["subprocess", "os.system", "shell=True", "eval(", "popen"]
hits = [b for b in banned if b in body.split("#")[0] or f"\n{b}" in body]
hits = []
for line_no, line in enumerate(body.splitlines(), 1):
    code = line.split("#")[0]
    for b in banned:
        if b in code:
            hits.append(f"{line_no}: {b}")
check("static: state helper has no execution primitive", not hits, str(hits))
check("static: state helper uses O_NOFOLLOW", "O_NOFOLLOW" in body)
check("static: state helper uses dir_fd-relative operations", "dir_fd=" in body)
check("static: state helper uses O_EXCL for the temp file", "O_EXCL" in body)

print()
failed = [r for r in results if not r[0]]
print(f"{len(results) - len(failed)}/{len(results)} passed")
if failed:
    print("FAILURES:")
    for _, name, detail in failed:
        print(f"  - {name}  {detail}")
sys.exit(1 if failed else 0)
