#!/usr/bin/env python3
"""Reject common credentials and model weights in tracked files or reachable history."""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


patterns = [
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    re.compile(rb"\b(?:ghp_|github_pat_|sk-proj-|sk-)[A-Za-z0-9_-]{24,}\b"),
    re.compile(rb"\bAKIA[A-Z0-9]{16}\b"),
    re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{24,}\b"),
]
model_suffixes = {".gguf", ".onnx", ".safetensors", ".nemo", ".mlmodel", ".mlmodelc", ".mlpackage"}
issues = set()


def inspect(path, data, source):
    if Path(path).suffix.lower() in model_suffixes or any(
        Path(part).suffix.lower() in model_suffixes for part in Path(path).parts
    ):
        issues.add((path, source, "model weights"))
    if any(pattern.search(data) for pattern in patterns):
        issues.add((path, source, "possible credential"))


for raw in git("ls-files", "-z").split(b"\0"):
    if raw:
        path = raw.decode("utf-8", "surrogateescape")
        file = ROOT / path
        if file.is_file():
            inspect(path, file.read_bytes(), "working tree")

objects = git("rev-list", "--objects", "--all").splitlines()
for row in objects:
    parts = row.split(b" ", 1)
    if len(parts) != 2:
        continue
    oid, raw_path = parts
    if git("cat-file", "-t", oid.decode()).strip() != b"blob":
        continue
    inspect(raw_path.decode("utf-8", "surrogateescape"), git("cat-file", "blob", oid.decode()), "history")

for path, source, kind in sorted(issues):
    print(f"{source}: {path}: {kind}", file=sys.stderr)
print(f"Scanned tracked files and {len(objects)} reachable Git objects; {len(issues)} findings.")
sys.exit(bool(issues))
