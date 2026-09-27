Candidate / baseline; lower is better. Times are median microseconds. Allocation/reductions cover the caller only.

| Scenario | Rows | Baseline µs | Candidate µs | Time | Allocation | Reductions | Diff bytes (base → candidate) |
|---|---:|---:|---:|---:|---:|---:|---:|
| keyed/append | 10 | 43.1 | 39.0 | 0.91x | 0.96x | 1.00x | 1056 → 1056 |
| keyed/append | 100 | 464.0 | 440.0 | 0.95x | 0.96x | 1.02x | 9163 → 9163 |
| keyed/append | 1000 | 6435.0 | 5749.6 | 0.89x | 0.96x | 1.00x | 93770 → 93770 |
| keyed/clear | 10 | 2.4 | 2.4 | 1.00x | 0.99x | 1.00x | 31 → 31 |
| keyed/clear | 100 | 27.0 | 26.8 | 0.99x | 1.00x | 1.00x | 31 → 31 |
| keyed/clear | 1000 | 255.6 | 493.1 | 1.93x | 1.00x | 0.99x | 31 → 31 |
| keyed/prepend | 10 | 43.4 | 38.3 | 0.88x | 0.96x | 0.99x | 1053 → 1053 |
| keyed/prepend | 100 | 454.7 | 429.5 | 0.94x | 0.96x | 0.99x | 9157 → 9157 |
| keyed/prepend | 1000 | 6142.7 | 5401.3 | 0.88x | 0.96x | 1.00x | 93761 → 93761 |
| keyed/remove_half | 10 | 15.5 | 14.4 | 0.93x | 0.96x | 1.00x | 533 → 533 |
| keyed/remove_half | 100 | 203.3 | 208.9 | 1.03x | 0.96x | 1.00x | 4566 → 4566 |
| keyed/remove_half | 1000 | 3161.2 | 3213.9 | 1.02x | 0.96x | 1.00x | 46669 → 46669 |
| keyed/reverse | 10 | 34.5 | 31.8 | 0.92x | 0.95x | 1.00x | 774 → 774 |
| keyed/reverse | 100 | 462.2 | 504.9 | 1.09x | 0.96x | 1.00x | 8067 → 8067 |
| keyed/reverse | 1000 | 5264.0 | 5865.3 | 1.11x | 0.96x | 1.01x | 84570 → 84570 |
| reactivity/changed | 10 | 29.8 | 28.8 | 0.97x | n/a | n/a | 222 → 222 |
| reactivity/changed | 100 | 327.4 | 296.6 | 0.91x | n/a | n/a | 2383 → 2383 |
| reactivity/changed | 1000 | 4245.9 | 4075.9 | 0.96x | n/a | n/a | 25784 → 25784 |
| reactivity/unchanged | 10 | 3.0 | 2.0 | 0.67x | n/a | n/a | 2 → 2 |
| reactivity/unchanged | 100 | 27.6 | 3.8 | 0.14x | n/a | n/a | 2 → 2 |
| reactivity/unchanged | 1000 | 208.3 | 67.7 | 0.32x | n/a | n/a | 2 → 2 |
| render/leaf_state | 10 | 34.1 | 31.5 | 0.93x | n/a | n/a | 774 → 774 |
| render/leaf_state | 100 | 475.5 | 421.9 | 0.89x | n/a | n/a | 8066 → 8066 |
| render/leaf_state | 1000 | 5634.9 | 4885.5 | 0.87x | n/a | n/a | 84568 → 84568 |
| render/mount | 10 | 27.8 | 25.2 | 0.91x | 0.96x | 0.96x | 966 → 966 |
| render/mount | 100 | 423.7 | 400.2 | 0.94x | 0.96x | 1.00x | 9069 → 9069 |
| render/mount | 1000 | 4831.6 | 4518.7 | 0.94x | 0.96x | 1.00x | 93672 → 93672 |
| render/unchanged | 10 | 34.4 | 31.7 | 0.92x | 0.95x | 1.00x | 774 → 774 |
| render/unchanged | 100 | 449.1 | 441.9 | 0.98x | 0.96x | 1.00x | 8067 → 8067 |
| render/unchanged | 1000 | 5652.7 | 5134.8 | 0.91x | 0.96x | 0.98x | 84570 → 84570 |
