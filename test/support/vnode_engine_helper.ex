defmodule Filament.Test.VNodeEngineHelper do
  @moduledoc false
  @doc """
  Compile a template source through `Filament.VNodeEngine` at the call site's
  compile time. Used by Phase 1.4 tests that need to exercise macro components
  (e.g. colocated hooks) — those write to the caller module's attributes and
  thus must run during the caller's `defmodule` body.
      defmodule MyFixture do
        use Filament.Component
        import Filament.Test.VNodeEngineHelper
        def template, do: vnode_template ~s\"\"\"
          <div>...</div>
        \"\"\"
      end
  """
  defmacro vnode_template(source) do
    Filament.TagEngine.compile(source,
      caller: __CALLER__,
      file: __CALLER__.file,
      line: __CALLER__.line,
      indentation: 0,
      tag_handler: Filament.HTMLEngine
    )
  end
end
