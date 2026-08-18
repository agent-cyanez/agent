#!/usr/bin/env python3
"""Vela usage tracker — queries quota utilization and aggregates token counts
from Claude Code session transcripts for rolling-window estimation."""

import json
import os
import glob
import sys
import time
import urllib.request
from datetime import datetime, timedelta, timezone

TRANSCRIPTS_DIR = os.path.expanduser("~/.claude/projects/-home-vela-agent")
CREDENTIALS_FILE = os.path.expanduser("~/.claude/.credentials.json")
CACHE_FILE = os.path.expanduser("~/agent/data/usage-cache.json")
CALIBRATION_FILE = os.path.expanduser("~/agent/data/usage-calibration.json")


def _load_credentials():
    try:
        with open(CREDENTIALS_FILE) as f:
            creds = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None, None
    oauth = creds.get("claudeAiOauth", {})
    return oauth, creds


def _parse_timestamp(ts):
    if isinstance(ts, str):
        return ts
    if isinstance(ts, (int, float)):
        return datetime.fromtimestamp(ts / 1000, tz=timezone.utc).isoformat()
    return None


def parse_sessions():
    sessions = glob.glob(os.path.join(TRANSCRIPTS_DIR, "*.jsonl"))
    result = []

    for sf in sessions:
        total_in = 0
        total_out = 0
        cache_create = 0
        cache_read = 0
        model = None
        turns = 0
        started = None
        ended = None

        try:
            with open(sf) as f:
                for line in f:
                    d = json.loads(line)
                    ts = _parse_timestamp(d.get("timestamp"))
                    if ts:
                        if not started:
                            started = ts
                        ended = ts
                    if d.get("type") == "assistant" and "message" in d:
                        msg = d["message"]
                        if isinstance(msg, dict):
                            if not model:
                                model = msg.get("model")
                            if "usage" in msg:
                                u = msg["usage"]
                                total_in += u.get("input_tokens", 0)
                                total_out += u.get("output_tokens", 0)
                                cache_create += u.get("cache_creation_input_tokens", 0)
                                cache_read += u.get("cache_read_input_tokens", 0)
                                turns += 1
        except Exception:
            pass

        if turns > 0 and started:
            result.append({
                "started": started,
                "ended": ended,
                "model": model,
                "turns": turns,
                "in": total_in,
                "out": total_out,
                "cache_create": cache_create,
                "cache_read": cache_read,
            })

    result.sort(key=lambda s: s["started"])
    return result


def rolling_window(sessions, hours=5):
    now = datetime.now(timezone.utc)
    cutoff = (now - timedelta(hours=hours)).isoformat()
    in_window = [s for s in sessions if s["started"] >= cutoff[:19]]
    totals = {"sessions": len(in_window), "in": 0, "out": 0, "cache_create": 0, "cache_read": 0, "turns": 0}
    for s in in_window:
        totals["in"] += s["in"]
        totals["out"] += s["out"]
        totals["cache_create"] += s["cache_create"]
        totals["cache_read"] += s["cache_read"]
        totals["turns"] += s["turns"]
    return totals


def weighted_tokens(totals):
    """Weight tokens by relative API cost to approximate quota impact.
    Opus 4.6: input=$15, output=$75, cache_write=$18.75, cache_read=$1.875 per MTok.
    Normalized to input=1x."""
    return (
        totals["in"] * 1.0
        + totals["out"] * 5.0
        + totals["cache_create"] * 1.25
        + totals["cache_read"] * 0.125
    )


def aggregate_by_date(sessions, days=None):
    cutoff = None
    if days:
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")

    by_date = {}
    for s in sessions:
        date = s["started"][:10]
        if cutoff and date < cutoff:
            continue
        if date not in by_date:
            by_date[date] = {
                "sessions": 0, "turns": 0,
                "in": 0, "out": 0,
                "cache_create": 0, "cache_read": 0,
                "models": set(),
            }
        by_date[date]["sessions"] += 1
        by_date[date]["turns"] += s["turns"]
        by_date[date]["in"] += s["in"]
        by_date[date]["out"] += s["out"]
        by_date[date]["cache_create"] += s["cache_create"]
        by_date[date]["cache_read"] += s["cache_read"]
        if s["model"]:
            by_date[date]["models"].add(s["model"])

    return by_date


def _bar(pct, width=20):
    filled = int(round(pct / 100 * width))
    return "[" + "#" * filled + "." * (width - filled) + "]"


def fetch_quota(force=False):
    oauth, raw_creds = _load_credentials()
    if not oauth:
        return None

    token = oauth.get("accessToken", "")
    if not token:
        return None

    expires_at = oauth.get("expiresAt", 0)
    if expires_at < time.time() * 1000:
        token = _refresh_token(raw_creds)
        if not token:
            return None

    if not force and os.path.exists(CACHE_FILE):
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
            _save_calibration(data)
            return data
    except Exception:
        if os.path.exists(CACHE_FILE):
            try:
                with open(CACHE_FILE) as f:
                    return json.load(f).get("data")
            except Exception:
                pass
        return None


def _refresh_token(raw_creds):
    oauth = raw_creds.get("claudeAiOauth", {})
    rt = oauth.get("refreshToken", "")
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
        oauth["accessToken"] = data["access_token"]
        oauth["expiresAt"] = int(time.time() * 1000) + data.get("expires_in", 3600) * 1000
        if "refresh_token" in data:
            oauth["refreshToken"] = data["refresh_token"]
        with open(CREDENTIALS_FILE, "w") as f:
            json.dump(raw_creds, f)
        return data["access_token"]
    except Exception:
        return None


def _save_calibration(quota_data):
    """Save a calibration point: (timestamp, utilization%, rolling_window_tokens).
    Over time these data points let us estimate utilization between API calls."""
    sessions = parse_sessions()
    window = rolling_window(sessions, hours=5)
    wt = weighted_tokens(window)

    point = {
        "timestamp": time.time(),
        "five_hour_pct": quota_data.get("five_hour", {}).get("utilization"),
        "seven_day_pct": quota_data.get("seven_day", {}).get("utilization"),
        "window_weighted_tokens": wt,
        "window_sessions": window["sessions"],
        "window_out": window["out"],
    }

    history = []
    if os.path.exists(CALIBRATION_FILE):
        try:
            with open(CALIBRATION_FILE) as f:
                history = json.load(f)
        except Exception:
            pass

    history.append(point)
    history = history[-100:]

    os.makedirs(os.path.dirname(CALIBRATION_FILE), exist_ok=True)
    with open(CALIBRATION_FILE, "w") as f:
        json.dump(history, f, indent=2)


def estimate_utilization(sessions):
    """Estimate current utilization by comparing current token volume to the
    last calibration point."""
    if not os.path.exists(CALIBRATION_FILE):
        return None

    try:
        with open(CALIBRATION_FILE) as f:
            history = json.load(f)
    except Exception:
        return None

    valid = [p for p in history if p.get("five_hour_pct") and p.get("window_weighted_tokens")]
    if not valid:
        return None

    latest = valid[-1]
    ref_pct = latest["five_hour_pct"]
    ref_wt = latest["window_weighted_tokens"]

    if ref_pct <= 0 or ref_wt <= 0:
        return None

    window = rolling_window(sessions, hours=5)
    current_wt = weighted_tokens(window)

    estimated_pct = (current_wt / ref_wt) * ref_pct
    return {
        "estimated_5h_pct": round(min(estimated_pct, 100), 1),
        "based_on_snapshot_age_min": round((time.time() - latest["timestamp"]) / 60),
        "current_weighted_tokens": current_wt,
        "ref_weighted_tokens": ref_wt,
        "ref_pct": ref_pct,
    }


def main():
    days = None
    json_output = False
    force_fetch = False
    for arg in sys.argv[1:]:
        if arg == "--json":
            json_output = True
        elif arg.startswith("--days="):
            days = int(arg.split("=")[1])
        elif arg == "--force":
            force_fetch = True
        elif arg == "--help":
            print("Usage: usage-report.py [--days=N] [--json] [--force]")
            print("  --days=N  Only show last N days (default: all)")
            print("  --json    Output JSON instead of text")
            print("  --force   Force quota fetch (ignore cache)")
            return

    sessions = parse_sessions()
    by_date = aggregate_by_date(sessions, days)

    quota = fetch_quota(force=force_fetch)
    window_5h = rolling_window(sessions, hours=5)
    estimation = estimate_utilization(sessions)

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
        print(json.dumps({
            "quota": quota,
            "rolling_5h": window_5h,
            "estimation": estimation,
            "daily": out,
        }, indent=2))
        return

    print("=== Quota (live from Anthropic) ===\n")

    if quota:
        fh = quota.get("five_hour", {})
        sd = quota.get("seven_day", {})
        fh_pct = fh.get("utilization", "?")
        sd_pct = sd.get("utilization", "?")

        if isinstance(fh_pct, (int, float)):
            print(f"  5-hour:   {_bar(fh_pct)} {fh_pct}%", end="")
            if "resets_at" in fh:
                reset = fh["resets_at"][:16].replace("T", " ")
                print(f"  resets {reset} UTC", end="")
            print()

        if isinstance(sd_pct, (int, float)):
            print(f"  7-day:    {_bar(sd_pct)} {sd_pct}%", end="")
            if "resets_at" in sd:
                reset = sd["resets_at"][:16].replace("T", " ")
                print(f"  resets {reset} UTC", end="")
            print()

        limits = quota.get("limits", [])
        for lim in limits:
            scope = lim.get("scope")
            if scope and scope.get("model", {}).get("display_name"):
                name = scope["model"]["display_name"]
                pct = lim.get("percent", "?")
                kind = lim.get("kind", "")
                if isinstance(pct, (int, float)):
                    print(f"  {name} ({kind}): {_bar(pct)} {pct}%")

        eu = quota.get("extra_usage", {})
        if eu:
            status = "enabled" if eu.get("is_enabled") else "disabled"
            reason = f" ({eu.get('disabled_reason', '')})" if not eu.get("is_enabled") else ""
            print(f"  Credits:  {status}{reason}")

        if os.path.exists(CACHE_FILE):
            try:
                with open(CACHE_FILE) as f:
                    age = time.time() - json.load(f).get("fetched_at", 0)
                print(f"  Fetched:  {int(age / 60)} min ago")
            except Exception:
                pass
    else:
        print("  (Unavailable — rate limited or token expired)")

    print("\n=== 5-Hour Rolling Window (local) ===\n")
    print(f"  Sessions:  {window_5h['sessions']}")
    print(f"  Turns:     {window_5h['turns']}")
    print(f"  Output:    {window_5h['out']:>10,} tokens")
    print(f"  Input:     {window_5h['in']:>10,} tokens")
    print(f"  Cache:     {window_5h['cache_create']:>10,} created")

    if estimation:
        est = estimation["estimated_5h_pct"]
        age = estimation["based_on_snapshot_age_min"]
        print(f"\n  Estimated: {_bar(est)} ~{est}%  (calibrated {age} min ago)")

    print("\n=== Daily Totals ===\n")

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
