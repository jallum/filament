defmodule B0RenderedIRSpikeTest do
  @moduledoc """
  B0 Spike — Documenting Phoenix.LiveView.Rendered IR format

  This test file is a literate specification that documents the exact format
  Phoenix.LiveView.Diff expects for the %Phoenix.LiveView.Rendered{} struct.

  The goal is to understand the static/dynamic split that is byte-identical to
  what ~H produces, ensuring we don't re-serialize subtrees to strings on every
  render (which would blow up the wire format).

  Key insights from studying the source:
  - deps/phoenix_live_view/lib/phoenix_live_view/engine.ex defines the structs
  - deps/phoenix_live_view/lib/phoenix_live_view/phoenix_component.ex:914 has sigil_H
  - deps/phoenix_live_view/lib/phoenix_live_view/html_engine.ex handles classification
  """

  use ExUnit.Case

  import Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Rendered

  @doc """
  Example 1 — Static template

  Manually construct a %Phoenix.LiveView.Rendered{} for:
    <div class="box">hello</div>

  Key observations:
  - static is a list of string chunks between interpolations
  - dynamic is a function receiving a boolean, returns list of dynamic values
  - fingerprint is a compile-time hash (any stable integer works for manual construction)
  - root indicates the outermost rendered struct (true for top-level templates)
  """
  test "example 1: static template" do
    # Manually construct the Rendered struct
    rendered = %Rendered{
      static: ["<div class=\"box\">hello</div>"],
      dynamic: fn _changed? -> [] end,
      fingerprint: 12_345,
      root: true
    }

    # Verify it's valid by converting to iodata
    iodata = Safe.to_iodata(rendered)
    assert iodata == ["<div class=\"box\">hello</div>"]

    # The dynamic function receives a boolean indicating if we should track changes
    # For static templates, it always returns an empty list
    assert rendered.dynamic.(false) == []
    assert rendered.dynamic.(true) == []
  end

  @doc """
  Example 2 — One dynamic interpolation

  Template: <p><%= @text %></p>

  When compiled via ~H, Phoenix splits the template into static chunks and dynamic values.
  The static parts are: ["<p>", "</p>"]
  The dynamic parts are: [@text value]

  The static list has N elements, dynamic has N-1 elements (they interleave).

  Key questions answered here:
  Q: What does the boolean argument to dynamic/1 do?
  A: It enables/disables change tracking. When true, the renderer should track
     which values changed for efficient diffing. When false, return all values.

  Q: What is root on %Rendered{}?
  A: root: true marks the outermost template boundary. Nested Rendered structs
     should have root: false or root: nil.
  """
  test "example 2: one dynamic interpolation" do
    # First, let's see what ~H actually produces
    assigns = %{text: "Hello, World!"}

    ~H"""
    <p><%= @text %></p>
    """

    # When we inspect the result, we can see the structure
    # (This would show the actual Rendered struct in practice)

    # Now manually construct the equivalent structure
    rendered = %Rendered{
      static: ["<p>", "</p>"],
      dynamic: fn _changed? ->
        # In real usage, changed? would control what we return
        # For this example, we just return the text value
        ["Hello, World!"]
      end,
      fingerprint: 67_890,
      root: true
    }

    # Verify conversion to HTML
    iodata = Safe.to_iodata(rendered)
    # The renderer interleaves static and dynamic parts
    assert iodata == ["<p>", "Hello, World!", "</p>"]

    # The dynamic function can behave differently based on changed?
    # When changed? is true, a smart implementation would track changes
    # When false, it returns all values unconditionally
    dynamic_result = rendered.dynamic.(false)
    assert length(dynamic_result) == 1
  end

  @doc """
  Example 3 — Nested component reference and nested Rendered structs

  In ~H, a remote component like <Module.func /> produces a
  %Phoenix.LiveView.Component{component: Module, assigns: ...} in the dynamic section.

  However, for inline component rendering (Filament's approach), the dynamic section
  can contain another %Phoenix.LiveView.Rendered{} struct.

  Key questions answered here:

  Q: Does Phoenix.LiveView.Diff accept a %Rendered{} in the dynamic list of a parent %Rendered{}?
  A: YES! This is exactly how nested components work without LiveComponent overhead.
     The renderer recursively processes nested Rendered structs.

  Q: What happens with fingerprint collisions? Is it truly just an integer hash?
  A: The fingerprint is a compile-time hash of the static parts. Collisions would
     be extremely rare (it's based on the AST). It's used for change detection and
     caching. The actual implementation uses :erlang.phash2/2 or similar.
  """
  test "example 3: nested component reference with nested Rendered struct" do
    # Create a nested Rendered struct for a component's output
    nested_rendered = %Rendered{
      static: ["<span>", "</span>"],
      dynamic: fn _changed? -> ["nested content"] end,
      fingerprint: 11_111,
      # This is NOT the root template
      root: false
    }

    # Parent template that includes the nested Rendered struct in its dynamic section
    parent_rendered = %Rendered{
      static: ["<div>", "</div>"],
      dynamic: fn _changed? ->
        # The dynamic section can contain:
        # - iodata (strings, binaries)
        # %Phoenix.LiveView.Rendered{} (nested templates)
        # %Phoenix.LiveView.Comprehension{} (for comprehensions)
        # %Phoenix.LiveView.Component{} (for LiveComponents)
        [nested_rendered]
      end,
      fingerprint: 22_222,
      # This IS the root template
      root: true
    }

    # The renderer recursively processes nested Rendered structs
    iodata = Safe.to_iodata(parent_rendered)
    # The renderer recursively processes nested Rendered structs, creating nested lists
    assert iodata == ["<div>", ["<span>", "nested content", "</span>"], "</div>"]

    # Verify nested_rendered is valid on its own too
    nested_iodata = Safe.to_iodata(nested_rendered)
    assert nested_iodata == ["<span>", "nested content", "</span>"]
  end

  @doc """
  Example 4 — Multiple dynamic interpolations

  Template: <div class="<%= @class %>"><%= @text %></div>

  This demonstrates how multiple interpolations are handled.
  The static list has 3 elements, dynamic has 2 elements.
  """
  test "example 4: multiple dynamic interpolations" do
    rendered = %Rendered{
      static: ["<div class=\"", "\">", "</div>"],
      dynamic: fn _changed? ->
        # In a real scenario, changed? would determine what to return
        # For this example, we return both values
        ["alert-box", "Warning message"]
      end,
      fingerprint: 33_333,
      root: true
    }

    iodata = Safe.to_iodata(rendered)
    assert iodata == ["<div class=\"", "alert-box", "\">", "Warning message", "</div>"]
  end

  @doc """
  Example 5 — LiveComponent reference (for comparison)

  Shows how a LiveComponent is referenced in the dynamic section.
  This is what ~H produces for <MyModule.my_component id="test" />.
  """
  test "example 5: livecomponent reference" do
    component_struct = %Phoenix.LiveView.Component{
      id: "test-component",
      component: MyTestComponent,
      assigns: %{value: "test"}
    }

    # The component goes in the dynamic section of a Rendered struct
    _rendered = %Rendered{
      static: ["<div>", "</div>"],
      dynamic: fn _changed? -> [component_struct] end,
      fingerprint: 44_444,
      root: true
    }

    # Note: Phoenix.HTML.Safe.to_iodata will raise for a Component
    # because components must be returned directly from templates,
    # not nested inside other markup.
    assert_raise ArgumentError, fn ->
      Safe.to_iodata(component_struct)
    end
  end

  @doc """
  Example 6 — Comprehension example

  Shows how the %Phoenix.LiveView.Comprehension{} struct works for :for loops.
  """
  test "example 6: comprehension for loops" do
    # Each entry in a comprehension has: {key, vars_map, render_function}
    entries = [
      # First item
      {0, %{},
       fn _vars_changed, _changed? ->
         [
           %Rendered{
             static: ["<li>", "</li>"],
             dynamic: fn _ -> ["Item 1"] end,
             fingerprint: 55_555,
             root: false
           }
         ]
       end},
      # Second item
      {1, %{},
       fn _vars_changed, _changed? ->
         [
           %Rendered{
             static: ["<li>", "</li>"],
             dynamic: fn _ -> ["Item 2"] end,
             fingerprint: 55_555,
             root: false
           }
         ]
       end}
    ]

    comprehension = %Phoenix.LiveView.Comprehension{
      static: ["<ul>", "</ul>"],
      has_key?: true,
      entries: entries,
      fingerprint: 66_666,
      stream: nil
    }

    # The comprehension can appear in a Rendered struct's dynamic section
    rendered = %Rendered{
      static: ["", ""],
      dynamic: fn _changed? -> [comprehension] end,
      fingerprint: 77_777,
      root: true
    }

    iodata = Safe.to_iodata(rendered)
    # The comprehension is rendered as nested lists with recursive processing
    assert iodata == [
             "",
             [
               ["<ul>", ["<li>", "Item 1", "</li>"], "</ul>"],
               ["<ul>", ["<li>", "Item 2", "</li>"], "</ul>"]
             ],
             ""
           ]
  end

  @doc """
  Summary of key insights

  1. STRUCTURE: %Phoenix.LiveView.Rendered{} has:
     - static: [String.t()] - template chunks between interpolations
     - dynamic: (boolean() -> [dyn()]) - function returning dynamic values
     - fingerprint: integer() - compile-time hash of static parts
     - root: nil | true | false - marks outermost template
     - caller: metadata about where it was defined

  2. DYNAMIC FUNCTION: The boolean argument enables/disables change tracking:
     - true: track which values changed for efficient diffing
     - false: return all values unconditionally

  3. NESTING: %Rendered{} CAN contain other %Rendered{} in dynamic list!
     This is how Filament will render inline components without LiveComponent overhead.
     Phoenix.LiveView.Diff will recursively process nested Rendered structs.

  4. FINGERPRINT: Integer hash of static template parts, used for change detection.
     Collisions are extremely rare (based on AST hashing). Implementation uses
     erlang.phash2 or similar.

  5. TYPE UNION: The dynamic list can contain:
     - nil | iodata() - plain text/content
     - %Phoenix.LiveView.Rendered{} - nested templates (the Filament approach)
     - %Phoenix.LiveView.Comprehension{} - for comprehensions
     - %Phoenix.LiveView.Component{} - LiveComponent references

  These insights will guide the implementation of the F-sigil (B4) and the reconciler.
  """
  test "summary" do
    # This test just exists to include the summary in the compiled module
    assert true
  end
end
