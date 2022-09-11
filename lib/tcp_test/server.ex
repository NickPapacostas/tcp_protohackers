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
    case read_line(socket) do
      {:ok, data} ->
        write_line(data, socket)
        serve(socket)

      error ->
        :gen_tcp.close(socket)
    end
  end

  defp read_line(socket) do
    Logger.info("#{inspect(socket)} waiting to receive...")

    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        Logger.info("Received: #{inspect(data)}")
        {:ok, data}

      error ->
        Logger.error("Error reading line: #{inspect(error)}")
        error
    end
  end

  defp write_line(line, socket) do
    :gen_tcp.send(socket, line)
  end
end
