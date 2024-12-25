defmodule ElixirClusterGame.RoshamboLaser.GameState do
  use GenServer

  alias ElixirClusterGame.ChannelManager
  alias ElixirClusterGame.RoshamboLaser.Game

  # Public API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def handle_first_shot(target_person, move), do: GenServer.cast(__MODULE__, {:first_shot, target_person, move})
  def set_starting_player(player), do: GenServer.cast(__MODULE__, {:set_starting_player, player})
  def declare_shot_ended(), do: GenServer.cast(__MODULE__, :declare_shot_ended)
  def get_starting_player(), do: GenServer.call(__MODULE__, :get_starting_player)
  def get_rules(), do: GenServer.call(__MODULE__, :get_rules)
  def get_game_history(), do: GenServer.call(__MODULE__, :get_game_history)
  def record_reply_and_new_shot(from_message_id, pending_message_move, player_who_won, their_new_chosen_target, their_move), do:
    GenServer.cast(__MODULE__, {:record_reply_and_new_shot, from_message_id, pending_message_move, player_who_won, their_new_chosen_target, their_move})
  def record_reply_and_beam_end(from_message_id, pending_message_move, player_who_won, end_or_missed), do:
    GenServer.cast(__MODULE__, {:record_reply_and_beam_end, from_message_id, pending_message_move, player_who_won, end_or_missed})
  def record_reply_and_new_won(from_message_id, move_to_record_at_message_id, winner, other_user, other_users_move), do:
    GenServer.cast(__MODULE__, {:record_reply_and_new_won, from_message_id, move_to_record_at_message_id, winner, other_user, other_users_move})
  def record_reply_and_new_split(from_message_id, move_to_record_at_message_id, winners), do:
    GenServer.cast(__MODULE__, {:record_reply_and_new_split, from_message_id, move_to_record_at_message_id, winners})
  def record_new_shot(from_message_id, shooter, shooter_move, target), do:
    GenServer.cast(__MODULE__, {:record_new_shot, from_message_id, shooter, shooter_move, target})

  # GenServer callbacks

  @impl true
  def init(_args) do
    {:ok,
     %{
       rules: Game.default_rules(),
       history: [],
       next_message_id: 1,
       shot_in_progress: false
     }}
  end

  @impl true
  def handle_call(:get_rules, _from, state) do
    {:reply, state.rules, state}
  end

  def handle_call(:get_game_history, _from, state) do
    {:reply, state.history, state}
  end

  def handle_call(:get_starting_player, _from, state) do
    {:reply, Map.get(state.rules, :starting_player), state}
  end

  @impl true
  def handle_cast({:set_starting_player, player}, state) do
    new_rules = Map.put(state.rules, :starting_player, player)
    {:noreply, %{state | rules: new_rules}}
  end

  def handle_cast({:first_shot, _target_person, _move}, %{shot_in_progress: true} = state) do
    IO.puts("[GameState] Shot in progress, ignoring first_shot")
    {:noreply, state}
  end
  def handle_cast({:first_shot, target_person, move}, state) do
    shooter = state.rules.starting_player
    {msg_id, state} = next_message_id(state)
    shot_chain = []
    shot = new_shot(shooter, move, target_person, msg_id)
    shot_msg = {:shot, shot, shot_chain}

    ChannelManager.broadcast_game_message({:send_message, target_person, msg_id, shot_msg})

    {:noreply, %{state | history: state.history ++ [shot], shot_in_progress: true}}
  end

  def handle_cast(:declare_shot_ended, state) do
    {:noreply, %{state | shot_in_progress: false}}
  end

  def handle_cast({:record_reply_and_new_shot, _,_,_,_,_}, %{shot_in_progress: false} = state), do: {:noreply, state}
  def handle_cast({:record_reply_and_new_shot, pending_message_id, pending_message_move, player_who_won, their_new_chosen_target, their_move}, state) do
    {msg_id, state} = next_message_id(state)
    new_shot = new_shot(player_who_won, their_move, their_new_chosen_target, msg_id)

    # Apply to the change to the history, walking through it's branching tree structure, apply it just after the :pending message id
    state = update_pending_message_id(state.history, pending_message_id, pending_message_move, new_shot)

    {:noreply, state}
  end

  def handle_cast({:record_reply_and_beam_end, _,_,_,_}, %{shot_in_progress: false} = state), do: {:noreply, state}
  def handle_cast({:record_reply_and_beam_end, pending_message_id, pending_message_move, player_who_won, end_or_missed}, state) do
    new_item = end_or_missed(player_who_won, end_or_missed)

    # Apply to the change to the history, walking through it's branching tree structure, add it just after the :pending message id
    state = update_pending_message_id(state.history, pending_message_id, pending_message_move, new_item)

    {:noreply, state}
  end

  def handle_cast({:record_reply_and_new_split, _,_,_}, %{shot_in_progress: false} = state), do: {:noreply, state}
  def handle_cast({:record_reply_and_new_split, pending_message_id, pending_message_move, {win_choice_one, win_choice_two}}, state) do
    shot_chain = generate_shot_chain(state.history, pending_message_id)
    {state, split_one} = new_split_history(win_choice_one, shot_chain, state)
    {state, split_two} = new_split_history(win_choice_two, shot_chain, state)
    new_item = {:split_beam, split_one, split_two}

    # Apply to the change to the history, walking through it's branching tree structure, add it just after the :pending message id
    state = update_pending_message_id(state.history, pending_message_id, pending_message_move, new_item)

    {:noreply, state}
  end

  def handle_cast({:record_reply_and_new_won, _,_,_,_,_}, %{shot_in_progress: false} = state), do: {:noreply, state}
  def handle_cast({:record_reply_and_new_won, pending_message_id, pending_message_move, winner, other_user, other_users_move}, state) do
    {new_message_id, state} = next_message_id(state)
    shot_chain = generate_shot_chain(state.history, pending_message_id)
    won = new_won(winner, new_message_id)
    won_msg = {:won, other_user, other_users_move, shot_chain}

    # Apply to the change to the history, walking through it's branching tree structure, add it just after the :pending message id
    state = update_pending_message_id(state.history, pending_message_id, pending_message_move, won)

    ChannelManager.broadcast_game_message({:send_message, winner, new_message_id, won_msg})

    {:noreply, state}
  end

  def handle_cast({:record_new_shot, _,_,_,_}, %{shot_in_progress: false} = state), do: {:noreply, state}
  def handle_cast({:record_new_shot, pending_message_id, shooter, shooter_move, target}, state) do
    {new_message_id, state} = next_message_id(state)
    shot_chain = generate_shot_chain(state.history, pending_message_id)
    shot = new_shot(shooter, shooter_move, target, new_message_id)
    shot_msg = {:shot, shot, shot_chain}

    ChannelManager.broadcast_game_message({:send_message, target, new_message_id, shot_msg})

    {:noreply, %{state | history: state.history ++ [shot]}}
  end

  def new_split_history({winner, other_user, other_users_move}, shot_chain, state) do
    {new_message_id, state} = next_message_id(state)
    won = new_won(winner, new_message_id)
    won_msg = {:won, other_user, other_users_move, shot_chain}

    ChannelManager.broadcast_game_message({:send_message, winner, new_message_id, won_msg})

    {state, [won]}
  end

  def generate_shot_chain(history, pending_message_id, chain \\ []) do
    # Walk through the history including branches like update_pending_message_id, and identify the chain (just the winners names only)
    case List.last(history) do
      {_, _, _, {:pending, ^pending_message_id}} ->
        # Found the pending message, add the chain to the list
        chain ++ [history |> Enum.map(fn {w,_,_,_} -> w end)]
      {_, {:pending, ^pending_message_id}, nil, nil} ->
        # Found the pending message, add the chain to the list
        chain ++ [history |> Enum.map(fn {w,_,_,_} -> w end)]
      {_, _, _, {:split_beam, split_one, split_two}} ->
        new_chain = [history |> Enum.drop(-1) |> Enum.map(fn {w,_,_,_} -> w end)]
        chain_one = generate_shot_chain(split_one, pending_message_id, chain ++ new_chain)
        chain_two = generate_shot_chain(split_two, pending_message_id, chain ++ new_chain)
        # if either chain has a list, return it
        case {chain_one,chain_two} do
          {:not_found, :not_found} -> :not_found
          {_, :not_found} -> chain_one
          {:not_found, _} -> chain_two
        end
      _ ->
        :not_found
    end
  end

  def update_pending_message_id(history, pending_message_id, pending_update, new_history_item_to_add) do
    # If the last message is :pending...
    case List.last(history) do
      # a player who won, nominating the person they will shoot next
      #   The new_shot contains a new pending message as the last element
      {_a, {:pending, ^pending_message_id}, nil, nil} ->
        { new_shot } = pending_update
        List.replace_at(history, length(history) - 1, new_shot)
      # the player who was shot, choosing their response move
      {a, b, c, {:pending, ^pending_message_id}} ->
        {pending_message_move} = pending_update
        # Update the last pending item
        new_history = List.replace_at(history, length(history) - 1, {a, b, c, pending_message_move})
        # Apply the function to the history
        new_history ++ [new_history_item_to_add]

        # This case is not an update, but proceeding to the next level of the tree
      {:split_beam, split_one, split_two} ->
        # Nest to each branch
        s1 = update_pending_message_id(split_one, pending_message_id, pending_update, new_history_item_to_add)
        s2 = update_pending_message_id(split_two, pending_message_id, pending_update, new_history_item_to_add)

        # Update just in case, any edits were made
        List.replace_at(history, length(history) - 1, {:split_beam, s1, s2})
      _ ->
        # If the last message is not :pending or a split, do nothing
        history
    end
  end

  def get_all_history_nodes(history, acc \\ []) do
    case List.last(history) do
      {_, _, _, _} ->
        acc ++ [history]
      {:split_beam, split_one, split_two} ->
        acc ++ [history |> Enum.drop(-1)] ++ get_all_history_nodes(split_one) ++ get_all_history_nodes(split_two)
    end
  end

  def get_all_history_shots(history) do
    get_all_history_nodes(history, [])
    |> Enum.filter(fn {_,n,_,_} -> n != :end end)
    |> Enum.filter(fn {_,n,_,_} -> n != :missed end)
  end

  def get_all_beam_ends(history, acc \\ [])
  def get_all_beam_ends([], acc), do: acc
  def get_all_beam_ends(history, acc) do
    case List.last(history) do
      {_, _, _, _} = n ->
        acc ++ [n]
      {:split_beam, split_one, split_two} ->
        acc ++ [history |> Enum.drop(-1)] ++ get_all_beam_ends(split_one) ++ get_all_beam_ends(split_two)
    end
  end

  def next_message_id(state) do
    {state.next_message_id, %{state | next_message_id: state.next_message_id + 1}}
  end

  def new_shot(shooter, move, target, message_id), do: {shooter, move, target, {:pending, message_id}}
  def new_won(winner, message_id), do: {winner, {:pending, message_id}, nil, nil}
  def end_or_missed(shooter, end_or_missed), do: {shooter, end_or_missed, nil, nil}
end
