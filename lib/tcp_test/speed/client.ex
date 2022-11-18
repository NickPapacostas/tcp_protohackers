defmodule TcpTest.Speed.Client do
  require Logger

  use GenServer, restart: :transient

  def start_link(client_socket) do
    Logger.info("Client GenServer started #{inspect(client_socket)}...")
    GenServer.start_link(__MODULE__, client_socket)
  end

  def get_socket(pid) do
    GenServer.call(pid, :get_socket)
  end

  ## Callbacks

  @impl true
  def init(socket) do
    {:ok, %{socket: socket, type: :pending, heartbeat: false, currently_parsing: nil}}
  end

  def terminate(_, _) do
    :ok
  end

  def handle_call(:get_socket, from, %{socket: socket} = state) do
    {:reply, socket, state}
  end

  @impl true
  def handle_cast(:shutdown, %{socket: socket} = state) do
    shutdown(socket)
    {:noreply, state}
  end

  def handle_cast(:shutdown, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:send_heartbeat, interval}, %{socket: socket} = state) do
    :gen_tcp.send(socket, <<0x41::8>>)
    Process.send_after(self(), {:send_heartbeat, interval}, interval)
    {:noreply, %{state | heartbeat: true}}
  end

  def handle_info({:tcp, _socket, packet}, state) do
    new_state = parse_message(packet, state)
    {:noreply, new_state}
  end

  def handle_info({:tcp_closed, socket}, _state) do
    shutdown(socket)
  end

  def handle_info({:tcp_error, socket, _reason}, _state) do
    shutdown(socket)
  end

  # want heartbeat message
  defp parse_message(
         <<0x40::8, remaining_data::binary>> = message,
         %{socket: socket, heartbeat: false} = state
       ) do
    case remaining_data do
      <<interval::32, rest::binary>> ->
        if interval > 0 do
          Process.send(self(), {:send_heartbeat, interval * 100}, [])

          if String.length(rest) != 0 do
            parse_message(rest, %{state | heartbeat: true})
          else
            %{state | heartbeat: true}
          end
        else
          %{state | heartbeat: true}
        end

      _unfinished ->
        %{state | currently_parsing: message}
    end
  end

  # init
  defp parse_message(
         <<0x80::8, rest::binary>> = message,
         %{type: :pending, socket: socket} = state
       ) do
    case rest do
      <<road::16, mile::16, limit::16, next_message::binary>> ->
        Logger.info(
          "Camera received intro message with " <>
            "#{inspect(socket)} road: #{inspect(road)}, mile: #{inspect(mile)}, limit: #{inspect(limit)}"
        )

        TcpTest.Speed.RoadSupervisor.register(road)

        new_state =
          Map.merge(state, %{
            type: :camera,
            currently_parsing: nil,
            socket: socket,
            road: road,
            mile: mile,
            limit: limit
          })

        if String.length(next_message) != 0 do
          parse_message(next_message, new_state)
        else
          new_state
        end

      _unfinished ->
        %{state | currently_parsing: message}
    end
  end

  defp parse_message(
         <<0x81::8, data::binary>> = message,
         %{type: :pending, socket: socket} = state
       ) do
    case data do
      <<road_count::8, remaining_data::binary>> ->
        if String.length(remaining_data) < road_count do
          %{state | currently_parsing: message}
        else
          {rest, roads} =
            Enum.reduce(1..road_count, {remaining_data, []}, fn _, {data, acc} ->
              case data do
                <<road::16, rest::binary>> ->
                  TcpTest.Speed.RoadSupervisor.register(road)
                  :pg.join("dispatcher:#{road}", self())
                  {rest, acc ++ [road]}

                _ ->
                  {data, acc}
              end
            end)

          Logger.info(
            "Dispatcher received intro message with " <>
              "#{inspect(socket)} road_count: #{inspect(road_count)}"
          )

          new_state =
            Map.merge(state, %{
              currently_parsing: nil,
              type: :dispatcher,
              socket: socket,
              roads: roads
            })

          if String.length(rest) != 0 do
            parse_message(rest, new_state)
          else
            new_state
          end
        end

      _unfinished ->
        %{state | currently_parsing: message}
    end
  end

  # plate message
  defp parse_message(
         <<0x20::8, remaining_data::binary>> = message,
         %{
           type: :camera,
           road: road,
           mile: mile,
           limit: limit,
           socket: socket
         } = state
       ) do
    case remaining_data do
      <<str_length::8, rest::binary>> ->
        {timestamp_and_rest, plate} =
          Enum.reduce(1..str_length, {rest, ""}, fn _, {data, acc} ->
            <<character::binary-size(1), rest::binary>> = data
            {rest, acc <> character}
          end)

        case timestamp_and_rest do
          <<timestamp::32, next_message::binary>> ->
            Logger.info(
              "Camera #{inspect(socket)} registing observation " <>
                "road: #{inspect(road)}, mile: #{inspect(mile)}, plate: #{inspect(plate)}, timestamp: #{inspect(timestamp)}"
            )

            TcpTest.Speed.Road.register_observation(road, mile, limit, plate, timestamp)
            state = %{state | currently_parsing: nil}

            if String.length(next_message) != 0 do
              parse_message(next_message, state)
            else
              state
            end

          _unfinished ->
            %{state | currently_parsing: message}
        end

      _ ->
        %{state | currently_parsing: message}
    end
  end

  defp parse_message("", state) do
    Logger.info("Client received empty message")

    state
  end

  defp parse_message(next_packets, %{currently_parsing: currently_parsing} = state)
       when not is_nil(currently_parsing) do
    parse_message(currently_parsing <> next_packets, state)
  end

  defp parse_message(invalid_message, state) do
    Logger.info(
      "Client received invalid message #{inspect(invalid_message)} state : #{inspect(state)}"
    )

    IO.puts("#{inspect(String.length(invalid_message))}")
    shutdown(state.socket)
  end

  defp shutdown(socket) do
    Logger.info("Shutting down: #{inspect(socket)}")
    # "error code, 3, 'bad'"
    :gen_tcp.send(socket, <<0x10::8, 0x03::8, 98::8, 97::8, 100::8>>)
    :gen_tcp.shutdown(socket, :write)
    GenServer.cast(self(), :shutdown)
    {:noreply, :shutting_down}
  end
end
