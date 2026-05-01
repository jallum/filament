defmodule Filament.Test.LiveView do
  @moduledoc """
  Rung 4 test helpers for Filament components running in a full LiveView.

  Usage in a test module:

      defmodule MyFeatureTest do
        use Filament.Test.LiveView, endpoint: MyApp.Endpoint
      end

  This brings in Phoenix.LiveViewTest, ExUnit.Case, and the helpers below.
  """

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, async: false
      use Phoenix.LiveViewTest

      import Filament.Test.LiveView.Helpers

      setup do
        endpoint = unquote(opts[:endpoint])

        unless endpoint do
          raise "Filament.Test.LiveView requires endpoint: MyApp.Endpoint"
        end

        :ok
      end
    end
  end
end
