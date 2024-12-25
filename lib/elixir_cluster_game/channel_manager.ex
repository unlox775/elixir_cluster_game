defmodule ElixirClusterGame.ChannelManager do
  use GenServer
  require Logger

  alias ElixirClusterGame.NodeName
  alias Game.Handler, as: PlayersGameModule
  alias ElixirClusterGame.RoshamboLaser.Game, as: RoshamboGame
  alias ElixirClusterGame.RoshamboLaser.GameState, as: RoshamboState

  @topic "cluster:lobby"

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{nodes: %{NodeName.short_name() => :self}, dice_rolls_by_type: %{}, dice_roll_winners_by_type: %{}}, name: __MODULE__)
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

  def roll_dice(message_type) do
    # This node gets a random nunber (as all others are getting at the same moment)
    random_number = Enum.random(1..10_000_000)
    broadcast({:roll_dice, Node.self(), {message_type, random_number}})
  end

  def is_player_present?(player_name) do
    # Check if a player is present in the cluster
    # by checking the state of the ChannelManager
    state = GenServer.call(__MODULE__, fn state -> state end)
    # state is a map of already shortened names, check if this player name is in the map
    Map.has_key?(state, player_name)
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


  def broadcast(msg) do
    Phoenix.PubSub.broadcast(ElixirClusterGame.PubSub, @topic, msg)
  end

  defp shorten_node_name(full_node) do
    full_str = Atom.to_string(full_node)
    [short | _] = String.split(full_str, "@")
    String.to_atom(short)
  end

  # ------------------------------------------------------------------------
  # New public methods for the game system
  # ------------------------------------------------------------------------

  def broadcast_game_end(game_end_payload) do
    # Everyone sees :game_end
    Phoenix.PubSub.broadcast(
      ElixirClusterGame.PubSub,
      @topic,
      {:game_end, game_end_payload}
    )
  end

  def broadcast_game_message(msg) do
    # For arbitrary game messages broadcast
    Phoenix.PubSub.broadcast(
      ElixirClusterGame.PubSub,
      @topic,
      {:game_message, msg}
    )
  end

  # For direct one-node message, you might do a to_named approach,
  # but for simplicity we’re using broadcast in the example.

  # ------------------------------------------------------------------------
  # handle_info for incoming PubSub messages
  # ------------------------------------------------------------------------

  @impl true

  def handle_info({:nodeup, full_node_name}, state) do
    # This message might come from your NodeWatcher when a node joins.
    short = shorten_node_name(full_node_name)

    # Start an all-node roll_dice
    roll_dice(:new_starting_player)

    state = %{state | nodes: Map.put(state.nodes, short, full_node_name)}
    Logger.info("Node joined: #{full_node_name} as #{short}.  Cluster: #{inspect(Map.keys(state.nodes))}")
    {:noreply, state}
  end

  def handle_info({:nodedown, full_node_name}, state) do
    short = shorten_node_name(full_node_name)

    # Start an all-node roll_dice
    roll_dice(:new_starting_player)

    state = %{state | nodes: Map.delete(state.nodes, short)}
    Logger.info("Node left: #{full_node_name} (short: #{short}).  Cluster: #{inspect(Map.keys(state.nodes))}")
    {:noreply, state}
  end

  def handle_info({:roll_dice, from_node, roll}, state) do
    roll_identifier = all_nodes_to_identifier(state)
    {state, did_record_a_new_roll} = record_roll(from_node, roll, roll_identifier, state)

    {:noreply, notify_winner_if_roll_complete(state, roll, roll_identifier, did_record_a_new_roll)}
  end

  def handle_info({:to_all, from_node, game_msg}, state) do
    handle_incoming_message(from_node, game_msg)
    {:noreply, state}
  end

  def handle_info({:to_named, from_node, target_short_name, game_msg}, state) do
    my_short = ElixirClusterGame.NodeName.short_name()
    if my_short == target_short_name do
      handle_incoming_message(from_node, game_msg)
    end
    {:noreply, state}
  end

  def handle_info({:game_end, game_end_payload}, state) do
    # When the game ends, call the Game.game_end function:
    RoshamboGame.game_end(game_end_payload)
    {:noreply, state}
  end

  def handle_info({:game_message, {:send_message, to_player, message_id, msg}}, state) do
    my_short = ElixirClusterGame.NodeName.short_name()
    if my_short == to_player do
      # call this user' local handler:
      RoshamboGame.handle_incoming_message(message_id, msg)
    else
      # Not for us, ignore or do nothing
      :ok
    end

    {:noreply, state}
  end

  # Handle unknown messages
  def handle_info(_, state), do: {:noreply, state}

  def record_roll(from_node, {type, random_number}, roll_identifier, state) do
    with map_by_identifier <- Map.get(state.dice_rolls_by_type, type, %{}),
         map_by_player <- Map.get(map_by_identifier, roll_identifier, %{}),
         {:already_rolled, false} <- {:already_rolled, Map.has_key?(map_by_player, from_node)} do
      map_by_player = Map.put(map_by_player, from_node, random_number)
      map_by_identifier = Map.put(map_by_identifier, roll_identifier, map_by_player)
      {%{state | dice_rolls_by_type: Map.put(state.dice_rolls_by_type, type, map_by_identifier)}, true}
    else
      _ -> {state, false}
    end
  end

  def notify_winner_if_roll_complete(state, _, _, false), do: state
  def notify_winner_if_roll_complete(state, {type, _}, roll_identifier, _) do
    current_roll_identifier = all_nodes_to_identifier(state)
    rolls = map_size(state.dice_rolls_by_type[type][roll_identifier])
    winning_node = Map.to_list(state.dice_rolls_by_type[type][roll_identifier]) |> Enum.max_by(&elem(&1, 1)) |> elem(0)
    cond do
      current_roll_identifier != roll_identifier -> state
      rolls != map_size(state.nodes) -> state
      Map.get(state.dice_roll_winners_by_type, type, nil) == winning_node -> state
      true ->
        winning_roll(type, winning_node)
        %{state | dice_roll_winners_by_type: Map.put(state.dice_roll_winners_by_type, type, winning_node)}  |> IO.inspect(label: "new winner")
    end
  end

  def winning_roll(:new_starting_player, winning_node) do
    Logger.info("New starting player: #{winning_node}")
    RoshamboState.set_starting_player(winning_node)
  end

  defp handle_incoming_message(from_node, game_msg) do
    PlayersGameModule.handle(shorten_node_name(from_node), game_msg)
  end

  defp all_nodes_to_identifier(state) do
    Map.keys(state.nodes)|> Enum.sort() |> Enum.join("_")
  end
end
