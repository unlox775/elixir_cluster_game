defmodule ElixirClusterGame.NodeName do
  def short_name do
    shorten(node())
  end

  def shorten(full_node) do
    full_str = Atom.to_string(full_node)
    [short | _] = String.split(full_str, "@")
    String.to_atom(short)
  end
end
