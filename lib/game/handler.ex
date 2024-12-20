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
end
