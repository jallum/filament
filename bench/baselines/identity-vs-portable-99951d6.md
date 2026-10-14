Candidate / baseline; lower is better. Times are median microseconds. Allocation/reductions cover the caller only.

| Scenario | Rows | Baseline µs | Candidate µs | Time | Allocation | Reductions | Diff bytes (base → candidate) |
|---|---:|---:|---:|---:|---:|---:|---:|
| keyed/append | 10 | 39.6 | 37.0 | 0.93x | 1.00x | 1.00x | 1056 → 1056 |
| keyed/append | 100 | 435.3 | 411.3 | 0.94x | 1.00x | 1.03x | 9163 → 9163 |
| keyed/append | 1000 | 5335.2 | 4832.1 | 0.91x | 1.00x | 1.00x | 93770 → 93770 |
| keyed/clear | 10 | 2.4 | 2.3 | 0.95x | 1.00x | 1.00x | 31 → 31 |
| keyed/clear | 100 | 27.3 | 25.6 | 0.94x | 1.00x | 1.00x | 31 → 31 |
| keyed/clear | 1000 | 471.5 | 404.2 | 0.86x | 1.00x | 1.00x | 31 → 31 |
| keyed/prepend | 10 | 37.3 | 36.8 | 0.99x | 1.00x | 1.00x | 1053 → 1053 |
| keyed/prepend | 100 | 426.9 | 415.5 | 0.97x | 1.00x | 1.00x | 9157 → 9157 |
| keyed/prepend | 1000 | 5092.4 | 5222.3 | 1.03x | 1.00x | 1.00x | 93761 → 93761 |
| keyed/remove_half | 10 | 13.4 | 13.5 | 1.01x | 1.00x | 1.00x | 533 → 533 |
| keyed/remove_half | 100 | 232.5 | 203.6 | 0.88x | 1.00x | 1.00x | 4566 → 4566 |
| keyed/remove_half | 1000 | 3129.4 | 2934.7 | 0.94x | 1.00x | 1.01x | 46669 → 46669 |
| keyed/reverse | 10 | 31.3 | 30.9 | 0.99x | 1.00x | 1.00x | 774 → 774 |
| keyed/reverse | 100 | 424.7 | 452.5 | 1.07x | 1.00x | 0.94x | 8067 → 8067 |
| keyed/reverse | 1000 | 5591.2 | 5081.7 | 0.91x | 1.00x | 1.00x | 84570 → 84570 |
| reactivity/changed | 10 | 30.1 | 29.1 | 0.97x | n/a | n/a | 222 → 222 |
| reactivity/changed | 100 | 314.6 | 317.4 | 1.01x | n/a | n/a | 2383 → 2383 |
| reactivity/changed | 1000 | 4288.7 | 3975.0 | 0.93x | n/a | n/a | 25784 → 25784 |
| reactivity/unchanged | 10 | 2.0 | 1.2 | 0.59x | n/a | n/a | 2 → 2 |
| reactivity/unchanged | 100 | 4.4 | 1.5 | 0.34x | n/a | n/a | 2 → 2 |
| reactivity/unchanged | 1000 | 77.0 | 18.6 | 0.24x | n/a | n/a | 2 → 2 |
| render/leaf_state | 10 | 32.3 | 32.0 | 0.99x | n/a | n/a | 774 → 774 |
| render/leaf_state | 100 | 459.0 | 441.2 | 0.96x | n/a | n/a | 8066 → 8066 |
| render/leaf_state | 1000 | 5143.4 | 4945.2 | 0.96x | n/a | n/a | 84568 → 84568 |
| render/mount | 10 | 26.0 | 25.4 | 0.98x | 1.00x | 1.00x | 966 → 966 |
| render/mount | 100 | 396.3 | 376.2 | 0.95x | 1.00x | 1.00x | 9069 → 9069 |
| render/mount | 1000 | 4535.3 | 4054.1 | 0.89x | 1.00x | 0.99x | 93672 → 93672 |
| render/unchanged | 10 | 34.3 | 31.3 | 0.91x | 1.00x | 1.00x | 774 → 774 |
| render/unchanged | 100 | 442.8 | 426.5 | 0.96x | 1.00x | 1.00x | 8067 → 8067 |
| render/unchanged | 1000 | 5569.3 | 4809.6 | 0.86x | 1.00x | 1.01x | 84570 → 84570 |
