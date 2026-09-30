Candidate / baseline; lower is better. Times are median microseconds. Allocation/reductions cover the caller only.

| Scenario | Rows | Baseline µs | Candidate µs | Time | Allocation | Reductions | Diff bytes (base → candidate) |
|---|---:|---:|---:|---:|---:|---:|---:|
| keyed/append | 10 | 26.4 | 43.1 | 1.63x | 1.31x | 1.04x | 1065 → 1056 |
| keyed/append | 100 | 422.8 | 464.0 | 1.10x | 1.28x | 1.06x | 9263 → 9163 |
| keyed/append | 1000 | 6262.0 | 6435.0 | 1.03x | 1.26x | 0.99x | 94771 → 93770 |
| keyed/clear | 10 | 1.5 | 2.4 | 1.57x | 1.24x | 1.09x | 20 → 31 |
| keyed/clear | 100 | 20.7 | 27.0 | 1.31x | 1.13x | 1.10x | 20 → 31 |
| keyed/clear | 1000 | 187.0 | 255.6 | 1.37x | 1.12x | 1.10x | 20 → 31 |
| keyed/prepend | 10 | 27.3 | 43.4 | 1.59x | 1.28x | 1.03x | 1112 → 1053 |
| keyed/prepend | 100 | 389.8 | 454.7 | 1.17x | 1.25x | 1.03x | 9757 → 9157 |
| keyed/prepend | 1000 | 5891.1 | 6142.7 | 1.04x | 1.24x | 0.95x | 100662 → 93761 |
| keyed/remove_half | 10 | 10.6 | 15.5 | 1.46x | 1.36x | 1.15x | 455 → 533 |
| keyed/remove_half | 100 | 169.7 | 203.3 | 1.20x | 1.26x | 1.07x | 4534 → 4566 |
| keyed/remove_half | 1000 | 4155.1 | 3161.2 | 0.76x | 1.25x | 0.94x | 47088 → 46669 |
| keyed/reverse | 10 | 25.5 | 34.5 | 1.35x | 1.20x | 0.95x | 944 → 774 |
| keyed/reverse | 100 | 310.6 | 462.2 | 1.49x | 1.18x | 0.99x | 9588 → 8067 |
| keyed/reverse | 1000 | 5610.0 | 5264.0 | 0.94x | 1.18x | 0.92x | 100492 → 84570 |
| reactivity/changed | 10 | 18.5 | 29.8 | 1.61x | n/a | n/a | 432 → 222 |
| reactivity/changed | 100 | 325.0 | 327.4 | 1.01x | n/a | n/a | 4304 → 2383 |
| reactivity/changed | 1000 | 6492.0 | 4245.9 | 0.65x | n/a | n/a | 44806 → 25784 |
| reactivity/unchanged | 10 | 1.2 | 3.0 | 2.57x | n/a | n/a | 2 → 2 |
| reactivity/unchanged | 100 | 1.6 | 27.6 | 17.41x | n/a | n/a | 2 → 2 |
| reactivity/unchanged | 1000 | 4.0 | 208.3 | 52.62x | n/a | n/a | 2 → 2 |
| render/leaf_state | 10 | 23.5 | 34.1 | 1.45x | n/a | n/a | 894 → 774 |
| render/leaf_state | 100 | 373.0 | 475.5 | 1.27x | n/a | n/a | 9087 → 8066 |
| render/leaf_state | 1000 | 5466.5 | 5634.9 | 1.03x | n/a | n/a | 94590 → 84568 |
| render/mount | 10 | 19.3 | 27.8 | 1.44x | 1.22x | 1.04x | 1073 → 966 |
| render/mount | 100 | 266.1 | 423.7 | 1.59x | 1.22x | 1.02x | 9807 → 9069 |
| render/mount | 1000 | 3335.1 | 4831.6 | 1.45x | 1.21x | 1.03x | 100711 → 93672 |
| render/unchanged | 10 | 32.0 | 34.4 | 1.07x | 1.23x | 0.98x | 894 → 774 |
| render/unchanged | 100 | 359.9 | 449.1 | 1.25x | 1.21x | 1.00x | 9088 → 8067 |
| render/unchanged | 1000 | 5901.4 | 5652.7 | 0.96x | 1.20x | 0.95x | 94592 → 84570 |
