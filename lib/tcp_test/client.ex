defmodule TcpTest.Client do
  require Logger

  use GenServer

  @intro_message "Welcome to budgetchat! What shall I call you?"

  def start_link(client_socket) do
    Logger.info("Client GenServer started #{inspect(client_socket)}...")
    GenServer.start_link(__MODULE__, client_socket)
  end

  ## Callbacks

  @impl true
  def init(socket) do
    write_response(socket, @intro_message)
    {:ok, %{socket: socket}}
  end

  @impl true
  def handle_cast({:send_response, message}, %{socket: socket} = state) do
    write_response(socket, message)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:shutdown, %{socket: socket} = state) do
    shutdown(socket)
    {:noreply, state}
  end

  def handle_info({:tcp, socket, packet}, state) do
    IO.inspect(packet, label: "incoming packet")
    GenServer.cast(TcpTest.Chat.Room, {:new_message, packet, self()})
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, state) do
    IO.inspect("Socket has been closed")
    shutdown(socket)
    {:noreply, state}
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    IO.inspect(socket, label: "connection closed due to #{reason}")
    shutdown(socket)
    {:noreply, state}
  end

  defp write_response(socket, message) do
    message_with_new_line =
      if String.ends_with?("message", "\n") do
        message
      else
        "#{message}\n"
      end

    Logger.info("Writing on #{inspect(socket)}: #{inspect(message_with_new_line)}")
    :gen_tcp.send(socket, message_with_new_line)
  end

  defp shutdown(socket) do
    Logger.info("Shutting down: #{inspect(socket)}")
    :gen_tcp.shutdown(socket, :write)
    GenServer.cast(TcpTest.Chat.Room, {:leave, self()})
  end
end
