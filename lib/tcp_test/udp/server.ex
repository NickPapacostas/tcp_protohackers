defmodule TcpTest.Udp.Server do
  require Logger

  use GenServer

  def start_link(listening_port) do
    IO.inspect("init!")

    GenServer.start_link(__MODULE__, listening_port, name: __MODULE__)
  end

  ## Callbacks

  @impl true
  def init(port) do
    res = :gen_udp.open(port, [:binary, active: false])

    IO.inspect("RES")
    IO.inspect(res)
    {:ok, socket} = res
    Logger.info("Listening socket #{inspect(socket)}")
    {:ok, %{socket: socket, store: %{}}, {:continue, :listen_and_reply}}
  end

  @impl true
  def handle_continue(:listen_and_reply, state) do
    GenServer.cast(self(), :listen_and_reply)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:listen_and_reply, %{socket: socket, store: store}) do
    updated_state = listen_and_reply(socket, store)
    GenServer.cast(self(), :listen_and_reply)
    {:noreply, updated_state}
  end

  defp listen_and_reply(socket, store) do
    Logger.info("waiting...")

    case :gen_udp.recv(socket, 0) do
      {:ok, response} ->
        Logger.info("Received: #{inspect(response)}")
        updated_store = process_message(socket, response, store)
        %{socket: socket, store: updated_store}

      error ->
        Logger.error("Error receiving: #{inspect(error)}")
        %{socket: socket, store: store}
    end
  end

  defp process_message(socket, {address, port, data}, store) do
    case String.split(data, "=") do
      ["version" | _] ->
        reply(socket, address, port, "version=NickyP")
        store

      [key] ->
        reply(socket, address, port, "#{key}=#{Map.get(store, key, "")}")
        store

      [key | rest] ->
        Map.put(store, key, Enum.join(rest, "="))
    end
  end

  defp reply(socket, address, port, data) do
    Logger.info(
      "Replying to #{inspect(socket)} #{inspect(address)} #{inspect(port)}: #{inspect(data)}"
    )

    :gen_udp.send(socket, address, port, data)
  end
end
