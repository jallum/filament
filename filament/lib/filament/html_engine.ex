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
    Phoenix.LiveView.HTMLEngine.handle_attributes(ast, meta)
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
