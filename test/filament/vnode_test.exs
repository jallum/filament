defmodule Filament.VNodeTest do
  use ExUnit.Case, async: true

  alias Filament.VNode

  defmodule TestComponent do
    @moduledoc false
  end

  describe "VNode variants" do
    test ":text variant" do
      assert {:text, "hello"} = vnode = {:text, "hello"}
      assert VNode.validate!(vnode) == vnode
    end

    test ":text variant with iolist" do
      vnode = {:text, ["hello", " ", "world"]}
      assert VNode.validate!(vnode) == vnode
    end

    test ":element variant" do
      vnode = {:element, "div", [{"class", "container"}], [{:text, "content"}]}
      assert VNode.validate!(vnode) == vnode
    end

    test ":element with boolean attribute" do
      vnode = {:element, "input", [{"disabled", true}, {"value", nil}], []}
      assert VNode.validate!(vnode) == vnode
    end

    test ":element with nested children" do
      vnode = {
        :element,
        "div",
        [],
        [
          {:element, "p", [], [{:text, "paragraph"}]},
          {:text, "more text"}
        ]
      }

      assert VNode.validate!(vnode) == vnode
    end

    test ":component variant" do
      vnode = {:component, TestComponent, %{value: "test"}, nil}
      assert VNode.validate!(vnode) == vnode
    end

    test ":component variant with explicit key" do
      vnode = {:component, TestComponent, %{value: "test"}, "item-42"}
      assert VNode.validate!(vnode) == vnode
    end

    test ":fragment variant" do
      vnode = {:fragment, [{:text, "hello"}, {:text, "world"}]}
      assert VNode.validate!(vnode) == vnode
    end

    test ":fragment variant with nested elements" do
      vnode = {
        :fragment,
        [
          {:element, "h1", [], [{:text, "Title"}]},
          {:element, "p", [], [{:text, "Text"}]}
        ]
      }

      assert VNode.validate!(vnode) == vnode
    end
  end

  describe "validate!/1 with deeply nested trees" do
    test "validates deeply nested fragment and element tree" do
      vnode = {
        :fragment,
        [
          {:element, "div", [{"class", "container"}],
           [
             {:element, "h1", [], [{:text, "Title"}]},
             {:element, "ul", [],
              [
                {:element, "li", [], [{:text, "Item 1"}]},
                {:element, "li", [], [{:text, "Item 2"}]}
              ]}
           ]}
        ]
      }

      assert VNode.validate!(vnode) == vnode
    end

    test "validates component tree with nesting" do
      vnode = {
        :fragment,
        [
          {:component, TestComponent, %{header: true}, nil},
          {:element, "div", [],
           [
             {:component, TestComponent, %{content: "main"}, "content-1"},
             {:component, TestComponent, %{content: "footer"}, "content-2"}
           ]}
        ]
      }

      assert VNode.validate!(vnode) == vnode
    end
  end

  describe "validate!/1 returns vnode unchanged" do
    test "returns text vnode unchanged" do
      vnode = {:text, "hello"}
      assert VNode.validate!(vnode) === vnode
    end

    test "returns element vnode unchanged" do
      vnode = {:element, "div", [], []}
      assert VNode.validate!(vnode) === vnode
    end

    test "returns component vnode unchanged" do
      vnode = {:component, TestComponent, %{}, nil}
      assert VNode.validate!(vnode) === vnode
    end

    test "returns fragment vnode unchanged" do
      vnode = {:fragment, []}
      assert VNode.validate!(vnode) === vnode
    end
  end

  describe "VNode.Error" do
    test "is a proper defexception with message field" do
      exception = VNode.Error.exception(message: "test error")
      assert exception.message == "test error"
      assert Exception.message(exception) == "test error"
    end

    test "can be raised with default message" do
      assert_raise VNode.Error, fn ->
        raise VNode.Error
      end
    end

    test "can be raised with custom message" do
      assert_raise VNode.Error, "test message", fn ->
        raise VNode.Error, message: "test message"
      end
    end
  end

  test "returns the vnode unchanged when valid" do
    vnode = {
      :fragment,
      [
        {:text, "hello"},
        {:element, "p", [], [{:text, "world"}]},
        {:component, TestComponent, %{prop: "value"}, nil}
      ]
    }

    result = VNode.validate!(vnode)
    assert result == vnode
    # Same reference, not just equal
    assert result === vnode
  end
end
