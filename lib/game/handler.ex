defmodule Game.Handler do
  alias ElixirClusterGame.ChannelManager

  def send_to_named(named, msg) do
    ChannelManager.send_to_named(named, msg)
  end

  def send_to_all(msg) do
    ChannelManager.send_to_all(msg)
  end

  def handle(from_node, game_msg) do
    IO.puts("Received game message from #{from_node}: #{inspect(game_msg)}")
  end
  def handle({:shot, _shooter, _shooter_move, _target, _shot_chain}) do
    :rock
    # IO.puts("Received game message from #{from_node}: #{inspect(game_msg)}")
  end

  def handle({:won, _other_player, :paper, _shot_chain}) do
    :end_beam
    # IO.puts("Received game message from #{from_node}: #{inspect(game_msg)}")
  end

  def handle({:won, _other_player, _their_move, _shot_chain}) do
    {:shoot, :ethan, :rock}
  end
end
