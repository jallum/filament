defmodule Filament.LoopChildFibersTest do
  use ExUnit.Case, async: true

  import Filament.Test

  # A child with a handler of its own and state of its own.
  defmodule Counter do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:n, :integer, required: true)
      prop(:on_pick, :any, required: true)

      def render(%{n: n} = props) do
        {count, set_count} = use_state(0)

        ~F"""
        <span>
          <button class={"pick pick-#{n}"} on_click={props.on_pick}>pick {n}</button>
          <button class={"bump bump-#{n}"} on_click={fn -> set_count.(count + 1) end}>count {n}={count}</button>
        </span>
        """
      end
    end
  end

  # A loop holding an element handler beside a child component, and a
  # state of the parent's the loop doesn't read.
  defmodule Rows do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props) do
        {picked, pick} = use_state(nil)
        {other, set_other} = use_state(0)

        ~F"""
        <div>
          <button class="other" on_click={fn -> set_other.(other + 1) end}>other {other}</button>
          <p class="picked">picked {picked}</p>
          <ul>
            <li :for={n <- [1, 2]} :key={n}>
              <button class={"mark mark-#{n}"} on_click={fn -> pick.(-n) end}>mark</button>
              <Filament.LoopChildFibersTest.Counter n={n} on_pick={fn -> pick.(n) end} />
            </li>
          </ul>
        </div>
        """
      end
    end
  end

  # The same, the loop unkeyed, in a block.
  defmodule BlockRows do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props) do
        {picked, pick} = use_state(nil)
        {other, set_other} = use_state(0)

        ~F"""
        <div>
          <button class="other" on_click={fn -> set_other.(other + 1) end}>other {other}</button>
          <p class="picked">picked {picked}</p>
          {for n <- [1, 2] do}
            <button class={"mark mark-#{n}"} on_click={fn -> pick.(-n) end}>mark</button>
            <Filament.LoopChildFibersTest.Counter n={n} on_pick={fn -> pick.(n) end} />
          {end}
        </div>
        """
      end
    end
  end

  # A child rendered by a helper the template interpolates.
  defmodule Helped do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props) do
        {picked, pick} = use_state(nil)
        {other, set_other} = use_state(0)

        ~F"""
        <div>
          <button class="other" on_click={fn -> set_other.(other + 1) end}>other {other}</button>
          <p class="picked">picked {picked}</p>
          {counter(1, pick)}
        </div>
        """
      end

      defp counter(n, pick) do
        ~F"""
        <Filament.LoopChildFibersTest.Counter n={n} on_pick={fn -> pick.(n) end} />
        """
      end
    end
  end

  # The handler and the component in different branches of a loop item, so
  # no single item holds both.
  defmodule CaseRows do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props) do
        {picked, pick} = use_state(nil)
        {other, set_other} = use_state(0)

        ~F"""
        <div>
          <button class="other" on_click={fn -> set_other.(other + 1) end}>other {other}</button>
          <p class="picked">picked {picked}</p>
          {for item <- [:mark, 1] do}
            {case item do}
              {:mark ->}
                <button class="mark" on_click={fn -> pick.(0) end}>mark</button>
              {n ->}
                <Filament.LoopChildFibersTest.Counter n={n} on_pick={fn -> pick.(n) end} />
            {end}
          {end}
        </div>
        """
      end
    end
  end

  defmodule IfRows do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props) do
        {picked, pick} = use_state(nil)
        {other, set_other} = use_state(0)

        ~F"""
        <div>
          <button class="other" on_click={fn -> set_other.(other + 1) end}>other {other}</button>
          <p class="picked">picked {picked}</p>
          {for item <- [:mark, 1] do}
            {if item == :mark do}
              <button class="mark" on_click={fn -> pick.(0) end}>mark</button>
            {else}
              <Filament.LoopChildFibersTest.Counter n={item} on_pick={fn -> pick.(item) end} />
            {end}
          {end}
        </div>
        """
      end
    end
  end

  for parent <- [Rows, BlockRows, Helped, CaseRows, IfRows] do
    @parent parent

    test "#{inspect(parent)}: a child keeps its handlers when the parent renders again unchanged around it" do
      view = @parent |> mount!(%{}) |> click!("button.other") |> update()
      assert render_text(view) =~ "other 1"

      view = view |> click!("button.pick-1") |> update()
      assert render_text(view) =~ "picked 1"
    end

    test "#{inspect(parent)}: a child's own state shows, and stays its own" do
      view = @parent |> mount!(%{}) |> click!("button.bump-1") |> update()
      assert render_text(view) =~ "count 1=1"

      view = view |> click!("button.bump-1") |> update() |> click!("button.other") |> update()
      assert render_text(view) =~ "count 1=2"
      assert render_text(view) =~ "other 1"
    end
  end
end
