from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from bs4 import BeautifulSoup


APP_JSON_SUFFIX = ".tldrgpt.json"


@dataclass(frozen=True)
class SerializedConversation:
    title: str
    messages: list[dict[str, str]]


def companion_json_path(html_path: Path) -> Path:
    return html_path.with_name(f"{html_path.stem}{APP_JSON_SUFFIX}")


def extract_title(html_path: Path) -> str:
    soup = BeautifulSoup(html_path.read_text(encoding="utf-8", errors="replace"), "html.parser")
    title = soup.find("title")
    value = title.get_text(" ", strip=True) if title else ""
    return value or html_path.stem


def serialize_html_conversation(html_path: Path) -> SerializedConversation:
    soup = BeautifulSoup(html_path.read_text(encoding="utf-8", errors="replace"), "html.parser")
    title_tag = soup.find("title")
    title = title_tag.get_text(" ", strip=True) if title_tag else html_path.stem
    messages: list[dict[str, str]] = []

    for item in soup.select(".conversation-item"):
        author = item.select_one(".author")
        content = item.select_one(".conversation-content")
        if not content:
            continue

        author_classes = set(author.get("class", [])) if author else set()
        prompt = "user" if "user" in author_classes else "ChatGPT"
        message = content.get_text("\n", strip=True)
        if message:
            messages.append({"prompt": prompt, "message": message})

    return SerializedConversation(title=title or html_path.stem, messages=messages)


def load_analysis_json(json_path: Path) -> dict[str, Any] | None:
    if not json_path.exists():
        return None
    try:
        return json.loads(json_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def write_serialized_json(
    html_path: Path,
    serialized: SerializedConversation,
    existing: dict[str, Any] | None = None,
) -> Path:
    json_path = companion_json_path(html_path)
    now = datetime.now(timezone.utc).isoformat()
    data = existing or {}
    data.update(
        {
            "schema_version": 1,
            "source_file": html_path.name,
            "title": serialized.title,
            "serialized_at": now,
            "conversation": serialized.messages,
        }
    )
    data.setdefault("analysis", None)
    data.setdefault("analysis_status", "unanalyzed")
    json_path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    return json_path


def has_complete_analysis(data: dict[str, Any] | None) -> bool:
    if not data:
        return False
    analysis = data.get("analysis")
    return bool(
        isinstance(analysis, dict)
        and isinstance(analysis.get("markdown"), str)
        and analysis.get("markdown").strip()
        and isinstance(analysis.get("tags"), list)
    )
