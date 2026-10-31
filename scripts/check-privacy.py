#!/usr/bin/env python3
"""Check staged source files or unpacked release files without printing secrets."""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PATTERNS = {
    "absolute home directory": rb"/(?:Users|home)/[A-Za-z0-9][A-Za-z0-9_.-]*/",
    "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
    "GitHub credential": rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})",
    "service API credential": rb"sk-(?:ant-|proj-)?[A-Za-z0-9_-]{32,}",
    "AWS access key": rb"(?:AKIA|ASIA)[A-Z0-9]{16}",
    "credential in URL": rb"https?://[^\s/:@]+:[^\s/@]+@",
}
PRIVATE_NAMES = {"backup", "backups", ".build", "node_modules", "__pycache__", "private", ".local"}
PRIVATE_FILES = {"HANDOVER.md", ".DS_Store", "settings.json", "ui-overview.png", "connections-audit.png"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=pathlib.Path,
                        help="Scan files/directories; default: staged Git files")
    args = parser.parse_args()
    errors = []
    if args.paths:
        files = sorted({file for path in args.paths
                        for file in (path.rglob("*") if path.is_dir() else [path])
                        if file.is_file() and not file.is_symlink()})
    else:
        names = subprocess.check_output(["git", "ls-files", "--cached", "-z"], cwd=ROOT).split(b"\0")
        files = [ROOT / name.decode() for name in names if name]
        for file in files:
            relative = file.relative_to(ROOT)
            if (set(relative.parts) & PRIVATE_NAMES or file.name in PRIVATE_FILES
                    or file.name.startswith(".env") or file.suffix in {".key", ".pem", ".p12", ".jsonl"}
                    or (relative.parts[0] == "docs" and file.name.startswith("audit-"))):
                errors.append((relative, "private local file is staged"))
    for file in files:
        data = file.read_bytes() if args.paths else subprocess.check_output(
            ["git", "show", f":{file.relative_to(ROOT)}"], cwd=ROOT)
        for label, pattern in PATTERNS.items():
            if re.search(pattern, data):
                errors.append((file.relative_to(ROOT) if file.is_relative_to(ROOT) else file, label))
    if errors:
        for file, label in errors:
            print(f"FAIL: {file}: {label}", file=sys.stderr)
        return 1
    print(f"Privacy check passed: {len(files)} files scanned.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
