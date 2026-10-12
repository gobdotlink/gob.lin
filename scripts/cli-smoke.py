#!/usr/bin/env python3
"""Exercise the CLI protocol using synthetic fixtures and an isolated data root."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import wave

root = Path(__file__).resolve().parent.parent
binary_directory = Path(sys.argv[1]).resolve()
binary = binary_directory / "goblin"
fixtures = root / "Tests/EvaluationSmoke/fixtures"


def run(*arguments, status=0):
    result = subprocess.run([str(binary), *map(str, arguments)], capture_output=True, text=True, timeout=20)
    assert result.returncode == status, (arguments, result.returncode, result.stderr)
    return result


report = json.loads(run("eval", fixtures / "A.jsonl", fixtures / "B.jsonl", "--json").stdout)
assert report["alignedRecords"] == 2
assert report["a"]["wordErrorRate"] == 0.1 and report["b"]["wordErrorRate"] == 0.2
assert report["b"]["ordinaryWordFalseCorrections"] == 2
assert "-like +lisa" in run("eval", fixtures / "A.jsonl", fixtures / "B.jsonl").stdout

with tempfile.TemporaryDirectory(prefix="goblin-cli-smoke-") as temporary:
    scratch = Path(temporary)
    records_directory = scratch / "records"
    records_directory.mkdir()
    (records_directory / "clips.jsonl").write_bytes((fixtures / "A.jsonl").read_bytes())
    replay = [json.loads(line) for line in run("replay", records_directory, "--recorded").stdout.splitlines()]
    assert {record["id"] for record in replay} == {"ordinary", "jargon"}
    assert all(record["source"] == "recorded_transcript" for record in replay)
    assert replay[0]["rawText"] == "run day review after commit"
    (records_directory / "duplicate.jsonl").write_bytes((fixtures / "A.jsonl").read_bytes())
    assert run("replay", records_directory, "--recorded", status=1).stdout == ""

    history = scratch / "history"
    subprocess.run([str(binary_directory / "EvaluationSmoke"), "--history-fixture", str(history)], check=True, capture_output=True, timeout=20)
    exported = [json.loads(line) for line in run("replay", "history", "--recorded", "--history-dir", history).stdout.splitlines()]
    assert len(exported) == 2 and all(record["source"] == "recorded_transcript" for record in exported)
    assert {record["finalText"] for record in exported} == {"run day review after commit", "i like it at home"}

    audio = scratch / "synthetic-silence.wav"
    with wave.open(str(audio), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(16000)
        writer.writeframes(bytes(640))
    unavailable = run("transcribe", audio, status=3)
    assert unavailable.stdout == "" and json.loads(unavailable.stderr)["error"]["code"] == "engine_not_configured"
    assert json.loads(run("replay", scratch, status=3).stderr)["error"]["code"] == "engine_not_configured"

    invalid = scratch / "invalid.jsonl"
    invalid.write_text("{not json}\n")
    failure = json.loads(run("eval", invalid, fixtures / "B.jsonl", status=1).stderr)
    assert "line 1" in failure["error"]["message"]

assert json.loads(run("--unknown", status=2).stderr)["error"]["code"] == "usage"
print("CLI smoke passed: JSON/JSONL, recorded replay, isolated history export, ID-aligned eval, structured failures, honest missing-engine result.")
