Candidate / baseline; lower is better. Times are median microseconds. Allocation/reductions cover the caller only.

| Scenario | Rows | Baseline µs | Candidate µs | Time | Allocation | Reductions | Diff bytes (base → candidate) |
|---|---:|---:|---:|---:|---:|---:|---:|
| keyed/append | 10 | 26.9 | 36.9 | 1.37x | 1.25x | 1.05x | 1065 → 1056 |
| keyed/append | 100 | 399.5 | 412.0 | 1.03x | 1.23x | 1.04x | 9263 → 9163 |
| keyed/append | 1000 | 6174.5 | 5020.7 | 0.81x | 1.21x | 0.98x | 94771 → 93770 |
| keyed/clear | 10 | 1.5 | 2.3 | 1.49x | 1.22x | 1.09x | 20 → 31 |
| keyed/clear | 100 | 20.8 | 25.5 | 1.22x | 1.13x | 1.10x | 20 → 31 |
| keyed/clear | 1000 | 194.3 | 437.4 | 2.25x | 1.12x | 1.09x | 20 → 31 |
| keyed/prepend | 10 | 27.3 | 36.4 | 1.33x | 1.23x | 1.01x | 1112 → 1053 |
| keyed/prepend | 100 | 419.7 | 429.1 | 1.02x | 1.20x | 1.02x | 9757 → 9157 |
| keyed/prepend | 1000 | 5545.6 | 4948.5 | 0.89x | 1.19x | 0.95x | 100662 → 93761 |
| keyed/remove_half | 10 | 16.2 | 13.6 | 0.84x | 1.30x | 1.15x | 455 → 533 |
| keyed/remove_half | 100 | 174.0 | 200.8 | 1.15x | 1.22x | 1.07x | 4534 → 4566 |
| keyed/remove_half | 1000 | 3753.0 | 2882.1 | 0.77x | 1.21x | 0.94x | 47088 → 46669 |
| keyed/reverse | 10 | 24.0 | 31.0 | 1.29x | 1.14x | 0.95x | 944 → 774 |
| keyed/reverse | 100 | 358.0 | 427.9 | 1.20x | 1.13x | 1.04x | 9588 → 8067 |
| keyed/reverse | 1000 | 5831.0 | 4997.9 | 0.86x | 1.13x | 0.92x | 100492 → 84570 |
| reactivity/changed | 10 | 25.5 | 29.6 | 1.16x | n/a | n/a | 432 → 222 |
| reactivity/changed | 100 | 288.7 | 326.9 | 1.13x | n/a | n/a | 4304 → 2383 |
| reactivity/changed | 1000 | 6554.7 | 4722.8 | 0.72x | n/a | n/a | 44806 → 25784 |
| reactivity/unchanged | 10 | 1.6 | 1.3 | 0.82x | n/a | n/a | 2 → 2 |
| reactivity/unchanged | 100 | 1.5 | 1.7 | 1.11x | n/a | n/a | 2 → 2 |
| reactivity/unchanged | 1000 | 4.0 | 17.1 | 4.27x | n/a | n/a | 2 → 2 |
| render/leaf_state | 10 | 23.3 | 34.0 | 1.46x | n/a | n/a | 894 → 774 |
| render/leaf_state | 100 | 391.9 | 476.8 | 1.22x | n/a | n/a | 9087 → 8066 |
| render/leaf_state | 1000 | 5501.7 | 5533.0 | 1.01x | n/a | n/a | 94590 → 84568 |
| render/mount | 10 | 20.7 | 25.5 | 1.23x | 1.17x | 1.00x | 1073 → 966 |
| render/mount | 100 | 292.2 | 376.4 | 1.29x | 1.17x | 1.02x | 9807 → 9069 |
| render/mount | 1000 | 3393.4 | 5035.6 | 1.48x | 1.16x | 1.03x | 100711 → 93672 |
| render/unchanged | 10 | 23.6 | 32.1 | 1.36x | 1.17x | 0.98x | 894 → 774 |
| render/unchanged | 100 | 420.6 | 459.0 | 1.09x | 1.16x | 1.00x | 9088 → 8067 |
| render/unchanged | 1000 | 5472.1 | 8561.9 | 1.56x | 1.15x | 0.95x | 94592 → 84570 |
