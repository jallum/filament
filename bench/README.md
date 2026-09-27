# Filament benchmarks

This suite is based on `main`, with the same fixtures and inputs usable on
`target-agnostic-substrate`. `support/compat.exs` adapts only the observable hook,
message protocol, and rendered-output boundary. It does not select faster
implementations or different work for either branch.

## Run

```sh
mix deps.get
# Validate all workloads without collecting timing samples (also runs in CI):
mix run bench/run.exs --verify-only
# Short smoke measurement, not a stable performance baseline:
ERL_FLAGS='+S 4:4' mix run bench/run.exs --quick --sizes 10 --output tmp/bench/smoke.json
# Full baseline (commit tracked changes first):
ERL_FLAGS='+S 4:4' mix run bench/run.exs --label main --output tmp/bench/main.json
# After applying the identical harness to another revision:
ERL_FLAGS='+S 4:4' mix run bench/run.exs --label substrate --output tmp/bench/substrate.json
mix run bench/compare.exs tmp/bench/main.json tmp/bench/substrate.json
```

Use `--suite render/`, `--suite keyed/`, or `--suite reactivity/` to select a
family, and `--sizes 10,100,1000` to choose row counts. Run branches sequentially
on the same idle machine, with the same Elixir/OTP, dependency lockfile, and
scheduler count. Each worktree needs its own compiled build artifacts. Repeat
runs before interpreting small differences. Do not compare quick and full runs.

## Timed work

All scenarios finish at a JSON-encoded Phoenix LiveView diff. They include
reconciliation, any required vnode conversion, Phoenix diff traversal, and JSON
encoding. They exclude browser DOM work, network transport, compilation, fixture
setup, correctness checks, and cleanup.

| Family | Workload |
|---|---|
| render/mount | Mount N keyed stateful rows and produce the initial diff |
| render/unchanged | Rerender with identical props and produce the next diff |
| render/leaf_state | Invoke one leaf's setter, receive/apply its message, rerender the root, and produce the diff |
| keyed/* | Append, prepend, reverse, remove half, or clear an existing keyed list |
| reactivity/changed | Synchronously write new observable state, consume all delivered updates, rerender once, and produce the diff |
| reactivity/unchanged | Write identical state; verify zero delivery and produce an empty diff without rerendering |

The reactive cases have N subscriptions in **one owner process**. They measure
server call + delivery + render completion, not just enqueue time. They do not
measure cross-owner fanout or mailbox saturation. Setup creates a fresh server
and subscriptions per sample. Cleanup waits for unsubscription to finish on both
APIs before stopping that server.

Before timing, and after every measured invocation (outside the timer), the
suite reconstructs the client HTML from each incremental diff and checks it against
the full render. It also checks rendered values and row order, keyed fiber retention, fiber counts,
message/update counts, and subscription cleanup. A faster incorrect result must
fail, not become a benchmark win. CI runs these checks, not timing thresholds.

## Reading results

JSON summaries record median/mean/p99 time (nanoseconds), variation, sample counts,
caller-process allocations (bytes), and caller-process reductions. Benchee's
allocation/reduction measurements **exclude the observable GenServer**. Separate
untimed preflight diagnostics record that server's reduction delta and memory
snapshots (bytes; after a GC before the write, but not after the write). These
snapshots are not total allocation or peak-memory measurements.

Diagnostics also record serialized diff bytes, full HTML bytes, message/update
counts, and remaining fibers. The comparison prints candidate/baseline ratios;
less than 1 means less measured work. It rejects mismatched runtimes, hardware,
scheduler counts, harness hashes, lockfiles, measurement configuration, or
scenario sets.

Each report identifies the exact git revision, last library-changing commit,
implementation family, time, runtime, hardware, and harness/lock hashes. Full
runs refuse tracked dirty changes. Raw results normally go under ignored
`tmp/bench/`; selected reference reports can be committed under `bench/baselines/`
with the command and limitations described alongside them.

The default run uses 1 second warmup, 2 seconds timing, 0.5 seconds allocation
measurement, and 0.5 seconds reductions per scenario, with `parallel: 1`.
Treat this as a starting baseline, not a performance SLA. Deep-tree lifecycle,
source switching, capture dispatch, and multiple-owner fanout can be added as
separate workloads; APIs that only exist on the substrate need their own baseline.
