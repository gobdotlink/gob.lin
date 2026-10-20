#!/usr/bin/env python3
"""Score `goblin dictionary-eval` JSONL files with the GOB-14 dictionary-biasing metrics.

Each input file is one arm: one engine, one glossary, paired unbiased (`rawText`) and
biased (`text`) transcripts per clip. Metrics follow the GOB-14 research handoff:

- Name hits: the complete target spelling, ignoring case and punctuation ("post hog" is not "PostHog").
- Recovered / lost: target hits gained or lost against the same engine's unbiased output.
- Ordinary worsened: ordinary-control clips whose word-error count increased.
- Words damaged: reference words recognized correctly before biasing and wrong after,
  anywhere in any clip (including name-bearing sentences), excluding the target's own words.
- WER: literal word substitutions, deletions and insertions against the synthetic source text.

Zero damage means zero detected by this scorer on this dataset, not a general safety guarantee.
"""
import argparse
import json
import re
import statistics
import sys
from pathlib import Path


def words(text):
    return re.sub(r"[^\w\s']|_", " ", text.lower()).replace("'", "").split()


def alignment(reference, hypothesis):
    """Return (errors, set of reference positions matched exactly) for a minimum-edit alignment."""
    rows, cols = len(reference) + 1, len(hypothesis) + 1
    cost = [[0] * cols for _ in range(rows)]
    for i in range(rows):
        cost[i][0] = i
    for j in range(cols):
        cost[0][j] = j
    for i in range(1, rows):
        for j in range(1, cols):
            same = reference[i - 1] == hypothesis[j - 1]
            cost[i][j] = min(cost[i - 1][j - 1] + (0 if same else 1), cost[i - 1][j] + 1, cost[i][j - 1] + 1)
    matched, i, j = set(), len(reference), len(hypothesis)
    while i > 0 and j > 0:
        same = reference[i - 1] == hypothesis[j - 1]
        if cost[i][j] == cost[i - 1][j - 1] + (0 if same else 1):
            if same:
                matched.add(i - 1)
            i, j = i - 1, j - 1
        elif cost[i][j] == cost[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    return cost[-1][-1], matched


def contains(tokens, phrase):
    return any(tokens[k:k + len(phrase)] == phrase for k in range(len(tokens) - len(phrase) + 1))


def target_positions(reference, target):
    phrase = words(target)
    for k in range(len(reference) - len(phrase) + 1):
        if reference[k:k + len(phrase)] == phrase:
            return set(range(k, k + len(phrase)))
    return set()


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(fraction * (len(ordered) - 1)))]


def score(path, split=None):
    configuration, clips = None, []
    for line in Path(path).read_text().splitlines():
        record = json.loads(line)
        if record["recordType"] == "configuration":
            configuration = record
        elif record["recordType"] == "clip" and split in (None, record["split"]):
            clips.append(record)
    if configuration is None or not clips:
        sys.exit(f"{path}: missing configuration or clip records")
    result = {"file": Path(path).name, "engine": configuration["engine"], "method": configuration["method"],
              "terms": configuration["termCount"], "clips": len(clips),
              "boost": configuration.get("keytermBoost"), "names": 0, "rawNames": 0, "targets": 0,
              "recovered": 0, "lost": 0, "ordinary": 0, "ordinaryWorsened": 0, "damaged": 0,
              "rawErrors": 0, "errors": 0, "referenceWords": 0, "changed": 0, "damage": []}
    raw_ms, biased_ms, added_ms = [], [], []
    for clip in clips:
        reference, raw, biased = words(clip["reference"]), words(clip["rawText"]), words(clip["text"])
        raw_errors, raw_matched = alignment(reference, raw)
        errors, matched = alignment(reference, biased)
        result["rawErrors"] += raw_errors
        result["errors"] += errors
        result["referenceWords"] += len(reference)
        result["changed"] += raw != biased
        excluded = set()
        if clip["target"]:
            phrase = words(clip["target"])
            hit, raw_hit = contains(biased, phrase), contains(raw, phrase)
            result["targets"] += 1
            result["names"] += hit
            result["rawNames"] += raw_hit
            result["recovered"] += hit and not raw_hit
            result["lost"] += raw_hit and not hit
            excluded = target_positions(reference, clip["target"])
        else:
            result["ordinary"] += 1
            result["ordinaryWorsened"] += errors > raw_errors
        damaged = sorted((raw_matched - matched) - excluded)
        if damaged:
            result["damaged"] += len(damaged)
            result["damage"].append({"id": clip["id"], "words": [reference[k] for k in damaged],
                                     "raw": clip["rawText"], "text": clip["text"]})
        raw_ms.append(clip["rawMilliseconds"])
        biased_ms.append(clip["biasedMilliseconds"])
        added_ms.append(clip["biasedMilliseconds"] - clip["rawMilliseconds"])
    result["rawWER"] = result["rawErrors"] / result["referenceWords"]
    result["WER"] = result["errors"] / result["referenceWords"]
    result["rawMedianMilliseconds"] = statistics.median(raw_ms)
    result["biasedMedianMilliseconds"] = statistics.median(biased_ms)
    result["biasedP95Milliseconds"] = percentile(biased_ms, 0.95)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="+", help="dictionary-eval JSONL files, one arm each")
    parser.add_argument("--split", help="score only clips from this manifest split, e.g. original or fresh")
    parser.add_argument("--json", action="store_true", help="print full results, including damaged-word cases")
    arguments = parser.parse_args()
    results = [score(path, arguments.split) for path in arguments.files]
    if arguments.json:
        print(json.dumps(results, indent=2))
        return
    print("| Arm | Terms | Names (unbiased → biased) | Recovered / lost | Ordinary worsened | Words damaged | WER (unbiased → biased) | Median ms (unbiased → biased) | p95 biased ms |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for r in results:
        arm = r["engine"] + (f" boost {r['boost']:g}" if r["boost"] is not None else "") + f" ({r['file']})"
        print(f"| {arm} | {r['terms']} | {r['rawNames']} → {r['names']}/{r['targets']} | {r['recovered']} / {r['lost']} "
              f"| {r['ordinaryWorsened']}/{r['ordinary']} | {r['damaged']} | {r['rawWER']:.2%} → {r['WER']:.2%} "
              f"| {r['rawMedianMilliseconds']:.0f} → {r['biasedMedianMilliseconds']:.0f} | {r['biasedP95Milliseconds']:.0f} |")
    for r in results:
        for case in r["damage"]:
            print(f"\n{r['file']} damaged {case['words']} in {case['id']}:\n  unbiased: {case['raw']}\n  biased:   {case['text']}")


if __name__ == "__main__":
    main()
