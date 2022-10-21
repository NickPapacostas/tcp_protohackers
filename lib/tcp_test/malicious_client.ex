defmodule TcpTest.MaliciousClient do
  require Logger

  use GenServer

  def start_link(client_socket) do
    Logger.info("Client GenServer started #{inspect(client_socket)}...")
    GenServer.start_link(__MODULE__, client_socket)
  end

  ## Callbacks

  @ip {206, 189, 113, 124}
  @port 16963
  @tonys_address "7YWHMfk9JZe0LM0g1ZauHuiSxhI"

  @impl true
  def init(client_socket) do
    {:ok, upstream_socket} =
      :gen_tcp.connect({206, 189, 113, 124}, 16963, [
        :binary,
        packet: :line,
        active: true
      ])

    {:ok, %{client_socket: client_socket, upstream_socket: upstream_socket}}
  end

  @impl true
  def handle_cast(
        :shutdown,
        %{client_socket: client_socket, upstream_socket: upstream_socket} = state
      ) do
    shutdown(client_socket)
    shutdown(upstream_socket)
    {:noreply, state}
  end

  def handle_info(
        {:tcp, upstream_socket, packet},
        %{
          client_socket: client_socket,
          upstream_socket: upstream_socket
        } = state
      ) do
    write(client_socket, replace_address(packet))
    {:noreply, state}
  end

  def handle_info(
        {:tcp, client_socket, packet},
        %{
          client_socket: client_socket,
          upstream_socket: upstream_socket
        } = state
      ) do
    write(upstream_socket, replace_address(packet))
    {:noreply, state}
  end

  def handle_info(
        {:tcp_closed, client_socket},
        %{
          client_socket: client_socket,
          upstream_socket: upstream_socket
        } = state
      ) do
    shutdown(upstream_socket)
    {:noreply, state}
  end

  def handle_info(
        {:tcp_closed, upstream_socket},
        %{
          client_socket: client_socket,
          upstream_socket: upstream_socket
        } = state
      ) do
    shutdown(client_socket)
    {:noreply, state}
  end

  def handle_info(
        {:tcp_error, socket, reason},
        %{
          client_socket: client_socket,
          upstream_socket: upstream_socket
        } = state
      ) do
    shutdown(socket)
    {:noreply, state}
  end

  defp write(socket, packet) do
    Logger.info("Writing on #{inspect(socket)}: #{inspect(packet)}")
    :gen_tcp.send(socket, packet)
  end

  defp shutdown(socket) do
    Logger.info("Shutting down: #{inspect(socket)}")
    :gen_tcp.shutdown(socket, :write)
  end

  defp replace_address(packet) do
    Regex.replace(~r/(^|\s)(7[a-zA-Z0-9]{25,35})(?=$|\s)/, packet, fn _match,
                                                                      start,
                                                                      address,
                                                                      ending ->
      Logger.info("Replacing #{address} with tonys")
      "#{start}#{@tonys_address}#{ending}"
    end)
  end
end
