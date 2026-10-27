#!/usr/bin/env bash
# Background half of the speech-to-text shadow comparison: transcribe one saved
# sample with the provider that did not answer the caller, ask a cheap judge
# which transcript is better, and append one row to the experiment CSV.
#
# Usage (started detached by bin/fm-deepgram-stt.sh; not a caller-facing tool):
#   fm-stt-shadow.sh <sample-dir> <primary-provider> <primary-ms> [<caller>]
#   fm-stt-shadow.sh --help
#
# <sample-dir> holds audio.<ext> and <primary>.json, the primary provider's raw
# answer. The other provider (deepgram or local) writes <other>.json beside it,
# its transcript is compared with the primary's raw transcript (vocabulary
# rewrites are not applied to either side), and the sample keeps
# deepgram.txt, local.txt and judge.txt for re-judging later.
#
# Samples take turns on the other provider (a lock in data/stt-experiment/),
# and its time is measured from the start of its turn.
#
# Judge: one call, given both transcripts as A and B in
# random order plus config/stt-vocabulary when present, answering A, B or tie
# with a one-line reason. `judge` in config/stt picks the model: `haiku`
# (claude-haiku-5-5 through the claude CLI), `luna` (openai-codex/gpt-6-luna
# through the pi CLI), or `auto` (the default), which asks quota-axi and tries
# first the candidate that is not exhausted_now with the higher spendPriority,
# then the other when that call fails. Reasoning is per model:
# `judge_effort_haiku` (claude --effort, default medium) and
# `judge_effort_luna` (pi --thinking, default xhigh). Each call runs in an empty temporary
# directory with no tools, settings, MCP servers or project instructions, and
# gives up after 180 seconds.
#
# Row (data/stt-experiment/results.csv, header written once): timestamp, source,
# audio_seconds, primary, deepgram_ms, local_ms, deepgram_status,
# local_status, winner, reason, judge_model, sample. A status is ok, down (the
# local engine is not running), or error; winner is deepgram, local, tie, or
# none when no judgement was made. source is <caller>, reduced to the name of
# the script or program it runs (unknown when absent).
#
# Exit: 0 once a row is written (whatever it records), 2 on bad usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-deepgram-lib.sh
. "$SCRIPT_DIR/fm-deepgram-lib.sh"

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
  exit 0
fi
[ "$#" -ge 3 ] && [ "$#" -le 4 ] && [ -d "$1" ] || {
  printf 'fm-stt-shadow: usage: fm-stt-shadow.sh <sample-dir> <primary> <primary-ms> [<caller>]\n' >&2
  exit 2
}

exec python3 - "$1" "$2" "$3" "${4:-}" "$SCRIPT_DIR" \
  "$FM_HOME/config/stt-vocabulary" "$(fm_stt_setting judge auto)" \
  "$(fm_stt_setting judge_effort_haiku medium)" "$(fm_stt_setting judge_effort_luna xhigh)" <<'PY'
import csv, datetime, fcntl, glob, json, os, random, subprocess, sys, tempfile, time

sample, primary, primary_ms, source, bindir, vocab_path, judge_pref, haiku_effort, luna_effort = sys.argv[1:10]
other = "local" if primary == "deepgram" else "deepgram"
# A caller command line names its script when it runs one, else its program.
words = source.split()
source = next((os.path.basename(w) for w in words if w.endswith(".sh")),
              os.path.basename(words[0]) if words else "unknown")
root = os.path.dirname(os.path.dirname(sample))
audio = (glob.glob(os.path.join(sample, "audio.*")) or [""])[0]

def note(msg):
    print(f"fm-stt-shadow: {os.path.basename(sample)}: {msg}", file=sys.stderr)

def text_of(path):
    try:
        data = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if isinstance(data, dict) and isinstance(data.get("text"), str):
        return data["text"].strip()
    try:
        return data["results"]["channels"][0]["alternatives"][0].get("transcript", "").strip()
    except (KeyError, IndexError, TypeError, AttributeError):
        return None

# The other provider, timed the same way the primary was.
env = dict(os.environ, FM_STT_SHADOW="false", FM_STT_PROVIDER=other)
if other == "local":
    cmd = [os.path.join(bindir, "fm-stt-local.sh"), "--json", audio]
else:
    cmd = [os.path.join(bindir, "fm-deepgram-stt.sh"), "--json", audio]
# One sample at a time, so the time is the engine's and not a queue's.
with open(os.path.join(root, ".shadow.lock"), "a") as lock, \
        open(os.path.join(sample, f"{other}.json"), "wb") as out:
    fcntl.flock(lock, fcntl.LOCK_EX)
    started = time.monotonic()
    rc = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=out, env=env).returncode
    other_ms = round((time.monotonic() - started) * 1000)
other_status = "ok" if rc == 0 else ("down" if other == "local" and rc == 3 else "error")

texts = {primary: text_of(os.path.join(sample, f"{primary}.json")),
         other: text_of(os.path.join(sample, f"{other}.json")) if rc == 0 else None}
for name, text in texts.items():
    if text is not None:
        open(os.path.join(sample, f"{name}.txt"), "w", encoding="utf-8").write(text + "\n")
status = {primary: "ok" if texts[primary] is not None else "error", other: other_status}
if rc == 0 and texts[other] is None:
    status[other] = "error"

def duration():
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                              "-of", "csv=p=0", audio], capture_output=True, text=True, timeout=30).stdout
        return f"{float(out.strip()):.1f}"
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    try:
        out = subprocess.run(["afinfo", audio], capture_output=True, text=True, timeout=30).stdout
        for line in out.splitlines():
            if "estimated duration" in line:
                return f"{float(line.split(':')[1].split()[0]):.1f}"
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        pass
    return ""

CANDIDATES = {
    "haiku": ("claude", "claude-haiku-5-5",
              lambda p: ["claude", "-p", "--model", "claude-haiku-5-5", "--effort", haiku_effort,
                         "--no-session-persistence", "--tools", "", "--setting-sources", "",
                         "--strict-mcp-config", "--system-prompt", "You judge speech-to-text transcripts.", p]),
    "luna": ("codex", "openai-codex/gpt-6-luna",
             lambda p: ["pi", "-p", "--model", "openai-codex/gpt-6-luna", "--thinking", luna_effort,
                        "--no-session", "--no-tools", "--no-mcp", "--no-extensions", "--no-skills",
                        "--no-context-files", "--no-prompt-templates",
                        "--system-prompt", "You judge speech-to-text transcripts.", p]),
}

def judge_order():
    if judge_pref in CANDIDATES:
        return [judge_pref] + [k for k in CANDIDATES if k != judge_pref]
    try:
        data = json.loads(subprocess.run(
            ["quota-axi", "--json", "--max-age", "5m", "--provider", "claude,codex"],
            capture_output=True, text=True, timeout=60).stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return ["haiku", "luna"]
    rank = {}
    for prov in data.get("providers", []):
        for avail in (prov.get("quotaSemantics") or {}).get("effectiveAvailability", []):
            if avail.get("scope") == "all_models":
                exhausted = (avail.get("runway") or {}).get("status") == "exhausted_now"
                prio = (avail.get("selection") or {}).get("spendPriority")
                rank[prov.get("provider")] = (not exhausted, prio if isinstance(prio, (int, float)) else float("-inf"))
    return sorted(CANDIDATES, key=lambda k: rank.get(CANDIDATES[k][0], (False, float("-inf"))), reverse=True)

def judge():
    try:
        vocab = open(vocab_path, encoding="utf-8", errors="replace").read().strip()
    except OSError:
        vocab = ""
    labels = [primary, other]
    random.shuffle(labels)
    prompt = (
        "Two speech-to-text engines transcribed the same short recording of one speaker "
        "talking to their software assistant. Decide which transcript more faithfully and "
        "usefully renders what was most likely said: correct words, names and terms, sensible "
        "punctuation. Ignore differences that do not change meaning. If both are equally good, "
        "answer tie.\n\n"
        + (f"Names and terms this speaker uses (a `heard => written` line shows the intended "
           f"spelling):\n{vocab}\n\n" if vocab else "")
        + f"Transcript A:\n{texts[labels[0]]}\n\nTranscript B:\n{texts[labels[1]]}\n\n"
        'Answer with one line of JSON only: {"winner": "A" | "B" | "tie", "reason": "<one short sentence>"}'
    )
    log = []
    for key in judge_order():
        _, model, build = CANDIDATES[key]
        with tempfile.TemporaryDirectory() as cwd:
            try:
                res = subprocess.run(build(prompt), cwd=cwd, stdin=subprocess.DEVNULL,
                                     capture_output=True, text=True, timeout=180)
            except (OSError, subprocess.SubprocessError) as exc:
                log.append(f"{model}: {exc}")
                continue
        out = res.stdout.strip()
        log.append(f"{model} exit {res.returncode}:\n{out}\n{res.stderr.strip()[-400:]}")
        if res.returncode != 0:
            continue
        start, end = out.find("{"), out.rfind("}")
        try:
            verdict = json.loads(out[start:end + 1])
            pick = str(verdict.get("winner", "")).strip().upper()
            reason = " ".join(str(verdict.get("reason", "")).split())
        except ValueError:
            continue
        mapping = {"A": labels[0], "B": labels[1], "TIE": "tie"}
        if pick in mapping:
            open(os.path.join(sample, "judge.txt"), "w", encoding="utf-8").write(
                f"A={labels[0]} B={labels[1]}\n" + "\n\n".join(log) + "\n")
            return mapping[pick], reason, model
    open(os.path.join(sample, "judge.txt"), "w", encoding="utf-8").write(
        f"A={labels[0]} B={labels[1]}\n" + "\n\n".join(log) + "\n")
    return "none", "judge failed", ""

if all(status[p] == "ok" for p in status):
    winner, reason, judge_model = judge()
else:
    winner, reason, judge_model = "none", f"{other} {status[other]}" if status[other] != "ok" else f"{primary} unreadable", ""

ms = {primary: primary_ms, other: str(other_ms)}
row = [datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), source, duration(),
       primary, ms["deepgram"], ms["local"], status["deepgram"], status["local"],
       winner, reason, judge_model, os.path.relpath(sample, root)]
header = ["timestamp", "source", "audio_seconds", "primary", "deepgram_ms", "local_ms",
          "deepgram_status", "local_status", "winner", "reason", "judge_model", "sample"]
results = os.path.join(root, "results.csv")
fd = os.open(results, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
with os.fdopen(fd, "a", newline="", encoding="utf-8") as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    writer = csv.writer(fh, lineterminator="\n")
    if fh.tell() == 0:
        writer.writerow(header)
    writer.writerow(row)
if winner == "none":
    note(reason)
PY
