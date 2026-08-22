#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 dravr.ai
# ABOUTME: Limitation-register gates — deferral prose ban, marker format, phase-ledger format
# ABOUTME: Tracker-agnostic: configured via registre.toml or REGISTRE_* environment variables

# WHAT THIS IS
# ------------
# An LLM writing production code will document a gap rather than admit it. The
# comment reads as diligence — "the descriptor lookup isn't threaded through",
# "strict mode is a follow-up" — and it passes every review, every lint, every
# test. Then it sits there for months, because nothing in the toolchain treats
# an honest comment as debt.
#
# These gates make honesty produce a tracked obligation. Deferral prose is
# banned outright; the only way to keep it is a marker naming the limited item
# and pointing at a filed issue:
#
#   LIMITATION(registre#42): <the limited item, named on this line>
#
# So at authoring time the choice is: implement it properly, or register it.
# Never a quiet comment. The register itself is normally a PRIVATE tracker —
# when the code repo is public, a precise inventory of incomplete defences is a
# roadmap — which is why the tracker is configuration, not a constant.
#
# GATES
#   1. Unregistered deferral/confession prose in non-test sources.
#   2. Marker format — LIMITATION( without <marker>#<digits>: is a malformed,
#      and therefore unregistered, exemption.
#   3. Feature-phase ledger format, when a ledger file is present (or required):
#      every entry needs name / current / advance_when / review_by, so the
#      companion review workflow can read it.
#   4. File length cap (opt-in): any scanned file over max_file_lines fails —
#      a file that outgrows its cap needs a helper extracted, not more scroll.
#   5. Inline suppression allow-list (opt-in): #[allow(clippy::…)] or
#      #[expect(clippy::…)] naming a lint outside allowed_inline_allows fails —
#      one declared list instead of copies drifting across script and docs.
#
# USAGE
#   limitation-gates.sh <scan-dir>...
#
#   Scans the configured source extensions under the given directories
#   (non-existent ones are skipped, so callers may pass a superset), excluding
#   test, bench, example, and generated trees for every supported language.
#
#   Exit 0 clean, 1 violations found.
#
# CONFIGURATION (first match wins)
#   environment         registre.toml            default
#   ------------------  -----------------------  --------------------------
#   REGISTRE_TRACKER    tracker = "o/r"          unset (generic messages)
#   REGISTRE_MARKER     marker  = "registre"     registre
#   REGISTRE_LEDGER     ledger  = "path"         feature-phases.yaml
#   REGISTRE_REQUIRE_LEDGER
#                       require_ledger = true    false (checked if present)
#   REGISTRE_EXTENSIONS extensions = "java,ts"   rs,ts,tsx
#   REGISTRE_EXCLUDE    exclude = "**/legacy/**" none (adds to the built-ins)
#   REGISTRE_MAX_FILE_LINES
#                       max_file_lines = 500     unset (gate 4 off)
#   REGISTRE_ALLOWED_INLINE_ALLOWS
#                       allowed_inline_allows = "lint_a,lint_b"
#                                                unset (gate 5 off)
#
# The marker word is configurable but should be treated as permanent once
# chosen: it is embedded in every source comment across the codebase.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

GATES_FAILED=false

gate_fail() {
    echo -e "${RED}❌ $1${NC}"
    GATES_FAILED=true
}

gate_pass() {
    echo -e "${GREEN}✅ $1${NC}"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONFIG_FILE="${REGISTRE_CONFIG:-registre.toml}"

# Read a bare `key = "value"` / `key = true` pair from the config file. Values
# are simple scalars by design — this deliberately avoids a TOML dependency so
# the gates stay a single portable script with no install step.
config_value() {
    local key="$1"
    [ -f "$CONFIG_FILE" ] || return 0
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$CONFIG_FILE" \
        | head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '"'\''' | tr -d '[:space:]'
}

TRACKER="${REGISTRE_TRACKER:-$(config_value tracker)}"
MARKER="${REGISTRE_MARKER:-$(config_value marker)}"
MARKER="${MARKER:-registre}"
LEDGER_FILE="${REGISTRE_LEDGER:-$(config_value ledger)}"
LEDGER_FILE="${LEDGER_FILE:-feature-phases.yaml}"
REQUIRE_LEDGER="${REGISTRE_REQUIRE_LEDGER:-$(config_value require_ledger)}"
REQUIRE_LEDGER="${REQUIRE_LEDGER:-false}"
# Which source files to scan, comma-separated bare extensions. Defaults suit a
# Rust/TypeScript repo; a Java project sets extensions = "java,ts,js".
EXTENSIONS="${REGISTRE_EXTENSIONS:-$(config_value extensions)}"
EXTENSIONS="${EXTENSIONS:-rs,ts,tsx}"
# Extra exclude globs on top of the built-in test/generated conventions.
EXCLUDE_EXTRA="${REGISTRE_EXCLUDE:-$(config_value exclude)}"
# File length cap for gate 4. Unset or 0 disables the gate — the cap is repo
# policy, not something this tool can guess.
MAX_FILE_LINES="${REGISTRE_MAX_FILE_LINES:-$(config_value max_file_lines)}"
case "$MAX_FILE_LINES" in
    ''|0) MAX_FILE_LINES="" ;;
    *[!0-9]*)
        echo -e "${RED}limitation-gates: max_file_lines must be a whole number, got '${MAX_FILE_LINES}'${NC}"
        exit 1 ;;
esac
# Clippy lints that may be silenced inline, comma-separated bare names, for
# gate 5. Unset disables the gate.
ALLOWED_INLINE_ALLOWS="${REGISTRE_ALLOWED_INLINE_ALLOWS:-$(config_value allowed_inline_allows)}"

# Where to tell the author to file the issue.
if [ -n "$TRACKER" ]; then
    FILE_AT="file it in $TRACKER"
else
    FILE_AT="file it in your configured tracker (set tracker in $CONFIG_FILE)"
fi

MARKER_RE="LIMITATION\\(${MARKER}#[0-9]+\\):"

SCAN_DIRS=()
for d in "$@"; do
    [ -d "$d" ] && SCAN_DIRS+=("$d")
done

if [ "$#" -eq 0 ]; then
    echo -e "${RED}limitation-gates: no scan directories given${NC}"
    echo "Usage: limitation-gates.sh <scan-dir>..."
    exit 1
fi

# Callers may pass a superset (e.g. "crates src packages") and the ones that do
# not exist are skipped. But if NOTHING matched, the invocation is wrong — a
# typo'd path, or a caller whose shell did not word-split its directory list —
# and a gate that silently passes on a bad invocation is worse than no gate.
if [ "${#SCAN_DIRS[@]}" -eq 0 ]; then
    echo -e "${RED}limitation-gates: none of the given paths is a directory:${NC}"
    for d in "$@"; do echo "  - $d"; done
    echo "Nothing was scanned, so this is a failure rather than a pass."
    exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
    echo -e "${RED}limitation-gates: ripgrep (rg) is required${NC}"
    exit 1
fi

# Build the include globs from the configured extensions, and the exclude globs
# from the language conventions for "this file is a test" plus any extra globs
# the repo configured.
INCLUDE_GLOBS=()
for ext in $(printf '%s' "$EXTENSIONS" | tr ',' ' '); do
    INCLUDE_GLOBS+=(-g "*.${ext}")
done

# Test/bench/example/generated trees, across the languages this tool supports.
# NB: globs use `**` deliberately — rg's `*` never crosses `/`, so a `!*/tests/*`
# form silently fails to exclude nested test directories. `src/test/**` is the
# Maven/Gradle convention and is NOT covered by `**/tests/**`; SwiftPM's
# `Tests/` is capitalised, and rg globs are case-sensitive, so it gets its own
# entry alongside the `*Tests.swift` file convention.
EXCLUDE_GLOBS=(
    -g '!**/tests/**' -g '!**/test/**' -g '!**/src/test/**' -g '!**/src/it/**'
    -g '!**/benches/**' -g '!**/examples/**' -g '!**/testFixtures/**'
    -g '!*_test.rs' -g '!*.test.ts' -g '!*.test.tsx' -g '!*.test.js'
    -g '!*.spec.ts' -g '!*.spec.tsx' -g '!*.spec.js'
    -g '!*Test.java' -g '!*Tests.java' -g '!*IT.java' -g '!*TestCase.java'
    -g '!**/Tests/**' -g '!*Tests.swift'
    -g '!**/target/**' -g '!**/build/**' -g '!**/node_modules/**' -g '!**/dist/**'
    -g '!**/generated/**' -g '!**/generated-sources/**' -g '!**/vendor/**'
    -g '!**/*.min.js'
)
for extra in $(printf '%s' "$EXCLUDE_EXTRA" | tr ',' ' '); do
    [ -n "$extra" ] && EXCLUDE_GLOBS+=(-g "!${extra}")
done

rg_scoped() {
    rg "$@" "${SCAN_DIRS[@]}" \
        "${INCLUDE_GLOBS[@]}" "${EXCLUDE_GLOBS[@]}" \
        2>/dev/null
}

echo -e "${BLUE}==== Limitation Register Gates ====${NC}"

# ---------------------------------------------------------------------------
# Gate 1: deferral / confession prose without a marker
# ---------------------------------------------------------------------------
# Two families, one rule. "Confession" is an admission the code is unfinished
# ("for now, return", "in a real implementation"). "Deferral" is the honest
# twin — it documents debt without registering it ("is the follow-up", "not
# yet wired"). Line-based patterns can be defeated by a wrap mid-phrase; the
# authoring-time rule in your agent instructions is the primary enforcement
# and this scan is the backstop.
CONFESSION_PATTERNS='not yet implemented|in a real implementation|would be [a-z. ]*in production|would be database-backed|implement(ed)? later|for now, (return|store|trigger|set a default|we.?ll skip)|return empty[a-z. ]*for now|is the follow.?up|in a follow.?up (commit|change|pr)|not (yet )?threaded through|not yet wired'

CONFESSION_HITS=$(rg_scoped -i -n "$CONFESSION_PATTERNS" | rg -v "$MARKER_RE" || true)
CONFESSION_COUNT=$(printf '%s' "$CONFESSION_HITS" | grep -c . 2>/dev/null || true)

if [ "${CONFESSION_COUNT:-0}" -gt 0 ]; then
    echo -e "${RED}Unregistered deferral/confession prose — implement the real thing, or register the gap and put LIMITATION(${MARKER}#n): on the same line:${NC}"
    printf '%s\n' "$CONFESSION_HITS" | head -20
    gate_fail "$CONFESSION_COUNT unregistered deferral/confession comment(s) — $FILE_AT"
else
    gate_pass "No unregistered deferral/confession prose"
fi

# ---------------------------------------------------------------------------
# Gate 2: marker format
# ---------------------------------------------------------------------------
# A marker exempts its line from gate 1, so a malformed one (no issue number)
# is an unregistered exemption — the exact hole the register exists to close.
BAD_MARKERS=$(rg_scoped -n 'LIMITATION\(' | rg -v "$MARKER_RE" || true)
BAD_MARKER_COUNT=$(printf '%s' "$BAD_MARKERS" | grep -c . 2>/dev/null || true)

if [ "${BAD_MARKER_COUNT:-0}" -gt 0 ]; then
    echo -e "${RED}Malformed LIMITATION marker(s) — required form: LIMITATION(${MARKER}#<issue>):${NC}"
    printf '%s\n' "$BAD_MARKERS" | head -10
    gate_fail "$BAD_MARKER_COUNT malformed LIMITATION marker(s) — $FILE_AT and reference its number"
else
    gate_pass "All LIMITATION markers reference a registered issue"
fi

# ---------------------------------------------------------------------------
# Gate 3: feature-phase ledger format
# ---------------------------------------------------------------------------
# The dark-launch register: a feature shipped disarmed (flag off, shadow mode,
# log-only) gets an entry with a review date, so phase 1 cannot silently become
# forever. The format is fixed and shallow on purpose — the review workflow
# parses it with awk, no YAML dependency.
if [ ! -f "$LEDGER_FILE" ]; then
    if [ "$REQUIRE_LEDGER" = "true" ]; then
        gate_fail "$LEDGER_FILE missing — the dark-launch ledger must exist (an empty features: list is valid)"
    fi
else
    LEDGER_ENTRIES=$(grep -c '^  - name: ' "$LEDGER_FILE" 2>/dev/null || true)
    LEDGER_OK=true
    for ledger_key in current advance_when review_by; do
        KEY_COUNT=$(grep -c "^    ${ledger_key}: " "$LEDGER_FILE" 2>/dev/null || true)
        if [ "${KEY_COUNT:-0}" -ne "${LEDGER_ENTRIES:-0}" ]; then
            gate_fail "$LEDGER_FILE: ${KEY_COUNT:-0} '${ledger_key}:' key(s) for ${LEDGER_ENTRIES:-0} entries — every entry needs name/current/advance_when/review_by"
            LEDGER_OK=false
        fi
    done
    BAD_REVIEW_DATES=$(grep '^    review_by: ' "$LEDGER_FILE" 2>/dev/null | grep -Ev 'review_by: [0-9]{4}-[0-9]{2}-[0-9]{2}$' || true)
    if [ -n "$BAD_REVIEW_DATES" ]; then
        gate_fail "$LEDGER_FILE: review_by must be YYYY-MM-DD — $BAD_REVIEW_DATES"
        LEDGER_OK=false
    fi
    if [ "$LEDGER_OK" = true ]; then
        gate_pass "Feature phase ledger well-formed (${LEDGER_ENTRIES:-0} dark-launched feature(s))"
    fi
fi

# ---------------------------------------------------------------------------
# Gate 4 (opt-in): file length cap
# ---------------------------------------------------------------------------
# A source file that outgrows its cap needs a focused helper extracted, not a
# longer scroll. Runs over the same include/exclude scope as the other gates,
# and only when the repo declares a cap.
if [ -n "$MAX_FILE_LINES" ]; then
    OVERSIZED=$(rg --files "${SCAN_DIRS[@]}" "${INCLUDE_GLOBS[@]}" "${EXCLUDE_GLOBS[@]}" 2>/dev/null \
        | while IFS= read -r scanned_file; do
            file_lines=$(wc -l < "$scanned_file" | tr -d '[:space:]')
            if [ "${file_lines:-0}" -gt "$MAX_FILE_LINES" ]; then
                printf '%s: %s lines\n' "$scanned_file" "$file_lines"
            fi
        done)
    OVERSIZED_COUNT=$(printf '%s' "$OVERSIZED" | grep -c . 2>/dev/null || true)

    if [ "${OVERSIZED_COUNT:-0}" -gt 0 ]; then
        echo -e "${RED}Files over the ${MAX_FILE_LINES}-line cap — extract a focused helper:${NC}"
        printf '%s\n' "$OVERSIZED" | head -10
        gate_fail "$OVERSIZED_COUNT file(s) over ${MAX_FILE_LINES} lines"
    else
        gate_pass "No scanned file exceeds ${MAX_FILE_LINES} lines"
    fi
fi

# ---------------------------------------------------------------------------
# Gate 5 (opt-in): inline suppression allow-list
# ---------------------------------------------------------------------------
# An inline #[allow(clippy::…)] / #[expect(clippy::…)] silences a lint the
# repo's manifest set to deny, and nothing else notices. When the repo declares
# which lints may be silenced inline, everything outside that list fails — one
# list in one place, instead of copies drifting across script, manifest, and
# agent instructions.
if [ -n "$ALLOWED_INLINE_ALLOWS" ]; then
    ALLOWED_LIST=" $(printf '%s' "$ALLOWED_INLINE_ALLOWS" | tr ',' ' ') "
    SUPPRESSION_LINES=$(rg_scoped -n '#\[(allow|expect)\(clippy::' || true)
    BAD_SUPPRESSIONS=""
    while IFS= read -r suppression_hit; do
        [ -z "$suppression_hit" ] && continue
        for lint in $(printf '%s' "$suppression_hit" | grep -oE 'clippy::[a-z0-9_]+' | sed 's/clippy:://'); do
            case "$ALLOWED_LIST" in
                *" $lint "*) ;;
                *) BAD_SUPPRESSIONS="${BAD_SUPPRESSIONS}${suppression_hit} -> clippy::${lint}
" ;;
            esac
        done
    done <<< "$SUPPRESSION_LINES"
    BAD_SUPPRESSION_COUNT=$(printf '%s' "$BAD_SUPPRESSIONS" | grep -c . 2>/dev/null || true)

    if [ "${BAD_SUPPRESSION_COUNT:-0}" -gt 0 ]; then
        echo -e "${RED}Inline clippy suppression(s) outside allowed_inline_allows — fix the code, or add the lint to the declared list:${NC}"
        printf '%s' "$BAD_SUPPRESSIONS" | head -10
        gate_fail "$BAD_SUPPRESSION_COUNT unapproved inline clippy suppression(s)"
    else
        gate_pass "All inline clippy suppressions are on the declared list"
    fi
fi

if [ "$GATES_FAILED" = true ]; then
    exit 1
fi
