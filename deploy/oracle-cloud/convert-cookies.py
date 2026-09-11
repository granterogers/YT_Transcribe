#!/usr/bin/env python3
"""Convert a browser-extension JSON cookie export to the Netscape format yt-dlp needs.

Browser extensions (Cookie-Editor, EditThisCookie, Cookie Quick Manager) and
Playwright/Puppeteer all export JSON. yt-dlp's --cookies only accepts the
Netscape "cookies.txt" format, so a JSON export fails with a confusing parse
error rather than an obvious one.

    python3 convert-cookies.py vimeo.com_cookies.json ~/secrets/vimeo_cookies.txt

Cookie VALUES are never printed, logged, or returned -- only counts, names of
domains, and the output path. The output file is created with 0600 permissions.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def _expiry(cookie: dict) -> int:
    """Seconds since the epoch, or 0 for a session cookie."""
    for key in ("expirationDate", "expires", "expiry", "expiration_date"):
        value = cookie.get(key)
        # Playwright writes -1 for session cookies; extensions omit the key.
        if value is None or (isinstance(value, (int, float)) and value < 0):
            continue
        try:
            return int(float(value))
        except (TypeError, ValueError):
            continue
    return 0


def _bool(value, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"true", "yes", "1"}
    return default


def to_netscape(cookies: list[dict]) -> tuple[list[str], dict[str, int]]:
    lines: list[str] = []
    per_domain: dict[str, int] = {}
    for cookie in cookies:
        name = cookie.get("name")
        value = cookie.get("value")
        domain = cookie.get("domain") or ""
        if not name or value is None or not domain:
            continue
        # A leading dot means "and all subdomains". Extensions signal this with
        # hostOnly=false; Playwright encodes it in the domain string itself.
        host_only = _bool(cookie.get("hostOnly"), default=domain.startswith("."))
        if not domain.startswith(".") and not host_only:
            domain = "." + domain
        include_subdomains = "TRUE" if domain.startswith(".") else "FALSE"
        path = cookie.get("path") or "/"
        secure = "TRUE" if _bool(cookie.get("secure")) else "FALSE"
        lines.append("\t".join([domain, include_subdomains, path, secure,
                                str(_expiry(cookie)), str(name), str(value)]))
        per_domain[domain] = per_domain.get(domain, 0) + 1
    return lines, per_domain


def load(path: Path) -> list[dict]:
    raw = json.loads(path.read_text(encoding="utf-8-sig"))
    if isinstance(raw, dict):
        # Playwright/Puppeteer storageState nests the list under "cookies".
        for key in ("cookies", "Cookies"):
            if isinstance(raw.get(key), list):
                return raw[key]
        raise SystemExit(f"{path}: JSON object has no 'cookies' list.")
    if isinstance(raw, list):
        return raw
    raise SystemExit(f"{path}: expected a JSON array of cookies.")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print(f"usage: {argv[0]} <input.json> <output.txt>", file=sys.stderr)
        return 2
    source, target = Path(argv[1]).expanduser(), Path(argv[2]).expanduser()
    if not source.is_file():
        raise SystemExit(f"No such file: {source}")

    lines, per_domain = to_netscape(load(source))
    if not lines:
        raise SystemExit(f"{source}: no usable cookies found (each needs name, value and domain).")

    target.parent.mkdir(parents=True, exist_ok=True)
    # Create with 0600 from the outset rather than chmod-ing afterwards, so the
    # contents are never briefly world-readable.
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("# Netscape HTTP Cookie File\n")
        handle.write("# Converted from a JSON export. Do not commit or share.\n")
        for line in lines:
            handle.write(line + "\n")

    print(f"Wrote {len(lines)} cookie(s) to {target} (mode 0600)")
    for domain, count in sorted(per_domain.items()):
        print(f"  {domain}: {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
