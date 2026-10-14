Candidate / baseline; lower is better. Times are median microseconds. Allocation/reductions cover the caller only.

| Scenario | Rows | Baseline µs | Candidate µs | Time | Allocation | Reductions | Diff bytes (base → candidate) |
|---|---:|---:|---:|---:|---:|---:|---:|
| keyed/append | 10 | 26.4 | 39.0 | 1.48x | 1.25x | 1.05x | 1065 → 1056 |
| keyed/append | 100 | 422.8 | 440.0 | 1.04x | 1.23x | 1.08x | 9263 → 9163 |
| keyed/append | 1000 | 6262.0 | 5749.6 | 0.92x | 1.21x | 0.99x | 94771 → 93770 |
| keyed/clear | 10 | 1.5 | 2.4 | 1.57x | 1.22x | 1.09x | 20 → 31 |
| keyed/clear | 100 | 20.7 | 26.8 | 1.30x | 1.13x | 1.10x | 20 → 31 |
| keyed/clear | 1000 | 187.0 | 493.1 | 2.64x | 1.12x | 1.09x | 20 → 31 |
| keyed/prepend | 10 | 27.3 | 38.3 | 1.41x | 1.23x | 1.01x | 1112 → 1053 |
| keyed/prepend | 100 | 389.8 | 429.5 | 1.10x | 1.20x | 1.02x | 9757 → 9157 |
| keyed/prepend | 1000 | 5891.1 | 5401.3 | 0.92x | 1.19x | 0.95x | 100662 → 93761 |
| keyed/remove_half | 10 | 10.6 | 14.4 | 1.35x | 1.30x | 1.15x | 455 → 533 |
| keyed/remove_half | 100 | 169.7 | 208.9 | 1.23x | 1.22x | 1.07x | 4534 → 4566 |
| keyed/remove_half | 1000 | 4155.1 | 3213.9 | 0.77x | 1.21x | 0.94x | 47088 → 46669 |
| keyed/reverse | 10 | 25.5 | 31.8 | 1.25x | 1.14x | 0.95x | 944 → 774 |
| keyed/reverse | 100 | 310.6 | 504.9 | 1.63x | 1.13x | 0.99x | 9588 → 8067 |
| keyed/reverse | 1000 | 5610.0 | 5865.3 | 1.05x | 1.13x | 0.93x | 100492 → 84570 |
| reactivity/changed | 10 | 18.5 | 28.8 | 1.56x | n/a | n/a | 432 → 222 |
| reactivity/changed | 100 | 325.0 | 296.6 | 0.91x | n/a | n/a | 4304 → 2383 |
| reactivity/changed | 1000 | 6492.0 | 4075.9 | 0.63x | n/a | n/a | 44806 → 25784 |
| reactivity/unchanged | 10 | 1.2 | 2.0 | 1.71x | n/a | n/a | 2 → 2 |
| reactivity/unchanged | 100 | 1.6 | 3.8 | 2.39x | n/a | n/a | 2 → 2 |
| reactivity/unchanged | 1000 | 4.0 | 67.7 | 17.10x | n/a | n/a | 2 → 2 |
| render/leaf_state | 10 | 23.5 | 31.5 | 1.34x | n/a | n/a | 894 → 774 |
| render/leaf_state | 100 | 373.0 | 421.9 | 1.13x | n/a | n/a | 9087 → 8066 |
| render/leaf_state | 1000 | 5466.5 | 4885.5 | 0.89x | n/a | n/a | 94590 → 84568 |
| render/mount | 10 | 19.3 | 25.2 | 1.30x | 1.17x | 1.00x | 1073 → 966 |
| render/mount | 100 | 266.1 | 400.2 | 1.50x | 1.17x | 1.02x | 9807 → 9069 |
| render/mount | 1000 | 3335.1 | 4518.7 | 1.35x | 1.16x | 1.03x | 100711 → 93672 |
| render/unchanged | 10 | 32.0 | 31.7 | 0.99x | 1.17x | 0.98x | 894 → 774 |
| render/unchanged | 100 | 359.9 | 441.9 | 1.23x | 1.16x | 1.00x | 9088 → 8067 |
| render/unchanged | 1000 | 5901.4 | 5134.8 | 0.87x | 1.15x | 0.93x | 94592 → 84570 |
