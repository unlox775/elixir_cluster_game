defmodule ElixirClusterGame.NodeName do
  def short_name do
    # node() returns something like :"node1@hostname"
    # Convert it to a string and split
    node_str = Atom.to_string(node())
    [short | _] = String.split(node_str, "@")
    String.to_atom(short)
  end
end
