defmodule Filament.Bench.Report do
  @moduledoc false
  alias Filament.Bench.Compat
  alias Filament.Bench.Workloads

  def run(args) do
    Application.load(:benchee)

    {opts, sizes, jobs} = parse_args(args)

    config =
      if opts[:quick],
        do: [warmup: 0.05, time: 0.1, memory_time: 0.05, reduction_time: 0.05],
        else: [warmup: 1, time: 2, memory_time: 0.5, reduction_time: 0.5]

    diagnostics = preflight(jobs, sizes)
    IO.puts("Verified #{length(diagnostics)} scenarios (#{Compat.implementation()}).")

    if !opts[:verify_only] do
      metadata = metadata(opts[:label] || Compat.implementation())
      if metadata.dirty, do: raise("commit tracked changes before recording a baseline")

      functions =
        Map.new(jobs, fn job ->
          {job, {&Workloads.run/1, before_each: &Workloads.setup(job, &1), after_each: &Workloads.check_and_cleanup/1}}
        end)

      # Benchee's allocation/reduction collectors execute the function in a
      # different process from before_each. Process-owned mailboxes/setters
      # cannot move with that input, so those jobs only use its time collector.
      owned_jobs = ["render/leaf_state", "reactivity/changed", "reactivity/unchanged"]
      {owned, pure} = Map.split(functions, owned_jobs)
      inputs = Map.new(sizes, &{Integer.to_string(&1), &1})
      common = [inputs: inputs, parallel: 1, print: [fast_warning: false]]

      scenarios =
        [{pure, config}, {owned, Keyword.merge(config, memory_time: 0, reduction_time: 0)}]
        |> Enum.reject(fn {jobs, _} -> map_size(jobs) == 0 end)
        |> Enum.flat_map(fn {jobs, measurement} -> Benchee.run(jobs, measurement ++ common).scenarios end)
        |> Enum.map(&summary/1)

      report = %{
        schema: 1,
        metadata: metadata,
        configuration: Map.put(Map.new(config), :time_only_jobs, owned_jobs),
        diagnostics: diagnostics,
        scenarios: scenarios
      }

      path = opts[:output] || "tmp/bench/#{metadata.label}.json"
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
      IO.puts("Saved #{path}")
    end
  end

  defp parse_args(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          verify_only: :boolean,
          quick: :boolean,
          output: :string,
          label: :string,
          sizes: :string,
          suite: :string
        ]
      )

    if rest != [] or invalid != [], do: raise(ArgumentError, "invalid benchmark arguments: #{inspect(rest ++ invalid)}")
    sizes = opts |> Keyword.get(:sizes, "10,100,1000") |> String.split(",") |> Enum.map(&String.to_integer/1)
    if Enum.any?(sizes, &(&1 < 2)), do: raise(ArgumentError, "sizes must be >= 2")
    jobs = Enum.filter(Workloads.jobs(), &String.starts_with?(&1, Keyword.get(opts, :suite, "")))
    if jobs == [], do: raise(ArgumentError, "no matching benchmark suite")

    {opts, sizes, jobs}
  end

  defp preflight(jobs, sizes) do
    for job <- jobs, size <- sizes do
      input = Workloads.setup(job, size)
      if input.server, do: :erlang.garbage_collect(input.server)
      before = Workloads.server_resources(input)
      {:reductions, caller_before} = Process.info(self(), :reductions)
      result = Workloads.run(input)
      {:reductions, caller_after} = Process.info(self(), :reductions)
      after_run = Workloads.server_resources(input)
      metrics = Workloads.check_and_cleanup(result)

      server =
        if before do
          %{
            server_reductions: after_run.reductions - before.reductions,
            server_memory_before_bytes: before.memory,
            server_memory_after_bytes: after_run.memory
          }
        else
          %{}
        end

      %{
        job: job,
        size: size,
        metrics: metrics |> Map.merge(server) |> Map.put(:caller_reductions_diagnostic, caller_after - caller_before)
      }
    end
  end

  defp summary(scenario) do
    %{
      job: scenario.job_name,
      size: String.to_integer(scenario.input_name),
      time_ns: stats(scenario.run_time_data.statistics),
      caller_memory_bytes: stats(scenario.memory_usage_data.statistics),
      caller_reductions: stats(scenario.reductions_data.statistics)
    }
  end

  defp stats(%{sample_size: 0}), do: nil

  defp stats(stats) do
    %{
      median: stats.median,
      average: stats.average,
      p99: stats.percentiles[99],
      std_dev_ratio: stats.std_dev_ratio,
      sample_size: stats.sample_size
    }
  end

  defp metadata(label) do
    %{
      label: label,
      recorded_at: DateTime.to_iso8601(DateTime.utc_now()),
      commit: command("git", ["rev-parse", "HEAD"]),
      library_commit: command("git", ["log", "-1", "--format=%H", "--", "lib"]),
      dirty: command("git", ["status", "--porcelain", "--untracked-files=no"]) != "",
      implementation: Compat.implementation(),
      json_library: "Jason",
      elixir: System.version(),
      otp: System.otp_release(),
      erts: to_string(:erlang.system_info(:version)),
      schedulers: :erlang.system_info(:schedulers_online),
      architecture: to_string(:erlang.system_info(:system_architecture)),
      os: inspect(:os.type()),
      cpu: cpu(),
      lock_sha256: digest(["mix.lock"]),
      harness_sha256: digest(Enum.sort(Path.wildcard("bench/**/*.exs"))),
      benchee: to_string(Application.spec(:benchee, :vsn))
    }
  end

  defp digest(paths) do
    content = Enum.map(paths, fn path -> [path, 0, File.read!(path)] end)
    :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
  end

  defp cpu do
    case :os.type() do
      {:unix, :darwin} ->
        command("sysctl", ["-n", "machdep.cpu.brand_string"])

      {:unix, :linux} ->
        "/proc/cpuinfo"
        |> File.read!()
        |> String.split("\n")
        |> Enum.find("unknown", &String.starts_with?(&1, "model name"))

      _ ->
        "unknown"
    end
  end

  defp command(command, args) do
    {output, 0} = System.cmd(command, args)
    String.trim(output)
  end
end
