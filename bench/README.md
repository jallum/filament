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
| keyed/* | Append, prepend, reverse, move the last row to the front after editing its state, remove half, or clear a keyed list |
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

Benchee runs its memory and reductions collectors in a different process from
`before_each`. That would move execution away from the owner of prebuilt state
setters and subscriptions. Therefore **leaf-state and reactive jobs use Benchee's
time collector only**; their allocation/reduction distributions are explicitly
`null` (`n/a` in comparisons). Their preflight caller/server reduction deltas
remain available as single-run diagnostics, not statistical measurements. The
seven pure rendering/reconciliation jobs collect all three Benchee metrics.

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

When a revision supports `Filament.Web.render/2`, the compatibility adapter
selects `target: Filament.Web`, matching the production LiveView path. Older
substrate revisions use portable reconciliation followed by `Web.to_rendered`;
main already produces LiveView output. Inputs, completed work and correctness
checks remain identical. Reports distinguish `cell-web-direct` from `cell-vnode`.
Applying this adapter update changes the harness hash: older archived reports
must be recaptured with the updated harness before automated comparison.

The Web host selects compiled `~F` template plans when available. Portable targets
continue to receive vnode tuples. The compiled path hoists static HTML and uses
keyed LiveView comprehensions for homogeneous keyed component loops. Components
render only when their props, state or `use_value` values change. Dynamic attributes that require different
HTML shapes, heterogeneous loops, and manual vnode output use the existing
converter. `keyed/move` checks that the moved row retains its edited local state.

Timing reports record `json_library: "Jason"`. These measurements retain Jason
for continuity with archived baselines; the example applications already configure
Phoenix with Elixir `JSON`. Compare encoder changes separately using the same diff.

## Latest-value delivery proof

`ERL_FLAGS='+S 4:4' mix run bench/latest_delivery.exs` compares the current transport
with the isolated `support/latest_delivery.exs` experiment. An owner deliberately
leaves update messages unread while the producer performs 1,000 synchronous
writes. Setup, recovery, and final-value checks are outside the measured writes.
The printed write times are diagnostic samples, not stable Benchee baselines.

The experiment permits one batch in flight **per producer/owner pair**, regardless
of cell count. Each cell stores its latest projected value and acknowledged value.
While a batch is outstanding, writes overwrite the latest value without sending.
Acknowledgment advances only the matching cell generations, then sends the newest
values that differ from the acknowledged snapshot. A batch token prevents duplicate
or delayed acknowledgments from clearing a newer batch. Strict equality preserves
integer/float distinctions. Returning to the initial value still sends a correction
if the consumer received an intervening value.

Unsubscribe removes the cell, but keeps any outstanding batch until acknowledgment
or owner death. This prevents repeated unsubscribe/resubscribe cycles from opening
new delivery slots and accumulating stale messages. Replacement cells receive a
fresh generation and synchronous initial snapshot; old batches cannot overwrite
that snapshot. Each owner has one monitor, including owners whose last cell was
removed while a batch was outstanding. Owner death removes its flight and cells.

In the worked example, the current transport with #23's episode fix queues 101
messages for one cell and 1,100 for 1,000 cells: 100 ordinary batches followed by
one recovery notice per cell. The experiment queues one batch in either case,
then automatically delivers the final value when acknowledged. Tests exercise
final-value delivery, duplicate/foreign acknowledgments, projection replacement,
unsubscribe/resubscribe, partial removal, strict/projected equality, healthy owners,
and dead owners. This experiment does not change production delivery semantics.

Production integration must acknowledge **after processing**, including the host's
render and synchronous effects, rather than when receiving the message. LiveView
and LiveComponent adapters need that boundary; messages discarded because their
cell generations are stale must still release their batch. Hook projections should
continue to run at their existing boundary. Intermediate observable values may be
coalesced; applications needing every transition need an event-stream abstraction.
Multiple independent producers can each have one batch outstanding to the same
owner; a global owner-wide limit would require coordination between producers.
