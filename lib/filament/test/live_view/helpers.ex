defmodule Filament.Test.LiveView.Helpers do
  @moduledoc """
  Helper functions for Rung 4 integration tests.

  These wrap Phoenix.LiveViewTest functions with Filament-specific conventions.
  Import via `use Filament.Test.LiveView`.
  """

  import Phoenix.LiveViewTest

  @compile {:no_warn_undefined, [Floki]}

  defp require_floki! do
    Code.ensure_loaded?(Floki) ||
      raise """
      Filament.Test.LiveView.Helpers requires :floki. Add to your mix.exs:

          {:floki, "~> 0.38", only: :test}
      """
  end

  @doc """
  Click the element matching `selector` in a live view.
  Wraps Phoenix.LiveViewTest.element/2 + render_click/1.
  Returns the updated rendered HTML string.
  """
  @spec filament_click(view :: term(), selector :: String.t()) :: String.t()
  def filament_click(view, selector) do
    view |> element(selector) |> render_click()
  end

  @doc """
  Submit the form matching `selector` with `params`.
  Wraps Phoenix.LiveViewTest.element/2 + render_submit/2.
  Returns the updated rendered HTML string.
  """
  @spec filament_submit(view :: term(), selector :: String.t(), params :: map()) :: String.t()
  def filament_submit(view, selector, params \\ %{}) do
    view |> element(selector) |> render_submit(params)
  end

  @doc """
  Return the current rendered text content (tags stripped) for the live view.
  """
  @spec filament_text(view :: term()) :: String.t()
  def filament_text(view) do
    require_floki!()

    view
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.trim()
  end

  @doc """
  Assert that `selector` element has CSS class `class_name` in the current render.
  Raises RuntimeError with a descriptive message on failure.
  """
  @spec assert_has_class(view :: term(), selector :: String.t(), class_name :: String.t()) :: :ok
  def assert_has_class(view, selector, class_name) do
    require_floki!()

    html = render(view)
    elements = html |> Floki.parse_fragment!() |> Floki.find(selector)

    case elements do
      [] ->
        raise RuntimeError,
          message: "assert_has_class: no element matched #{inspect(selector)}"

      elements ->
        has_it? =
          Enum.any?(elements, fn el ->
            classes =
              el
              |> Floki.attribute("class")
              |> List.first("")
              |> String.split(~r/\s+/, trim: true)

            class_name in classes
          end)

        if !has_it? do
          raise RuntimeError,
            message:
              "assert_has_class: expected #{inspect(selector)} to have class " <>
                "#{inspect(class_name)} but it did not.\nRendered:\n#{html}"
        end

        :ok
    end
  end
end
