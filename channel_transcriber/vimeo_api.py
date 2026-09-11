from __future__ import annotations

import os
import re
import time

from .models import Video

# yt-dlp has no extractor for Vimeo "folders" (a Pro/Business organizational
# feature, distinct from public showcases/albums) -- enumerating one requires
# Vimeo's own REST API. Per-video extraction (captions/audio/etc.) still goes
# through yt-dlp as normal once a real video URL is known.
_FOLDER_URL_RE = re.compile(r"vimeo\.com/user/(?P<user_id>\d+)/folder/(?P<folder_id>\d+)")


def is_folder_url(url: str) -> bool:
    return _FOLDER_URL_RE.search(url) is not None


def _token() -> str:
    token = os.environ.get("VIMEO_ACCESS_TOKEN")
    if not token:
        raise RuntimeError(
            "VIMEO_ACCESS_TOKEN is not set. Create a personal access token (Public + Private scopes) "
            "at https://developer.vimeo.com/apps, then set it as an environment variable."
        )
    return token


def list_folder_videos(url: str, limit: int | None = None) -> list[Video]:
    import requests
    match = _FOLDER_URL_RE.search(url)
    if not match:
        raise ValueError(f"Not a recognized Vimeo folder URL: {url}")
    user_id, folder_id = match["user_id"], match["folder_id"]
    headers = {"Authorization": f"Bearer {_token()}", "Accept": "application/vnd.vimeo.*+json;version=3.4"}
    endpoint = f"https://api.vimeo.com/users/{user_id}/folders/{folder_id}/videos"

    videos: list[Video] = []
    params = {"per_page": 100, "page": 1}
    while True:
        response = requests.get(endpoint, headers=headers, params=params, timeout=30)
        if response.status_code == 429:
            time.sleep(5)
            continue
        if response.status_code == 404:
            raise RuntimeError(
                f"Vimeo API returned 404 for user {user_id} / folder {folder_id}. "
                "Check the folder still exists and this token's account has access to it."
            )
        response.raise_for_status()
        data = response.json()
        for item in data.get("data", []):
            video_id = item["uri"].rsplit("/", 1)[-1]
            created = (item.get("created_time") or "")[:10].replace("-", "")
            videos.append(Video(
                video_id=video_id,
                title=item.get("name") or video_id,
                url=item.get("link") or f"https://vimeo.com/{video_id}",
                upload_date=created or None,
                duration=item.get("duration"),
                channel=(item.get("user") or {}).get("name"),
                position=len(videos),
            ))
            if limit and len(videos) >= limit:
                return videos
        if not (data.get("paging") or {}).get("next"):
            break
        params["page"] += 1
    return videos
