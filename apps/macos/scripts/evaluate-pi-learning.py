#!/usr/bin/env python3
"""Score recorded synthetic model evaluations without connecting to a model or user account."""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path)
    args = parser.parse_args()
    fixtures = Path(__file__).resolve().parents[1] / "Tests/Fixtures/PiLearning/conversations.json"
    cases = json.loads(fixtures.read_text())
    rows = [json.loads(line) for line in args.results.read_text().splitlines() if line.strip()]
    if len({row["id"] for row in rows}) != len(rows):
        raise SystemExit("Duplicate result IDs")
    results = {row["id"]: row for row in rows}
    failures, hard_failures = [], []
    for case in cases:
        row = results.get(case["id"], {})
        misses = []
        for key, expected in case["expected"].items():
            if key == "hard_gate":
                continue
            if key.startswith("minimum_"):
                metric = key.removeprefix("minimum_")
                if row.get(metric, -1) < expected:
                    misses.append(key)
            elif key.startswith("maximum_"):
                metric = key.removeprefix("maximum_")
                if row.get(metric, float("inf")) > expected:
                    misses.append(key)
            elif row.get(key) != expected:
                misses.append(key)
        if misses:
            failures.append({"id": case["id"], "misses": misses})
            if case["expected"].get("hard_gate"):
                hard_failures.append(case["id"])
    print(json.dumps({"cases": len(cases), "passed": len(cases) - len(failures),
                      "failures": failures, "hard_gate_failures": hard_failures}, ensure_ascii=False, indent=2))
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
