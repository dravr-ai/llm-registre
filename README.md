# llm-registre

**CI gates that make an LLM register the gaps it ships instead of quietly documenting them.**

An LLM writing production code rarely leaves an obvious stub. It leaves an *honest comment*:

```rust
/// Deliberately the floor and not the per-channel value: the descriptor lookup
/// is feature-gated per channel. Threading it through is the follow-up.
const PLAN_TEXT_BUDGET: usize = 2_000;
```

That passes review — it reads as diligence. It passes lint, type-check, and every test, because
the code does exactly what the comment says. And then it sits there for months, because nothing in
the toolchain treats a truthful comment as debt. A 2026 audit of one codebase found a truncation
floor and an entire declared-but-unused capability surface hiding behind exactly this shape, months
after the sessions that wrote them ended.

The stub-hunting checks most teams already have are aimed at *dishonest* incompleteness — `TODO`,
`unimplemented!()`, a handler returning `Ok(vec![])`. This tool is aimed at the honest kind, which
is more common with LLM authors and much harder to see.

## The rule

Deferral prose is banned. The only way to keep it is a marker that names the limited item and
points at a filed issue:

```rust
/// LIMITATION(registre#42): `ChannelDescriptor::max_message_length` is not threaded through
/// `PlatformCommandContext`, so this is the cross-channel floor, not the per-channel value.
const PLAN_TEXT_BUDGET: usize = 2_000;
```

At authoring time the choice becomes: implement it properly, or register it. Never a quiet comment.

The issue number and the marker are a pair — neither is useful alone. `rg "LIMITATION\(registre#"`
is then a complete, queryable inventory of what your codebase knowingly does not do.

## Why the tracker is configuration

The register is normally a **private** tracker, separate from the code repo. When the code is
public, a precise inventory of incomplete defences — "this check is bypassable, here is how" — is a
roadmap. The code comment stays deliberately thin (it names the limited thing, nothing more); the
reasoning and the residual risk live in the tracker.

So the tracker is never hardcoded. Point it wherever you like, public or private.

## Install

```bash
git submodule add https://github.com/dravr-ai/llm-registre .registre
cp .registre/registre.example.toml registre.toml   # then edit `tracker`
```

Call it from whatever validation script you already run at pre-push and in CI:

```bash
./.registre/limitation-gates.sh src crates packages
```

Requires `bash` and [ripgrep](https://github.com/BurntSushi/ripgrep). No install step, no runtime,
no language dependency — it scans `.rs`, `.ts`, and `.tsx` sources and skips test, bench, example,
and generated trees.

## Configure

`registre.toml` at your repo root (every key optional; environment variables win):

```toml
tracker        = "your-org/your-private-tracker"  # where issues are filed
marker         = "registre"                       # the word inside LIMITATION(...)
ledger         = "feature-phases.yaml"            # dark-launch ledger path
require_ledger = false                            # true = the ledger file must exist
```

| Environment | Overrides |
|---|---|
| `REGISTRE_TRACKER` | `tracker` |
| `REGISTRE_MARKER` | `marker` |
| `REGISTRE_LEDGER` | `ledger` |
| `REGISTRE_REQUIRE_LEDGER` | `require_ledger` |
| `REGISTRE_CONFIG` | path to the config file itself |

Choose `marker` once and keep it: it is embedded in every source comment across your codebase.

## The three gates

**1 · Unregistered deferral prose.** Two families, one rule. *Confessions* admit the code is
unfinished ("for now, return", "in a real implementation", "would be … in production").
*Deferrals* are the honest twin — they document debt without registering it ("is the follow-up",
"in a follow-up commit", "not yet wired", "not threaded through"). Both fail unless the line
carries a marker.

**2 · Marker format.** A marker exempts its line from gate 1, so `LIMITATION(` without a
`registre#<digits>:` is an unregistered exemption — the exact hole the register exists to close.

**3 · Feature-phase ledger.** For features that ship *disarmed* — flag off, shadow mode, log-only
phase. Each gets an entry in `feature-phases.yaml`:

```yaml
features:
  - name: tainted-destructive-confirm
    surface: src/guardian/policy.rs
    current: defaults to Log (phase 1, measuring the base rate) — Confirm exists but is unarmed
    advance_when: base rate is measured and a confirmation UX exists
    review_by: 2026-09-30
```

The format is fixed and shallow on purpose: the companion workflow parses it with `awk`, no YAML
dependency. `.github/workflows/feature-phase-review-reusable.yml` in this repo is a reusable
GitHub Actions workflow that reads the ledger weekly and opens an issue in your tracker when a
`review_by` date passes — so phase 1 cannot silently become forever.

```yaml
jobs:
  review:
    uses: dravr-ai/llm-registre/.github/workflows/feature-phase-review-reusable.yml@main
    with:
      tracker: your-org/your-private-tracker
      repo_label: your-repo
      title_prefix: your-repo
    secrets:
      tracker_token: ${{ secrets.YOUR_TRACKER_TOKEN }}
```

## Workflow

1. You are about to write a comment explaining why something is incomplete. **Stop.**
2. If you can implement it now, do that instead — the gates exist to make this the default.
3. Otherwise file an issue in your tracker describing where it is, what is incomplete, and what
   the correct fix looks like.
4. Put `LIMITATION(registre#<n>):` on the comment line that names the limited item.
5. When the gap is fixed, delete the marker in the same change and close the issue. A stale marker
   still exempts prose, so exhausted markers are debt too.

## What this does not do

These gates are **per-change**. They stop new debt at authoring time and cannot reach the standing
stock of defects that live *between* diffs — a handler nothing reaches, an override nothing reads,
two components each locally correct and jointly wrong. Those come out of periodic adversarial
review, not a grep. A green gate means no new unregistered debt; it does not mean the codebase is
clean.

The scan is also line-based, so a phrase wrapped mid-sentence across two comment lines will slip
past it. Treat the rule in your agent instructions (`AGENTS.md`, `CLAUDE.md`, or equivalent) as the
primary enforcement and this as the backstop that catches what the instructions miss.

## License

Apache 2.0 — see [LICENSE](LICENSE).
