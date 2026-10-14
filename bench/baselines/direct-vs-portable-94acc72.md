Compiling 5 files (.ex)
Generated filament app
Candidate / baseline; lower is better. Times are median microseconds. Allocation/reductions cover the caller only.

| Scenario | Rows | Baseline µs | Candidate µs | Time | Allocation | Reductions | Diff bytes (base → candidate) |
|---|---:|---:|---:|---:|---:|---:|---:|
| keyed/append | 10 | 39.6 | 38.9 | 0.98x | 0.99x | 0.95x | 1056 → 1056 |
| keyed/append | 100 | 435.3 | 545.3 | 1.25x | 0.99x | 0.99x | 9163 → 9163 |
| keyed/append | 1000 | 5335.2 | 6282.1 | 1.18x | 0.99x | 0.93x | 93770 → 93770 |
| keyed/clear | 10 | 2.4 | 2.4 | 0.98x | 0.99x | 0.99x | 31 → 31 |
| keyed/clear | 100 | 27.3 | 28.5 | 1.05x | 1.00x | 1.00x | 31 → 31 |
| keyed/clear | 1000 | 471.5 | 284.5 | 0.60x | 1.00x | 1.01x | 31 → 31 |
| keyed/prepend | 10 | 37.3 | 41.8 | 1.12x | 0.99x | 0.93x | 1053 → 1053 |
| keyed/prepend | 100 | 426.9 | 536.1 | 1.26x | 0.99x | 0.99x | 9157 → 9157 |
| keyed/prepend | 1000 | 5092.4 | 6727.1 | 1.32x | 0.99x | 0.96x | 93761 → 93761 |
| keyed/remove_half | 10 | 13.4 | 14.0 | 1.04x | 0.99x | 0.96x | 533 → 533 |
| keyed/remove_half | 100 | 232.5 | 219.8 | 0.95x | 0.99x | 0.96x | 4566 → 4566 |
| keyed/remove_half | 1000 | 3129.4 | 3611.8 | 1.15x | 0.99x | 0.97x | 46669 → 46669 |
| keyed/reverse | 10 | 31.3 | 32.9 | 1.05x | 0.99x | 0.96x | 774 → 774 |
| keyed/reverse | 100 | 424.7 | 465.5 | 1.10x | 0.99x | 0.90x | 8067 → 8067 |
| keyed/reverse | 1000 | 5591.2 | 6410.3 | 1.15x | 0.99x | 0.94x | 84570 → 84570 |
| reactivity/changed | 10 | 30.1 | 31.5 | 1.05x | n/a | n/a | 222 → 222 |
| reactivity/changed | 100 | 314.6 | 317.5 | 1.01x | n/a | n/a | 2383 → 2383 |
| reactivity/changed | 1000 | 4288.7 | 5390.2 | 1.26x | n/a | n/a | 25784 → 25784 |
| reactivity/unchanged | 10 | 2.0 | 2.0 | 0.98x | n/a | n/a | 2 → 2 |
| reactivity/unchanged | 100 | 4.4 | 5.0 | 1.13x | n/a | n/a | 2 → 2 |
| reactivity/unchanged | 1000 | 77.0 | 73.0 | 0.95x | n/a | n/a | 2 → 2 |
| render/leaf_state | 10 | 32.3 | 34.1 | 1.06x | n/a | n/a | 774 → 774 |
| render/leaf_state | 100 | 459.0 | 464.0 | 1.01x | n/a | n/a | 8066 → 8066 |
| render/leaf_state | 1000 | 5143.4 | 7263.7 | 1.41x | n/a | n/a | 84568 → 84568 |
| render/mount | 10 | 26.0 | 25.9 | 1.00x | 0.99x | 0.96x | 966 → 966 |
| render/mount | 100 | 396.3 | 405.8 | 1.02x | 0.98x | 0.97x | 9069 → 9069 |
| render/mount | 1000 | 4535.3 | 5328.9 | 1.17x | 0.99x | 0.94x | 93672 → 93672 |
| render/unchanged | 10 | 34.3 | 33.5 | 0.97x | 0.99x | 0.96x | 774 → 774 |
| render/unchanged | 100 | 442.8 | 523.4 | 1.18x | 0.99x | 0.95x | 8067 → 8067 |
| render/unchanged | 1000 | 5569.3 | 7351.2 | 1.32x | 0.99x | 0.95x | 84570 → 84570 |
