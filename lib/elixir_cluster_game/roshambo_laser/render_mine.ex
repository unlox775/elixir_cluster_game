defmodule ElixirClusterGame.RoshamboLaser.RenderMine do
  @moduledoc """
  Converts a "roshambo laser" nested structure into an ASCII diagram.

  The input is a structure like:
  [
    {:ethan, :paper, :dad, :rock},
    {:ethan, :scissors, :rose, :scissors},
    {
      :split_beam,
      [
        {:ethan, :scissors, :dad, :scissors},
        {
          :split_beam,
          [
            {:ethan, :x, nil, nil},
          ],
          [
            {:dad, :paper, :rose, :scissors},
            {:rose, :x, nil, nil}
          ]
        }
      ],
      [
        {:rose, :paper, :ethan, :scissors},
        {:ethan, :x, nil, nil}
      ]
    }
  ]

  This code:
  1. Parses the structure into a grid of cells.
  2. Computes widths.
  3. Renders ASCII.

  Cell types: :normal, :end, :split_start, :split_connector, :split_right, :empty
  Each cell: %{type: atom, top_label: String.t() | nil, right_label: String.t() | nil}
  """

  # Public API
  def render(structure) do
    # Convert the structure into a grid
    {grid, max_x} = build_grid(structure)

    # Compute column widths
    col_widths = compute_column_widths(grid, max_x)

    # Render ASCII
    ascii = render_ascii(grid, col_widths)
    ascii
  end

  # ------------------------------------------------------------
  # Step 1: Building the grid
  #
  # We'll define a recursive function that walks the structure and populates `grid`.
  # `grid` is a list of rows (y), each row is a list of cells, indexed by x.
  #
  # Returns {grid, max_x}
  #
  # This is an example Grid:
  # [
  #   [
  #     %{right_label: "dad:rock", top_label: "ethan:paper", type: :normal},
  #     %{type: :empty},
  #     %{type: :empty}
  #   ],
  #   [
  #     %{top_label: "ethan:scissors", type: :split_start},
  #     %{type: :split_connector},
  #     %{right_label: "rose:scissors", type: :split_right}
  #   ],
  #   [
  #     %{top_label: "ethan:scissors", type: :split_start},
  #     %{right_label: "dad:scissors", type: :split_right},
  #     %{right_label: "ethan:scissors", top_label: "rose:paper", type: :normal}
  #   ],
  #   [
  #     %{top_label: "ethan:x", type: :end},
  #     %{right_label: "rose:scissors", top_label: "dad:paper", type: :normal},
  #     %{top_label: "ethan:x", type: :end}
  #   ],
  #   [%{type: :empty}, %{top_label: "rose:x", type: :end}, %{type: :empty}]
  # ]
  # ------------------------------------------------------------

  def build_grid(structure) do
    # grid is a map: %{rows: %{y => [cells]}, max_y: integer, max_x: integer}
    # We'll store state in a struct for convenience and return final grid at end.
    state = %{
      rows: %{},
      max_x: 0,
      max_y: nil
    }

    # Start at (x=0, y=-1) so first move down increments y to 0 on first cell
    {state, _end_x, _end_y} = traverse(structure, 0, -1, state)

    # compute max_y
    max_y = state.rows |> Map.keys() |> Enum.max()
    state = %{state | max_y: max_y}

    # Convert rows map to list of lists
    # rows keys from 0..max_y
    rows_list =
      0..max_y
      |> Enum.map(&(Map.get(state.rows, &1, [])))

    # Pad each row so all rows have the same length (max_x+1)
    max_x = state.max_x
    padded_rows = Enum.map(rows_list, &pad_row(&1, max_x+1))

    {padded_rows, max_x}
  end

  defp pad_row(row, length) do
    row_length = row_length(row)
    if row_length < length do
      row ++ Enum.map(0..(length - row_length - 1), fn _ -> empty_cell() end)
    else
      row
    end
  end

  defp row_length(row), do: Enum.count(row)

  # The end of this thread
  defp traverse([], cur_x, cur_y, state), do: {state, cur_x, cur_y}

  defp traverse([head | tail], cur_x, cur_y, state) do
    # Process one element, which can be:
    # {:playerA, moveA, playerB, moveB} or {:player, :x, nil, nil} or {:split_beam, left_sub, right_sub}
    {state, new_x, new_y} = process_step(head, tail, cur_x, cur_y, state)
    # Continue with tail below the last element of head
    traverse(tail, new_x, new_y, state)
  end

  # End of a chain, will always be :x, and empty tail
  defp process_step({p1, :x, nil, nil}, [], cur_x, cur_y, state) do
    # move down
    new_y = cur_y + 1
    {put_cell(state, cur_x, new_y, %{type: :end, top_label: "#{p1}:x"}), cur_x, new_y}
  end

  # A step that does Not result in a split (4-element next step, and :split ones are 3 element)
  defp process_step({p1, m1, p2, m2}, [{_,_,_,_}|_], cur_x, cur_y, state) do
    # move down
    new_y = cur_y + 1
    {put_cell(state, cur_x, new_y, %{type: :normal, top_label: "#{p1}:#{m1}", right_label: "#{p2}:#{m2}"}), cur_x, new_y}
  end

  # A step that results in a split (3-element next step)
  defp process_step({p1, m1, p2, m2}, [{:split_beam,_,_}|_], cur_x, cur_y, state) do
    # move down
    new_y = cur_y + 1
    # IO.inspect(state.rows, label: "before split start")
    state = put_cell(state, cur_x, new_y, %{type: :split_start, top_label: "#{p1}:#{m1}"})
    # Split starts next to it
    # IO.inspect(state.rows, label: "before new column")
    state = insert_column_after(state, cur_x)
    # IO.inspect(cur_x, label: "cur_x")
    # IO.inspect(state.rows, label: "after new column")
    split_x = cur_x + 1
    split_y = new_y
    state = put_cell(state, split_x, split_y, %{type: :split_right, right_label: "#{p2}:#{m2}"})
    # IO.inspect(state.rows, label: "after split right")

    # The next item is the split beam, which will depth-first the outer split first
    {state, cur_x, new_y}
  end

  # When it splits, it is always the end of a chain
  defp process_step({:split_beam, left_sub, right_sub}, [], cur_x, cur_y, state) when is_list(left_sub) and is_list(right_sub) do
    # Handle y first, because when splits happpen later in the X branch, it adds columns and shifts Y over
    right_x = cur_x + 1
    right_y = cur_y
    # IO.inspect(state.rows, label: "pre right_sub")
    {state, _cur_x, _cur_y} = traverse(right_sub, right_x, right_y, state)

    left_x = cur_x
    left_y = cur_y
    # IO.inspect(state.rows, label: "pre left_sub")
    {state, new_x, new_y} = traverse(left_sub, left_x, left_y, state)
    # IO.inspect(state.rows, label: "post left_sub")
    {state, new_x, new_y}
  end

  defp empty_cell do
    %{type: :empty}
  end

  defp split_connector do
    %{type: :split_connector}
  end

  # while_inserting column:
  #   if the cell to the right is split_connector, or split_right, then add a split_connector
  #   otherwise add an empty cell
  defp insert_column_after(state, x) do
    # Insert a new column after x
    # Shift all columns after x to the right
    new_rows = Enum.reduce(state.rows, %{}, fn {y, row}, acc ->
      # same as the row, but with an extra cell at x
      new_row = Enum.reduce(ensure_row_width(row, state.max_x) |> Enum.with_index(), [], fn {cell, x_idx}, new_row_acc ->
        # If this cell is at x, insert a new cell
        if x_idx == x do
          if Map.get(Enum.at(row, x+1, %{}), :type, :none) in [:split_connector, :split_right] do
            new_row_acc ++ [cell] ++ [split_connector()]
          else
            new_row_acc ++ [cell] ++ [empty_cell()]
          end
        else
          new_row_acc ++ [cell]
        end
      end)
      Map.put(acc, y, new_row)
    end)
    %{state | rows: new_rows, max_x: state.max_x + 1}
  end

  defp put_cell(state, x, y, cell) do
    row = Map.get(state.rows, y, [])
    row = ensure_row_width(row, x)
    row = List.replace_at(row, x, cell)
    %{state | rows: Map.put(state.rows, y, row), max_x: max(state.max_x, x)}
  end

  defp ensure_row_width(row, x) do
    needed = x - row_length(row)
    if needed >= 0 do
      row ++ Enum.map(0..needed, fn _ -> empty_cell() end)
    else
      row
    end
  end

  # ------------------------------------------------------------
  # Step 2: Compute column widths
  # The width is actually 2 numbers, as the arrow "||" line is centered with the
  # top label, and the right label is to the right of the double-line.  This means
  # that we have a pre_line_width, and a post_line_width.
  #
  # The post_line width for a column is at least the length of the longest right_label, but
  # if the half of top_label (because it it centered) is greater than the right_label, use that.
  # ------------------------------------------------------------

  defp compute_column_widths(grid, max_x) do
      # For each column, find:
      # - max_tl: max length of top_label
      # - max_rl: max length of right_label
      # Then pre_line = ceil((max_tl+1)/2)
      # post_line = max(floor(max_tl/2), max_rl)
      # total width = pre_line + 2 (line chars) + post_line
      # If max_tl = 0 (no top_label), just assume 1 char for top alignment:
      # Then pre_line = 1, post_line = max(0, max_rl), at least giving space for line and right_label.
      # Adjust as needed.

      0..max_x
      |> Enum.map(fn col ->
        col_cells = Enum.map(grid, &Enum.at(&1, col, %{type: :empty}))
        max_tl = col_cells |> Enum.map(&(label_length(Map.get(&1, :top_label, "")))) |> Enum.max()
        max_rl = col_cells |> Enum.map(&(label_length(Map.get(&1, :right_label,"")))) |> Enum.max()

        max_tl = if max_tl < 1, do: 1, else: max_tl # at least 1 char to place line nicely

        pre_line = div(max_tl + 1, 2) # ceil-half
        post_line = max(div(max_tl, 2), max_rl)

        # total width
        {pre_line, post_line + 1}
      end)
  end

  defp label_length(nil), do: 0
  defp label_length(s), do: String.length(s)

  # ------------------------------------------------------------
  # Step 3: Render ASCII
  #
  # We'll do a simplistic rendering:
  # Each cell type has it's own function:
  #  - It will return a list of 4 strings, one for each line of the cell.
  #  - By reading the pre_line and post_line, the arrows will line up.
  #  - The full char width of the cell is pre_line + 2 + post_line.
  #
  # This is an example output:
  #     ethan:paper
  #        ||
  #        || dad:rock
  #        \/
  #    ethan:scissors
  #        ||=====================================\
  #        ||                                    || rose:scissors
  #        \/                                    \/
  #    ethan:scissors                        rose:paper
  #        ||==============\                     ||
  #        ||             || dad:scissors        || ethan:scissors
  #        \/             \/                     \/
  #     ethan:x        dad:paper              ethan:x
  #                       ||
  #                       || rose:scissors
  #                       \/
  #                     rose:x
  # ------------------------------------------------------------
  defp render_ascii(grid, col_widths) do
    Enum.map(grid, fn row ->
      Enum.map(row |> Enum.with_index(), fn {cell, col} ->
        lines = cell_ascii(cell, Enum.at(col_widths, col))
        IO.puts("#{cell[:type]}: ================ \n#{lines |> Enum.join("\n")}")
        lines
      end)
      # Now each cell is a list of 4 strings, we need to stitch line 1 from each cell together, etc
      |> Enum.reduce(["","","",""], fn cell_lines, acc ->
        Enum.zip(cell_lines, acc)
        |> Enum.map(fn {cell_line, acc_line} -> acc_line <> cell_line end)
      end)
      |> Enum.join("\n")
    end)
    |> Enum.join("\n")
  end

  def cell_ascii(%{type: :empty}, {pre_line, post_line}), do:
    Enum.map(0..3, fn _ -> String.duplicate(" ", pre_line + 2 + post_line) end)

  def cell_ascii(%{type: :normal, top_label: tl, right_label: rl}, {pre_line, post_line}) do
    right_gap_space = String.duplicate(" ", post_line - pre_line) # it should always be equal or greater
    pre_line_space = String.duplicate(" ", pre_line)
    post_line_space = String.duplicate(" ", post_line)
    [
      center_text(tl, pre_line*2+2) <> right_gap_space,
      pre_line_space <> "||" <> post_line_space,
      pre_line_space <> "||" <> left_text(rl, post_line),
      pre_line_space <> "\\/" <> post_line_space
    ]
  end

  def cell_ascii(%{type: :split_start, top_label: tl}, {pre_line, post_line}) do
    right_gap_space = String.duplicate(" ", post_line - pre_line) # it should always be equal or greater
    pre_line_space = String.duplicate(" ", pre_line)
    post_line_space = String.duplicate(" ", post_line)
    [
      center_text(tl, pre_line*2+2) <> right_gap_space,
      pre_line_space <> "||" <> String.duplicate("=", post_line),
      pre_line_space <> "||" <> post_line_space,
      pre_line_space <> "\\/" <> post_line_space
    ]
  end

  def cell_ascii(%{type: :split_connector}, {pre_line, post_line}) do
    spaces_line = String.duplicate(" ", pre_line + 2 + post_line)
    horiz_line = String.duplicate("=", pre_line + 2 + post_line)
    [spaces_line,horiz_line,spaces_line,spaces_line]
  end

  def cell_ascii(%{type: :split_right, right_label: rl}, {pre_line, post_line}) do
    pre_line_space = String.duplicate(" ", pre_line)
    post_line_space = String.duplicate(" ", post_line)
    [
      String.duplicate(" ", pre_line + 2 + post_line),
      String.duplicate("=", pre_line) <> "=\\" <> post_line_space,
      pre_line_space <> "||" <> left_text(rl, post_line),
      pre_line_space <> "\\/" <> post_line_space
    ]
  end

  def cell_ascii(%{type: :end, top_label: tl}, {pre_line, post_line}) do
    right_gap_space = String.duplicate(" ", post_line - pre_line) # it should always be equal or greater
    spaces_line = String.duplicate(" ", pre_line + 2 + post_line)
    [
      center_text(tl, pre_line*2+2) <> right_gap_space,
      spaces_line, spaces_line, spaces_line
    ]
  end

  defp center_text(s, width) do
    left = div(width - String.length(s), 2)
    right = width - String.length(s) - left
    String.duplicate(" ", left) <> s <> String.duplicate(" ", right)
  end

  defp left_text(s, width) do
    " "
    <>
    s <>
    String.duplicate(" ", width - String.length(s) - 1)
  end
end
