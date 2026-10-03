#!/usr/bin/env python3
"""Score paired, locally produced Apple Speech/Whisper transcripts; never sends audio.
Input: JSON array of {id, language: ja|en, engine: apple|whisper, reference, original, decoded}.
This checks recognition accuracy only. Corpus coverage, codec timing, size and memory are separate gates.
"""
import argparse
import json
import re
import unicodedata
from collections import defaultdict


def tokens(text, language):
    normalized = unicodedata.normalize("NFKC", text).casefold()
    if language == "ja":
        return [c for c in normalized if not c.isspace() and not unicodedata.category(c).startswith("P")]
    return re.findall(r"\w+(?:'\w+)?", normalized)


def distance(reference, hypothesis):
    row = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        following = [i]
        for j, actual in enumerate(hypothesis, 1):
            following.append(min(following[-1] + 1, row[j] + 1, row[j - 1] + (expected != actual)))
        row = following
    return row[-1]


def evaluate(samples):
    totals = defaultdict(lambda: [0, 0, 0])
    seen = set()
    details = []
    for sample in samples:
        language, engine = sample["language"], sample["engine"]
        if language not in {"ja", "en"} or engine not in {"apple", "whisper"}:
            raise ValueError("Expected ja/en and apple/whisper")
        key = (sample["id"], language, engine)
        if key in seen:
            raise ValueError("Duplicate sample/engine")
        seen.add(key)
        reference = tokens(sample["reference"], language)
        if not reference:
            raise ValueError("Reference must contain scored text")
        original = distance(reference, tokens(sample["original"], language))
        decoded = distance(reference, tokens(sample["decoded"], language))
        delta = 100 * (decoded - original) / len(reference)
        details.append({"id": sample["id"], "language": language, "engine": engine, "delta_pp": delta, "passed": delta <= 2})
        total = totals[(engine, language)]
        total[0] += len(reference)
        total[1] += original
        total[2] += decoded
    expected = {(engine, language) for engine in ("apple", "whisper") for language in ("ja", "en")}
    if set(totals) != expected:
        raise ValueError("Both engines and both languages are required")
    aggregates = [{"engine": engine, "language": language, "reference_units": count,
                   "original_error_percent": 100 * original / count,
                   "decoded_error_percent": 100 * decoded / count,
                   "delta_pp": 100 * (decoded - original) / count,
                   "passed": 100 * (decoded - original) / count <= 0.5}
                  for (engine, language), (count, original, decoded) in sorted(totals.items())]
    return {"passed": all(row["passed"] for row in details + aggregates), "aggregates": aggregates, "samples": details}


def self_test():
    assert distance(list("abc"), list("adc")) == 1
    assert distance([], list("abc")) == 3
    assert tokens("ＡＢＣ、 １２", "ja") == list("abc12")
    samples = [{"id": "sample", "language": language, "engine": engine, "reference": "one two", "original": "one two", "decoded": "one two"}
               for language in ("ja", "en") for engine in ("apple", "whisper")]
    assert evaluate(samples)["passed"]
    samples[0]["decoded"] = "wrong"
    assert not evaluate(samples)["passed"]
    try:
        evaluate(samples[:1])
    except ValueError:
        pass
    else:
        raise AssertionError("Missing engines/languages must fail")
    print("6 quality scorer checks passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", nargs="?")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.results:
        with open(args.results, encoding="utf-8") as source:
            report = evaluate(json.load(source))
        print(json.dumps(report, ensure_ascii=False, indent=2))
        raise SystemExit(0 if report["passed"] else 1)
    else:
        parser.error("Provide a results JSON file or --self-test")
