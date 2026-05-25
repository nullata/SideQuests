from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .serializer import load_analysis_json


SYSTEM_PROMPT = """You analyze exported ChatGPT conversations for a personal archive.
Return only valid JSON with this exact shape:
{
  "markdown": "A concise TLDR summary followed by a sequential list of topics discussed.",
  "tags": ["short-topic-tag"]
}

The markdown must start with a short TLDR section, then include an "Important Notes" section when useful, and then a "Topics Discussed" ordered list. Tags should be lowercase, concise, and based on the conversation topics."""

ANALYSIS_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "markdown": {"type": "string"},
        "tags": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["markdown", "tags"],
}


@dataclass(frozen=True)
class BackendConfig:
    """Resolved configuration for whichever analysis backend is active."""

    backend: str  # "codex" or "openai"
    codex_command: str
    codex_model: str
    codex_timeout_seconds: int
    openai_base_url: str
    openai_api_key: str
    openai_model: str
    openai_timeout_seconds: int

    @property
    def is_openai(self) -> bool:
        return self.backend == "openai"

    @property
    def model(self) -> str:
        return self.openai_model if self.is_openai else self.codex_model

    @property
    def endpoint(self) -> str:
        """Human-readable identifier for the active backend target."""
        return self.openai_base_url if self.is_openai else self.codex_command


def analyze_conversation_json(json_path: Path, config: BackendConfig) -> dict[str, Any]:
    data = load_analysis_json(json_path)
    if not data:
        raise ValueError(f"Cannot read serialized conversation JSON: {json_path}")
    if not data.get("conversation"):
        raise ValueError("Serialized conversation has no messages to analyze.")

    payload = {
        "title": data.get("title"),
        "conversation": data.get("conversation"),
    }
    instruction = _user_instruction(payload)

    if config.is_openai:
        raw_text = _call_openai_compatible(
            system_prompt=SYSTEM_PROMPT,
            user_prompt=instruction,
            base_url=config.openai_base_url,
            api_key=config.openai_api_key,
            model=config.openai_model,
            timeout_seconds=config.openai_timeout_seconds,
        )
    else:
        raw_text = _call_codex_cli(
            prompt=f"{SYSTEM_PROMPT}\n\n{instruction}",
            model=config.codex_model,
            codex_command=config.codex_command,
            cwd=json_path.parent,
            timeout_seconds=config.codex_timeout_seconds,
        )

    analysis = _parse_analysis(raw_text)
    data["analysis"] = analysis
    data["analysis_status"] = "complete"
    data["analyzed_at"] = datetime.now(timezone.utc).isoformat()
    data["analysis_error"] = None
    json_path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    return data


def codex_available(codex_command: str) -> bool:
    return shutil.which(codex_command) is not None


def backend_available(config: BackendConfig) -> bool:
    if config.is_openai:
        return _openai_reachable(config.openai_base_url, config.openai_api_key)
    return codex_available(config.codex_command)


def mark_analysis_failed(json_path: Path, error: str) -> None:
    data = load_analysis_json(json_path) or {}
    data["analysis_status"] = "failed"
    data["analysis_error"] = error
    data["analyzed_at"] = datetime.now(timezone.utc).isoformat()
    json_path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


def _user_instruction(payload: dict[str, Any]) -> str:
    return (
        "Analyze this serialized ChatGPT conversation JSON. "
        "Return the requested JSON object only.\n\n"
        f"{json.dumps(payload, ensure_ascii=False)}"
    )


def _call_codex_cli(
    prompt: str,
    model: str,
    codex_command: str,
    cwd: Path,
    timeout_seconds: int,
) -> str:
    if not codex_available(codex_command):
        raise RuntimeError(f"Codex CLI command not found: {codex_command}")

    with tempfile.TemporaryDirectory(prefix="tldrgpt-codex-") as tmpdir:
        tmp_path = Path(tmpdir)
        schema_path = tmp_path / "analysis.schema.json"
        output_path = tmp_path / "analysis.json"
        schema_path.write_text(json.dumps(ANALYSIS_SCHEMA), encoding="utf-8")

        command = [
            codex_command,
            "exec",
            "--model",
            model,
            "--sandbox",
            "read-only",
            "--skip-git-repo-check",
            "--ephemeral",
            "--output-schema",
            str(schema_path),
            "--output-last-message",
            str(output_path),
            "-",
        ]
        result = subprocess.run(
            command,
            input=prompt,
            text=True,
            capture_output=True,
            cwd=cwd,
            timeout=timeout_seconds,
            check=False,
        )
        if result.returncode != 0:
            stderr = result.stderr.strip()
            stdout = result.stdout.strip()
            detail = stderr or stdout or f"exit code {result.returncode}"
            raise RuntimeError(f"Codex CLI analysis failed: {detail}")

        if output_path.exists():
            output = output_path.read_text(encoding="utf-8").strip()
            if output:
                return output

        output = result.stdout.strip()
        if not output:
            raise RuntimeError("Codex CLI returned an empty analysis response.")
        return output


def _call_openai_compatible(
    system_prompt: str,
    user_prompt: str,
    base_url: str,
    api_key: str,
    model: str,
    timeout_seconds: int,
) -> str:
    if not base_url:
        raise RuntimeError(
            "OPENAI_BASE_URL is not set; the OpenAI-compatible backend has no endpoint to call."
        )

    url = base_url.rstrip("/") + "/chat/completions"
    common = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0.2,
        "stream": False,
    }
    # Ask for JSON output first; fall back to a plain request for servers that
    # reject the response_format field (handled by lenient parsing downstream).
    attempts = [
        {**common, "response_format": {"type": "json_object"}},
        dict(common),
    ]

    last_error: Exception | None = None
    for index, body in enumerate(attempts):
        try:
            raw = _http_post_json(url, body, api_key, timeout_seconds)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace").strip()
            message = f"OpenAI-compatible API error {exc.code} from {url}: {detail or exc.reason}"
            if index == 0 and exc.code in (400, 404, 422, 501):
                last_error = RuntimeError(message)
                continue
            raise RuntimeError(message) from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(
                f"Could not reach OpenAI-compatible API at {url}: {getattr(exc, 'reason', exc)}"
            ) from exc
        return _content_from_chat_response(raw)

    raise last_error or RuntimeError("OpenAI-compatible API request failed.")


def _http_post_json(url: str, body: dict[str, Any], api_key: str, timeout_seconds: int) -> str:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if api_key:
        req.add_header("Authorization", f"Bearer {api_key}")
    with urllib.request.urlopen(req, timeout=timeout_seconds) as resp:
        return resp.read().decode("utf-8")


def _content_from_chat_response(raw: str) -> str:
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError("OpenAI-compatible API returned a non-JSON HTTP body.") from exc

    choices = parsed.get("choices")
    if not isinstance(choices, list) or not choices:
        raise RuntimeError("OpenAI-compatible API response contained no choices.")
    message = choices[0].get("message") or {}
    content = message.get("content")
    if not isinstance(content, str) or not content.strip():
        raise RuntimeError("OpenAI-compatible API response contained an empty message.")
    return content


def _openai_reachable(base_url: str, api_key: str, timeout: float = 2.0) -> bool:
    if not base_url:
        return False
    url = base_url.rstrip("/") + "/models"
    req = urllib.request.Request(url, method="GET")
    if api_key:
        req.add_header("Authorization", f"Bearer {api_key}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status < 500
    except urllib.error.HTTPError as exc:
        # A 401/403/404 still means the server is up and answering.
        return exc.code < 500
    except (urllib.error.URLError, OSError):
        return False


def _parse_analysis(raw_text: str) -> dict[str, Any]:
    try:
        parsed = _loads_lenient(raw_text)
    except json.JSONDecodeError as exc:
        raise ValueError("Analysis response was not valid JSON.") from exc

    markdown = parsed.get("markdown")
    tags = parsed.get("tags")
    if not isinstance(markdown, str) or not markdown.strip():
        raise ValueError("Analysis response JSON is missing a non-empty markdown field.")
    if not isinstance(tags, list):
        raise ValueError("Analysis response JSON is missing a tags list.")

    clean_tags = []
    for tag in tags:
        if isinstance(tag, str) and tag.strip():
            clean_tags.append(tag.strip().lower())

    return {"markdown": markdown.strip(), "tags": clean_tags}


def _loads_lenient(raw_text: str) -> Any:
    """Parse JSON, tolerating markdown fences or surrounding prose from local models."""
    text = raw_text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z0-9]*\s*", "", text)
        text = re.sub(r"\s*```$", "", text).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start != -1 and end > start:
            return json.loads(text[start : end + 1])
        raise
