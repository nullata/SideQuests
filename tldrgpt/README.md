# tldrgpt

`tldrgpt` is a Flask + HTML + JavaScript + Tailwind app for browsing exported ChatGPT conversations, serializing them into structured JSON, and generating summaries with topic tags. Analysis runs against either the local Codex CLI or any OpenAI-compatible API (Ollama, LM Studio, [LlamaMan](https://github.com/nullata/llamaman), etc.).

The expected source files are standalone ChatGPT conversation `.html` exports produced in the browser with [Tampermonkey](https://www.tampermonkey.net/) plus the [ChatGPT Exporter userscript](https://greasyfork.org/en/scripts/456055-chatgpt-exporter).

## Features

- Scan a source directory for exported ChatGPT `.html` conversations.
- Display conversation titles in a searchable sidebar.
- Render the original conversation HTML in an iframe.
- Serialize each conversation into a companion `.tldrgpt.json` file.
- Analyze one conversation or all unanalyzed conversations through `codex exec` or an OpenAI-compatible API.
- Render the analysis markdown with readable headings and list formatting.
- Show analysis tags as searchable pills.
- View the full beautified raw companion JSON from the UI.
- Soft-delete conversations by moving their HTML and JSON files to a deleted-data directory.

## Setup

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Edit `.env` before starting:

```env
SOURCE_DATA=example-data
DELETED_DATA=deleted-data

ANALYSIS_BACKEND=codex

CODEX_COMMAND=codex
CODEX_MODEL=gpt-5.2-codex
CODEX_TIMEOUT_SECONDS=600

OPENAI_BASE_URL=http://localhost:11434/v1
OPENAI_API_KEY=
OPENAI_MODEL=llama3.1
OPENAI_TIMEOUT_SECONDS=600

FLASK_DEBUG=1
```

`SOURCE_DATA` is scanned for `*.html` files.

`DELETED_DATA` receives soft-deleted `.html` and `.tldrgpt.json` files.

`ANALYSIS_BACKEND` selects the analysis engine: `codex` (local Codex CLI) or `openai` (any OpenAI-compatible API).

### Codex backend

`CODEX_COMMAND` is the local Codex CLI executable.

`CODEX_MODEL` controls which Codex model performs analysis.

`CODEX_TIMEOUT_SECONDS` controls how long one analysis job can run before it is marked failed.

### OpenAI-compatible backend

Set `ANALYSIS_BACKEND=openai` to summarize with a local (or remote) OpenAI-compatible `/chat/completions` endpoint instead of Codex.

`OPENAI_BASE_URL` is the API base URL. Examples:

```text
Ollama:    http://localhost:11434/v1
LM Studio: http://localhost:1234/v1
LlamaMan:  http://localhost:42069/v1
```

`OPENAI_API_KEY` is the bearer token. Leave it blank for servers that don't require auth (Ollama, LM Studio); set it for [LlamaMan](https://github.com/nullata/llamaman) when `require_auth` is on.

`OPENAI_MODEL` is the model name as the server exposes it (e.g. `llama3.1`).

`OPENAI_TIMEOUT_SECONDS` controls how long one analysis request can run before it is marked failed.

#### How it works

- Sends the whole serialized conversation in one request as a `system` + `user` message pair to `<OPENAI_BASE_URL>/chat/completions` (plain stdlib HTTP, no extra dependencies).
- Requests `response_format: json_object`; if the server rejects it, retries once without it and recovers the JSON with a lenient parser that strips code fences and surrounding prose from smaller local models.
- `OPENAI_API_KEY` is sent as a bearer token only when set.
- Availability is probed with `GET <OPENAI_BASE_URL>/models`; the result is reported by `/api/health` and shown in the sidebar.
- The conversation is sent in a single shot, so the model's **context window must be large enough to hold your longest conversation**.

## Run

```bash
source .venv/bin/activate
flask --app app run --debug
```

Open `http://127.0.0.1:5000`.

Analysis requires whichever backend you selected to be reachable: the local Codex CLI installed and logged in, or an OpenAI-compatible server running at `OPENAI_BASE_URL`. Browsing, serialization, raw JSON viewing, and soft delete still work without successful analysis.

## Application Flow

On startup, the app asynchronously scans `SOURCE_DATA` for `.html` files. Each file becomes a conversation entry in the sidebar. The displayed title is read from the HTML `<title>` tag.

Selecting a conversation opens the original HTML export in an iframe so it is rendered as a page, not shown as source text.

Clicking **Analyze** runs this sequence:

1. Parse the HTML export.
2. Extract `.conversation-item` blocks.
3. Convert each message into `{ "prompt": "user", "message": "..." }` or `{ "prompt": "ChatGPT", "message": "..." }`.
4. Save the serialized conversation as a companion JSON file in `SOURCE_DATA`.
5. Send the serialized conversation to the active backend (`codex exec` or the OpenAI-compatible API) for analysis.
6. Store the returned markdown summary and topic tags in the companion JSON file.

The **Analyze All** button queues analysis for every conversation that does not already have complete analysis.

## Companion JSON

For a source file:

```text
ChatGPT-Active_Reading_Strategies.html
```

the app writes:

```text
ChatGPT-Active_Reading_Strategies.tldrgpt.json
```

Example structure:

```json
{
  "schema_version": 1,
  "source_file": "ChatGPT-Active_Reading_Strategies.html",
  "title": "Active Reading Strategies",
  "serialized_at": "2026-04-27T12:00:00+00:00",
  "conversation": [
    { "prompt": "user", "message": "..." },
    { "prompt": "ChatGPT", "message": "..." }
  ],
  "analysis": {
    "markdown": "## TLDR\n...",
    "tags": ["reading", "communication"]
  },
  "analysis_status": "complete",
  "analyzed_at": "2026-04-27T12:01:00+00:00",
  "analysis_error": null
}
```

## UI States

Sidebar status indicators:

```text
✅ analyzed successfully
⚠️ serialized, but analysis is incomplete or failed
```

The sidebar search matches both conversation titles and tags.

## API Routes

```text
GET    /api/health
POST   /api/scan
GET    /api/conversations
GET    /api/conversations/<id>/html
GET    /api/conversations/<id>/analysis
GET    /api/conversations/<id>/json
POST   /api/conversations/<id>/serialize
POST   /api/conversations/<id>/analyze
POST   /api/analyze-all
DELETE /api/conversations/<id>
```

## Implementation Notes

The HTML serializer currently targets ChatGPT Exporter-style files with `.conversation-item`, `.author`, and `.conversation-content` elements.

The Codex backend runs through local one-shot Codex CLI mode using `codex exec`. The app passes a strict output schema and reads the final response from `--output-last-message`.

Both backends share the same prompt and the same lenient JSON parser (it tolerates markdown fences or surrounding prose from smaller local models), so analysis output is consistent regardless of which one is active. See [OpenAI-compatible backend](#openai-compatible-backend) for the request flow.
