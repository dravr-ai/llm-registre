#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 dravr.ai
# ABOUTME: Tests for limitation-gates.sh — a throwaway repo per case, with the real script run in it
# ABOUTME: The tracker is a stub gh on PATH answering from a fixture, so no case reaches the network
#
# Run from anywhere: bash limitation-gates.test.sh
#
# Why a stub and not a live tracker: every case needs a tracker in a known
# state (an issue closed, one unlabelled, one missing), and a real one would
# drift under the suite. The stub answers the exact REST listing the gate
# makes, applies the gate's own --jq filter with the real jq, and fails every
# other call — a GraphQL query, `gh issue view`, a per-issue lookup — so a gate
# that reached for one cannot pass here. The live half is the scheduled
# reconciliation job a consumer runs against its real tracker.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GATES="$HERE/limitation-gates.sh"
PASS=0
FAIL=0

ok()  { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }
die() { printf '\n  💥 %s\n\n' "$1" >&2; exit 2; }

check() { # <description> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi
}
contains() { # <description> <needle> <haystack>
    if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 — no '$2' in: $3"; fi
}
lacks() { # <description> <needle> <haystack>
    if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 — unexpected '$2' in: $3"; else ok "$1"; fi
}

[ -x "$GATES" ] || die "limitation-gates.sh is not executable next to this file"
command -v rg >/dev/null 2>&1 || die "ripgrep (rg) is required: the gates scan with it"
command -v jq >/dev/null 2>&1 || die "jq is required: the stub tracker applies the gate's --jq filter with it"

# A developer shell may export REGISTRE_* for its own repo; none of it belongs here.
for var in $(env | sed -n 's/^\(REGISTRE_[A-Z_]*\)=.*/\1/p'); do unset "$var"; done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/registre-test.XXXXXX") || die "mktemp -d failed"
[ -n "$WORK" ] && [ -d "$WORK" ] || die "no work directory"
trap 'rm -rf "$WORK"' EXIT

TRACKER="acme/register"
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'GH'
#!/bin/bash
# Stub tracker. Logs every call, then answers only
# `gh api --paginate repos/<tracker>/issues?state=all...` from $STUB_ISSUES.
set -o pipefail
printf '%s\n' "$*" >> "$STUB_LOG"
if [ -n "${STUB_FAIL:-}" ]; then echo "$STUB_FAIL" >&2; exit 1; fi
if [ -n "${STUB_RAW:-}" ]; then printf '%s\n' "$STUB_RAW"; exit 0; fi
[ "${1:-}" = api ] || { echo "stub gh: only REST listings are served, not '$1'" >&2; exit 64; }
shift
url="" filter="" paginate=false
while [ $# -gt 0 ]; do
    case "$1" in
        --paginate) paginate=true; shift ;;
        --jq) filter="$2"; shift 2 ;;
        -*) echo "stub gh: unexpected option $1" >&2; exit 64 ;;
        *) url="$1"; shift ;;
    esac
done
$paginate || { echo "stub gh: a listing must be paginated" >&2; exit 64; }
case "$url" in
    "repos/$STUB_TRACKER/issues?"*state=all*) ;;
    *) echo "stub gh: not the tracker's issue listing: $url" >&2; exit 64 ;;
esac
label=$(printf '%s' "$url" | sed -n 's/.*[?&]labels=\([^&]*\).*/\1/p')
jq --arg label "$label" '[.[] | select($label == "" or ([.labels[].name] | index($label)))]' \
    "$STUB_ISSUES" | jq -r "$filter"
GH
chmod +x "$STUB_BIN/gh"

# GitHub's REST shape, trimmed to the fields the gate reads. A pull request is
# an issue with a pull_request key, exactly as the issues endpoint returns it.
ISSUES="$WORK/issues.json"
cat > "$ISSUES" <<'JSON'
[
  {"number": 10, "state": "open",   "labels": [{"name": "limitation"}, {"name": "acme"}]},
  {"number": 11, "state": "closed", "labels": [{"name": "limitation"}]},
  {"number": 12, "state": "open",   "labels": [{"name": "bug"}]},
  {"number": 13, "state": "closed", "labels": []},
  {"number": 14, "state": "open",   "labels": [{"name": "limitation"}], "pull_request": {"url": "https://example.test/pr/14"}},
  {"number": 15, "state": "open",   "labels": [{"name": "limitation"}]}
]
JSON
printf '[]\n' > "$WORK/empty.json"

CASE=0
# A repo with a registre.toml naming the stub tracker and src/lib.rs holding
# one comment line per marker number given.
new_repo() { # <marker-number>...
    local repo n
    CASE=$((CASE + 1))
    repo="$WORK/case-$CASE"
    mkdir -p "$repo/src"
    printf 'tracker = "%s"\nscan_dirs = "src"\n' "$TRACKER" > "$repo/registre.toml"
    : > "$repo/src/lib.rs"
    for n in "$@"; do
        printf '// LIMITATION(registre#%s): the item this names\n' "$n" >> "$repo/src/lib.rs"
    done
    printf 'fn main() {}\n' >> "$repo/src/lib.rs"
    printf '%s' "$repo"
}

OUT=""
STATUS=0
LOG=""
gates() { # <repo> [args...] — sets OUT, STATUS and LOG; extra env comes from the caller
    local repo=$1; shift
    LOG="$repo/gh.log"
    rm -f "$LOG"
    OUT=$(cd "$repo" && PATH="$STUB_BIN:$PATH" STUB_LOG="$LOG" STUB_TRACKER="$TRACKER" \
        STUB_ISSUES="${ISSUES_FILE:-$ISSUES}" "$GATES" "$@" 2>&1)
    STATUS=$?
}
calls() { if [ -f "$LOG" ]; then grep -c . "$LOG"; else echo 0; fi; }

printf '\nlimitation-gates tests\n\n'

# ---- the flag is off by default, and off means offline
R=$(new_repo 10 999)
gates "$R"
check "without --verify-tracker the gates pass on shape alone" 0 "$STATUS"
check "…and make no network call at all" 0 "$(calls)"
lacks "…and say nothing about the tracker" "acme/register" "$OUT"

# ---- open and labelled passes, from one listing
R=$(new_repo 10 15 10)
gates "$R" --verify-tracker
check "markers naming open, labelled issues pass" 0 "$STATUS"
contains "the pass counts sites and distinct issues" \
    "All 3 LIMITATION marker(s) name an open 'limitation' issue on acme/register (2 issue(s))" "$OUT"
check "three markers cost one listing, not a call per marker" 1 "$(calls)"
contains "the listing is the labelled one" "labels=limitation" "$(cat "$LOG")"
contains "it includes closed issues" "state=all" "$(cat "$LOG")"
contains "it asks for full pages" "per_page=100" "$(cat "$LOG")"

# ---- a closed register entry fails
R=$(new_repo 10 11)
gates "$R" --verify-tracker
check "a marker citing a closed issue fails" 1 "$STATUS"
contains "the failure names the site and the state" "src/lib.rs:2  registre#11: closed" "$OUT"
lacks "the open one is not reported" "registre#10:" "$OUT"
check "a closed labelled issue is judged from the labelled listing alone" 1 "$(calls)"

# ---- a number never filed fails
R=$(new_repo 999)
gates "$R" --verify-tracker
check "a marker citing a missing issue fails" 1 "$STATUS"
contains "the failure says the issue does not exist" "registre#999: no such issue on acme/register" "$OUT"
check "a missing issue costs exactly one more listing" 2 "$(calls)"
lacks "the second listing is the whole tracker" "labels=" "$(sed -n 2p "$LOG")"

# ---- open but unlabelled fails
R=$(new_repo 12)
gates "$R" --verify-tracker
check "a marker citing an open issue without the label fails" 1 "$STATUS"
contains "the failure names the missing label" "registre#12: open, but not labelled limitation" "$OUT"

# ---- closed and unlabelled fails
R=$(new_repo 13)
gates "$R" --verify-tracker
check "a marker citing a closed unlabelled issue fails" 1 "$STATUS"
contains "the failure says both" "registre#13: closed, and not labelled limitation" "$OUT"

# ---- a pull request is not a register entry
R=$(new_repo 14)
gates "$R" --verify-tracker
check "a marker citing a pull request fails" 1 "$STATUS"
contains "the failure says what it is" "registre#14: a pull request, not an issue" "$OUT"

# ---- every bad marker is reported, and only those
R=$(new_repo 10 11 999 12)
gates "$R" --verify-tracker
check "a mix with any bad marker fails" 1 "$STATUS"
contains "the count is the bad markers only" "3 LIMITATION marker(s) name no open 'limitation' issue on acme/register" "$OUT"

# ---- the tracker cannot be read: fail closed
R=$(new_repo 10)
STUB_FAIL="gh: Resource not accessible by integration (HTTP 403)" gates "$R" --verify-tracker
check "a 403 from the tracker fails the gate" 1 "$STATUS"
contains "the failure says nothing was verified" "Cannot read acme/register — nothing was verified" "$OUT"
contains "and carries the tracker's answer" "HTTP 403" "$OUT"
lacks "a refused listing never reads as a pass" "name an open" "$OUT"

R=$(new_repo)
STUB_FAIL="gh: Bad credentials (HTTP 401)" gates "$R" --verify-tracker
check "an unreadable tracker fails even with no marker to check" 1 "$STATUS"

R=$(new_repo 10)
STUB_RAW="<html>rate limited</html>" gates "$R" --verify-tracker
check "an answer in the wrong shape fails" 1 "$STATUS"
contains "…and says it could not read it" "Unreadable answer listing acme/register" "$OUT"

R=$(new_repo 10)
ISSUES_FILE="$WORK/empty.json" gates "$R" --verify-tracker
check "a tracker that answers with no issues at all fails" 1 "$STATUS"
contains "…and names the likely cause" "answered with no issues at all" "$OUT"

# gh itself absent: a PATH holding only the tools the gates use, minus gh.
NOGH="$WORK/nogh"
mkdir -p "$NOGH"
for tool in bash rg sed head tr grep awk mktemp rm sort cut wc cat env; do
    ln -sf "$(command -v "$tool")" "$NOGH/$tool"
done
R=$(new_repo 10)
OUT=$(cd "$R" && PATH="$NOGH" "$GATES" --verify-tracker 2>&1); STATUS=$?
check "no gh CLI fails the gate rather than skipping it" 1 "$STATUS"
contains "…and names what is missing" "needs the gh CLI" "$OUT"

R=$(new_repo 10)
printf 'scan_dirs = "src"\n' > "$R/registre.toml"
gates "$R" --verify-tracker
check "verification with no tracker configured fails" 1 "$STATUS"
contains "…and says to configure one" "no tracker is configured" "$OUT"
check "…without calling anything" 0 "$(calls)"

# ---- the opt-in has three spellings, and the environment wins over the file
R=$(new_repo 999)
printf 'verify_tracker = true\n' >> "$R/registre.toml"
gates "$R"
check "verify_tracker = true in registre.toml turns the gate on" 1 "$STATUS"
contains "…and it judges the marker" "registre#999: no such issue" "$OUT"
REGISTRE_VERIFY_TRACKER=false gates "$R"
check "REGISTRE_VERIFY_TRACKER=false overrides the file" 0 "$STATUS"
check "…and then nothing is called" 0 "$(calls)"
R=$(new_repo 999)
REGISTRE_VERIFY_TRACKER=true gates "$R"
check "REGISTRE_VERIFY_TRACKER=true turns the gate on" 1 "$STATUS"

R=$(new_repo 10)
printf 'verify_tracker = yes\n' >> "$R/registre.toml"
gates "$R"
check "a verify_tracker that is not true/false is refused" 1 "$STATUS"
contains "…by name" "verify_tracker must be true or false, got 'yes'" "$OUT"
check "…before anything is called" 0 "$(calls)"

R=$(new_repo 10 12)
printf 'label = "bug"\n' >> "$R/registre.toml"
gates "$R" --verify-tracker
check "the label is configuration" 1 "$STATUS"
contains "…the listing asks for the configured one" "labels=bug" "$(sed -n 1p "$LOG")"
contains "…and judges against it" "registre#10: open, but not labelled bug" "$OUT"

# ---- only the register's scope is verified
# Test, bench and example trees are outside every gate, so a fixture citing a
# number that was never filed is out of reach by the same rule that keeps it
# out of gate 1 — there is no exemption list to maintain.
R=$(new_repo 10)
mkdir -p "$R/src/tests" "$R/docs"
printf '// LIMITATION(registre#999): a fixture\n' > "$R/src/tests/helper.rs"
printf 'LIMITATION(registre#999): prose\n' > "$R/docs/notes.md"
printf 'let x = 1; // LIMITATION(registre#999): a spec\n' > "$R/src/thing.spec.ts"
gates "$R" --verify-tracker
check "markers outside the scanned scope are not verified" 0 "$STATUS"
lacks "…and not mentioned" "registre#999" "$OUT"
contains "…while the one in scope is" "All 1 LIMITATION marker(s)" "$OUT"

R=$(new_repo)
gates "$R" --verify-tracker
check "no marker in scope passes once the tracker answers" 0 "$STATUS"
contains "…and says there was nothing to reconcile" "No LIMITATION markers in scope; acme/register is readable" "$OUT"
check "…after probing the tracker once" 1 "$(calls)"

# ---- options
R=$(new_repo 999)
gates "$R" --verify-tracker src
check "an explicit directory still works after the flag" 1 "$STATUS"
contains "…and is verified" "registre#999: no such issue" "$OUT"
gates "$R" src --verify-tracker
check "the flag after a directory is refused, never dropped" 1 "$STATUS"
contains "…with a reason" "options go before the directories" "$OUT"
check "…before anything is called" 0 "$(calls)"
gates "$R" --verify
check "an unknown option is refused" 1 "$STATUS"
contains "…by name" "unknown option '--verify'" "$OUT"

R=$(new_repo 999)
printf 'verify_tracker = true\n' >> "$R/registre.toml"
gates "$R" --list-files
check "--list-files still lists with verification configured" 0 "$STATUS"
check "…the scanned file only" "src/lib.rs" "$OUT"
check "…and never calls the tracker" 0 "$(calls)"
gates "$R" --list-files --verify-tracker
check "--list-files with --verify-tracker is refused" 1 "$STATUS"

# ---- the offline gates are unchanged by the flag
R=$(new_repo 10)
printf '// the lookup is the follow-up\n' >> "$R/src/lib.rs"
gates "$R" --verify-tracker
check "deferral prose still fails with verification on" 1 "$STATUS"
contains "…from gate 1" "unregistered deferral/confession comment(s)" "$OUT"
contains "…while gate 6 still judges the markers" "All 1 LIMITATION marker(s)" "$OUT"

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
