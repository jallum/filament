#!/usr/bin/env bash
set -euo pipefail

# Create Track B epic first, capture its ID
EPIC_ID=$(bw create "Track B: Fiber runtime and reconciler" \
  --type epic \
  --priority 1 \
  --description "Core runtime for Filament. Builds the fiber tree data structures, the defcomponent macro, the ~F sigil, a pure render walk, the reconciler, and finally the LiveView adapter that plugs it all in.

This epic is the critical path for the entire project. Nothing else in tracks C–I can begin until B7 is merged.

Project root: /Users/j5n/Workspace/filament/filament/
Phoenix LiveView target: ~> 1.0 (phoenix_live_view 1.0.x)
Elixir target: ~> 1.17

Delivery order: B0 → B1, B2 (parallel) → B3 → B4 → B5 → B6 → B7" \
  --silent)

echo "Epic: $EPIC_ID"

# ─────────────────────────────────────────────────────────
# B0 — Spike: LiveView deps + Rendered IR documentation
# ─────────────────────────────────────────────────────────
B0=$(bw create "B0: Spike — add LiveView deps and document Rendered IR" \
  --type task \
  --priority 1 \
  --parent "$EPIC_ID" \
  --description "## Goal

Add phoenix_live_view as a dependency and write a test file that documents — through working examples — the exact format that Phoenix.LiveView.Diff expects. This is a knowledge ticket. Its deliverable is annotated code, not production modules. It MUST be closed before B4 (~F sigil) begins.

## Why this ticket exists

The ~F sigil (B4) must produce %Phoenix.LiveView.Rendered{} structs with a static/dynamic split that is byte-identical to what ~H produces. A naïve implementation that re-serialises subtrees to strings on every render will blow up the wire format. Before writing any framework code, we need to understand precisely what the IR looks like and verify our mental model against a running system.

## Step 1 — Add dependencies

In mix.exs, add to defp deps:

  {:phoenix, \"~> 1.7\"},
  {:phoenix_live_view, \"~> 1.0\"},
  {:phoenix_html, \"~> 4.0\"},
  {:plug, \"~> 1.16\", only: :test},
  {:plug_cowboy, \"~> 2.7\", only: :test}

Run: mix deps.get

These are needed at runtime (phoenix_live_view) and for integration tests (plug_cowboy). Add :phoenix_live_view to the :extra_applications list in application/0 if needed.

## Step 2 — Study the structs

Read these files in the freshly-fetched deps:

  deps/phoenix_live_view/lib/phoenix_live_view/engine.ex
    - Phoenix.LiveView.Rendered  (line ~108)  defstruct [:static, :dynamic, :fingerprint, :root, caller: :not_available]
      - :static   — [String.t()]           — list of template string chunks between interpolations
      - :dynamic  — (boolean() -> [dyn()]) — fn receiving changed? boolean, returns list of dynamic values
      - :fingerprint — integer()           — compile-time hash of the static parts, stable per call site
    - Phoenix.LiveView.Comprehension  (line ~58)   — what :for comprehensions produce
    - Phoenix.LiveView.Component      (line ~1)    — what LiveComponent references produce

  deps/phoenix_live_view/lib/phoenix_component.ex  line ~914
    - defmacro sigil_H/2 — calls Phoenix.LiveView.TagEngine.compile/2 with tag_handler: Phoenix.LiveView.HTMLEngine

  deps/phoenix_live_view/lib/phoenix_live_view/html_engine.ex
    - classify_type/1 — how tag names are categorised (:tag, :remote_component, :local_component, :slot)
    - classify_type(<<first, _::binary>> = name) when first in ?A..?Z  →  {:remote_component, name}

## Step 3 — Write the spike test file

Create test/b0_rendered_ir_spike_test.exs. It should NOT be a normal ExUnit test with assertions — it is a literate specification. Use @moduledoc and inline comments extensively.

The file must compile and run (mix test test/b0_rendered_ir_spike_test.exs) with no errors.

Include at minimum these three annotated examples:

### Example 1 — Static template

Manually construct a %Phoenix.LiveView.Rendered{} for the template:
  <div class=\"box\">hello</div>
That is: static = [\"<div class=\\\"box\\\">hello</div>\"], dynamic = fn _ -> [] end, fingerprint = <any stable integer>

Verify that Phoenix.HTML.Safe.to_iodata/1 on this struct produces the expected HTML string. This confirms the struct is valid.

### Example 2 — One dynamic interpolation

Manually construct %Phoenix.LiveView.Rendered{} equivalent to:
  <p><%= @text %></p>
Static parts split around the interpolation: [\"\", \"<p>\", \"</p>\"] — wait, actually it should be [\"<p>\", \"</p>\"] with dynamic = fn _ -> [some_value] end
(Use the actual ~H sigil on an equivalent Phoenix.Component to see what the compiler generates, then reproduce it manually.)

Use Code.quoted_to_algebra or IO.inspect to show what ~H actually produces. Include that output as a comment so future readers understand the format.

### Example 3 — Nested component reference

In ~H, a remote component like <Module.func /> produces a %Phoenix.LiveView.Component{id: ..., component: Module, assigns: ...} in the dynamic section. Demonstrate this. Then show: what happens when the dynamic section contains a %Phoenix.LiveView.Rendered{} instead of a %Phoenix.LiveView.Component{}? (This is the approach Filament will use for inline component rendering.)

## Key questions to answer in comments

1. What is `root` on %Rendered{}? (Hint: true means this is the outermost rendered struct)
2. What does the `changed?` boolean argument to dynamic/1 do? When is it true vs false?
3. Does Phoenix.LiveView.Diff accept a %Rendered{} in the dynamic list of a parent %Rendered{}? (Answer: yes — this is how nested components work without LiveComponent overhead)
4. What happens with fingerprint collisions? Is it truly just an integer hash?

## Acceptance criteria

- mix deps.get succeeds and adds phoenix_live_view ~> 1.0 to mix.lock
- mix test test/b0_rendered_ir_spike_test.exs passes (no assertions needed — just compile and run)
- The test file contains at least 80 lines of annotated examples and comments
- mix compile --warnings-as-errors passes after adding the deps
- The four key questions above are answered in comments

## Do NOT

- Write any production code in lib/ during this ticket
- Implement any Filament modules
- Write any tests for Filament functionality" \
  --silent)

echo "B0: $B0"

# ─────────────────────────────────────────────────────────
# B1 — Filament.Fiber struct
# ─────────────────────────────────────────────────────────
B1=$(bw create "B1: Define Filament.Fiber struct and typespecs" \
  --type task \
  --priority 1 \
  --parent "$EPIC_ID" \
  --description "## Goal

Create lib/filament/fiber.ex defining the %Filament.Fiber{} struct. This is the core in-memory node in the fiber tree — one per mounted component instance.

No dependency on the spike (B0) — can run in parallel with it.

## The struct

defmodule Filament.Fiber do
  @enforce_keys [:id, :component]
  defstruct [
    :id,          # String.t()        — stable path-based identifier, see below
    :key,         # term() | nil      — explicit :key from parent, used by reconciler
    :component,   # module()          — the component module (implements render/1)
    :props,       # map()             — current props passed to this fiber, default %{}
    :hook_slots,  # list()            — [{slot_index :: non_neg_integer(), value :: term()}], default []
    :children,    # [String.t()]      — ordered child fiber IDs, default []
    :parent_id,   # String.t() | nil  — nil for the root fiber
    :status       # :mounting | :stable | :updating | :unmounting — default :mounting
  ]
end

Add a @type t :: %__MODULE__{...} with full field types.

## ID generation

Fiber IDs are path-based strings, not random UUIDs. Stability across re-renders is required for the reconciler to match instances.

Rules:
- Root fiber: \"root\"
- Indexed child (no key): parent_id <> \".\" <> to_string(component) <> \"[\" <> to_string(index) <> \"]\"
  e.g. \"root.Elixir.CartView[0]\"
- Keyed child: parent_id <> \".\" <> to_string(component) <> \"[key=\" <> inspect(key) <> \"]\"
  e.g. \"root.Elixir.CartView[key=42]\"

Implement:
  Filament.Fiber.new/1  — accepts keyword list, validates @enforce_keys, sets defaults
  Filament.Fiber.child_id/3  — child_id(parent_fiber, component_module, key_or_index)
    where key_or_index is {:key, term()} | {:index, non_neg_integer()}

## Tests

Create test/filament/fiber_test.exs. Cover:
  1. new/1 with all fields — struct is created correctly
  2. new/1 without :id raises KeyError (enforce_keys)
  3. new/1 without :component raises KeyError (enforce_keys)
  4. new/1 sets :status default to :mounting
  5. child_id/3 with {:index, 0} produces deterministic string
  6. child_id/3 with {:key, \"abc\"} produces deterministic string
  7. child_id/3 called twice with same args produces identical ID (idempotent)
  8. child_id/3 with different keys produces different IDs

## Acceptance criteria

- mix test test/filament/fiber_test.exs passes with zero failures
- mix compile --warnings-as-errors passes
- dialyzer passes on lib/filament/fiber.ex (run: mix dialyzer)" \
  --silent)

echo "B1: $B1"

# ─────────────────────────────────────────────────────────
# B2 — VNode IR types
# ─────────────────────────────────────────────────────────
B2=$(bw create "B2: Define VNode IR types (Filament.VNode)" \
  --type task \
  --priority 1 \
  --parent "$EPIC_ID" \
  --description "## Goal

Create lib/filament/vnode.ex defining the VNode type system. VNodes are the intermediate representation that a component's render/1 function returns. The renderer (B5) later resolves VNodes into %Phoenix.LiveView.Rendered{} structs.

Can run in parallel with B1 and the B0 spike.

## Why tagged tuples, not structs

VNodes are pattern-matched heavily during the render walk. Tagged tuples are faster and produce less GC pressure than structs for this use case. Each variant is a tuple with a leading atom tag.

## The five variants

Define these in lib/filament/vnode.ex:

### :text
  {:text, content :: iodata()}
  A text node. content may be a binary or iolist.

### :element
  {:element, tag :: binary(), attrs :: [{binary(), term()}], children :: [t()]}
  An HTML element. tag is a lowercase binary (\"div\", \"span\"). attrs is a keyword-style
  list of {name, value} pairs where value may be a binary, boolean, or nil (nil = omit attr).
  children is a list of vnodes.

### :component
  {:component, module :: module(), props :: map(), key :: term() | nil}
  A reference to a child Filament component. Not rendered immediately — the render walk
  resolves it by calling module.render(props).
  key must be non-nil when this vnode appears inside a :keyed_list.

### :fragment
  {:fragment, children :: [t()]}
  A transparent grouping with no corresponding DOM node. Used for conditional blocks
  and multi-root component output.

### :keyed_list
  {:keyed_list, items :: [{key :: term(), vnode :: t()}]}
  An explicitly-keyed list of vnodes. The reconciler uses the key to match instances
  across renders. Duplicate keys are a runtime error.

## Type definition

@type t ::
  {:text, iodata()}
  | {:element, binary(), [{binary(), term()}], [t()]}
  | {:component, module(), map(), term() | nil}
  | {:fragment, [t()]}
  | {:keyed_list, [{term(), t()}]}

## Validation

Implement Filament.VNode.validate!/1 which recursively validates a vnode tree.
It raises %Filament.VNode.Error{} (define this exception) if:
  1. A :keyed_list contains duplicate keys — message: \"duplicate key #{inspect key} in keyed list\"
  2. A :keyed_list item's vnode is itself a :keyed_list (no nested keyed lists at same level)
  3. A :component vnode inside a :keyed_list has key: nil — message: \"component #{inspect mod} inside keyed_list must have a non-nil key\"

validate!/1 returns the vnode unchanged if valid (for use in pipelines).

## Tests

Create test/filament/vnode_test.exs. Cover:
  1. Each of the five variant types constructs as expected (pattern match succeeds)
  2. validate!/1 accepts a well-formed :keyed_list with unique keys
  3. validate!/1 raises on duplicate keys in :keyed_list
  4. validate!/1 accepts a :component with key: nil when NOT inside :keyed_list
  5. validate!/1 raises on a :component with key: nil when inside :keyed_list
  6. validate!/1 accepts a deeply nested tree with :fragment, :element, :text
  7. validate!/1 returns the vnode unchanged when valid

## Acceptance criteria

- mix test test/filament/vnode_test.exs passes
- mix compile --warnings-as-errors passes
- @type t is defined and complete
- %Filament.VNode.Error{} is a proper defexception with a :message field" \
  --silent)

echo "B2: $B2"

# ─────────────────────────────────────────────────────────
# B3 — defcomponent macro
# ─────────────────────────────────────────────────────────
B3=$(bw create "B3: Implement defcomponent macro and Filament.Component behaviour" \
  --type task \
  --priority 1 \
  --parent "$EPIC_ID" \
  --description "## Goal

Create lib/filament/component.ex implementing the defcomponent macro and the Filament.Component behaviour. This is how application developers define Filament components.

Depends on: B1 (%Filament.Fiber{}), B2 (VNode types).
B0 spike is not required before starting this ticket, but read it before writing render/1 docs.

## What defcomponent does

defcomponent is a macro that defines a module with:
  1. Prop declarations via the prop/3 macro
  2. Compile-time typespec generation for the props map
  3. Runtime prop validation (raises on missing required props)
  4. The render/1 contract (user-defined, macro enforces it exists)
  5. __filament_component__?/0 marker function

## Usage shape (from the proposal)

  defcomponent TodoItem do
    prop :todo,      Todo,      required: true
    prop :on_toggle, :function, required: true
    prop :class,     :string,   default: \"\"

    def render(%{todo: todo, on_toggle: on_toggle, class: class}) do
      ~F\"\"\"
      <li class={class}>
        <span on_click={fn -> on_toggle.(todo.id) end}>{todo.text}</span>
      </li>
      \"\"\"
    end
  end

After macro expansion, TodoItem is a normal Elixir module.

## Prop type atoms

Support these type atoms: :string, :integer, :float, :boolean, :atom, :map, :list,
:function, :any. Also allow any module name (e.g. Todo, MyApp.Cart) for struct types.

## Generated code (what the macro produces)

Given prop declarations, the macro generates:

  @props [todo: %{type: Todo, required: true, default: :__no_default__},
          on_toggle: %{type: :function, required: true, default: :__no_default__},
          class: %{type: :string, required: false, default: \"\"}]

  @type props() :: %{
    required(:todo) => Todo.t(),
    required(:on_toggle) => (... -> any()),
    optional(:class) => String.t()
  }

  def __filament_component__?, do: true
  def __props__, do: @props

  def __validate_props__!(props) when is_map(props) do
    # check each required prop exists in the map
    # raises ArgumentError with message: \"required prop :todo missing from #{inspect props}\"
  end

The typespec for :function is (... -> any()). For module types (structs), use ModuleName.t()
if the module exports it, otherwise term().

## Compile-time enforcement

After the defcomponent block closes, use @after_compile or Module.defines?/2 to verify that
render/1 is defined. If not, raise a compile error:
  CompileError, \"defcomponent #{name} must define render/1\"

## Filament.Component behaviour

Separately, define the behaviour:
  @callback render(props()) :: Phoenix.LiveView.Rendered.t()

Components automatically implement this via defcomponent. Application code can also
implement it directly (without defcomponent) for advanced cases.

The behaviour also defines:
  @optional_callbacks [__validate_props__!: 1, __props__: 0]

## Tests

Create test/filament/component_test.exs. Cover:
  1. A minimal defcomponent with one required prop compiles without error
  2. Calling __filament_component__?() on the generated module returns true
  3. Calling __validate_props__!(%{todo: %{}}) with required prop present — no raise
  4. Calling __validate_props__!(%{}) with required prop absent — raises ArgumentError
    with the prop name in the message
  5. Default props: calling __validate_props__!(%{}) when all props have defaults — no raise
    AND __props__ shows the default values
  6. defcomponent without a def render/1 block raises a compile error (use assert_raise CompileError
    or Code.compile_string/1 in the test)
  7. defcomponent with two required props, one missing — error message names the missing prop

## Acceptance criteria

- mix test test/filament/component_test.exs passes
- mix compile --warnings-as-errors produces no warnings
- dialyzer on lib/filament/component.ex passes
- A defcomponent'd module passes is_atom(MyModule) and function_exported?(MyModule, :render, 1)
- __filament_component__?/0 returns true" \
  --silent)

echo "B3: $B3"

# ─────────────────────────────────────────────────────────
# B4 — ~F sigil
# ─────────────────────────────────────────────────────────
B4=$(bw create "B4: Implement ~F sigil — HEEx template compiler for Filament" \
  --type task \
  --priority 1 \
  --parent "$EPIC_ID" \
  --description "## Goal

Implement the ~F sigil in lib/filament/sigil_f.ex. This is the most technically complex task in Track B. The sigil compiles HEEx-style templates into %Phoenix.LiveView.Rendered{} structs that are wire-compatible with Phoenix LiveView's existing diff engine.

Depends on: B0 (spike — read findings before writing any code), B2 (VNode types), B3 (defcomponent macro).

## Critical reading before you start

Read test/b0_rendered_ir_spike_test.exs IN FULL. Specifically understand:
  1. The %Phoenix.LiveView.Rendered{} struct fields and semantics
  2. How the dynamic/1 function receives a changed? boolean
  3. That a %Phoenix.LiveView.Rendered{} can appear inside the dynamic list of a parent %Rendered{},
     and Phoenix.LiveView.Diff handles this natively — this is how nested components work
  4. The fingerprint: a compile-time integer hash of the static parts, stable per call site

Also read:
  deps/phoenix_live_view/lib/phoenix_component.ex  line ~914  (sigil_H implementation)
  deps/phoenix_live_view/lib/phoenix_live_view/tag_engine.ex  (tag classification and handling)
  deps/phoenix_live_view/lib/phoenix_live_view/html_engine.ex  (classify_type/1)

## Implementation strategy

### Phase 1 — Delegate to TagEngine (get it working first)

The ~H sigil is implemented as:

  defmacro sigil_H({:<<>>, meta, [expr]}, modifiers) do
    Phoenix.LiveView.TagEngine.compile(expr,
      file: __CALLER__.file,
      line: __CALLER__.line + 1,
      caller: __CALLER__,
      indentation: meta[:indentation] || 0,
      tag_handler: Phoenix.LiveView.HTMLEngine
    )
  end

For Phase 1, implement ~F IDENTICALLY to ~H but with tag_handler: Filament.HTMLEngine.

Create lib/filament/html_engine.ex as a thin wrapper around Phoenix.LiveView.HTMLEngine:

  defmodule Filament.HTMLEngine do
    @behaviour Phoenix.LiveView.TagEngine

    # Delegate everything to HTMLEngine except classify_type for uppercase bare names
    defdelegate handle_attributes(ast, meta), to: Phoenix.LiveView.HTMLEngine
    defdelegate void?(name), to: Phoenix.LiveView.HTMLEngine
    defdelegate annotate_body(caller), to: Phoenix.LiveView.HTMLEngine
    defdelegate annotate_slot(name, tag_meta, close_meta, caller), to: Phoenix.LiveView.HTMLEngine

    # For uppercase names WITHOUT a dot (bare component names like \"CartView\"),
    # classify as :remote_component — this causes TagEngine to call CartView.render(assigns)
    # exactly as if it were a Phoenix function component Module.function call.
    # For everything else, delegate to HTMLEngine.
    def classify_type(name) do
      Phoenix.LiveView.HTMLEngine.classify_type(name)
    end
  end

At this stage ~F is identical to ~H. Run the Phase 1 tests to confirm it works.

### Phase 2 — Compile-time :key enforcement

Add a compile-time check in Filament.HTMLEngine: when a :remote_component or :local_component
tag appears inside a :for comprehension without a :key attribute, raise a CompileError:

  \"Component <#{name}> used in a :for comprehension without :key. \"
  \"Add key={expr} to enable stable reconciliation.\"

To detect \"inside :for\": Phoenix.LiveView.TagEngine passes the caller context through meta.
Check meta[:for] or look at the surrounding context. If the check is not straightforward at
the tag handler level, raise a compile error in the ~F macro itself by inspecting the AST
output of TagEngine.compile for :for nodes without matching :key attrs on component children.

### Phase 3 — Uppercase bare-module syntax (optional stretch goal)

IF Phase 1 and 2 are working and time permits, make <CartView /> work as an alias for
<CartView.render />. That is: a bare uppercase name like CartView is treated as calling
CartView.render(assigns). This requires overriding classify_type to reclassify bare uppercase
names as local_component pointing to the render function.

This is a stretch goal. If it requires significant complexity, skip it and leave a TODO comment.
The :for / :key check (Phase 2) is more important.

## Note on the ~F macro location

The ~F macro must be available via \"import Filament.Component\" (or \"use Filament.Component\").
When defcomponent generates a module, it should automatically import Filament.Sigil so that
render/1 bodies can use ~F without an explicit import. Wire this up in the Filament.Component
behaviour's __using__ macro.

## Tests

Create test/filament/sigil_f_test.exs. Cover:

  1. A static template ~F\"<div>hello</div>\" produces a %Phoenix.LiveView.Rendered{} with
     non-nil fingerprint and static list containing the HTML
  2. A template with one interpolation: ~F\"<p>{@text}</p>\" — calling the dynamic fn
     with a %{text: \"world\"} assigns produces [\"world\"]
  3. The fingerprint of the same template compiled twice is identical (stable across compilations)
  4. A template with a nested component via dot syntax <.TodoItem.render todo={@todo} /> compiles
     and renders without error
  5. A :for comprehension on a component WITHOUT :key raises a CompileError at compile time
     (use Code.compile_string/2 with assert_raise in the test)
  6. A :for comprehension WITH :key={item.id} compiles and produces a
     %Phoenix.LiveView.Comprehension{has_key?: true} in the dynamic output
  7. An element with event handler attr on_click={fn -> :ok end} compiles without error

## Acceptance criteria

- mix test test/filament/sigil_f_test.exs passes with all 7 tests green
- A component using ~F in its render/1 via defcomponent compiles cleanly
- mix compile --warnings-as-errors passes
- The wire output (Phoenix.HTML.Safe.to_iodata/1) of a ~F template is identical to the
  equivalent ~H template for static HTML
- The compile-time :key check fires correctly (test 5 above)" \
  --silent)

echo "B4: $B4"

# ─────────────────────────────────────────────────────────
# B5 — Filament.Renderer
# ─────────────────────────────────────────────────────────
B5=$(bw create "B5: Implement Filament.Renderer — pure render walk" \
  --type task \
  --priority 1 \
  --parent "$EPIC_ID" \
  --description "## Goal

Create lib/filament/renderer.ex implementing Filament.Renderer. This module performs the render walk: given a component module and its props, it calls render/1 and recursively resolves any child {:component, mod, props, key} vnodes. The result is a %Phoenix.LiveView.Rendered{} that can be handed to Phoenix LiveView's diff engine.

Depends on: B1 (Fiber), B2 (VNode), B3 (defcomponent), B4 (~F sigil).

## Key design constraint

Filament.Renderer is a PURE function module — no GenServer, no Agent, no process state of its own.
Hook state (use_state, use_observable, etc. — Track C and D) is accessed via a render context
stored in the process dictionary during render. This ticket wires up the slot infrastructure
stub; hooks themselves are implemented in later tracks.

## Modules to create

### Filament.RenderContext

Create lib/filament/render_context.ex:

  defmodule Filament.RenderContext do
    @enforce_keys [:fiber_id, :fiber_tree]
    defstruct [
      :fiber_id,     # String.t()           — current fiber being rendered
      :fiber_tree,   # %{String.t() => Filament.Fiber.t()}  — full tree (read-only during render)
      hook_index: 0, # non_neg_integer()    — current hook slot index, incremented per hook call
      new_fibers: %{} # %{String.t() => Filament.Fiber.t()} — fibers discovered this pass
    ]
  end

The render context lives in the process dictionary under key :filament_render_context for the
duration of each component's render/1 call. It is set before calling render/1 and cleared after.

DO NOT leak the render context between components — it must be saved and restored around
recursive child renders. Use a try/after pattern or explicit save/restore.

### Filament.Renderer

Create lib/filament/renderer.ex:

  @spec render(module(), map(), Filament.RenderContext.t()) :: Phoenix.LiveView.Rendered.t()
  def render(component_module, props, context)

Algorithm:
  1. Call component_module.__validate_props__!(props) — raises ArgumentError if invalid
  2. Set the render context: Process.put(:filament_render_context, %{context | hook_index: 0})
  3. Call component_module.render(props) — this executes the ~F template, returns %Rendered{}
     If render/1 returns a {:component, ...} vnode instead of %Rendered{}, call render_vnode/2
     (see below). In practice, ~F always returns %Rendered{}, but be defensive.
  4. Collect any new fibers accumulated in the context during step 3
  5. Clear the render context: Process.delete(:filament_render_context)
  6. Return the %Rendered{} (child {:component} vnodes were already resolved inline by ~F
     during step 3, as each component tag calls Filament.Renderer.render/3 recursively)

### Inline component resolution

In Phase 1 of B4, <CartView /> in ~F compiles to CartView.render(assigns). That returns a
%Rendered{} directly. There is no post-processing needed in Renderer for this case.

However, the Renderer needs a hook for when component tags produce {:component, mod, props, key}
vnodes in a context where ~F cannot resolve them (e.g., programmatic vnode construction).
Implement:

  @spec render_vnode(Filament.VNode.t(), Filament.RenderContext.t()) :: Phoenix.LiveView.Rendered.t()
  def render_vnode({:component, mod, props, key}, context) do
    child_id = Filament.Fiber.child_id(
      %Filament.Fiber{id: context.fiber_id, component: mod},
      mod,
      if(key, do: {:key, key}, else: {:index, 0})
    )
    child_context = %{context | fiber_id: child_id}
    render(mod, props, child_context)
  end
  def render_vnode({:text, content}, _context), do: Phoenix.HTML.raw(content)
  # ... other variants

## Hook infrastructure stub

Provide this function in Filament.Renderer (or a Filament.Hooks module):

  @spec current_context() :: Filament.RenderContext.t() | nil
  def current_context() do
    Process.get(:filament_render_context)
  end

  @spec next_hook_slot() :: {non_neg_integer(), Filament.RenderContext.t()}
  def next_hook_slot() do
    ctx = Process.get(:filament_render_context) || raise \"hook called outside render\"
    index = ctx.hook_index
    Process.put(:filament_render_context, %{ctx | hook_index: index + 1})
    {index, ctx}
  end

These are the entry points that use_state, use_observable, use_hold (Tracks C, D, E) will call.

## Tests

Create test/filament/renderer_test.exs. Create test fixtures in test/support/fixtures/:

  test/support/fixtures/hello_component.ex — a defcomponent with one prop :name :: :string,
    required: true, renders ~F\"<p>Hello, {@name}!</p>\"

  test/support/fixtures/wrapper_component.ex — a defcomponent with one prop :inner :: :string,
    renders ~F\"<div><.hello_component name={@inner} /></div>\" (or equivalent)

Tests:
  1. render(HelloComponent, %{name: \"world\"}, ctx) returns %Phoenix.LiveView.Rendered{}
  2. Phoenix.HTML.Safe.to_iodata/1 on the result contains \"Hello, world\"
  3. render(HelloComponent, %{}, ctx) raises ArgumentError (missing required prop)
  4. render(WrapperComponent, %{inner: \"Alice\"}, ctx) returns rendered output containing \"Alice\"
  5. Rendering WrapperComponent does not leak render context — current_context() is nil after render
  6. next_hook_slot() called during a render returns incrementing indices: 0, 1, 2...
  7. next_hook_slot() called outside a render raises

## Acceptance criteria

- mix test test/filament/renderer_test.exs passes
- mix compile --warnings-as-errors passes
- Process dictionary is clean after render (no :filament_render_context key left behind)
- render/3 is safe to call concurrently from multiple processes (it uses per-process dictionary)" \
  --silent)

echo "B5: $B5"

# ─────────────────────────────────────────────────────────
# B6 — Filament.Reconciler
# ─────────────────────────────────────────────────────────
B6=$(bw create "B6: Implement Filament.Reconciler — fiber tree mount/update/unmount" \
  --type task \
  --priority 1 \
  --parent "$EPIC_ID" \
  --description "## Goal

Create lib/filament/reconciler.ex implementing the fiber tree manager. The reconciler tracks
component instances across renders, preserving hook state by matching fiber IDs, and mounting
or unmounting fibers as the tree shape changes.

Depends on: B5 (Renderer must be working).

## Data types

@type fiber_tree() :: %{String.t() => Filament.Fiber.t()}

The fiber_tree is an ordinary Elixir map. The reconciler does not own a process — it is a
functional module that takes and returns fiber_tree values. The caller (B7, the LiveView adapter)
owns the tree and stores it in socket assigns.

## API

### mount/2

  @spec mount(module(), map()) :: {fiber_tree(), Phoenix.LiveView.Rendered.t()}
  def mount(root_component, props)

Creates the initial fiber tree.
  1. Create root fiber: Filament.Fiber.new(id: \"root\", component: root_component, props: props)
  2. Create empty RenderContext: %Filament.RenderContext{fiber_id: \"root\", fiber_tree: %{}}
  3. Call Filament.Renderer.render(root_component, props, context)
  4. Collect new_fibers from the context (children discovered during render)
  5. Build tree: %{\"root\" => root_fiber} merged with new_fibers, all with status: :stable
  6. Return {tree, rendered}

### update/3

  @spec update(fiber_tree(), String.t(), map()) :: {fiber_tree(), Phoenix.LiveView.Rendered.t()}
  def update(tree, fiber_id, new_props)

Re-renders the fiber at fiber_id with new_props.
  1. Fetch fiber from tree, raise Filament.ReconcilerError if not found
  2. Update fiber: %{fiber | props: new_props, status: :updating}
  3. Render with updated context
  4. Reconcile children:
     - Children in new render but not in old tree: add to tree with status: :mounting, then :stable
     - Children in both: if props changed, call update/3 recursively; otherwise leave unchanged
     - Children in old tree but not new render: mark :unmounting, then remove from tree
  5. Set fiber status to :stable
  6. Return {new_tree, rendered}

### Keyed list reconciliation

When the renderer produces a %Phoenix.LiveView.Comprehension{has_key?: true} in its output,
the reconciler must match existing fibers by key rather than position:
  - For each (key, rendered_item) pair in the comprehension entries:
    - Look for an existing fiber with matching key in the previous children list
    - If found: update it (props may have changed)
    - If not found: mount a new fiber for it
  - Any existing keyed fiber whose key does not appear in the new output: unmount

Duplicate key detection: if two entries in a %Comprehension have the same key, raise:
  %Filament.ReconcilerError{message: \"duplicate key #{inspect key} from component #{inspect mod}\"}

### unmount/1

  @spec unmount(fiber_tree()) :: :ok
  def unmount(tree)

Marks all fibers as :unmounting. Returns :ok.
(Hook cleanup callbacks — use_effect teardown — will be wired in Track C. For now this
is a no-op beyond the status change. The status signal is the hook for future cleanup.)

### Filament.ReconcilerError

Define this exception in lib/filament/reconciler_error.ex:
  defexception [:message]

## Tests

Create test/filament/reconciler_test.exs. Use test fixtures from test/support/fixtures/
(created in B5, extend as needed).

Add to fixtures:
  CounterComponent — has prop :count :: :integer, required: true,
    renders ~F\"<p>{@count}</p>\"
  ParentComponent — has prop :items :: :list, required: true,
    renders ~F\"<ul><.CounterComponent.render :for={i <- @items} :key={i} count={i} /></ul>\"

Tests:
  1. mount(CounterComponent, %{count: 0}) — tree has one fiber \"root\", rendered contains \"0\"
  2. update(tree, \"root\", %{count: 1}) — rendered contains \"1\", tree fiber has updated props
  3. update with same props — rendered output is unchanged, tree is identical
  4. mount(ParentComponent, %{items: [1, 2, 3]}) — tree has 4 fibers (root + 3 children)
  5. update(tree, \"root\", %{items: [1, 3]}) — item 2 fiber is removed, items 1 and 3 preserved
  6. update(tree, \"root\", %{items: [3, 1]}) — items reordered, fibers matched by key (same IDs)
  7. Duplicate keys raise Filament.ReconcilerError
  8. unmount(tree) returns :ok and all fibers have status: :unmounting
  9. update on a fiber_id not in tree raises Filament.ReconcilerError

## Acceptance criteria

- mix test test/filament/reconciler_test.exs passes (9 tests)
- mix compile --warnings-as-errors passes
- Keyed reconciliation test (test 6) demonstrates fiber identity preserved across reorder" \
  --silent)

echo "B6: $B6"

# ─────────────────────────────────────────────────────────
# B7 — Filament.LiveView adapter
# ─────────────────────────────────────────────────────────
B7=$(bw create "B7: Implement Filament.LiveView adapter — plug fiber tree into Phoenix LiveView" \
  --type task \
  --priority 1 \
  --parent "$EPIC_ID" \
  --description "## Goal

Create lib/filament/live_view.ex implementing the Filament.LiveView adapter. This is the public-facing integration point: application developers put 'use Filament.LiveView' in a Phoenix LiveView module and define root_component/0. Everything else is handled by the framework.

Depends on: B6 (Reconciler must be complete and tested).

## What \"use Filament.LiveView\" injects

When a LiveView module calls 'use Filament.LiveView', it injects:

### mount/3

  def mount(_params, _session, socket) do
    component = root_component()
    props = build_props(socket)
    {tree, rendered} = Filament.Reconciler.mount(component, props)
    socket = socket
      |> assign(:_filament_tree, tree)
      |> assign(:_filament_rendered, rendered)
    {:ok, socket}
  end

build_props/1 converts socket.assigns to a plain map for the root component.
Exclude internal LiveView assigns (:flash, :live_action, etc.) or use assign_new
to let the component declare which assigns it cares about.
For the initial implementation: pass all of socket.assigns as props and let
__validate_props__! sort out what is required.

### render/1

  def render(assigns) do
    assigns._filament_rendered
  end

Returns the %Phoenix.LiveView.Rendered{} stored in assigns. Phoenix LiveView's diff
engine takes it from here unchanged.

### handle_event/3

Events arrive as {\"filament:event\", %{\"fiber_id\" => id, \"event\" => name, \"payload\" => p}, socket}.
The event dispatch in Track E will use this naming convention. For now, log and ignore events
with this prefix:

  def handle_event(\"filament:\" <> _rest, _params, socket) do
    {:noreply, socket}
  end

Also handle the pattern where a ~F template emits phx-click or phx-change events on HTML
elements (non-component events): these arrive as normal LiveView events and should be forwarded
to the root fiber for now. Dispatch:

  def handle_event(event, params, socket) do
    tree = socket.assigns._filament_tree
    root_fiber = tree[\"root\"]
    # Dispatch to root component's handle_event if it defines one.
    # If not defined, log a warning and return {:noreply, socket}.
    case function_exported?(root_fiber.component, :handle_event, 3) do
      true ->
        {new_props, _} = root_fiber.component.handle_event(event, params, root_fiber.props)
        {tree, rendered} = Filament.Reconciler.update(tree, \"root\", new_props)
        {:noreply, assign(socket, _filament_tree: tree, _filament_rendered: rendered)}
      false ->
        {:noreply, socket}
    end
  end

### handle_info/3

Observable update notifications will arrive here (wired in Track D). Add a placeholder now:

  def handle_info({:filament_update, _fiber_id, _new_state}, socket) do
    # Track D will implement this. For now, noop.
    {:noreply, socket}
  end

### The root_component/0 callback

Define this behaviour callback in Filament.LiveView:
  @callback root_component() :: module()

The LiveView must implement it:
  def root_component(), do: MyApp.CheckoutPage

## Module structure

lib/filament/live_view.ex contains:

  defmodule Filament.LiveView do
    @callback root_component() :: module()

    defmacro __using__(_opts) do
      quote do
        use Phoenix.LiveView
        @behaviour Filament.LiveView
        # inject mount/3, render/1, handle_event/3, handle_info/3
        ...
      end
    end
  end

Use @before_compile if any after_compile hooks are needed.

## Tests

Create test/filament/live_view_test.exs. This is a RUNG 4 test (integration). It requires a
test Phoenix endpoint and router.

Create test/support/test_endpoint.ex — a minimal Phoenix.Endpoint for tests:
  use Phoenix.Endpoint, otp_app: :filament
  plug Plug.Session, store: :cookie, key: \"_filament_test\", signing_salt: \"test\"
  plug Phoenix.LiveView.Flash
  plug router

Create test/support/test_router.ex — a minimal Phoenix.Router:
  use Phoenix.Router
  import Phoenix.LiveView.Router
  live \"/counter\", Filament.Test.CounterLiveView

Create test/support/test_live_views/counter_live_view.ex:
  defmodule Filament.Test.CounterLiveView do
    use Filament.LiveView
    def root_component, do: Filament.Test.Fixtures.CounterComponent
    def mount(%{}, %{}, socket) do
      {:ok, assign(socket, count: 0)}
    end
  end

(CounterComponent is defined in test/support/fixtures/counter_component.ex from B6.)

Tests:
  1. Phoenix.LiveViewTest.live(conn, \"/counter\") mounts successfully and returns {:ok, view, html}
  2. html contains the rendered output of CounterComponent with count: 0
  3. The rendered html is valid (contains no \"filament:\" debug artifacts)

## Acceptance criteria

- mix test test/filament/live_view_test.exs passes
- mix compile --warnings-as-errors passes
- A LiveView using 'use Filament.LiveView' renders its root component on mount
- The wire output is byte-identical to a vanilla Phoenix.LiveView rendering the same HTML
  (verify by comparing Phoenix.HTML.Safe.to_iodata output)
- No warnings about undefined behaviours or unimplemented callbacks

## Definition of done for Track B

When B7 is merged and all tests from B1–B7 pass on CI (GitHub Actions matrix — see
.github/workflows/ci.yml), Track B is complete. Tracks C (hooks) and D (observables)
can then begin in parallel." \
  --silent)

echo "B7: $B7"

# ─────────────────────────────────────────────────────────
# Wire dependencies
# ─────────────────────────────────────────────────────────

echo ""
echo "Wiring dependencies..."

# B0 must close before B4 (sigil cannot be written without spike findings)
bw dep add "$B0" blocks "$B4"

# B1 and B2 must both exist before B3 (defcomponent uses Fiber + VNode)
bw dep add "$B1" blocks "$B3"
bw dep add "$B2" blocks "$B3"

# B2 and B3 needed before B4 (sigil needs VNode types + defcomponent for test fixtures)
bw dep add "$B2" blocks "$B4"
bw dep add "$B3" blocks "$B4"

# B4 needed before B5 (Renderer calls component.render which uses ~F)
bw dep add "$B4" blocks "$B5"

# B5 needed before B6 (Reconciler drives Renderer)
bw dep add "$B5" blocks "$B6"

# B6 needed before B7 (LiveView adapter drives Reconciler)
bw dep add "$B6" blocks "$B7"

echo ""
echo "Done. Summary:"
echo "  Epic: $EPIC_ID"
echo "  B0 (spike):       $B0  →blocks→ B4"
echo "  B1 (Fiber):       $B1  →blocks→ B3"
echo "  B2 (VNode):       $B2  →blocks→ B3, B4"
echo "  B3 (defcomponent):$B3  →blocks→ B4"
echo "  B4 (~F sigil):    $B4  →blocks→ B5"
echo "  B5 (Renderer):    $B5  →blocks→ B6"
echo "  B6 (Reconciler):  $B6  →blocks→ B7"
echo "  B7 (LiveView):    $B7"
echo ""
echo "Ready work (should be B0, B1, B2 — all unblocked):"
bw ready
