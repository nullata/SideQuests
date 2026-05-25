from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

from flask import Flask, abort, jsonify, render_template, request, send_file

from .analyzer import BackendConfig, backend_available
from .config import load_settings
from .store import ConversationStore


def create_app() -> Flask:
    settings = load_settings()
    app = Flask(__name__, template_folder="../templates", static_folder="../static")
    app.config["DEBUG"] = settings.debug

    backend = BackendConfig(
        backend=settings.analysis_backend,
        codex_command=settings.codex_command,
        codex_model=settings.codex_model,
        codex_timeout_seconds=settings.codex_timeout_seconds,
        openai_base_url=settings.openai_base_url,
        openai_api_key=settings.openai_api_key,
        openai_model=settings.openai_model,
        openai_timeout_seconds=settings.openai_timeout_seconds,
    )

    executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="tldrgpt")
    store = ConversationStore(
        source_data=settings.source_data,
        deleted_data=settings.deleted_data,
        backend=backend,
        executor=executor,
    )
    store.start_scan()

    @app.get("/")
    def index():
        return render_template("index.html")

    @app.get("/api/health")
    def health():
        return jsonify(
            {
                "ok": True,
                "sourceData": str(settings.source_data),
                "deletedData": str(settings.deleted_data),
                "scan": store.scan_status(),
                "backend": backend.backend,
                "model": backend.model,
                "endpoint": backend.endpoint,
                "backendAvailable": backend_available(backend),
            }
        )

    @app.post("/api/scan")
    def scan():
        store.start_scan()
        return jsonify(store.scan_status())

    @app.get("/api/conversations")
    def conversations():
        return jsonify({"conversations": store.list_conversations(), "scan": store.scan_status()})

    @app.get("/api/conversations/<path:record_id>/html")
    def conversation_html(record_id: str):
        try:
            record = store.get_record(record_id)
        except KeyError:
            abort(404)
        return send_file(record.html_path)

    @app.get("/api/conversations/<path:record_id>/analysis")
    def conversation_analysis(record_id: str):
        try:
            return jsonify(store.get_analysis(record_id))
        except KeyError:
            abort(404)

    @app.get("/api/conversations/<path:record_id>/json")
    def conversation_json(record_id: str):
        try:
            return jsonify(store.get_raw_json(record_id))
        except FileNotFoundError:
            return jsonify({"error": "No companion JSON exists for this conversation yet."}), 404
        except KeyError:
            abort(404)

    @app.post("/api/conversations/<path:record_id>/serialize")
    def serialize(record_id: str):
        try:
            json_path = store.ensure_serialized(record_id)
        except KeyError:
            abort(404)
        return jsonify({"ok": True, "jsonPath": str(json_path)})

    @app.post("/api/conversations/<path:record_id>/analyze")
    def analyze(record_id: str):
        try:
            store.get_record(record_id)
        except KeyError:
            abort(404)
        store.analyze(record_id)
        return jsonify({"ok": True, "queued": True})

    @app.post("/api/analyze-all")
    def analyze_all():
        return jsonify({"ok": True, "queued": store.analyze_all_unanalyzed()})

    @app.delete("/api/conversations/<path:record_id>")
    def delete_conversation(record_id: str):
        try:
            store.soft_delete(record_id)
        except KeyError:
            abort(404)
        return jsonify({"ok": True})

    @app.errorhandler(404)
    def not_found(_error):
        if request.path.startswith("/api/"):
            return jsonify({"error": "Not found"}), 404
        return "Not found", 404

    return app
