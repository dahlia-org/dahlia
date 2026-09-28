import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
from scripts import evaluate_memory

SECRET = "非公開の本文"


class Hindsight:
    def __init__(self, clone_status="completed", documents=(), reprocess_status=None):
        self.calls = []
        self.clone_status = clone_status
        self.documents = list(documents)
        self.reprocess_status = reprocess_status or {}
        self.polls = 0
        self.banks = set()

    def __call__(self, method, path, body=None, query=None):
        self.calls.append((method, path, body, query))
        if path.endswith("/config") and method == "GET":
            bank = path.removesuffix("/config")
            if bank not in self.banks:
                raise evaluate_memory.EvaluationError("GET request failed with HTTP 404", 404)
            return {"bank_id": bank}
        if path == "source/clone":
            self.banks.add(query["target_bank_id"])
            return {"operation_id": "clone-op"}
        if path == "source/operations/clone-op":
            self.polls += 1
            return {"status": "processing" if self.polls == 1 else self.clone_status}
        if path.endswith("/operations"):
            return {"total": 0, "operations": []}
        if "/operations/reprocess-" in path:
            return {"status": self.reprocess_status.get(path.rsplit("/", 1)[-1], "completed")}
        if path.endswith("/reprocess"):
            # Re-extraction rewrites the document, which moves it in the updated_at-ordered listing.
            document = path.split("/")[-2]
            self.documents.remove(document)
            self.documents.append(document)
            return {"operation_id": f"reprocess-{document}"}
        if path.endswith("/documents"):
            page = self.documents[query["offset"] : query["offset"] + 2]
            return {"items": [{"id": document} for document in page], "total": len(self.documents)}
        if path.endswith("/memories/recall"):
            return self.recall(body)
        return {}

    def recall(self, body):
        if body["query"] == "q1" and "observation" not in body["types"]:
            results = [
                {"document_id": "mtg_00000000000000000000000001", "text": SECRET},
                {"document_id": "mtg_00000000000000000000000002", "text": SECRET},
            ]
            return {"results": results}
        if body["query"] == "q2" and "observation" in body["types"]:
            # The expected document is the second source of the top observation.
            observation = {"type": "observation", "text": SECRET, "source_fact_ids": ["f0", "f1"]}
            sources = {
                "f0": {"document_id": "mtg_00000000000000000000000007"},
                "f1": {"document_id": "mtg_00000000000000000000000003", "text": SECRET},
            }
            return {"results": [observation], "source_facts": sources}
        if body["query"] == "q3":
            raise evaluate_memory.EvaluationError("POST request failed with HTTP 500")
        return {"results": []}


def test_reports_only_numbers_and_deletes_the_clone():
    hindsight = Hindsight()
    questions = [
        ("q1", {"mtg_00000000000000000000000002"}),
        ("q2", {"mtg_00000000000000000000000003"}),
        ("q3", {"mtg_00000000000000000000000004"}),
    ]
    result = evaluate_memory.evaluate(hindsight, "source", questions, ks=(1, 2), sleep=lambda seconds: None)

    baseline, observed = result["variants"]
    assert (baseline["observations"], observed["observations"]) == (False, True)
    assert baseline["hit_at"] == {"1": 0.0, "2": 0.3333} and baseline["mrr"] == 0.1667
    assert observed["hit_at"] == {"1": 0.0, "2": 0.3333} and observed["mrr"] == 0.1667
    assert baseline["errors"] == observed["errors"] == 1
    output = json.dumps(result, ensure_ascii=False)
    assert SECRET not in output and "q1" not in output and "mtg_" not in output

    method, path, _, query = next(call for call in hindsight.calls if call[1] == "source/clone")
    clone = query["target_bank_id"]
    assert (method, path) == ("POST", "source/clone") and clone.startswith("dahlia_eval_")
    assert query["include_history"] == "false"
    assert hindsight.calls[-1][:2] == ("DELETE", clone)
    recalls = [body for _, path, body, _ in hindsight.calls if path.endswith("/memories/recall")]
    assert all(path.startswith(clone) for _, path, _, _ in hindsight.calls[1:] if not path.startswith("source/"))
    assert recalls[0] == {
        **evaluate_memory.DAHLIA_RECALL,
        "query": "q1",
        "include": {"entities": None, "chunks": {"max_tokens": 8192}},
    }
    assert recalls[3]["prefer_observations"] and recalls[3]["include"]["source_facts"] == {}


def test_observation_sources_have_distinct_ranks_within_the_five_document_limit():
    response = {
        "results": [
            {"type": "observation", "source_fact_ids": ["f1", "f2", "missing"]},
            {"type": "world", "document_id": "mtg_00000000000000000000000004"},
            {"type": "experience", "document_id": "mtg_00000000000000000000000002"},
            {"type": "observation", "source_fact_ids": ["f3"]},
        ],
        "source_facts": {
            "f1": {"document_id": "mtg_00000000000000000000000002"},
            "f2": {"document_id": "mtg_00000000000000000000000003"},
            "f3": {"document_id": "mtg_00000000000000000000000005"},
        },
    }
    ranks = evaluate_memory.document_ranks(response)
    assert ranks == {
        "mtg_00000000000000000000000002": 1,
        "mtg_00000000000000000000000003": 2,
        "mtg_00000000000000000000000004": 3,
        "mtg_00000000000000000000000005": 4,
    }
    response = {
        "results": [{"type": "observation", "source_fact_ids": [str(i) for i in range(10)]}],
        "source_facts": {str(i): {"document_id": f"mtg_0000000000000000000000000{i}"} for i in range(10)},
    }
    assert evaluate_memory.document_ranks(response) == {f"mtg_0000000000000000000000000{i}": i + 1 for i in range(5)}


def test_a_failed_clone_is_still_deleted():
    hindsight = Hindsight(clone_status="failed")
    with pytest.raises(evaluate_memory.EvaluationError, match="failed"):
        evaluate_memory.evaluate(
            hindsight, "source", [("q1", {"mtg_00000000000000000000000002"})], sleep=lambda seconds: None
        )
    assert hindsight.calls[-1][0] == "DELETE"
    assert not any(path.endswith("/memories/recall") for _, path, _, _ in hindsight.calls)


def test_existing_evaluation_bank_is_never_modified_or_deleted():
    calls = []

    def send(method, path, body=None, query=None):
        calls.append((method, path))
        assert method == "GET" and path.endswith("/config")
        return {"bank_id": path.removesuffix("/config")}

    with pytest.raises(evaluate_memory.EvaluationError, match="^memory_evaluation_bank_exists$"):
        evaluate_memory.evaluate(send, "source", [], sleep=lambda seconds: None)
    assert len(calls) == 1


@pytest.mark.parametrize("status", [401, 403, 503])
def test_failed_existence_check_never_creates_or_deletes_a_bank(status):
    calls = []

    def send(method, path, body=None, query=None):
        calls.append(method)
        raise evaluate_memory.EvaluationError("Synthetic failure", status)

    with pytest.raises(evaluate_memory.EvaluationError):
        evaluate_memory.evaluate(send, "source", [], sleep=lambda seconds: None)
    assert calls == ["GET"]


def test_unacknowledged_clone_is_not_deleted():
    calls = []

    def send(method, path, body=None, query=None):
        calls.append(method)
        if method == "GET":
            raise evaluate_memory.EvaluationError("Not found", 404)
        raise evaluate_memory.EvaluationError("Synthetic acknowledgement loss")

    with pytest.raises(evaluate_memory.EvaluationError):
        evaluate_memory.evaluate(send, "source", [], sleep=lambda seconds: None)
    assert calls == ["GET", "POST"]


def test_extraction_and_reranking_variants_change_only_the_clone():
    documents = [
        "mtg_00000000000000000000000002",
        "mtg_00000000000000000000000003",
        "smem_00000000000000000000000004",
        "mtg_00000000000000000000000005",
        "mtg_00000000000000000000000006",
    ]
    hindsight = Hindsight(documents=documents)
    result = evaluate_memory.evaluate(
        hindsight,
        "source",
        [("q1", {"mtg_00000000000000000000000002"})],
        rerank=("on", "off"),
        observations=(False,),
        extraction={"retain_default_strategy": "meeting"},
        sleep=lambda seconds: None,
    )
    clone = next(call[3]["target_bank_id"] for call in hindsight.calls if call[1] == "source/clone")
    reprocessed = [path for method, path, _, _ in hindsight.calls if path.endswith("/reprocess")]
    # Every document exactly once, although the listing reorders while pages are read.
    assert reprocessed == [f"{clone}/documents/{document}/reprocess" for document in documents]
    patches = [body for method, path, body, _ in hindsight.calls if method == "PATCH"]
    assert all(path.startswith(clone) for method, path, _, _ in hindsight.calls if method in ("PATCH", "DELETE"))
    assert patches == [
        {"updates": {"retain_default_strategy": "meeting"}},
        {"updates": {"enable_reranking": True}},
        {"updates": {"enable_reranking": False}},
    ]
    assert [variant["rerank"] for variant in result["variants"]] == ["on", "off"]


def test_a_failed_reprocess_stops_before_scoring():
    hindsight = Hindsight(
        documents=["mtg_00000000000000000000000002", "mtg_00000000000000000000000003"],
        reprocess_status={"reprocess-mtg_00000000000000000000000003": "failed"},
    )
    with pytest.raises(evaluate_memory.EvaluationError, match="failed"):
        evaluate_memory.evaluate(
            hindsight,
            "source",
            [("q1", {"mtg_00000000000000000000000002"})],
            extraction={"retain_extraction_mode": "verbose"},
            sleep=lambda seconds: None,
        )
    assert hindsight.calls[-1][0] == "DELETE"
    assert not any(path.endswith("/memories/recall") for _, path, _, _ in hindsight.calls)


def test_questions_are_validated_without_echoing_them(tmp_path):
    path = tmp_path / "questions.jsonl"
    path.write_text(
        json.dumps({"query": SECRET, "expected": "mtg_00000000000000000000000002"}, ensure_ascii=False) + "\n"
    )
    with pytest.raises(evaluate_memory.EvaluationError) as error:
        evaluate_memory.load_questions(path)
    assert SECRET not in str(error.value) and "line 1" in str(error.value)
    path.write_text(json.dumps({"query": SECRET, "expected": ["mtg_00000000000000000000000002"]}) + "\n\n")
    assert evaluate_memory.load_questions(path) == [(SECRET, {"mtg_00000000000000000000000002"})]


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
