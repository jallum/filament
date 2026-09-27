# Reference measurements

`main-355e421.json` measures main 0.5.1 with the benchmark harness at
`222446f794e45480597dac353bd12806647886c1`. Its metadata identifies the last
library-changing commit separately from the full harness revision.

Command: `ERL_FLAGS='+S 4:4' mix run bench/run.exs --label main --output tmp/bench/main.json`

This is one local run on an Apple M4 Pro, Elixir 1.19.4 / OTP 28, with four
schedulers. Use the report metadata and comparison script to check compatibility.
Repeat measurements before treating small differences as regressions. These
numbers are a reference, not a CI performance threshold. See ../README.md for
measurement scope and process-owned scenario limitations.
