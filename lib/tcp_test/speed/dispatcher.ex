defmodule TcpTest.Speed.Dispatcher do
  require Logger

  use GenServer

  def start_link(client_socket, inital_message) do
    Logger.info("Dispatcher GenServer started #{inspect(client_socket)}...")
    GenServer.start_link(__MODULE__, [client_socket, inital_message])
  end

  ## Callbacks

  @impl true
  def init([socket, initial_message]) do
    case parse_message(initial_message, :initial) do
      {:init, roads} ->
        Enum.each(roads, fn road ->
          <<road_int::16>> = road
          IO.inspect("road reg as #{road_int}")
          :pg.join("dispatcher:#{road_int}", self())
        end)

        {:ok, %{socket: socket, roads: roads, dispatched_tickets: %{}}}

      _ ->
        shutdown(socket)
    end
  end

  @impl true
  def handle_cast(
        {:dispatch_tickets, road, tickets},
        %{socket: socket, dispatched_tickets: dispatched_tickets} = state
      ) do
    new_dates_by_plate =
      Enum.map(tickets, fn ticket_params ->
        {plate, first_mile, first_timestamp, second_mile, second_timestamp, speed} = ticket_params
        unix_day = floor(second_timestamp / 86400)

        ticket_days_for_plate = Map.get(dispatched_tickets, plate, [])

        if unix_day in ticket_days_for_plate do
          nil
        else
          formatted_speed = trunc(speed * 100)
          plate_length = String.length(plate)

          IO.inspect("sending:")

          IO.inspect(
            <<plate::binary-size(plate_length), road::16, first_mile::16, first_timestamp::32,
              second_mile::16, second_timestamp::32, formatted_speed::16>>
          )

          :gen_tcp.send(
            socket,
            <<plate::binary-size(plate_length), road::16, first_mile::16, first_timestamp::32,
              second_mile::16, second_timestamp::32, formatted_speed::16>>
          )

          {plate, unix_day}
        end
      end)
      |> Enum.reject(&is_nil(&1))

    new_dispatched =
      Enum.reduce(new_dates_by_plate, dispatched_tickets, fn {plate, day}, dispatched_map ->
        previous = Map.get(dispatched_map, plate, [])
        Map.put(dispatched_map, plate, previous ++ [day])
      end)

    {:noreply, %{state | dispatched_tickets: new_dispatched}}
  end

  @impl true
  def handle_cast(:shutdown, %{socket: socket} = state) do
    shutdown(socket)
    {:noreply, state}
  end

  def handle_info({:tcp, socket, packet}, state) do
    IO.inspect(packet, label: "Dispatcher incoming packet")
    parse_message(packet)
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
  defp parse_message(<<0x81::8, road_count::8, remaining_data::binary>>, :initial) do
    Logger.info(
      "Dispatcher received intro message with " <>
        "road_count: #{inspect(road_count)}"
    )

    {rest, roads} =
      Enum.reduce(1..road_count, {remaining_data, []}, fn _, {data, acc} ->
        <<road::binary-size(2), rest::binary>> = data
        {rest, acc ++ [road]}
      end)

    if rest && rest != "" do
      parse_message(rest)
      {:init, roads}
    else
      {:init, roads}
    end
  end

  defp parse_message(invalid_message) do
    Logger.info("Dispatcher received invalid message #{inspect(invalid_message)}")

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
