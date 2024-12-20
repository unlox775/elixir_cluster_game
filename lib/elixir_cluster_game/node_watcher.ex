defmodule ElixirClusterGame.NodeWatcher do
  use GenServer

  @check_interval 500

  def start_link(_args) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(_state) do
    schedule_check()
    {:ok, Node.list()}
  end

  def handle_info(:check_nodes, known_nodes) do
    current_nodes = Node.list()
    Enum.each(current_nodes -- known_nodes, fn n ->
      IO.puts("[JOIN] Node joined: #{n}")
      IO.puts("Current cluster: #{inspect(current_nodes)}")
    end)

    Enum.each(known_nodes -- current_nodes, fn n ->
      IO.puts("[LEAVE] Node left: #{n}")
      IO.puts("Current cluster: #{inspect(current_nodes)}")
    end)


    schedule_check()
    {:noreply, current_nodes}
  end

  defp schedule_check do
    Process.send_after(self(), :check_nodes, @check_interval)
  end
end
