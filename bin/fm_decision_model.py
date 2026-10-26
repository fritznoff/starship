#!/usr/bin/env python3
"""Shared System One client; configuration contract: docs/configuration.md, Decision models.

Python: Client(home, env_file=None).call(payload, timeout, site, defaults, endpoint=None).
Shell: source fm-decision-model-lib.sh and use fm_decision_model --enabled, or
  fm_decision_model --output FILE --timeout SECONDS < request.json.
The shell entry returns the HTTP status, writes normalized JSON to FILE, and
keeps credentials in a descriptor, never argv or a subprocess environment.
Only the legacy TypeSafe origin (or loopback test endpoints) accepts overrides.
No redirects, retries, payload logging, or fallback to another provider.
"""
import argparse
import json
import math
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

KEYS = ("TYPESAFE_API_KEY", "CLOUDFLARE_API_KEY", "OPENROUTER_API_KEY")
PROVIDERS = {
    "typesafe": (KEYS[0], "jev-1.13.0", "https://api.typesafe.ai/v1/systemone"),
    "workers-ai": (KEYS[1], "clef-flash", "https://api.cloudflare.com/client/v4/accounts/{account}/ai/run/@cf/cloudflare/{model}"),
    "openrouter": (KEYS[2], "typesafe/jev-1.13", "https://openrouter.ai/api/v1/systemone"),
}


def env_values(path):
    """Read literals only; never source or evaluate a home .env."""
    path = pathlib.Path(path)
    try:
        if path.is_symlink() or not path.is_file():
            return {}
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    values = {}
    for match in re.finditer(r"(?m)^(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(.*)$", text):
        raw = match.group(2).strip()
        if raw[:1] in "'\"" and raw[-1:] == raw[:1] and len(raw) >= 2:
            raw = raw[1:-1]
        elif " #" in raw:
            raw = raw.split(" #", 1)[0].rstrip()
        values[match.group(1)] = raw.strip()
    return values


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, home, env_file=None, keys=None):
        self.home = pathlib.Path(home)
        config = pathlib.Path(os.environ.get("FM_CONFIG_OVERRIDE") or self.home / "config") / "decision-model.json"
        if config.is_symlink():
            raise ValueError("decision-model config must not be a symlink")
        cfg = json.loads(config.read_text()) if config.exists() else {}
        self.provider = cfg.get("provider", "typesafe")
        if self.provider not in PROVIDERS:
            raise ValueError("unknown decision-model provider")
        self.options = cfg.get("providers", {}).get(self.provider, {})
        key_name, default_model, self.url = PROVIDERS[self.provider]
        self.model = self.options.get("model", default_model)
        if not isinstance(self.model, str) or not re.fullmatch(r"[A-Za-z0-9@_./:~-]+", self.model):
            raise ValueError("invalid decision-model model")
        self.values = env_values(env_file or self.home / ".env")
        source = os.environ if keys is None else keys
        self.key = (source.get(key_name, "").strip() if keys is None else source.get(key_name, "")) or self.values.get(key_name, "")
        if "\n" in self.key or "\r" in self.key or len(self.key) > 2048:
            raise ValueError("invalid decision-model credential")
        self.baseline = self.provider == "typesafe" and self.model == "jev-1.13.0"
        # Clef's cap applies on gateways too. TypeSafe has no question-count cap.
        self.cap = 64 if self.provider == "workers-ai" or "clef" in self.model.lower() else None
        if self.provider == "workers-ai":
            account = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "").strip() or self.values.get("CLOUDFLARE_ACCOUNT_ID", "")
            if self.key and not re.fullmatch(r"[a-fA-F0-9]{32}", account):
                raise ValueError("Workers AI requires a Cloudflare account id")
            if not re.fullmatch(r"[A-Za-z0-9_-]+", self.model):
                raise ValueError("Workers AI model must be a Cloudflare model basename")
            self.url = self.url.format(account=account, model=self.model)

    def thresholds(self, site, defaults):
        configured = self.options.get("thresholds", {}).get(self.model, {}).get(site)
        if configured is None:
            return dict(defaults) if self.baseline else None
        if not isinstance(configured, dict) or configured.keys() != defaults.keys():
            raise ValueError("thresholds must name every threshold for this call site")
        for name, value in configured.items():
            maximum = 2 if name == "urgency" else 1
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 <= value <= maximum:
                raise ValueError("decision-model threshold out of range")
        return configured

    def endpoint(self, override):
        if not override or self.provider != "typesafe":
            return self.url
        url = urllib.parse.urlsplit(override)
        origin = (url.scheme, url.hostname, url.port)
        if url.username or url.password or url.fragment or not (
            origin == ("https", "api.typesafe.ai", None)
            or (url.scheme == "http" and url.hostname in ("127.0.0.1", "::1", "localhost"))
        ):
            raise ValueError("TypeSafe endpoint override must keep its origin (or use loopback for tests)")
        return override

    def call(self, payload, timeout, site, defaults, endpoint=None, transport=None, raw=None):
        if not self.key:
            raise ValueError("no decision-model credential")
        thresholds = self.thresholds(site, defaults)
        url = self.endpoint(endpoint)
        if not self.baseline:
            sys.stderr.write("decision-model: uncalibrated provider/model; %s\n" % (
                "advisory only (no thresholds configured)" if thresholds is None else "using configured thresholds"))
        questions = list(payload["questions"])
        cap = self.cap or max(1, len(questions))
        batches = [questions[i:i + cap] for i in range(0, len(questions), cap)]
        if not batches:
            raise ValueError("no decision-model questions")
        deadline = time.monotonic() + timeout
        bodies = []
        for batch in batches:
            request = dict(payload, model=self.model, questions={q: payload["questions"][q] for q in batch})
            if self.provider == "workers-ai":
                request.pop("model", None)
            # Preserve the default shell request bytes as well as the Python serialization.
            data = raw if raw is not None and self.baseline and len(batches) == 1 else json.dumps(request).encode("utf-8")
            remaining = timeout if self.baseline and len(batches) == 1 else deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("decision-model deadline")
            body = (transport or self._post)(url, data, remaining)
            if self.provider == "workers-ai":
                if body.get("success") is not True:
                    raise ValueError("Workers AI request failed")
                body = body.get("result")
            if self.baseline and len(batches) == 1 and thresholds == defaults:
                # Legacy callers own answer validation and its diagnostic wording.
                if isinstance(body, dict):
                    body.pop("_decision_thresholds", None)
                    body.pop("_decision_advisory", None)
                return body
            if not isinstance(body, dict) or not isinstance(body.get("answers"), dict):
                raise ValueError("missing decision-model answers")
            if len(batches) > 1 and set(body["answers"]) != set(batch):
                raise ValueError("incomplete decision-model batch")
            bodies.append(body)
        result = dict(bodies[0])
        if len(bodies) > 1:
            result["answers"] = {q: b["answers"][q] for b in bodies for q in b["answers"]}
            result["usage"] = {k: sum(b.get("usage", {}).get(k, 0) for b in bodies)
                               for k in ("input_tokens", "output_tokens")}
        # Metadata from the server must never authorize action on an uncalibrated model.
        result.pop("_decision_thresholds", None)
        result.pop("_decision_advisory", None)
        if not self.baseline or thresholds != defaults:
            result["_decision_thresholds"] = thresholds
            result["_decision_advisory"] = thresholds is None
        if not self.baseline:
            self._record(site, payload, result, thresholds)
        return result

    def _post(self, url, data, timeout):
        request = urllib.request.Request(url, data=data, headers={
            "Authorization": "Bearer %s" % self.key, "Content-Type": "application/json"})
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8", errors="replace"))

    def _record(self, site, payload, result, thresholds):
        # Scores only: never state, instructions, credentials or arbitrary response text.
        scores = {}
        for q, question in payload["questions"].items():
            answer = result["answers"].get(q)
            if not isinstance(answer, dict):
                continue
            scores[q] = {k: v for k, v in answer.items() if k in ("noul", "score", "confidence")
                         and type(v) in (int, float) and math.isfinite(v)}
            criteria = question.get("criteria", {})
            if question.get("type") == "choice" and answer.get("choice") in criteria:
                scores[q]["choice"] = answer["choice"]
                scores[q]["probabilities"] = {k: v for k, v in answer.get("probabilities", {}).items()
                                               if k in criteria and type(v) in (int, float) and math.isfinite(v)}
        record = dict(at=int(time.time()), provider=self.provider, model=self.model,
                      site=site, thresholds=thresholds, advisory=thresholds is None, scores=scores)
        path = pathlib.Path(os.environ.get("FM_STATE_OVERRIDE") or self.home / "state") / "decision-model-scores.jsonl"
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
            with os.fdopen(fd, "a") as handle:
                if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                    return
                handle.write(json.dumps(record) + "\n")
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True)
    parser.add_argument("--key-fd", type=int, required=True)
    parser.add_argument("--enabled", action="store_true")
    parser.add_argument("--output")
    parser.add_argument("--timeout", type=float, default=5)
    args = parser.parse_args()
    try:
        with os.fdopen(args.key_fd) as keys:
            values = keys.read().splitlines()
            if len(values) != len(KEYS):
                raise ValueError("invalid credential descriptor")
            client = Client(args.home, keys=dict(zip(KEYS, values)))
        if args.enabled:
            return 0 if client.key else 1
        raw = sys.stdin.buffer.read()
        payload = json.loads(raw)
        raw_response = None
        # Keep curl as dispatch's transport (including its HTTP-status contract).
        def post(url, data, timeout):
            nonlocal raw_response
            read_fd, write_fd = os.pipe()
            try:
                os.write(write_fd, ("Authorization: Bearer %s\n" % client.key).encode())
            finally:
                os.close(write_fd)
            with os.fdopen(read_fd, "rb") as header, tempfile.TemporaryDirectory() as tmp:
                path = str(pathlib.Path(tmp) / "response")
                proc = subprocess.run([
                    "curl", "-sS", "--max-time", "%g" % timeout, "-o", path, "-w", "%{http_code}",
                    "-X", "POST", url, "-H", "Content-Type: application/json", "-H", "@/dev/fd/%d" % header.fileno(),
                    "--data-binary", "@-"], input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    pass_fds=(header.fileno(),), timeout=timeout + 0.5,
                    env={k: v for k, v in os.environ.items() if k not in KEYS})
                code = int(proc.stdout) if proc.returncode == 0 and proc.stdout.isdigit() else 0
                if code != 200:
                    raise urllib.error.HTTPError(url, code, "decision-model HTTP error", {}, None)
                text = pathlib.Path(path).read_text()
                body = json.loads(text)
                if isinstance(body, dict) and not any(k.startswith("_decision_") for k in body):
                    raw_response = text
                return body
        result = client.call(payload, args.timeout, "dispatch", {"confidence": 0.6, "scope": 0.5}, transport=post, raw=raw)
        unchanged = client.baseline and client.thresholds("dispatch", {"confidence": 0.6, "scope": 0.5}) == {"confidence": 0.6, "scope": 0.5}
        pathlib.Path(args.output).write_text(raw_response if unchanged and raw_response is not None else json.dumps(result))
        print("200", end="")
        return 0
    except urllib.error.HTTPError as error:
        print("%03d" % error.code, end="")
        return 0
    except Exception as error:
        # Exception text can contain server-supplied content or credentials.
        sys.stderr.write("decision-model: %s\n" % type(error).__name__)
        return 2


if __name__ == "__main__":
    sys.exit(main())
