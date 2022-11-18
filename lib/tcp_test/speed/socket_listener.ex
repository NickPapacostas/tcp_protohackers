defmodule TcpTest.Speed.SocketListener do
  require Logger

  use GenServer

  def start_link(listening_port) do
    Logger.info("SocketListener starting on port #{listening_port}")
    GenServer.start_link(__MODULE__, listening_port, name: __MODULE__)
  end

  ## Callbacks

  @impl true
  def init(port) do
    {:ok, socket} =
      :gen_tcp.listen(
        port,
        [:binary, packet: :raw, active: true, reuseaddr: true]
      )

    Logger.info("SocketListener init on #{inspect(socket)}")
    {:ok, %{listening_socket: socket}, {:continue, :accept_connection}}
  end

  @impl true
  def handle_continue(:accept_connection, state) do
    GenServer.cast(self(), :accept_connection)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:accept_connection, %{listening_socket: socket}) do
    accept_connection(socket)
    GenServer.cast(self(), :accept_connection)
    {:noreply, %{listening_socket: socket}}
  end

  defp accept_connection(socket) do
    Logger.info("waiting...")
    {:ok, client_socket} = :gen_tcp.accept(socket)

    Logger.info("Connected to #{inspect(client_socket)}")
    {:ok, pid} = TcpTest.Speed.ClientSupervisor.start_child(client_socket)
    :gen_tcp.controlling_process(client_socket, pid)
  end

  defp shutdown(socket) do
    Logger.info("Shutting down: #{inspect(socket)}")
    # "error code, 3, 'bad'"
    :gen_tcp.send(socket, <<0x10::8, 0x03::8, 98::8, 97::8, 100::8>>)
    :gen_tcp.shutdown(socket, :write)
    GenServer.stop(self())
  end
end
