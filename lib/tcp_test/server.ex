defmodule TcpTest.Server do
  require Logger

  use GenServer

  def start_link(listening_port) do
    Logger.info("BOOTING on port #{listening_port}")
    GenServer.start_link(__MODULE__, listening_port, name: __MODULE__)
  end

  ## Callbacks

  @impl true
  def init(port) do
    {:ok, socket} =
      :gen_tcp.listen(
        port,
        [:binary, packet: :line, active: true, reuseaddr: true]
      )

    Logger.info("Listening socket #{inspect(socket)}")
    {:ok, socket, {:continue, :accept_connection}}
  end

  @impl true
  def handle_continue(:accept_connection, socket) do
    GenServer.cast(self(), :accept_connection)
    {:noreply, socket}
  end

  @impl true
  def handle_cast(:accept_connection, socket) do
    accept_connection(socket)
    GenServer.cast(self(), :accept_connection)
    {:noreply, socket}
  end

  defp accept_connection(socket) do
    Logger.info("waiting...")
    {:ok, client_socket} = :gen_tcp.accept(socket)

    Logger.info("Connected to #{inspect(client_socket)}")
    {:ok, client_handler_pid} = TcpTest.ClientSupervisor.start_child(client_socket)
  end
end
