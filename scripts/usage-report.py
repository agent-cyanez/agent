#!/usr/bin/env python3
"""Vela usage tracker — queries quota utilization (5-hour/7-day windows) and
aggregates token counts from Claude Code session transcripts."""

import json
import os
import glob
import sys
import time
import urllib.request
from datetime import datetime, timedelta

TRANSCRIPTS_DIR = os.path.expanduser("~/.claude/projects/-home-vela-agent")
CREDENTIALS_FILE = os.path.expanduser("~/.claude/.credentials.json")
CACHE_FILE = os.path.expanduser("~/agent/data/usage-cache.json")

def aggregate_transcripts(days=None):
    sessions = glob.glob(os.path.join(TRANSCRIPTS_DIR, "*.jsonl"))
    by_date = {}
    cutoff = None
    if days:
        cutoff = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")

    for sf in sessions:
        total_in = 0
        total_out = 0
        total_cache_create = 0
        total_cache_read = 0
        model = None
        turns = 0
        started = None

        try:
            with open(sf) as f:
                for line in f:
                    d = json.loads(line)
                    if d.get("type") == "assistant" and "message" in d:
                        msg = d["message"]
                        if isinstance(msg, dict):
                            if not model:
                                model = msg.get("model")
                            if "usage" in msg:
                                u = msg["usage"]
                                total_in += u.get("input_tokens", 0)
                                total_out += u.get("output_tokens", 0)
                                total_cache_create += u.get("cache_creation_input_tokens", 0)
                                total_cache_read += u.get("cache_read_input_tokens", 0)
                                turns += 1
                    if not started and "timestamp" in d:
                        ts = d["timestamp"]
                        if isinstance(ts, str):
                            started = ts[:10]
                        elif isinstance(ts, (int, float)):
                            started = datetime.fromtimestamp(ts / 1000).strftime("%Y-%m-%d")
        except Exception:
            pass

        if turns > 0 and started:
            if cutoff and started < cutoff:
                continue
            if started not in by_date:
                by_date[started] = {
                    "sessions": 0, "turns": 0,
                    "in": 0, "out": 0,
                    "cache_create": 0, "cache_read": 0,
                    "models": set(),
                }
            by_date[started]["sessions"] += 1
            by_date[started]["turns"] += turns
            by_date[started]["in"] += total_in
            by_date[started]["out"] += total_out
            by_date[started]["cache_create"] += total_cache_create
            by_date[started]["cache_read"] += total_cache_read
            if model:
                by_date[started]["models"].add(model)

    return by_date


def _bar(pct, width=20):
    filled = int(round(pct / 100 * width))
    return "[" + "#" * filled + "." * (width - filled) + "]"


def fetch_quota():
    try:
        with open(CREDENTIALS_FILE) as f:
            creds = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None

    token = creds.get("accessToken", "")
    if not token:
        return None

    expires_at = creds.get("expiresAt", 0)
    if expires_at < time.time() * 1000:
        token = refresh_token(creds)
        if not token:
            return None

    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE) as f:
                cached = json.load(f)
            if time.time() - cached.get("fetched_at", 0) < 3600:
                return cached.get("data")
        except Exception:
            pass

    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.233",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
            with open(CACHE_FILE, "w") as f:
                json.dump({"fetched_at": time.time(), "data": data}, f)
            return data
    except Exception as e:
        if os.path.exists(CACHE_FILE):
            try:
                with open(CACHE_FILE) as f:
                    return json.load(f).get("data")
            except Exception:
                pass
        return None


def refresh_token(creds):
    rt = creds.get("refreshToken", "")
    if not rt:
        return None

    payload = json.dumps({
        "grant_type": "refresh_token",
        "refresh_token": rt,
        "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    }).encode()

    req = urllib.request.Request(
        "https://platform.claude.com/v1/oauth/token",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        creds["accessToken"] = data["access_token"]
        creds["expiresAt"] = int(time.time() * 1000) + data.get("expires_in", 3600) * 1000
        if "refresh_token" in data:
            creds["refreshToken"] = data["refresh_token"]
        with open(CREDENTIALS_FILE, "w") as f:
            json.dump(creds, f)
        return data["access_token"]
    except Exception:
        return None


def main():
    days = None
    json_output = False
    for arg in sys.argv[1:]:
        if arg == "--json":
            json_output = True
        elif arg.startswith("--days="):
            days = int(arg.split("=")[1])
        elif arg == "--help":
            print("Usage: usage-report.py [--days=N] [--json]")
            print("  --days=N  Only show last N days (default: all)")
            print("  --json    Output JSON instead of text")
            return

    by_date = aggregate_transcripts(days)

    quota = fetch_quota()

    if json_output:
        out = {}
        for date in sorted(by_date.keys()):
            d = by_date[date]
            out[date] = {
                "sessions": d["sessions"],
                "turns": d["turns"],
                "input_tokens": d["in"],
                "output_tokens": d["out"],
                "cache_creation_tokens": d["cache_create"],
                "cache_read_tokens": d["cache_read"],
                "models": list(d["models"]),
            }
        print(json.dumps({"quota": quota, "daily": out}, indent=2))
        return

    print("=== Quota Utilization ===\n")

    if quota:
        if "five_hour" in quota:
            fh = quota["five_hour"]
            pct = fh.get("utilization", "?")
            bar = _bar(pct) if isinstance(pct, (int, float)) else ""
            print(f"  5-hour window:  {bar} {pct}%", end="")
            if "resets_at" in fh:
                print(f"  (resets: {fh['resets_at']})", end="")
            print()
        if "seven_day" in quota:
            sd = quota["seven_day"]
            pct = sd.get("utilization", "?")
            bar = _bar(pct) if isinstance(pct, (int, float)) else ""
            print(f"  7-day window:   {bar} {pct}%", end="")
            if "resets_at" in sd:
                print(f"  (resets: {sd['resets_at']})", end="")
            print()
        if "extra_usage" in quota:
            eu = quota["extra_usage"]
            print(f"  Extra usage:    {'enabled' if eu.get('is_enabled') else 'disabled'}", end="")
            if eu.get("used_credits") is not None:
                print(f"  ${eu['used_credits']:.2f}/{eu.get('monthly_limit', '?')}", end="")
            print()
        if "limits" in quota:
            for lim in quota["limits"]:
                print(f"  {lim.get('model', '?')}: {lim.get('utilization', '?')}% of {lim.get('window', '?')}")
    else:
        print("  (Unavailable — rate limited or token expired. Cached hourly.)")

    print("\n=== Token Usage ===\n")

    total = {"sessions": 0, "turns": 0, "in": 0, "out": 0, "cache_create": 0, "cache_read": 0}
    for date in sorted(by_date.keys()):
        d = by_date[date]
        for k in total:
            total[k] += d[k]
        models = ", ".join(d["models"] - {"<synthetic>"})
        print(f"  {date}:  {d['sessions']:3d} sessions  {d['turns']:4d} turns  "
              f"out: {d['out']:>10,}  [{models}]")

    print(f"\n  Total:    {total['sessions']:3d} sessions  {total['turns']:4d} turns  "
          f"out: {total['out']:>10,}")
    print(f"  Cache:    {total['cache_create']:>10,} created  {total['cache_read']:>10,} read")


if __name__ == "__main__":
    main()
