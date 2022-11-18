defmodule TcpTest.Speed.PendingServer do
  require Logger

  use GenServer

  def start(client_socket) do
    Logger.info("Pending server GenServer started #{inspect(client_socket)}...")
    GenServer.start(__MODULE__, client_socket)
  end

  ## Callbacks

  @impl true
  def init(socket) do
    {:ok, socket}
  end

  def handle_info({:tcp, socket, packet}, state) do
    Logger.info("PendingServer incoming packet for #{inspect(socket)}: #{inspect(packet)}")

    case parse_intro_message(packet) do
      :camera ->
        Logger.info("PendingServer camera connected")

        {:ok, _camera_handler_pid} = TcpTest.Speed.CameraSupervisor.start_child(socket, packet)

      :dispatcher ->
        Logger.info("PendingServer dispatcher connected")

        {:ok, _dispatcher_handler_pid} =
          TcpTest.Speed.DispatcherSupervisor.start_child(socket, packet)
    end

    shutdown()
  end

  def handle_info({:tcp_closed, socket}, state) do
    IO.inspect("Socket has been closed")
    shutdown()
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    IO.inspect(socket, label: "connection closed due to #{reason}")
    shutdown()
  end

  defp parse_message(invalid_message) do
    Logger.info("Pending server received invalid message #{inspect(invalid_message)}")

    {:error, :invalid_message}
  end

  defp shutdown() do
    Logger.info("Shutting down Pending server: #{inspect(self())}")
    {:stop, :normal, nil}
  end

  defp parse_intro_message(<<0x80::8, _rest::binary>>), do: :camera
  defp parse_intro_message(<<0x81::8, _rest::binary>>), do: :dispatcher
end
