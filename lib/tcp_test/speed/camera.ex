defmodule TcpTest.Speed.Camera do
  require Logger

  use GenServer

  def start_link(client_socket, inital_message) do
    Logger.info("Camera GenServer started #{inspect(client_socket)}...")
    GenServer.start_link(__MODULE__, [client_socket, inital_message])
  end

  ## Callbacks

  @impl true
  def init([socket, initial_message]) do
    case parse_message(initial_message, :initial) do
      {:init, road, mile, limit} ->
        TcpTest.Speed.RoadSupervisor.register(road)
        {:ok, %{socket: socket, road: road, mile: mile, limit: limit}}

      _ ->
        shutdown(socket)
    end
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
    IO.inspect(packet, label: "Camera incoming packet")
    parse_message(packet, state)
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

  # init
  defp parse_message(<<0x80::8, road::16, mile::16, limit::16>>, :initial) do
    Logger.info(
      "Camera received intro message with " <>
        "road: #{inspect(road)}, mile: #{inspect(mile)}, limit: #{inspect(limit)}"
    )

    {:init, road, mile, limit}
  end

  # plate message
  defp parse_message(
         <<0x20::8, remaining_data::binary>>,
         %{
           road: road,
           mile: mile,
           limit: limit
         } = state
       ) do
    <<str_length::8, rest::binary>> = remaining_data

    {timestamp_and_rest, plate} =
      Enum.reduce(1..str_length, {rest, ""}, fn _, {data, acc} ->
        <<character::binary-size(1), rest::binary>> = data
        {rest, acc <> character}
      end)

    <<timestamp::32, next_message::binary>> = timestamp_and_rest
    IO.inspect("PLATe #{inspect(plate)}")
    IO.inspect("tsta #{inspect(timestamp)}")

    Logger.info(
      "Camera registing observation " <>
        "road: #{inspect(road)}, plate: #{inspect(plate)}, timestamp: #{inspect(timestamp)}"
    )

    TcpTest.Speed.Road.register_observation(road, mile, limit, plate, timestamp)

    IO.inspect("next! #{inspect(next_message)}")

    if next_message != "" do
      parse_message(next_message, state)
    else
      :ok
    end
  end

  defp parse_message(invalid_message, state) do
    Logger.info(
      "Camera received invalid message #{inspect(invalid_message)} state : #{inspect(state)}"
    )

    {:error, :invalid_message}
  end

  defp shutdown(socket) do
    Logger.info("Shutting down: #{inspect(socket)}")
    # "error code, 3, 'bad'"
    :gen_tcp.send(socket, <<0x10::8, 0x03::8, 98::8, 97::8, 100::8>>)
    :gen_tcp.shutdown(socket, :write)
    GenServer.stop(self())
  end
end
