from __future__ import annotations

import re
import shutil
import threading
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

import bleach
import markdown as markdown_lib

from .analyzer import BackendConfig, analyze_conversation_json, mark_analysis_failed
from .serializer import (
    companion_json_path,
    extract_title,
    has_complete_analysis,
    load_analysis_json,
    serialize_html_conversation,
    write_serialized_json,
)


ALLOWED_MARKDOWN_TAGS = set(bleach.sanitizer.ALLOWED_TAGS).union(
    {
        "p",
        "h1",
        "h2",
        "h3",
        "h4",
        "pre",
        "code",
        "span",
        "br",
        "hr",
        "ol",
        "ul",
        "li",
        "strong",
        "em",
    }
)


@dataclass
class ConversationRecord:
    id: str
    title: str
    html_path: Path
    json_path: Path
    status: str
    tags: list[str] = field(default_factory=list)
    error: str | None = None


class ConversationStore:
    def __init__(
        self,
        source_data: Path,
        deleted_data: Path,
        backend: BackendConfig,
        executor: ThreadPoolExecutor,
    ) -> None:
        self.source_data = source_data
        self.deleted_data = deleted_data
        self.backend = backend
        self.executor = executor
        self._records: dict[str, ConversationRecord] = {}
        self._lock = threading.RLock()
        self._scan_future: Future[Any] | None = None
        self._analysis_jobs: dict[str, Future[Any]] = {}

    def start_scan(self) -> None:
        with self._lock:
            if self._scan_future and not self._scan_future.done():
                return
            self._scan_future = self.executor.submit(self.scan)

    def scan_status(self) -> dict[str, Any]:
        with self._lock:
            running = bool(self._scan_future and not self._scan_future.done())
            return {"running": running, "count": len(self._records)}

    def scan(self) -> list[ConversationRecord]:
        self.source_data.mkdir(parents=True, exist_ok=True)
        self.deleted_data.mkdir(parents=True, exist_ok=True)

        records: dict[str, ConversationRecord] = {}
        for html_path in sorted(self.source_data.rglob("*.html")):
            if not html_path.is_file():
                continue
            rel_path = html_path.relative_to(self.source_data)
            record_id = rel_path.as_posix()
            json_path = companion_json_path(html_path)
            json_data = load_analysis_json(json_path)
            try:
                title = str(json_data.get("title")) if json_data and json_data.get("title") else extract_title(html_path)
            except OSError:
                title = html_path.stem

            status = "new"
            tags: list[str] = []
            error = None
            if json_data:
                analysis = json_data.get("analysis")
                tags = analysis.get("tags", []) if isinstance(analysis, dict) else []
                error = json_data.get("analysis_error")
                if has_complete_analysis(json_data):
                    status = "analyzed"
                elif json_data.get("conversation"):
                    status = "warning"

            with self._lock:
                job = self._analysis_jobs.get(record_id)
                if job and not job.done():
                    status = "analyzing"

            records[record_id] = ConversationRecord(
                id=record_id,
                title=title,
                html_path=html_path,
                json_path=json_path,
                status=status,
                tags=tags if isinstance(tags, list) else [],
                error=error if isinstance(error, str) else None,
            )

        with self._lock:
            self._records = records
            return list(self._records.values())

    def list_conversations(self) -> list[dict[str, Any]]:
        with self._lock:
            return [self._public_record(record) for record in self._records.values()]

    def get_record(self, record_id: str) -> ConversationRecord:
        self.scan()
        with self._lock:
            record = self._records.get(record_id)
            if not record:
                raise KeyError(record_id)
            return record

    def get_analysis(self, record_id: str) -> dict[str, Any]:
        record = self.get_record(record_id)
        data = load_analysis_json(record.json_path)
        analysis = data.get("analysis") if data else None
        markdown = analysis.get("markdown") if isinstance(analysis, dict) else ""
        tags = analysis.get("tags") if isinstance(analysis, dict) else []
        normalized_markdown = _normalize_analysis_markdown(markdown or "")
        html = bleach.clean(
            markdown_lib.markdown(normalized_markdown, extensions=["extra", "sane_lists"]),
            tags=ALLOWED_MARKDOWN_TAGS,
            attributes={"a": ["href", "title"], "code": ["class"], "span": ["class"]},
            protocols=["http", "https", "mailto"],
        )
        return {
            "id": record.id,
            "title": record.title,
            "status": record.status,
            "tags": tags if isinstance(tags, list) else [],
            "markdown": markdown,
            "html": html,
            "error": data.get("analysis_error") if data else None,
        }

    def get_raw_json(self, record_id: str) -> dict[str, Any]:
        record = self.get_record(record_id)
        data = load_analysis_json(record.json_path)
        if not data:
            raise FileNotFoundError(record.json_path)
        return data

    def ensure_serialized(self, record_id: str) -> Path:
        record = self.get_record(record_id)
        existing = load_analysis_json(record.json_path)
        serialized = serialize_html_conversation(record.html_path)
        json_path = write_serialized_json(record.html_path, serialized, existing=existing)
        self.scan()
        return json_path

    def analyze(self, record_id: str) -> None:
        with self._lock:
            job = self._analysis_jobs.get(record_id)
            if job and not job.done():
                return
            self._analysis_jobs[record_id] = self.executor.submit(self._analyze_job, record_id)
        self.scan()

    def analyze_all_unanalyzed(self) -> int:
        records = self.scan()
        queued = 0
        for record in records:
            if record.status != "analyzed":
                self.analyze(record.id)
                queued += 1
        return queued

    def soft_delete(self, record_id: str) -> None:
        record = self.get_record(record_id)
        self.deleted_data.mkdir(parents=True, exist_ok=True)

        for path in [record.html_path, record.json_path]:
            if not path.exists():
                continue
            relative = path.relative_to(self.source_data)
            target = self.deleted_data / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                stamp = datetime.now().strftime("%Y%m%d%H%M%S")
                target = target.with_name(f"{target.stem}.{stamp}{target.suffix}")
            shutil.move(str(path), str(target))

        self.scan()

    def _analyze_job(self, record_id: str) -> None:
        try:
            json_path = self.ensure_serialized(record_id)
            analyze_conversation_json(json_path=json_path, config=self.backend)
        except Exception as exc:
            try:
                record = self.get_record(record_id)
                if record.json_path.exists():
                    mark_analysis_failed(record.json_path, str(exc))
            except Exception:
                pass
        finally:
            self.scan()

    def _public_record(self, record: ConversationRecord) -> dict[str, Any]:
        return {
            "id": record.id,
            "title": record.title,
            "status": record.status,
            "tags": record.tags,
            "error": record.error,
        }


def _normalize_analysis_markdown(markdown: str) -> str:
    text = markdown.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not text:
        return ""

    labels = ("TLDR", "Important Notes", "Topics Discussed")
    label_pattern = "|".join(re.escape(label) for label in labels)

    text = re.sub(
        rf"(^|\n)\s*(?:\*\*)?({label_pattern})(?:\*\*)?\s*",
        lambda match: f"{match.group(1)}## {match.group(2)}\n\n",
        text,
    )
    text = re.sub(
        rf"(?<!#)\s+({label_pattern})\s+",
        lambda match: f"\n\n## {match.group(1)}\n\n",
        text,
    )
    text = re.sub(r"[ \t]+(\d+\.\s+)", r"\n\1", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()
