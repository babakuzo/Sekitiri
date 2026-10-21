#!/usr/bin/env python3
"""Evaluate local Sekitiri transcript exports against a consented fixture manifest.

Usage: python3 Tools/evaluate_transcription.py path/to/fixtures.json
       python3 Tools/evaluate_transcription.py --self-test

All paths are relative to the manifest. This tool reads local JSON/text only; it
does not load models, record audio, contact a service, or download anything.
WER compares spelling, so equivalent spoken/written numbers need human review.
"""

import argparse
import json
from pathlib import Path
import re
import sys
import unicodedata


def words(text):
    text = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    return re.findall(r"[^\W_]+(?:'[^\W_]+)*", text, flags=re.UNICODE)


def word_error_rate(reference, hypothesis):
    expected, actual = words(reference), words(hypothesis)
    if not expected:
        # Exact silence uses a strict sentinel score, since WER's normal
        # denominator is undefined: no recognized words = 0, any speech = 1.
        return 0 if not actual else 1
    row = list(range(len(actual) + 1))
    for i, expected_word in enumerate(expected, 1):
        next_row = [i]
        for j, actual_word in enumerate(actual, 1):
            next_row.append(min(next_row[-1] + 1, row[j] + 1,
                                row[j - 1] + (expected_word != actual_word)))
        row = next_row
    return row[-1] / len(expected)


def evaluate(manifest_path):
    manifest = json.loads(manifest_path.read_text())
    results = []
    for fixture in manifest["fixtures"]:
        export = json.loads((manifest_path.parent / fixture["transcript_file"]).read_text())
        hypothesis = " ".join(segment["text"] for segment in export["segments"])
        reference = fixture.get("reference")
        if reference is None:
            reference = (manifest_path.parent / fixture["reference_file"]).read_text()
        wer = word_error_rate(reference, hypothesis)
        normalized = " ".join(words(hypothesis))
        missing = [phrase for phrase in fixture.get("required_phrases", [])
                   if " ".join(words(phrase)) not in normalized]
        result = {"id": fixture["id"], "word_error_rate": round(wer, 4),
                  "missing_required_phrases": missing,
                  "passed": wer <= fixture.get("maximum_wer", 0.15) and not missing}
        recording = fixture.get("recording_seconds")
        processing = fixture.get("recognition_seconds")
        if recording and processing is not None:
            result["recognition_realtime_factor"] = round(processing / recording, 4)
        if fixture.get("after_stop_seconds") is not None:
            result["after_stop_seconds"] = fixture["after_stop_seconds"]
        results.append(result)
    if not results:
        raise ValueError("The manifest contains no fixtures")
    return results


def self_test():
    assert words("L’équipe, déjà! Let's go.") == ["l'équipe", "déjà", "let's", "go"]
    assert word_error_rate("one two three", "one two three") == 0
    assert word_error_rate("one two three", "one three") == 1 / 3
    assert word_error_rate("one two three", "one new two three") == 1 / 3
    assert word_error_rate("one two three", "one four three") == 1 / 3
    assert word_error_rate("Bonjour Emma, budget 450 euros.",
                           "bonjour emma budget 450 euros") == 0
    assert word_error_rate("", "") == 0
    assert word_error_rate("", "hallucinated speech") == 1
    print("Transcription evaluation self-tests passed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, nargs="?")
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    if arguments.self_test:
        self_test()
    elif arguments.manifest:
        try:
            report = evaluate(arguments.manifest)
            print(json.dumps({"fixtures": report}, ensure_ascii=False, indent=2))
            sys.exit(0 if all(case["passed"] for case in report) else 1)
        except (OSError, ValueError, KeyError, TypeError) as error:
            parser.exit(2, f"Cannot evaluate fixtures: {error}\n")
    else:
        parser.error("provide a fixture manifest or --self-test")
