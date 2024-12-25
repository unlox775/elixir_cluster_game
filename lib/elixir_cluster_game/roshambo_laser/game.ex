defmodule ElixirClusterGame.RoshamboLaser.Game do
@moduledoc """
  Contains pure game logic and utility functions, separate from the GenServer state.

  The history structure is typically a list of tuples or nested splits:

      [
        {:ethan, :paper, :dad, :rock},
        {:ethan, :scissors, :rose, :scissors},
        {:split_beam, [...], [...]}
      ]

  Each 4-tuple often represents a shot: {shooter, shooter_move, target, target_move_or_result}.
  'beam_end' or 'missed' can appear instead of a move, indicating a beam ended or was missed.

  A `:split_beam` node indicates branching game states.
  """

  require Logger
  alias ElixirClusterGame.ChannelManager
  alias ElixirClusterGame.RoshamboLaser.GameState
  alias ElixirClusterGame.NodeName

  @default_rules %{
    all_players_shot_at_least_n_times: 2,
    final_num_beams_is_eq: 2,
    max_total_shots: 6,
    starting_player: nil
  }

  def default_rules do
    @default_rules
  end

  def first_shot(target_person, move) do
    # Only the starting player can make the first shot
    starting_player = GameState.get_starting_player()
    current_player = NodeName.short_name()

    case current_player do
      ^starting_player ->
        # This is the starting player
        GameState.handle_first_shot(target_person, move)

      _ ->
        # Not the starting player
        {:error, "Only the starting player can make the first shot"}
    end
  end

  def handle_incoming_message(message_id, {:shot, {shooter, shooter_move, target, _}, shot_chain}), do:
    handle_incoming_shot(message_id, shooter, shooter_move, target, shot_chain)

  def handle_incoming_message(message_id, {:won, {other_player, their_move, _}, shot_chain}), do:
    handle_incoming_won(message_id, other_player, their_move, shot_chain)

  def handle_incoming_shot(pending_message_id, shooter, shooter_move, target, shot_chain) do
    # set missed_code to a random number between 1 and 10_000_000_000
    auth_token = Enum.random(1..10_000_000_000)
    handle_arg = {:shot, shooter, shooter_move, target, shot_chain}

    # Call the Game.Handler, and catch if there is no matching function
    reply =
      try do
        Game.Handler.handle(handle_arg)
      rescue
        FunctionClauseError -> {:missed, auth_token}
        other -> {:error, auth_token, other}
      end

    case reply do
      {:missed, ^auth_token} ->
        GameState.record_reply_and_beam_end(pending_message_id, :missed, shooter, :missed)

      {:error, ^auth_token, error_message} ->
        Logger.info("Error calling your handle function: #{error_message}\n\nwith args: #{inspect(handle_arg)}")
        GameState.record_reply_and_beam_end(pending_message_id, :missed, shooter, :missed)

      target_move when target_move in [:rock, :paper, :scissors] ->
        winners = determine_winners([{shooter, shooter_move}, {target, target_move}])
        case Enum.count(winners) do
          1 ->
            [{winner, other_user, other_users_move}] = winners
            GameState.record_reply_and_new_won(pending_message_id, target_move, winner, other_user, other_users_move)
          _ ->
            GameState.record_reply_and_new_split(pending_message_id, target_move, winners)
        end

      illegal_reply ->
        Logger.info("Your function made an illegal reply: #{inspect(illegal_reply)}\n\nwith args: #{inspect(handle_arg)}")
        GameState.record_reply_and_beam_end(pending_message_id, :missed, shooter, :missed)
    end

    history = GameState.get_game_history()
    {game_over, game_was_won} = game_ended?(history, GameState.get_rules())
    if game_over do
      ChannelManager.broadcast_game_message({:game_end, history, game_was_won})
    end
  end

  def handle_incoming_won(pending_message_id, other_player, their_move, shot_chain) do
    # set missed_code to a random number between 1 and 10_000_000_000
    auth_token = Enum.random(1..10_000_000_000)
    handle_arg = {:won, other_player, their_move, shot_chain}

    # Call the Game.Handler, and catch if there is no matching function
    reply =
      try do
        Game.Handler.handle(handle_arg)
      rescue
        FunctionClauseError -> {:missed, auth_token}
        other -> {:error, auth_token, other}
      end

    current_player = NodeName.short_name()
    case reply do
      {:missed, ^auth_token} ->
        GameState.record_reply_and_beam_end(pending_message_id, their_move, current_player, :missed)

      {:error, ^auth_token, error_message} ->
        Logger.info("Error calling your handle function: #{error_message}\n\nwith args: #{inspect(handle_arg)}")
        GameState.record_reply_and_beam_end(pending_message_id, their_move, current_player, :missed)

      :end_beam ->
          GameState.record_reply_and_beam_end(pending_message_id, their_move, current_player, :end)

      {:shoot, player_to_shoot, shooter_move} when is_atom(player_to_shoot) and shooter_move in [:rock, :paper, :scissors] ->
        cond do
          ! ChannelManager.is_player_present?(player_to_shoot) ->
            Logger.info("Player #{player_to_shoot} is not present\n\nwith args: #{inspect(handle_arg)}")
            GameState.record_reply_and_beam_end(pending_message_id, their_move, current_player, :missed)
          player_to_shoot == current_player ->
            Logger.info("You attempted to shoot yourself (#{player_to_shoot}), which is not allowed\n\nwith args: #{inspect(handle_arg)}")
            GameState.record_reply_and_beam_end(pending_message_id, their_move, current_player, :missed)
          true ->
            GameState.record_new_shot(pending_message_id, current_player, shooter_move, player_to_shoot)
        end

      illegal_reply ->
        Logger.info("Your function made an illegal reply: #{inspect(illegal_reply)}\n\nwith args: #{inspect(handle_arg)}")
        GameState.record_reply_and_beam_end(pending_message_id, their_move, current_player, :missed)
    end
  end

  @doc """
  Returns true if the game has ended based on `game_history` and `game_rules`.
  Example rule checks might include:
    - `max_total_shots` reached
    - `all beams ended`
  """
  def game_ended?(game_history, game_rules) do
    max_shots = Map.get(game_rules, :max_total_shots, 6)
    total_shots = count_num_shots(game_history)
    game_over =
      if total_shots >= max_shots do
        true
      else
        # Optionally check if all beams ended, or other rule
        all_beams_ended = all_beams_ended?(game_history)
        all_beams_ended
      end

    game_was_won =
      player_with_least_shots(game_history) >= game_rules.all_players_shot_at_least_n_times
      && count_num_beams(game_history) == game_rules.final_num_beams_is_eq
      && !any_missed?(game_history)
      && all_beams_ended?(game_history)
      && count_num_shots(game_history) <= game_rules.max_total_shots

    {game_over, game_was_won}
  end

  def game_end({game_history, game_was_won}) do
    # Set the shot_in_progress to false in GameState
    GameState.declare_shot_ended()

    # render the game state
    IO.puts(ElixirClusterGame.RoshamboLaser.RenderTree.render(game_history))

    # if they won, Celebrate!
    if game_was_won do
      IO.puts("Congratulations! You won!")
    else
      IO.puts("Better luck next time!")
    end
  end

  @doc """
  Takes a list of players and moves, for example:

      [ {:dave, :rock}, {:ro, :scissors} ]

  Returns a list of winners, for instance `[{:dave, :rock}]`.
  If there's a tie (rock vs rock, etc.), it might return both, e.g. `[{:dave, :rock}, {:ro, :rock}]`.
  """
  def determine_winners(players_and_moves) when is_list(players_and_moves) do
    # A simplistic RPS: rock beats scissors, paper beats rock, scissors beats paper
    # If only 2 players, easy. If more, define multi-logic. Here's a 2-player example:
    # If tie, return both; else single winner.
    # Expand if you need multi-player logic or something more advanced.
    case players_and_moves do
      [{p1, m1}, {p2, m2}] ->
        cond do
          m1 == m2 ->
            # Tie => both win
            [{p1, p2, m2}, {p2, p1, m1}]

          beats?(m1, m2) ->
            # p1 wins
            [{p1, p2, m2}]

          true ->
            # p2 wins
            [{p2, p1, m1}]
        end

      # Possibly handle more than 2 players if desired:
      _ ->
        players_and_moves
    end
  end

  defp beats?(:rock, :scissors),   do: true
  defp beats?(:paper, :rock),      do: true
  defp beats?(:scissors, :paper),  do: true
  defp beats?(_move1, _move2),     do: false

  @doc """
  Counts how many shots have been made in the `game_history`.
  By default, any 4-tuple is considered a “shot,” but you can refine logic as needed.
  """
  def count_num_shots(game_history) do
    Enum.count(GameState.get_all_history_shots(game_history))
  end


  # Counts how many beams currently exist in the `game_history`.
  # A “beam” is essentially any path from top to bottom. A `:split_beam` branches into multiple beams.
  defp count_num_beams(game_history), do: Enum.count(GameState.get_all_beam_ends(game_history))


  # Checks if any shot was missed (e.g. ‘:missed’) in the final history.
  # Returns true if a player did not respond or if there's a :missed anywhere.
  defp any_missed?(game_history) do
    GameState.get_all_beam_ends(game_history)
    |> Enum.any?(fn {_,n,_,_} -> n == :missed end)
  end

  # Returns {player, number_of_shots} for the player with the least shots fired.
  # Tie-breaking is up to you. If multiple players have same min shots, returns one arbitrarily.
  defp player_with_least_shots(game_history) do
    # Tally how many times each player did the shooting, then pick the min.
    tally =
      GameState.get_all_history_shots(game_history)
      |> Enum.reduce(%{}, fn {shooter,_,_,_}, acc -> Map.update(acc, shooter, 1, &(&1 + 1)) end)
      |> Map.to_list()
    Enum.min_by(tally, &elem(&1, 1))
  end

  # Helper to see if all beams ended.
  # For example, a beam ends if the last item is :beam_end or if a chain has no further splits.
  defp all_beams_ended?(game_history) do
    GameState.get_all_beam_ends(game_history)
    |> Enum.all?(fn n -> Enum.count(Tuple.to_list(n)) == 4 && elem(n,1) == :end end)
  end
end
