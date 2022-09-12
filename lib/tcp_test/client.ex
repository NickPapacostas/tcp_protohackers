defmodule TcpTest.Client do
  # should be supervised >.<

  require Logger

  use GenServer

  @insert_command_char 73
  @query_command_char 81
  @valid_command_chars [@insert_command_char, @query_command_char]

  def start_link(client_socket) do
    Logger.info("Client GenServer started #{inspect(client_socket)}...")
    res = GenServer.start_link(__MODULE__, client_socket)
    Logger.info("RES #{inspect(res)}")
    res
  end

  ## Callbacks

  @impl true
  def init(socket) do
    ets_table_name = Port.info(socket)[:id] |> Integer.to_string() |> String.to_atom()

    Logger.info("creating table #{ets_table_name}")

    table = :ets.new(ets_table_name, [:public, :named_table])
    Logger.info("Created table #{ets_table_name}: #{inspect(table)}")
    {:ok, %{socket: socket, ets_table: table}, {:continue, :process_message}}
  end

  @impl true
  def handle_continue(:process_message, state) do
    process_message(state)
    GenServer.cast(self(), :process_message)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:process_message, state) do
    process_message(state)
    {:noreply, state}
  end

  defp process_message(%{socket: socket, ets_table: table}) do
    with {:ok, data} <- read_command(socket),
         {:ok, {command, first_arg, second_arg}} <- parse_command(data, socket) do
      case command do
        @insert_command_char ->
          Logger.info("Inserting #{inspect(first_arg)}, #{inspect(second_arg)}")
          insert(table, first_arg, second_arg)

        @query_command_char ->
          average = query_average(table, first_arg, second_arg)
          average_as_int32 = <<average::integer-signed-32>>

          Logger.info(
            "Responding with: #{inspect(average)} as bytes #{inspect(average_as_int32)}"
          )

          write_response(average_as_int32, socket)
      end

      GenServer.cast(self(), :process_message)
    end
  end

  defp insert(table, unix_time, price) do
    :ets.insert(table, {unix_time, price})
  end

  def query_average(table, start_time, end_time) do
    # Failed with bad arg something about parse transform :shrug
    # fun = :ets.fun2ms(fn {time, price} when time >= start_time and time <= end_time -> price end)
    # prices = :ets.select(table, fun)

    relevant_prices =
      :ets.tab2list(table)
      |> Enum.filter(fn {time, _price} -> time >= start_time and time <= end_time end)
      |> Enum.map(&elem(&1, 1))

    val =
      if relevant_prices == [] do
        0
      else
        trunc(Enum.sum(relevant_prices) / length(relevant_prices))
      end

    Logger.info("average! #{inspect(val)}")
    val
  end

  defp read_command(socket) do
    Logger.info("#{inspect(socket)} waiting to receive...")

    case :gen_tcp.recv(socket, 9) do
      {:ok, data} ->
        Logger.info("Received command: #{inspect(data)}")
        {:ok, data}

      {:error, :closed} ->
        shutdown(socket)
        {:error, :closed}

      unknown_request ->
        Logger.warning("Unknown response: #{inspect(unknown_request)}")
        shutdown(socket)
        {:error, :unknown_request}
    end
  end

  defp write_response(data, socket) do
    :gen_tcp.send(socket, data)
  end

  defp parse_command(data, socket) do
    case data do
      <<command, first_arg::integer-signed-32, second_arg::integer-signed-32>>
      when command in @valid_command_chars ->
        Logger.info(
          "Parsed values: #{inspect(command)} #{inspect(first_arg)} #{inspect(second_arg)} on socket #{inspect(socket)}"
        )

        {:ok, {command, first_arg, second_arg}}

      _ ->
        Logger.error("Match failure: #{inspect(data)} on socket #{inspect(socket)}")

        shutdown(socket)
        {:error, :invalid_message}
    end
  end

  defp shutdown(socket) do
    Logger.info("Shutting down: #{inspect(socket)}")
    :gen_tcp.shutdown(socket, :write)
  end
end
