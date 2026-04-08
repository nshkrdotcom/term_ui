defmodule TermUI.RuntimeCursorTest do
  use ExUnit.Case, async: false

  alias TermUI.Component.RenderNode
  alias TermUI.Event
  alias TermUI.Runtime

  defmodule CursorComponent do
    use TermUI.Elm

    def init(opts) do
      %{
        count: 0,
        cursor_pos: Keyword.get(opts, :cursor_pos, {0, 0})
      }
    end

    def event_to_msg(%Event.Key{key: :up}, _state), do: {:msg, :rerender}
    def event_to_msg(_, _state), do: :ignore

    def update(:rerender, state), do: {%{state | count: state.count + 1}, []}
    def update(_, state), do: {state, []}

    def view(state) do
      RenderNode.stack(:vertical, [
        RenderNode.cursor_hint(state.cursor_pos),
        RenderNode.text("frame #{state.count}")
      ])
    end
  end

  defmodule RecordingBackend do
    @behaviour TermUI.Backend

    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         size: Keyword.get(opts, :size, {4, 8}),
         cursor_visible: Keyword.get(opts, :cursor_visible, true),
         cursor_position: nil
       }}
    end

    def shutdown(_state), do: :ok

    def size(%{size: size}), do: {:ok, size}

    def move_cursor(%{test_pid: test_pid} = state, position) do
      send(test_pid, {:backend_call, :move_cursor, position})
      {:ok, %{state | cursor_position: position}}
    end

    def hide_cursor(%{cursor_visible: false} = state), do: {:ok, state}

    def hide_cursor(%{test_pid: test_pid} = state) do
      send(test_pid, {:backend_call, :hide_cursor})
      {:ok, %{state | cursor_visible: false}}
    end

    def show_cursor(%{cursor_visible: true} = state), do: {:ok, state}

    def show_cursor(%{test_pid: test_pid} = state) do
      send(test_pid, {:backend_call, :show_cursor})
      {:ok, %{state | cursor_visible: true}}
    end

    def clear(state), do: {:ok, state}

    def draw_cells(%{test_pid: test_pid} = state, cells) do
      send(test_pid, {:backend_call, :draw_cells, length(cells)})
      {:ok, state}
    end

    def flush(%{test_pid: test_pid} = state) do
      send(test_pid, {:backend_call, :flush})
      {:ok, state}
    end

    def poll_event(state, _timeout), do: {:timeout, state}
  end

  setup do
    :ok
  end

  test "hides the stale cursor before drawing a frame with a cursor hint" do
    {:ok, runtime} =
      Runtime.start_link(
        root: CursorComponent,
        backend: {RecordingBackend, test_pid: self()},
        render_interval: 10
      )

    assert_receive {:backend_call, :hide_cursor}
    assert_receive {:backend_call, :draw_cells, _}
    assert_receive {:backend_call, :flush}
    assert_receive {:backend_call, :move_cursor, {1, 1}}
    assert_receive {:backend_call, :show_cursor}

    assert_runtime_shutdown(runtime)
  end

  test "clamps cursor hints to the backend bounds before moving the cursor" do
    {:ok, runtime} =
      Runtime.start_link(
        root: CursorComponent,
        backend: {RecordingBackend, test_pid: self(), size: {4, 8}},
        render_interval: 10,
        cursor_pos: {20, 30}
      )

    assert_receive {:backend_call, :move_cursor, {4, 8}}

    assert_runtime_shutdown(runtime)
  end

  defp assert_runtime_shutdown(runtime) do
    ref = Process.monitor(runtime)
    Runtime.shutdown(runtime)
    assert_receive {:DOWN, ^ref, :process, ^runtime, _reason}
  end
end
