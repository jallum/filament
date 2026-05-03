defmodule Filament.ObservableError do
  @moduledoc false
  defexception [:message, :observable, :reason]
end
