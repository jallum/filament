[baseline_path, candidate_path] = System.argv()
baseline = baseline_path |> File.read!() |> Jason.decode!()
candidate = candidate_path |> File.read!() |> Jason.decode!()

for key <- ~w(elixir otp erts schedulers architecture os cpu lock_sha256 harness_sha256 benchee) do
  if baseline["metadata"][key] != candidate["metadata"][key], do: raise("incompatible baseline: #{key} differs")
end

if baseline["configuration"] != candidate["configuration"], do: raise("measurement configuration differs")
key = fn row -> {row["job"], row["size"]} end
reference = Map.new(baseline["scenarios"], &{key.(&1), &1})
current = Map.new(candidate["scenarios"], &{key.(&1), &1})
if Enum.sort(Map.keys(reference)) != Enum.sort(Map.keys(current)), do: raise("scenario sets differ")
base_metrics = Map.new(baseline["diagnostics"], &{key.(&1), &1["metrics"]})
new_metrics = Map.new(candidate["diagnostics"], &{key.(&1), &1["metrics"]})
ratio = fn new, old -> if old == 0, do: "n/a", else: :erlang.float_to_binary(new / old, decimals: 2) <> "x" end

IO.puts(
  "Candidate / baseline; lower is better. Times are median microseconds. Allocation/reductions cover the caller only.\n"
)

IO.puts(
  "| Scenario | Rows | Baseline µs | Candidate µs | Time | Allocation | Reductions | Diff bytes (base → candidate) |"
)

IO.puts("|---|---:|---:|---:|---:|---:|---:|---:|")

for {{job, size} = id, row} <- Enum.sort(current) do
  old = reference[id]
  time = row["time_ns"]["median"]
  old_time = old["time_ns"]["median"]

  IO.puts(
    "| #{job} | #{size} | #{Float.round(old_time / 1000, 1)} | #{Float.round(time / 1000, 1)} | #{ratio.(time, old_time)} | #{ratio.(row["caller_memory_bytes"]["median"], old["caller_memory_bytes"]["median"])} | #{ratio.(row["caller_reductions"]["median"], old["caller_reductions"]["median"])} | #{base_metrics[id]["diff_bytes"]} → #{new_metrics[id]["diff_bytes"]} |"
  )
end
