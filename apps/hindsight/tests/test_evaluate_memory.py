import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
from scripts import evaluate_memory

SECRET = "非公開の本文"


class Hindsight:
    def __init__(self, clone_status="completed", documents=()):
        self.calls = []
        self.clone_status = clone_status
        self.documents = list(documents)
        self.polls = 0

    def __call__(self, method, path, body=None, query=None):
        self.calls.append((method, path, body, query))
        if path == "source/clone":
            return {"operation_id": "clone-op"}
        if path == "source/operations/clone-op":
            self.polls += 1
            return {"status": "processing" if self.polls == 1 else self.clone_status}
        if path.endswith("/operations"):
            return {"total": 0, "operations": []}
        if path.endswith("/documents"):
            page = self.documents[query["offset"] : query["offset"] + 2]
            return {"items": [{"id": document} for document in page], "total": len(self.documents)}
        if path.endswith("/memories/recall"):
            return self.recall(body)
        return {}

    def recall(self, body):
        if body["query"] == "q1" and "observation" not in body["types"]:
            results = [{"document_id": "meeting-x", "text": SECRET}, {"document_id": "meeting-a", "text": SECRET}]
            return {"results": results}
        if body["query"] == "q2" and "observation" in body["types"]:
            observation = {"type": "observation", "text": SECRET, "source_fact_ids": ["f1"]}
            return {"results": [observation], "source_facts": {"f1": {"document_id": "meeting-b", "text": SECRET}}}
        if body["query"] == "q3":
            raise evaluate_memory.EvaluationError("POST request failed with HTTP 500")
        return {"results": []}


def test_reports_only_numbers_and_deletes_the_clone():
    hindsight = Hindsight()
    questions = [("q1", {"meeting-a"}), ("q2", {"meeting-b"}), ("q3", {"meeting-c"})]
    result = evaluate_memory.evaluate(hindsight, "source", questions, ks=(1, 2), sleep=lambda seconds: None)

    baseline, observed = result["variants"]
    assert (baseline["observations"], observed["observations"]) == (False, True)
    assert baseline["hit_at"] == {"1": 0.0, "2": 0.3333} and baseline["mrr"] == 0.1667
    assert observed["hit_at"] == {"1": 0.3333, "2": 0.3333} and observed["mrr"] == 0.3333
    assert baseline["errors"] == observed["errors"] == 1
    output = json.dumps(result, ensure_ascii=False)
    assert SECRET not in output and "q1" not in output and "meeting-" not in output

    method, path, _, query = hindsight.calls[0]
    clone = query["target_bank_id"]
    assert (method, path) == ("POST", "source/clone") and clone.startswith("eval-")
    assert query["include_history"] == "false"
    assert hindsight.calls[-1][:2] == ("DELETE", clone)
    recalls = [body for _, path, body, _ in hindsight.calls if path.endswith("/memories/recall")]
    assert all(path.startswith(clone) for _, path, _, _ in hindsight.calls[1:] if not path.startswith("source/"))
    assert recalls[0] == {**evaluate_memory.DAHLIA_RECALL, "query": "q1", "include": {"entities": None}}
    assert recalls[3]["prefer_observations"] and recalls[3]["include"]["source_facts"] == {}


def test_a_failed_clone_is_still_deleted():
    hindsight = Hindsight(clone_status="failed")
    with pytest.raises(evaluate_memory.EvaluationError, match="failed"):
        evaluate_memory.evaluate(hindsight, "source", [("q1", {"meeting-a"})], sleep=lambda seconds: None)
    assert hindsight.calls[-1][0] == "DELETE"
    assert not any(path.endswith("/memories/recall") for _, path, _, _ in hindsight.calls)


def test_extraction_and_reranking_variants_change_only_the_clone():
    hindsight = Hindsight(documents=["meeting-a", "meeting-b", "shared-c"])
    result = evaluate_memory.evaluate(
        hindsight,
        "source",
        [("q1", {"meeting-a"})],
        rerank=("on", "off"),
        observations=(False,),
        extraction={"retain_default_strategy": "meeting"},
        sleep=lambda seconds: None,
    )
    clone = hindsight.calls[0][3]["target_bank_id"]
    reprocessed = [path for method, path, _, _ in hindsight.calls if path.endswith("/reprocess")]
    assert reprocessed == [f"{clone}/documents/{document}/reprocess" for document in hindsight.documents]
    patches = [body for method, path, body, _ in hindsight.calls if method == "PATCH"]
    assert all(path.startswith(clone) for method, path, _, _ in hindsight.calls if method in ("PATCH", "DELETE"))
    assert patches == [
        {"updates": {"retain_default_strategy": "meeting"}},
        {"updates": {"enable_reranking": True}},
        {"updates": {"enable_reranking": False}},
    ]
    assert [variant["rerank"] for variant in result["variants"]] == ["on", "off"]


def test_questions_are_validated_without_echoing_them(tmp_path):
    path = tmp_path / "questions.jsonl"
    path.write_text(json.dumps({"query": SECRET, "expected": "meeting-a"}, ensure_ascii=False) + "\n")
    with pytest.raises(evaluate_memory.EvaluationError) as error:
        evaluate_memory.load_questions(path)
    assert SECRET not in str(error.value) and "line 1" in str(error.value)
    path.write_text(json.dumps({"query": SECRET, "expected": ["meeting-a"]}) + "\n\n")
    assert evaluate_memory.load_questions(path) == [(SECRET, {"meeting-a"})]


def test_http_client_sends_the_token_but_never_follows_redirects():
    seen = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            seen.append((self.path, self.headers.get("authorization")))
            if self.path.endswith("/moved"):
                self.send_response(307)
                self.send_header("location", "/elsewhere")
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"operation_id": "op"}')

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        send = evaluate_memory.http_client(f"http://127.0.0.1:{server.server_port}/api/", "token")
        assert send("POST", "bank/clone", query={"target_bank_id": "eval-1"}) == {"operation_id": "op"}
        with pytest.raises(evaluate_memory.EvaluationError, match="HTTP 307"):
            send("POST", "bank/moved", {})
    finally:
        server.shutdown()
    assert seen == [
        ("/api/v1/default/banks/bank/clone?target_bank_id=eval-1", "Bearer token"),
        ("/api/v1/default/banks/bank/moved", "Bearer token"),
    ]
