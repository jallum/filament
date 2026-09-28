for file <- ~w(compat fixtures workloads report), do: Code.require_file("support/#{file}.exs", __DIR__)
Filament.Bench.Report.run(System.argv())
