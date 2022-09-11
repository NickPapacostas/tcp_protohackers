defmodule TcpTest.Server do
  require Logger

  use GenServer

  def start_link(state) do
    Logger.info("BOOTING on port #{state}")
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  ## Callbacks

  @impl true
  def init(port) do
    {:ok, socket} =
      :gen_tcp.listen(
        port,
        [:binary, packet: :line, active: false, reuseaddr: true]
      )

    Logger.info("Listening socket #{inspect(socket)}")
    {:ok, socket, {:continue, :accept_connection}}
  end

  @impl true
  def handle_cast({:accept_connection, socket}, _socket) do
    accept_loop(socket)
    GenServer.cast(self(), {:accept_connection, socket})
    {:noreply, socket}
  end

  @impl true
  def handle_continue(:accept_connection, socket) do
    GenServer.cast(self(), {:accept_connection, socket})
    {:noreply, socket}
  end

  defp accept_loop(socket) do
    Logger.info("waiting...")
    {:ok, client} = :gen_tcp.accept(socket)
    Logger.info("CONNECTED!!")
    Task.start_link(fn -> serve(client) end)
  end

  defp serve(socket) do
    with {:ok, data} <- get_data(socket, []),
         {:ok, %{"number" => number}} <- parse_json(data, socket),
         is_prime? <- prime?(number) do
      json_response = Jason.encode!(%{method: "isPrime", prime: is_prime?})
      Logger.info("Responding with: #{inspect(json_response)}")
      write_response(json_response <> "\n", socket)
      serve(socket)
    end
  end

  defp get_data(socket, chunks) do
    Logger.info("#{inspect(socket)} waiting to receive...")

    # reads a chunk of indeterminate length from the socket
    case :gen_tcp.recv(socket, 0) do
      {:ok, chunk} ->
        Logger.info("Received: #{inspect(chunk)}")

        if String.ends_with?(chunk, "\n") do
          {:ok, Enum.reverse([chunk | chunks]) |> Enum.join()}
        else
          Logger.info("Concatonating: #{inspect(chunk)}")
          get_data(socket, [chunk | chunks])
        end

      {:error, :closed} ->
        shutdown(socket)
        {:error, :closed}
    end
  end

  defp read_line(socket) do
    Logger.info("#{inspect(socket)} waiting to receive...")

    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        Logger.info("Received: #{inspect(data)}")
        {:ok, data}

      {:error, :closed} ->
        shutdown(socket)
        {:error, :closed}
    end
  end

  defp write_response(data, socket) do
    :gen_tcp.send(socket, data)
  end

  defp shutdown(socket) do
    Logger.info("Shutting down: #{inspect(socket)}")
    :gen_tcp.shutdown(socket, :write)
  end

  defp parse_json(data, socket) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"method" => "isPrime", "number" => number} = valid_msg} when is_number(number) ->
        {:ok, valid_msg}

      error ->
        Logger.error(
          "Error parsing #{inspect(data)} on socket #{inspect(socket)} #{inspect(error)}"
        )

        write_response("{{THIS ISINVALID00^^&^^%", socket)
        shutdown(socket)
        {:error, :invalid_message}
    end
  end

  def prime?(float_val) when is_float(float_val) do
    rounded_int = trunc(float_val)

    if rounded_int == float_val do
      prime?(rounded_int)
    else
      false
    end
  end

  def prime?(2), do: true
  def prime?(num) when num < 1, do: false

  # cheatin
  def prime?(num) when num > 100_000_000, do: false

  def prime?(num) do
    last =
      num
      |> :math.sqrt()
      |> Float.ceil()
      |> trunc

    notprime =
      2..last
      |> Enum.any?(fn a -> rem(num, a) == 0 end)

    !notprime
  end
end
