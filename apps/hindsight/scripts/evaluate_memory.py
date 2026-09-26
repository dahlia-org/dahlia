"""Compare Dahlia Memory recall variants on a disposable clone of a Hindsight bank.

Operator-run. Only aggregate numbers are printed: questions, recalled text and
document content never leave this process. The clone is deleted afterwards.
"""

import argparse
import itertools
import json
import math
import os
import statistics
import sys
import time
import uuid
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

# The recall request Dahlia Server sends today (apps/server/src/memory/hindsight.ts).
DAHLIA_RECALL = {"types": ["world", "experience"], "budget": "mid", "max_tokens": 4096}
BUSY = ("pending", "processing")


class EvaluationError(RuntimeError):
    pass


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None  # Never forward the bearer token to another location.


def http_client(url, token, opener=None):
    opener = opener or build_opener(_RejectRedirect)
    base = url.rstrip("/") + "/v1/default/banks/"

    def send(method, path, body=None, query=None):
        headers = {"content-type": "application/json"} if body is not None else {}
        if token:
            headers["authorization"] = f"Bearer {token}"
        target = base + path + (f"?{urlencode(query)}" if query else "")
        data = None if body is None else json.dumps(body).encode()
        try:
            with opener.open(Request(target, data=data, method=method, headers=headers), timeout=120) as response:
                payload = response.read()
        except HTTPError as error:
            raise EvaluationError(f"{method} request failed with HTTP {error.code}") from None
        return json.loads(payload) if payload else None

    return send


def load_questions(path):
    questions = []
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            raise EvaluationError(f"line {number}: invalid JSON") from None
        query = item.get("query") if isinstance(item, dict) else None
        expected = item.get("expected") if isinstance(item, dict) else None
        if not isinstance(query, str) or not query.strip() or not isinstance(expected, list) or not expected:
            raise EvaluationError(f"line {number}: expected {{'query': str, 'expected': [document ID, ...]}}")
        if not all(isinstance(document, str) and document for document in expected):
            raise EvaluationError(f"line {number}: expected must list Hindsight document IDs")
        questions.append((query, set(expected)))
    if not questions:
        raise EvaluationError("the question file is empty")
    return questions


def document_ranks(response):
    """Rank of each recalled document by its first result.

    An observation counts for the documents its source facts came from, and they all share
    that result's rank; later documents rank after every document already listed.
    """
    sources = response.get("source_facts") or {}
    ranks, listed = {}, 0
    for result in response.get("results", []):
        if result.get("type") == "observation":
            documents = [(sources.get(fact) or {}).get("document_id") for fact in result.get("source_fact_ids") or []]
        else:
            documents = [result.get("document_id")]
        new = [document for document in dict.fromkeys(documents) if document and document not in ranks]
        ranks.update((document, listed + 1) for document in new)
        listed += len(new)
    return ranks


def recall_body(query, observations):
    body = {**DAHLIA_RECALL, "query": query, "include": {"entities": None}}
    if observations:
        body["types"] = [*DAHLIA_RECALL["types"], "observation"]
        body["prefer_observations"] = True
        body["include"]["source_facts"] = {}
    return body


def summarize(ranks, latencies, errors, ks):
    count = len(ranks)
    ordered = sorted(latencies)
    return {
        "hit_at": {str(k): round(sum(rank is not None and rank <= k for rank in ranks) / count, 4) for k in ks},
        "mrr": round(sum(1 / rank for rank in ranks if rank) / count, 4),
        "latency_ms": {
            "p50": round(statistics.median(ordered), 1) if ordered else None,
            "p95": round(ordered[math.ceil(0.95 * len(ordered)) - 1], 1) if ordered else None,
            "max": round(ordered[-1], 1) if ordered else None,
        },
        "errors": errors,
    }


def wait_operation(send, bank, operation_id, *, timeout, sleep):
    deadline = time.monotonic() + timeout
    while True:
        status = send("GET", f"{quote(bank, safe='')}/operations/{quote(operation_id, safe='')}")["status"]
        if status == "completed":
            return
        if status not in BUSY:
            raise EvaluationError(f"operation ended as {status}")
        if time.monotonic() > deadline:
            raise EvaluationError("timed out waiting for an operation")
        sleep(5)


def wait_idle(send, bank, *, timeout, sleep):
    deadline = time.monotonic() + timeout
    while any(
        send("GET", f"{quote(bank, safe='')}/operations", query={"status": status, "limit": 1})["total"]
        for status in BUSY
    ):
        if time.monotonic() > deadline:
            raise EvaluationError("timed out waiting for background work")
        sleep(5)


def reprocess(send, bank, updates, *, timeout, sleep):
    """Re-extract every document of the clone with a different extraction setting (calls the LLM)."""
    path = quote(bank, safe="")
    send("PATCH", f"{path}/config", {"updates": updates})
    operations, offset = [], 0
    while True:
        page = send("GET", f"{path}/documents", query={"limit": 100, "offset": offset})
        for document in page["items"]:
            operations.append(
                send("POST", f"{path}/documents/{quote(document['id'], safe='')}/reprocess")["operation_id"]
            )
        offset += len(page["items"])
        if not page["items"] or offset >= page["total"]:
            break
    # A failed re-extraction would leave stale documents under the requested setting's label.
    deadline = time.monotonic() + timeout
    for operation_id in operations:
        wait_operation(send, bank, operation_id, timeout=max(0, deadline - time.monotonic()), sleep=sleep)
    wait_idle(send, bank, timeout=max(0, deadline - time.monotonic()), sleep=sleep)


def evaluate(
    send,
    bank,
    questions,
    *,
    ks=(1, 3, 5, 10),
    rerank=("inherit",),
    observations=(False, True),
    extraction=None,
    keep_clone=False,
    timeout=1800,
    sleep=time.sleep,
    clock=time.perf_counter,
):
    clone = f"eval-{uuid.uuid4().hex}"
    clone_path = quote(clone, safe="")
    submitted = send(
        "POST",
        f"{quote(bank, safe='')}/clone",
        query={"target_bank_id": clone, "include_history": "false"},
    )
    try:
        wait_operation(send, bank, submitted["operation_id"], timeout=timeout, sleep=sleep)
        wait_idle(send, clone, timeout=timeout, sleep=sleep)
        if extraction:
            reprocess(send, clone, extraction, timeout=timeout, sleep=sleep)
        variants = []
        for reranking, observed in itertools.product(rerank, observations):
            if reranking != "inherit":
                send("PATCH", f"{clone_path}/config", {"updates": {"enable_reranking": reranking == "on"}})
            ranks, latencies, errors = [], [], 0
            for query, expected in questions:
                started = clock()
                try:
                    response = send("POST", f"{clone_path}/memories/recall", recall_body(query, observed))
                except EvaluationError:
                    errors += 1
                    ranks.append(None)
                    continue
                latencies.append((clock() - started) * 1000)
                ranked = document_ranks(response)
                ranks.append(min((ranked[document] for document in expected if document in ranked), default=None))
            variants.append({"rerank": reranking, "observations": observed, **summarize(ranks, latencies, errors, ks)})
        return {"questions": len(questions), "extraction": extraction, "variants": variants}
    finally:
        if not keep_clone:
            try:
                send("DELETE", clone_path)
            except EvaluationError as error:
                print(f"Clone {clone} was not deleted: {error}", file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="Hindsight API base URL, e.g. https://<app>/api")
    parser.add_argument("--bank", required=True, help="Source bank ID; it is cloned, never modified")
    parser.add_argument("--questions", required=True, help="JSONL of {query, expected}; keep it out of the repository")
    parser.add_argument("--k", default="1,3,5,10", help="Comma-separated cutoffs for hit@k")
    parser.add_argument("--rerank", choices=["inherit", "on", "off", "both"], default="inherit")
    parser.add_argument("--observations", choices=["off", "on", "both"], default="both")
    extraction = parser.add_mutually_exclusive_group()
    extraction.add_argument("--extraction-mode", help="Reprocess the clone with retain_extraction_mode (uses the LLM)")
    extraction.add_argument("--strategy", help="Reprocess the clone with a named retain strategy (uses the LLM)")
    parser.add_argument("--keep-clone", action="store_true", help="Keep the clone for inspection")
    parser.add_argument("--timeout", type=int, default=1800, help="Seconds to wait for each background phase")
    args = parser.parse_args(argv)
    updates = None
    if args.extraction_mode:
        updates = {"retain_extraction_mode": args.extraction_mode}
    elif args.strategy:
        updates = {"retain_default_strategy": args.strategy}
    try:
        result = evaluate(
            http_client(args.url, os.environ.get("HINDSIGHT_EVAL_TOKEN")),
            args.bank,
            load_questions(args.questions),
            ks=tuple(int(k) for k in args.k.split(",")),
            rerank=("on", "off") if args.rerank == "both" else (args.rerank,),
            observations={"off": (False,), "on": (True,), "both": (False, True)}[args.observations],
            extraction=updates,
            keep_clone=args.keep_clone,
            timeout=args.timeout,
        )
    except EvaluationError as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
