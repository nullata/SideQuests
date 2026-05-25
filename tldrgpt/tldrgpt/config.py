from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


@dataclass(frozen=True)
class Settings:
    source_data: Path
    deleted_data: Path
    analysis_backend: str
    codex_command: str
    codex_model: str
    codex_timeout_seconds: int
    openai_base_url: str
    openai_api_key: str
    openai_model: str
    openai_timeout_seconds: int
    debug: bool


def load_settings() -> Settings:
    load_dotenv()

    source_data = os.getenv("SOURCE_DATA")
    deleted_data = os.getenv("DELETED_DATA")
    if not source_data or not deleted_data:
        raise RuntimeError(
            "SOURCE_DATA and DELETED_DATA must be set before starting tldrgpt."
        )

    backend = os.getenv("ANALYSIS_BACKEND", "codex").strip().lower()
    if backend not in {"codex", "openai"}:
        backend = "codex"

    return Settings(
        source_data=Path(source_data).expanduser().resolve(),
        deleted_data=Path(deleted_data).expanduser().resolve(),
        analysis_backend=backend,
        codex_command=os.getenv("CODEX_COMMAND", "codex"),
        codex_model=os.getenv("CODEX_MODEL", "gpt-5.2-codex"),
        codex_timeout_seconds=int(os.getenv("CODEX_TIMEOUT_SECONDS", "600")),
        openai_base_url=os.getenv("OPENAI_BASE_URL", "http://localhost:11434/v1").strip(),
        openai_api_key=os.getenv("OPENAI_API_KEY", "").strip(),
        openai_model=os.getenv("OPENAI_MODEL", "llama3.1").strip(),
        openai_timeout_seconds=int(os.getenv("OPENAI_TIMEOUT_SECONDS", "600")),
        debug=os.getenv("FLASK_DEBUG", "0").lower() in {"1", "true", "yes", "on"},
    )
