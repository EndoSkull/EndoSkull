#!/usr/bin/env python3
"""Refresh live.json for the Convoy 1943 home page.

For each channel we request /channel/<id>/live and read <link rel="canonical">.
YouTube points that at watch?v=<videoId> while a stream is running and back at
the channel URL when it is not, which gives us both the live flag and the id we
need to embed -- with no API key and no quota.

Nothing here is authenticated, so a failed lookup is treated as "offline"
rather than an error: a scrape that breaks should make the page fall back to
the latest recorded stream, never blank the hero.
"""

import json
import pathlib
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

# Order matters: the grid renders in this order, so EndoSkull leads.
CHANNELS = [
    {"handle": "EndoSkull", "name": "Endo Goes To War", "channelId": "UCDTebcknsML6lKuabmT0H-A"},
    {"handle": "MrBucket_Gaming", "name": "Mr. Bucket", "channelId": "UCp3HiZJVbOF-SpgG_oZMRZw"},
    {"handle": "Alistair_Lair", "name": "Alistair's Lair", "channelId": "UCt_E7O8-rn_6ePdOKRtslJg"},
    {"handle": "TLPtater", "name": "TLPTater", "channelId": "UClFbJxx12tSonNdmkU7J0cQ"},
]

FALLBACK_CHANNEL = CHANNELS[0]

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
CANONICAL = re.compile(r'<link rel="canonical" href="([^"]+)"')
WATCH_ID = re.compile(r"[?&]v=([\w-]{11})")
VIDEO_ID = re.compile(r'"videoId":"([\w-]{11})"')


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en-US,en;q=0.9"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.read().decode("utf-8", "replace")


def live_video_id(channel_id):
    """Return the running stream's video id, or None when the channel is idle."""
    try:
        html = get(f"https://www.youtube.com/channel/{channel_id}/live")
    except (urllib.error.URLError, TimeoutError) as exc:
        print(f"  lookup failed ({exc}) -- treating as offline", file=sys.stderr)
        return None

    canonical = CANONICAL.search(html)
    if not canonical:
        print("  no canonical tag -- treating as offline", file=sys.stderr)
        return None

    watch = WATCH_ID.search(canonical.group(1))
    return watch.group(1) if watch else None


def latest_stream_id(handle):
    """Newest video on the channel's /streams tab, in document order."""
    try:
        html = get(f"https://www.youtube.com/@{handle}/streams")
    except (urllib.error.URLError, TimeoutError) as exc:
        print(f"  streams tab failed ({exc})", file=sys.stderr)
        return None
    match = VIDEO_ID.search(html)
    return match.group(1) if match else None


def main():
    out = pathlib.Path(__file__).resolve().parent.parent / "live.json"
    previous = {}
    if out.exists():
        try:
            previous = json.loads(out.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            pass

    live = []
    for ch in CHANNELS:
        print(f"checking @{ch['handle']}")
        video_id = live_video_id(ch["channelId"])
        if video_id:
            print(f"  LIVE -> {video_id}")
            live.append({**ch, "videoId": video_id})

    # Keep the previous fallback if the streams tab is unreachable, so a bad
    # scrape never costs us the one video the page is guaranteed to show.
    fallback_id = latest_stream_id(FALLBACK_CHANNEL["handle"]) or previous.get("fallback", {}).get("videoId")
    if not fallback_id:
        print("no fallback video available", file=sys.stderr)
        return 1

    payload = {
        "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "live": live,
        "fallback": {"videoId": fallback_id, "name": FALLBACK_CHANNEL["name"], "handle": FALLBACK_CHANNEL["handle"]},
    }

    # Compare ignoring the timestamp so an unchanged status makes no commit.
    def significant(d):
        return {k: v for k, v in d.items() if k != "updated"}

    if previous and significant(previous) == significant(payload):
        print("no change")
        return 0

    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out.name}: {len(live)} live, fallback {fallback_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
