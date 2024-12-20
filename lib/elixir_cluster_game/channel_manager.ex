defmodule ElixirClusterGame.ChannelManager do
  use GenServer
  require Logger

  @topic "cluster:lobby"

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(ElixirClusterGame.PubSub, @topic)
    {:ok, state}
  end

  @doc """
  Send a message to all nodes in the cluster.

  `msg` can be any term, for example: `{:banana, 528}`
  """
  def send_to_all(msg) do
    broadcast({:to_all, Node.self(), msg})
  end

  @doc """
  Send a message to a specific short username.

  For example:
      send_to_named(:tommy, {:banana, 528})
  """
  def send_to_named(target_short_name, msg) do
    # We'll broadcast with a target_short_name and let all receivers
    # decide if it's for them.
    broadcast({:to_named, Node.self(), target_short_name, msg})
  end

  def handle_info({:nodeup, full_node_name}, state) do
    # This message might come from your NodeWatcher when a node joins.
    short = short_from_full_node_name(full_node_name)
    new_state = Map.put(state, short, full_node_name)
    Logger.info("Node joined: #{full_node_name} as #{short}")
    {:noreply, new_state}
  end

  def handle_info({:nodedown, full_node_name}, state) do
    short = short_from_full_node_name(full_node_name)
    new_state = Map.delete(state, short)
    Logger.info("Node left: #{full_node_name} (short: #{short})")
    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    # This will handle PubSub messages from broadcast
    case msg do
      {:to_all, from_node, game_msg} ->
        handle_incoming_message(from_node, game_msg)

      {:to_named, from_node, target_short_name, game_msg} ->
        my_short = ElixirClusterGame.NodeName.short_name()
        if my_short == target_short_name do
          handle_incoming_message(from_node, game_msg)
        end

      _ ->
        # Unknown message type
        :ok
    end

    {:noreply, state}
  end

  defp handle_incoming_message(from_node, game_msg) do
    # Extract the short name of sender for convenience
    from_short = short_from_full_node_name(from_node)

    # Here’s where you handle your actual game logic. For example:
    # pattern match on the game_msg and do something:
    case game_msg do
      {:banana, number} ->
        IO.puts("Received {:banana, #{number}} from #{from_short}")
      _ ->
        IO.puts("Received #{inspect(game_msg)} from #{from_short}")
    end
  end

  defp broadcast(msg) do
    Phoenix.PubSub.broadcast(ElixirClusterGame.PubSub, @topic, msg)
  end

  defp short_from_full_node_name(full_node) do
    full_str = Atom.to_string(full_node)
    [short | _] = String.split(full_str, "@")
    String.to_atom(short)
  end
end
