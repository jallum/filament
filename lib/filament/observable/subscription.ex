defmodule Filament.Observable.Subscription do
  @moduledoc false

  # Client-side hook state. The projection is refreshed on every render;
  # notifications retain the latest raw state even when the value is unchanged.
  @enforce_keys [:server, :raw, :project, :value]
  defstruct [:server, :raw, :project, :value]
end
