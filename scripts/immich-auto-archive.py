#!/usr/bin/env python3
"""Archive Immich assets in specified albums automatically.

Env vars:
  IMMICH_URL        Base URL (e.g. http://localhost:2283)
  IMMICH_API_KEY    API key with admin access
  ARCHIVE_ALBUMS    Comma-separated album names to auto-archive
  DRY_RUN           Set to "1" to list without archiving
"""

import json
import os
import sys
import urllib.request
import urllib.error


def api(base_url, key, method, path, body=None):
    url = f"{base_url}/api{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "x-api-key": key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method=method,
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read()) if resp.status != 204 else None


def get_all_albums(base_url, key):
    return api(base_url, key, "GET", "/albums")


def get_album_assets(base_url, key, album_id):
    album = api(base_url, key, "GET", f"/albums/{album_id}")
    return album.get("assets", [])


def archive_assets(base_url, key, asset_ids):
    if not asset_ids:
        return 0
    body = {"ids": asset_ids, "isArchived": True}
    api(base_url, key, "PUT", "/assets", body)
    return len(asset_ids)


def main():
    base_url = os.environ.get("IMMICH_URL", "").rstrip("/")
    api_key = os.environ.get("IMMICH_API_KEY", "")
    album_names_raw = os.environ.get("ARCHIVE_ALBUMS", "")
    dry_run = os.environ.get("DRY_RUN", "0") == "1"

    if not base_url or not api_key:
        print("Error: IMMICH_URL and IMMICH_API_KEY must be set", file=sys.stderr)
        sys.exit(1)

    if not album_names_raw:
        print("Error: ARCHIVE_ALBUMS must be set (comma-separated album names)", file=sys.stderr)
        sys.exit(1)

    target_names = {n.strip() for n in album_names_raw.split(",") if n.strip()}

    try:
        albums = get_all_albums(base_url, api_key)
    except urllib.error.URLError as e:
        print(f"Error connecting to Immich: {e}", file=sys.stderr)
        sys.exit(1)

    matched = {a["id"]: a["albumName"] for a in albums if a["albumName"] in target_names}

    unmatched = target_names - set(matched.values())
    if unmatched:
        print(f"Warning: albums not found: {', '.join(sorted(unmatched))}", file=sys.stderr)

    if not matched:
        print("No matching albums found. Nothing to do.")
        return

    total_archived = 0
    for album_id, album_name in sorted(matched.items(), key=lambda x: x[1]):
        assets = get_album_assets(base_url, api_key, album_id)
        unarchived = [a["id"] for a in assets if not a.get("isArchived", False)]

        if not unarchived:
            print(f"  {album_name}: 0 new assets to archive")
            continue

        if dry_run:
            print(f"  {album_name}: {len(unarchived)} assets would be archived (dry run)")
        else:
            count = archive_assets(base_url, api_key, unarchived)
            print(f"  {album_name}: archived {count} assets")
            total_archived += count

    if dry_run:
        print("Dry run complete — no changes made.")
    else:
        print(f"Done. Archived {total_archived} assets total.")


if __name__ == "__main__":
    main()
