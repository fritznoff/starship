#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-endpoint discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane (or,
# on t3code, which T3 thread) runs firstmate itself, both to inject escalations
# into it and, for the daemon, to validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.

# Default supervisor endpoint target/backend when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside both tmux and herdr.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# fm_supervisor_in_rex: this process runs directly inside a Rex block.
fm_supervisor_in_rex() {
  [ "${TERM_PROGRAM:-}" = rex ] && [ -n "${REX_SESSION:-}" ] && [ -n "${REX_BLOCK:-}" ]
}

# discover_supervisor_target: resolve the endpoint running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - uses the exact tmux target
#      forms owned by bin/fm-backend.sh's fm_backend_target_exists header, a
#      herdr "<session>:<pane-id>" target, or a T3 thread id (paired with
#      discover_supervisor_backend to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   4. TERM_PROGRAM=rex + $REX_SESSION + $REX_BLOCK - Rex injects them into every
#      block's process tree; compose the "<session-uuid>:<block-uuid>" target
#      bin/backends/rex.sh records (both ids without their kind prefix).
#      Checked after tmux and herdr, whose nested panes rewrite TERM_PROGRAM.
#   4b. The live T3 thread running in this home (discover_supervisor_t3code_thread)
#      - T3 puts nothing into the agent's environment, so this is a cwd match
#      over T3's live threads, consulted only when t3code is explicitly
#      selected and a T3 credential is configured.
#   5. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller can warn.
discover_supervisor_target() {
  local t3_thread
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  if fm_supervisor_in_rex; then
    printf '%s:%s' "${REX_SESSION#session:}" "${REX_BLOCK#block:}"
    return 0
  fi
  if t3_thread=$(discover_supervisor_t3code_thread); then
    printf '%s' "$t3_thread"
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_t3code_thread: the t3code rule both resolvers share.
# Cheap gate first so a home that never selected t3code makes no T3 call:
# explicit t3code selection (fm_backend_explicit_name) and a T3 credential
# (which carries the server origin) must both be present. Then the adapter's cwd
# match over this home (bin/backends/t3code.sh
# fm_backend_t3code_thread_for_home): exactly one live thread prints its id;
# none or an unreadable server returns 1 silently; more than one returns 2
# after the adapter has named the ids on stderr. Anything but 0 falls through.
discover_supervisor_t3code_thread() {
  command -v fm_backend_source >/dev/null 2>&1 || return 1
  [ "$(fm_backend_explicit_name)" = t3code ] || return 1
  fm_backend_source t3code 2>/dev/null || return 1
  [ -s "$(fm_backend_t3code_token_file)" ] || return 1
  fm_backend_t3code_thread_for_home "${FM_HOME:-.}"
}

# discover_supervisor_backend: resolve the supervisor endpoint's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux, herdr, rex, or t3code) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. TERM_PROGRAM=rex (with $REX_SESSION and $REX_BLOCK present) - rex.
#   4b. A live T3 thread in this home - t3code (stderr quiet here; the target
#      resolver reports an ambiguity once).
#   5. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  if fm_supervisor_in_rex; then
    printf 'rex'
    return 0
  fi
  if discover_supervisor_t3code_thread >/dev/null 2>&1; then
    printf 't3code'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}

# Optional primary routing hint, never ownership authority. From the owning
# primary's tool shell (also usable once after startup):
#   source /path/to/bin/fm-supervisor-target-lib.sh
#   fm_supervisor_publish_primary_pane /absolute/home/state
# state/.primary-pane is optional JSON: schema=1, pid (decimal string),
# start (kernel start ticks, or UTC/C-locale ps lstart), route (only keys below).
# Symlinks, non-private records and unsafe routing values are refused.
# Publication requires existing verified session ownership. Only inherited tmux
# and Herdr routing keys are saved, privately and atomically; no argv or secrets.
# Readers require the same live lock PID and process start identity. Unsupported
# routes or optional IO failures leave ordinary startup/mailbox delivery intact.
_FM_SUPERVISOR_LIB_DIR=$(dirname "${BASH_SOURCE[0]}")
fm_supervisor_publish_primary_pane() (  # <state-dir>
  local pid
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$_FM_SUPERVISOR_LIB_DIR/fm-session-lock-lib.sh"
  [ -f "$1/.lock" ] && [ ! -L "$1/.lock" ] || return 1
  pid=$(cat "$1/.lock") || return 1
  fm_session_lock_owned_by_self "$1" || return 1
  _fm_supervisor_primary_pane_record publish "$1" "$pid"
)

fm_supervisor_read_primary_pane() {  # <state-dir> <live-holder-pid>
  _fm_supervisor_primary_pane_record read "$1" "$2"
}

# JSON is data only: bounded no-follow reads, exact schema, allowlisted values.
# Keep process identity independent of argv, which title-rewriting can obscure.
_fm_supervisor_primary_pane_record() {  # <publish|read> <state-dir> <pid>
  python3 - "$@" <<'PYCODE'
import json, os, re, stat, subprocess, sys, tempfile

keys = {"TMUX", "TMUX_PANE", "HERDR_ENV", "HERDR_PANE_ID",
        "HERDR_SESSION", "HERDR_SOCKET_PATH"}
action, state, pid = sys.argv[1:]

def require(ok):
    if not ok:
        raise ValueError("invalid primary pane hint")

def read_file(path, private=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "r") as f:
        s = os.fstat(f.fileno())
        require(stat.S_ISREG(s.st_mode) and s.st_uid == os.getuid())
        require(not (s.st_mode & (0o077 if private else 0o022)))
        data = f.read(8193)
        require(len(data) <= 8192)
        return data

def identity():
    os.kill(int(pid), 0)
    proc = "/proc/" + pid + "/stat"
    if os.path.isfile(proc):
        with open(proc) as f:
            return "starttime=" + f.read().rsplit(")", 1)[1].split()[19]
    env = dict(os.environ, LC_ALL="C", TZ="UTC0")
    start = subprocess.check_output(["ps", "-p", pid, "-o", "lstart="],
                                    env=env, text=True).strip()
    require(bool(start) and "\n" not in start)
    return "lstart=" + start

def lock_matches():
    require(read_file(os.path.join(state, ".lock")).strip() == pid)

def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        require(key not in obj)
        obj[key] = value
    return obj

def validate_route(route):
    require(isinstance(route, dict) and bool(route) and not (set(route) - keys))
    for key, value in route.items():
        require(isinstance(value, str) and 0 < len(value) <= 1024)
        require(all(c.isprintable() for c in value))
        if key == "TMUX_PANE":
            require(re.fullmatch(r"%[0-9]+", value))
        elif key == "HERDR_ENV":
            require(value == "1")
        elif key in ("HERDR_PANE_ID", "HERDR_SESSION"):
            require(re.fullmatch(r"[A-Za-z0-9_.:-]+", value))
        elif key == "HERDR_SOCKET_PATH":
            require(os.path.isabs(value) and os.path.normpath(value) == value)
        elif key == "TMUX":
            require(re.fullmatch(r"/[^,]+,[0-9]+,[0-9]+", value))
            require(os.path.normpath(value.split(",")[0]) == value.split(",")[0])
    require("TMUX_PANE" in route or
            (route.get("HERDR_ENV") == "1" and "HERDR_PANE_ID" in route))

try:
    require(os.path.isabs(state) and not os.path.islink(state))
    s = os.stat(state)
    require(stat.S_ISDIR(s.st_mode) and s.st_uid == os.getuid() and not s.st_mode & 0o022)
    require(re.fullmatch(r"[1-9][0-9]*", pid))
    lock_matches()
    start = identity()
    path = os.path.join(state, ".primary-pane")
    if action == "publish":
        route = {k: os.environ[k] for k in keys if os.environ.get(k)}
        validate_route(route)
        require(not os.path.lexists(path) or
                (not os.path.islink(path) and stat.S_ISREG(os.stat(path).st_mode)
                 and os.stat(path).st_uid == os.getuid()))
        record = dict(schema=1, pid=pid, start=start, route=route)
        fd, tmp = tempfile.mkstemp(prefix=".primary-pane-", dir=state)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(record, f)
                f.write("\n")
            lock_matches()
            require(identity() == start and not os.path.islink(path))
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    else:
        require(action == "read")
        record = json.loads(read_file(path, private=True), object_pairs_hook=unique_object)
        require(isinstance(record, dict) and set(record) == {"schema", "pid", "start", "route"})
        require(type(record["schema"]) is int and record["schema"] == 1)
        require(record["pid"] == pid and record["start"] == start)
        validate_route(record["route"])
        lock_matches()
        require(identity() == start)
        for key, value in sorted(record["route"].items()):
            print(key + "=" + value)
except (OSError, ValueError, KeyError, IndexError, TypeError, subprocess.SubprocessError):
    sys.exit(1)
PYCODE
}
