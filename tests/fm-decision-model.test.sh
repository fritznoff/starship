#!/usr/bin/env bash
# Shared System One provider transport and calibration behavior, with stubbed HTTP.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-model)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import contextlib
import io
import json
import os
import pathlib
import runpy
import sys
import urllib.error
from unittest.mock import patch

root, home = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(root / "bin"))
from fm_decision_model import Client, KEYS, NoRedirect
(home / "config").mkdir()
(home / "state").mkdir()
account = "a" * 32
(home / ".env").write_text('export TYPESAFE_API_KEY="ts-test"\nCLOUDFLARE_API_KEY=cf-test\nOPENROUTER_API_KEY=or-test\nCLOUDFLARE_ACCOUNT_ID=' + account + '\n')
config = home / "config/decision-model.json"
payload = {"model": "jev-1.13.0", "state": {"example": "public"}, "questions": {
    "q": {"type": "noul", "instructions": "Is it true?"}}}
seen = []
mode = "normal"

class Response(io.BytesIO):
    pass

class Opener:
    def open(self, request, timeout):
        body = json.loads(request.data)
        seen.append((request.full_url, request.get_header("Authorization"), request.data, timeout))
        questions = body["questions"]
        answers = {}
        for name, question in questions.items():
            kind = question["type"]
            if kind == "noul":
                answers[name] = {"noul": 0.99}
            elif kind == "score":
                answers[name] = {"score": 2, "confidence": 0.99}
            else:
                choices = question["criteria"]
                choice = next(iter(choices))
                answers[name] = {"choice": choice, "confidence": 0.99,
                                 "probabilities": {k: int(k == choice) for k in choices}}
        result = {"model": body.get("model", "clef-flash"), "answers": answers,
                  "usage": {"input_tokens": 10, "output_tokens": 2}}
        if mode == "incomplete":
            result["answers"].pop(next(iter(answers)))
        if mode == "spoof":
            result.update(_decision_advisory=False, _decision_thresholds={"injection": 0})
        if request.full_url.startswith("https://api.cloudflare.com/"):
            result = {"success": mode != "failure", "result": result}
        return Response(json.dumps(result).encode())

def select(provider, model=None, thresholds=None):
    options = {}
    if model:
        options["model"] = model
    if thresholds is not None:
        options["thresholds"] = {model: thresholds}
    config.write_text(json.dumps({"provider": provider, "providers": {provider: options}}))

def reject(fn, message):
    try:
        fn()
    except (ValueError, TimeoutError, urllib.error.HTTPError):
        return
    raise AssertionError(message)

env = {"PATH": os.environ["PATH"], "HOME": str(home), "FM_HOME": str(home)}
with patch.dict(os.environ, env, clear=True), patch("urllib.request.build_opener", return_value=Opener()), contextlib.redirect_stderr(io.StringIO()):
    # Exact legacy model, URL, header, request serialization, answer shape and no new records.
    client = Client(home)
    body = client.call(payload, 5, "example", {"confidence": .6})
    assert seen[-1][:3] == ("https://api.typesafe.ai/v1/systemone", "Bearer ts-test", json.dumps(payload).encode())
    assert body == {"model": "jev-1.13.0", "answers": {"q": {"noul": .99}}, "usage": {"input_tokens": 10, "output_tokens": 2}}
    assert not (home / "state/decision-model-scores.jsonl").exists()
    assert client.thresholds("example", {"confidence": .6}) == {"confidence": .6}
    blank = home / "blank.env"
    blank.write_text("TYPESAFE_API_KEY=\nOPENROUTER_API_KEY=or-test\n")
    assert Client(home, env_file=blank).key == "", "empty assignment swallowed a different provider's credential"
    with patch.dict(os.environ, {"TYPESAFE_API_KEY": "env-wins"}):
        assert Client(home).key == "env-wins"
    reject(lambda: client.call(payload, 5, "example", {}, endpoint="https://evil.example/v1/systemone"), "cross-origin credential leak")
    reject(lambda: client.call(payload, 5, "example", {}, endpoint="https://api.typesafe.ai@evil.example/v1/systemone"), "userinfo credential leak")
    assert NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.example") is None

    select("workers-ai")
    client = Client(home)
    body = client.call(payload, 5, "example", {"confidence": .6}, endpoint="https://evil.example")
    assert seen[-1][0] == f"https://api.cloudflare.com/client/v4/accounts/{account}/ai/run/@cf/cloudflare/clef-flash"
    assert seen[-1][1] == "Bearer cf-test" and "model" not in json.loads(seen[-1][2])
    assert body["answers"] == {"q": {"noul": .99}} and body["_decision_advisory"]
    hundred = dict(payload, questions={f"q{i}": payload["questions"]["q"] for i in range(100)})
    seen.clear()
    body = client.call(hundred, 5, "example", {})
    assert [len(json.loads(row[2])["questions"]) for row in seen] == [64, 36]
    assert all(json.loads(row[2])["state"] == payload["state"] for row in seen)
    assert set(body["answers"]) == set(hundred["questions"])
    assert body["usage"] == {"input_tokens": 20, "output_tokens": 4}
    assert seen[1][3] <= seen[0][3] <= 5
    mode = "incomplete"
    reject(lambda: client.call(hundred, 5, "example", {}), "incomplete batch accepted")
    mode = "failure"
    reject(lambda: client.call(payload, 5, "example", {}), "unsuccessful Cloudflare envelope accepted")
    mode = "spoof"
    assert client.call(payload, 5, "example", {})["_decision_advisory"] is True
    mode = "normal"
    reject(lambda: client.call(payload, 0, "example", {}), "expired budget sent a request")

    select("openrouter", "cloudflare/clef-flash")
    seen.clear()
    body = Client(home).call(hundred, 5, "example", {})
    assert len(seen) == 2 and len(body["answers"]) == 100
    assert seen[0][0] == "https://openrouter.ai/api/v1/systemone" and seen[0][1] == "Bearer or-test"
    assert json.loads(seen[0][2])["model"] == "cloudflare/clef-flash"
    assert body["_decision_advisory"]
    select("typesafe", "jev-new")
    assert Client(home).call(payload, 5, "example", {})["_decision_advisory"]
    select("workers-ai", "clef-flash", {"example": {"confidence": .72}})
    assert Client(home).call(payload, 5, "example", {"confidence": .6})["_decision_thresholds"] == {"confidence": .72}
    select("workers-ai", "clef", {"example": {"confidence": .72}})
    select_cfg = json.loads(config.read_text())
    select_cfg["providers"]["workers-ai"]["model"] = "clef-flash"
    config.write_text(json.dumps(select_cfg))
    assert Client(home).call(payload, 5, "example", {"confidence": .6})["_decision_advisory"]
    for value in (True, -1, 1.01, float("nan")):
        select("workers-ai", "clef-flash", {"example": {"confidence": value}})
        reject(lambda: Client(home).call(payload, 5, "example", {"confidence": .6}), "invalid threshold accepted")
    select("workers-ai", "clef-flash", {"example": {}})
    reject(lambda: Client(home).call(payload, 5, "example", {"confidence": .6}), "incomplete thresholds accepted")
    with patch.dict(os.environ, {"CLOUDFLARE_ACCOUNT_ID": "../not-an-account"}):
        reject(lambda: Client(home), "account path injection")
    select("workers-ai")
    (home / ".env").write_text("TYPESAFE_API_KEY=ts-test\n")
    assert not Client(home).key, "TypeSafe key reused for Cloudflare"
    (home / ".env").write_text("CLOUDFLARE_API_KEY=cf-test\nCLOUDFLARE_ACCOUNT_ID=" + account)

    # Exercise real caller entry points, stubbing only HTTP (and Git diff for failure cause).
    def invoke(name, argv, stdin="", extra=None):
        output = io.StringIO()
        with patch.object(sys, "argv", [str(root / "bin" / name)] + argv), patch.object(sys, "stdin", io.StringIO(stdin)), contextlib.redirect_stdout(output), patch.dict(os.environ, extra or {}):
            try:
                runpy.run_path(str(root / "bin" / name), run_name="__main__")
            except SystemExit as error:
                assert error.code == 0, (name, error.code)
        return output.getvalue()

    guard = ["hook", "--home", str(home), "--config", str(home / "config"), "--state", str(home / "state"), "--task", "test", "--project", "demo"]
    (home / "config/command-guard").write_text("enabled = true\n")
    hook = json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push --force origin main"}})
    assert invoke("fm-command-guard.py", guard, hook) == "", "uncalibrated guard blocked"
    assert '"outcome": "advisory"' in (home / "state/command-guard.log").read_text(), (home / "state/command-guard.log").read_text()
    select("workers-ai", "clef-flash", {"command-guard": {"injection": 1, "irreversible": 1, "destructive": 1}})
    assert invoke("fm-command-guard.py", guard, hook) == "", "guard ignored configured thresholds"
    select("workers-ai", "clef-flash", {"command-guard": {"injection": .8, "irreversible": .6, "destructive": .7}})
    assert "deny" in invoke("fm-command-guard.py", guard, hook), "configured guard did not enforce"
    select("workers-ai")
    # The local database list remains enforced, even in advisory mode and without a key.
    assert "deny" in invoke("fm-command-guard.py", guard, json.dumps({"tool_name": "Bash", "tool_input": {"command": "psql -c 'DROP TABLE users'"}}))

    records = "test\tworking: migration deleted production users\n"
    assert invoke("fm-triage-second-look.py", [], records) == "", "uncalibrated triage promoted"
    seen.clear()
    scan = "".join(f"test-{i}\tworking: migration {i} deleted production users\n" for i in range(25))
    assert invoke("fm-triage-second-look.py", [], scan) == ""
    assert [len(json.loads(row[2])["questions"]) for row in seen] == [64, 36], "real 100-question status scan was not fully batched"
    select("workers-ai", "clef-flash", {"triage-second-look": {"needs_captain": 1, "adverse_event": 1, "understated_terminal": 1, "urgency": 2, "confidence": 1}})
    assert invoke("fm-triage-second-look.py", [], records) == "", "triage ignored configured thresholds"
    select("workers-ai", "clef-flash", {"triage-second-look": {"needs_captain": .9, "adverse_event": .9, "understated_terminal": .9, "urgency": 1.6, "confidence": .5}})
    assert "\talert\t" in invoke("fm-triage-second-look.py", [], records)
    select("workers-ai")
    failures = home / "failures.tsv"
    tail = home / "failure.log"
    tail.write_text("public fixture failure")
    failures.write_text("tests/example.test.sh\t" + str(tail) + "\n")
    with patch("subprocess.run") as git:
        git.return_value.returncode = 0
        git.return_value.stdout = b""
        assert invoke("fm-test-failure-cause.py", ["--root", str(home), str(failures)]) == ""
        select("workers-ai", "clef-flash", {"test-failure-cause": {"confidence": 1}})
        assert "unclear" in invoke("fm-test-failure-cause.py", ["--root", str(home), str(failures)]), "failure labels ignored configured thresholds"
        select("workers-ai", "clef-flash", {"test-failure-cause": {"confidence": .9}})
        assert "code-bug" in invoke("fm-test-failure-cause.py", ["--root", str(home), str(failures)])
    text = (home / "state/decision-model-scores.jsonl").read_text()
    for secret in ("ts-test", "cf-test", "or-test", "git push", "public fixture failure", "production users"):
        assert secret not in text, "scores log leaked input or credential"
    assert {json.loads(line)["site"] for line in text.splitlines()} >= {"example", "command-guard", "triage-second-look", "test-failure-cause"}
print("PASS: default compatibility, three providers, batching, credential isolation and caller advisory/threshold behavior")
PY
pass "shared decision models use isolated credentials and model-specific thresholds"
