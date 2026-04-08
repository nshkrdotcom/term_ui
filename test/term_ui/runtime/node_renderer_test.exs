defmodule TermUI.Runtime.NodeRendererTest do
  use ExUnit.Case, async: true

  alias TermUI.Component.RenderNode
  alias TermUI.Renderer.Buffer
  alias TermUI.Renderer.BufferManager
  alias TermUI.Runtime.NodeRenderer

  setup do
    # Generate a unique name for each test to avoid conflicts
    name = :"buffer_manager_#{System.unique_integer([:positive])}"
    {:ok, pid} = BufferManager.start_link(rows: 30, cols: 50, name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, bm: pid}
  end

  describe "render_to_buffer/4" do
    test "renders text node", %{bm: bm} do
      NodeRenderer.render_to_buffer({:text, "Hello"}, bm, 1, 1)

      buffer = BufferManager.get_current_buffer(bm)
      assert Buffer.get_cell(buffer, 1, 1).char == "H"
      assert Buffer.get_cell(buffer, 1, 2).char == "e"
      assert Buffer.get_cell(buffer, 1, 3).char == "l"
      assert Buffer.get_cell(buffer, 1, 4).char == "l"
      assert Buffer.get_cell(buffer, 1, 5).char == "o"
    end

    test "renders list of text nodes vertically", %{bm: bm} do
      NodeRenderer.render_to_buffer([{:text, "Line1"}, {:text, "Line2"}], bm, 1, 1)

      buffer = BufferManager.get_current_buffer(bm)
      assert Buffer.get_cell(buffer, 1, 1).char == "L"
      assert Buffer.get_cell(buffer, 2, 1).char == "L"
    end
  end

  describe "cursor_hint propagation" do
    test "returns nil cursor when no hint in tree", %{bm: bm} do
      {_w, _h, cursor} = NodeRenderer.render_to_buffer({:text, "Hello"}, bm, 1, 1)
      assert cursor == nil
    end

    test "returns absolute cursor position when hint present at start_row/col", %{bm: bm} do
      # cursor_hint placed BEFORE the text so it is rendered at the same row.
      # start_row=1, start_col=1; hint {0, 3} => absolute {1+0, 1+3} = {1, 4}
      node = RenderNode.stack(:vertical, [
        RenderNode.cursor_hint({0, 3}),
        RenderNode.text("abc")
      ])

      {_w, _h, cursor} = NodeRenderer.render_to_buffer(node, bm, 1, 1)
      assert cursor == {1, 4}
    end

    test "translates relative hint to absolute screen coordinates", %{bm: bm} do
      # Rendered starting at row=5, col=3; hint {0, 7} placed first => {5+0, 3+7} = {5, 10}
      node = RenderNode.stack(:vertical, [
        RenderNode.cursor_hint({0, 7}),
        RenderNode.text("hello")
      ])

      {_w, _h, cursor} = NodeRenderer.render_to_buffer(node, bm, 5, 3)
      assert cursor == {5, 10}
    end

    test "hint inside a nested stack resolves to correct absolute position", %{bm: bm} do
      # Outer stack at row=2, col=1. First child is a header (height 1).
      # Second child is an inner stack starting at row=3.
      # inner: cursor_hint({0, 2}) placed first at row=3 => {3+0, 1+2} = {3, 3}
      inner = RenderNode.stack(:vertical, [
        RenderNode.cursor_hint({0, 2}),
        RenderNode.text("xy")
      ])

      outer = RenderNode.stack(:vertical, [
        RenderNode.text("header"),
        inner
      ])

      {_w, _h, cursor} = NodeRenderer.render_to_buffer(outer, bm, 2, 1)
      assert cursor == {3, 3}
    end

    test "cursor_hint has zero dimensions and does not affect layout", %{bm: bm} do
      # cursor_hint placed first — it has {0, 0} dims so the text still renders at row 1
      node = RenderNode.stack(:vertical, [
        RenderNode.cursor_hint({0, 1}),
        RenderNode.text("ab")
      ])

      {_w, h, _cursor} = NodeRenderer.render_to_buffer(node, bm, 1, 1)
      # cursor_hint height=0 + text height=1 => total height = 1
      assert h == 1
    end

    test "viewport content cursor hints are ignored (sandboxed)", %{bm: bm} do
      # A cursor_hint inside a viewport should NOT propagate out,
      # because the hint position would be in temp-buffer space, not screen space.
      viewport_node = %{
        type: :viewport,
        content: RenderNode.stack(:vertical, [
          RenderNode.text("inner"),
          RenderNode.cursor_hint({0, 2})
        ]),
        scroll_x: 0,
        scroll_y: 0,
        width: 20,
        height: 5
      }

      {_w, _h, cursor} = NodeRenderer.render_to_buffer(viewport_node, bm, 1, 1)
      assert cursor == nil
    end

    test "render_to_buffer_direct also returns cursor hint" do
      {:ok, buffer} = Buffer.new(10, 20)

      node = RenderNode.stack(:vertical, [
        RenderNode.cursor_hint({0, 4}),
        RenderNode.text("test")
      ])

      {_w, _h, cursor} = NodeRenderer.render_to_buffer_direct(node, buffer, 3, 2)
      # hint first at row=3, col=2 => absolute {3+0, 2+4} = {3, 6}
      assert cursor == {3, 6}

      Buffer.destroy(buffer)
    end
  end

  describe "viewport rendering" do
    test "renders viewport content without scroll", %{bm: bm} do
      viewport_node = %{
        type: :viewport,
        content: {:text, "Hello World"},
        scroll_x: 0,
        scroll_y: 0,
        width: 20,
        height: 5
      }

      {width, height, _cursor} = NodeRenderer.render_to_buffer(viewport_node, bm, 1, 1)

      assert width == 20
      assert height == 5

      buffer = BufferManager.get_current_buffer(bm)
      assert Buffer.get_cell(buffer, 1, 1).char == "H"
      assert Buffer.get_cell(buffer, 1, 2).char == "e"
      assert Buffer.get_cell(buffer, 1, 5).char == "o"
    end

    test "renders viewport content with horizontal scroll", %{bm: bm} do
      viewport_node = %{
        type: :viewport,
        content: {:text, "Hello World"},
        scroll_x: 6,
        scroll_y: 0,
        width: 10,
        height: 5
      }

      NodeRenderer.render_to_buffer(viewport_node, bm, 1, 1)

      buffer = BufferManager.get_current_buffer(bm)
      # After scrolling 6 chars, "World" should be at position 1
      assert Buffer.get_cell(buffer, 1, 1).char == "W"
      assert Buffer.get_cell(buffer, 1, 2).char == "o"
      assert Buffer.get_cell(buffer, 1, 3).char == "r"
    end

    test "renders viewport content with vertical scroll", %{bm: bm} do
      # Multi-line content
      content = [{:text, "Line 1"}, {:text, "Line 2"}, {:text, "Line 3"}, {:text, "Line 4"}]

      viewport_node = %{
        type: :viewport,
        content: content,
        scroll_x: 0,
        scroll_y: 2,
        width: 20,
        height: 2
      }

      NodeRenderer.render_to_buffer(viewport_node, bm, 1, 1)

      buffer = BufferManager.get_current_buffer(bm)
      # After scrolling 2 lines, "Line 3" should be at row 1
      assert Buffer.get_cell(buffer, 1, 1).char == "L"
      assert Buffer.get_cell(buffer, 1, 6).char == "3"
      # And "Line 4" at row 2
      assert Buffer.get_cell(buffer, 2, 6).char == "4"
    end

    test "clips content to viewport dimensions", %{bm: bm} do
      # Content that exceeds viewport
      viewport_node = %{
        type: :viewport,
        content: {:text, "This is a very long line that should be clipped"},
        scroll_x: 0,
        scroll_y: 0,
        width: 10,
        height: 1
      }

      {width, height, _cursor} = NodeRenderer.render_to_buffer(viewport_node, bm, 5, 5)

      assert width == 10
      assert height == 1

      buffer = BufferManager.get_current_buffer(bm)
      # Content starts at (5, 5)
      assert Buffer.get_cell(buffer, 5, 5).char == "T"
      assert Buffer.get_cell(buffer, 5, 14).char == " "
    end

    test "handles empty content", %{bm: bm} do
      viewport_node = %{
        type: :viewport,
        content: {:text, ""},
        scroll_x: 0,
        scroll_y: 0,
        width: 10,
        height: 5
      }

      {width, height, _cursor} = NodeRenderer.render_to_buffer(viewport_node, bm, 1, 1)

      assert width == 10
      assert height == 5
    end

    test "combined horizontal and vertical scroll", %{bm: bm} do
      # Create a grid-like content
      content = [
        {:text, "ABCDEFGHIJ"},
        {:text, "KLMNOPQRST"},
        {:text, "UVWXYZ0123"},
        {:text, "4567890abc"}
      ]

      viewport_node = %{
        type: :viewport,
        content: content,
        scroll_x: 2,
        scroll_y: 1,
        width: 5,
        height: 2
      }

      NodeRenderer.render_to_buffer(viewport_node, bm, 1, 1)

      buffer = BufferManager.get_current_buffer(bm)
      # Row 1 should show "MNOPQ" (from "KLMNOPQRST" starting at col 3)
      assert Buffer.get_cell(buffer, 1, 1).char == "M"
      assert Buffer.get_cell(buffer, 1, 2).char == "N"
      # Row 2 should show "WXYZ0" (from "UVWXYZ0123" starting at col 3)
      assert Buffer.get_cell(buffer, 2, 1).char == "W"
      assert Buffer.get_cell(buffer, 2, 2).char == "X"
    end
  end
end
