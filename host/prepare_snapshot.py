#!/usr/bin/env python3
"""Host-only snapshot builder. Never execute this from inside an agent sandbox."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

MAX_FILE = 1024 * 1024
MAX_TOTAL = 32 * 1024 * 1024
MAX_HISTORY = 2 * 1024 * 1024
BLOCKED_PARTS = {".git", ".env", ".ssh", ".aws", ".gnupg", ".claude", "node_modules", ".next", "dist", "build", "coverage", ".venv", "vendor"}
BLOCKED_SUFFIXES = {".pem", ".key", ".p12", ".pfx", ".sqlite", ".db"}
BLOCKED_NAMES = {"id_rsa", "id_ed25519", ".npmrc", ".netrc", "credentials", "credentials.json", "secrets.json"}
SECRET_PATTERNS = [re.compile(x, re.I) for x in (
    r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
    r"AKIA[0-9A-Z]{16}",
    r"gh[pousr]_[A-Za-z0-9_]{20,}",
    r"sk-ant-[A-Za-z0-9_-]{16,}",
)]
def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout

def allowed(path):
    return not (set(path.parts) & BLOCKED_PARTS or path.name in BLOCKED_NAMES or path.suffix.lower() in BLOCKED_SUFFIXES or path.name.startswith(".env"))

def prepare(root, output, history_count):
    root = root.resolve(strict=True)
    output = output.absolute()
    if output.exists():
        raise ValueError("Destination must not exist")
    if output == root or root in output.parents:
        raise ValueError("Destination must be outside source repository")
    if not (root / ".git").exists():
        raise ValueError("Expected a Git repository")
    paths = git(root, "ls-files", "-z").split(b"\0")
    staged = []
    total = 0
    for raw in filter(None, paths):
        name = os.fsdecode(raw)
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts or not allowed(relative):
            continue
        source = root / relative
        if source.is_symlink() or not source.is_file():
            continue
        data = source.read_bytes()
        if len(data) > MAX_FILE or b"\0" in data:
            continue
        if any(pattern.search(data.decode("utf-8", "replace")) for pattern in SECRET_PATTERNS):
            raise ValueError(f"Potential secret in tracked file: {name}")
        total += len(data)
        if total > MAX_TOTAL:
            raise ValueError("Snapshot exceeds size budget")
        staged.append((relative, data))
    # Git log is intentionally metadata-only: full diffs can leak removed secrets.
    log = git(root, "log", f"-{history_count}", "--format=%H %aI %s", "--no-show-signature")
    if len(log) > MAX_HISTORY:
        raise ValueError("History exceeds size budget")
    with tempfile.TemporaryDirectory(prefix="roas-stage-", dir=str(output.parent)) as tmp:
        stage = Path(tmp)
        for relative, data in staged:
            target = stage / "source" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (stage / "history.txt").write_bytes(log)
        (stage / "REVIEW_SCOPE.txt").write_text(
            "Untrusted review input. History contains commit metadata only. "
            "No tests or project code were executed.\n"
        )
        # copytree rejects an existing destination and avoids symlinks.
        shutil.copytree(stage, output)
    return len(staged)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("repository", type=Path)
    p.add_argument("destination", type=Path)
    p.add_argument("--history-count", type=int, default=50)
    args = p.parse_args()
    if not 0 <= args.history_count <= 500:
        p.error("history-count must be between 0 and 500")
    print(f"Prepared {prepare(args.repository, args.destination, args.history_count)} tracked files at {args.destination}")
    print("WARNING: automatic secret filtering is incomplete. Manually inspect before using confidential input.")

if __name__ == "__main__":
    main()
