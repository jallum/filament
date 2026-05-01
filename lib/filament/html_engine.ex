defmodule Filament.HTMLEngine do
  @moduledoc """
  Tag handler for the ~F sigil that delegates to Phoenix.LiveView.HTMLEngine
  while adding Filament-specific validations and behaviors.
  """

  @behaviour Phoenix.LiveView.TagEngine

  # For Phase 1, delegate everything to HTMLEngine
  # Phase 2 will add :key enforcement for :for comprehensions
  # Phase 3 may add bare-module syntax support

  def classify_type(name) do
    Phoenix.LiveView.HTMLEngine.classify_type(name)
  end

  def handle_attributes(ast, meta) do
    ast = transform_event_attrs(ast)
    Phoenix.LiveView.HTMLEngine.handle_attributes(ast, meta)
  end

  defp transform_event_attrs({:{}, _, _} = tuple) do
    # Static attribute list — unlikely at top level, pass through
    tuple
  end

  defp transform_event_attrs({:%{}, meta, pairs}) do
    {:%{}, meta, Enum.map(pairs, &transform_event_pair/1)}
  end

  defp transform_event_attrs({:__block__, meta, exprs}) do
    {:__block__, meta, Enum.map(exprs, &transform_event_attrs/1)}
  end

  defp transform_event_attrs(other), do: other

  defp transform_event_pair({k, v}) do
    case k do
      "on_click" ->
        {"phx-click", quote(do: Filament.Hooks.register_event_handler(unquote(v)))}

      "on_submit" ->
        {"phx-submit", quote(do: Filament.Hooks.register_event_handler(unquote(v)))}

      _other ->
        {k, v}
    end
  end

  def void?(name) do
    Phoenix.LiveView.HTMLEngine.void?(name)
  end

  def annotate_caller(file, line) do
    Phoenix.LiveView.HTMLEngine.annotate_caller(file, line)
  end

  def annotate_body(caller) do
    Phoenix.LiveView.HTMLEngine.annotate_body(caller)
  end

  def annotate_slot(name, tag_meta, close_meta, caller) do
    Phoenix.LiveView.HTMLEngine.annotate_slot(name, tag_meta, close_meta, caller)
  end
end
