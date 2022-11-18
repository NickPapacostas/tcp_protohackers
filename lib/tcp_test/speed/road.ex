defmodule TcpTest.Speed.Road do
  require Logger

  use GenServer

  @dispatched_tickets_table :dispatched_tickets

  def start_link(road_number) do
    Logger.info("Road server starting for road #{road_number}")

    GenServer.start_link(__MODULE__, road_number, name: :"#{road_number}")
  end

  def register_observation(road, mile, limit, plate, timestamp) do
    case Process.whereis(:"#{road}") do
      nil ->
        Logger.error("Road server not found for #{road} observed mile #{mile}")
        {:error, :server_not_found}

      pid ->
        GenServer.cast(pid, {:register_observation, road, mile, limit, plate, timestamp})
    end
  end

  ## Callbacks

  @impl true
  def init(road_number) do
    Logger.info("Road #{inspect(road_number)} started...")

    Process.send_after(self(), :process_pending_tickets, 1000)

    {:ok,
     %{
       number: road_number,
       observations_by_plate: %{},
       pending_tickets: []
     }}
  end

  def handle_cast(
        {:register_observation, road, mile, limit, plate, timestamp},
        %{observations_by_plate: observations_by_plate} = state
      ) do
    updated_observations =
      observations_by_plate
      |> Map.get(plate, %{})
      |> Map.put(mile, timestamp)
      |> then(fn plate_observations ->
        Map.put(observations_by_plate, plate, plate_observations)
      end)

    state = add_pending_tickets(state, plate, Map.get(updated_observations, plate), limit)
    state = %{state | observations_by_plate: updated_observations}

    {:noreply, state}
  end

  def handle_info(
        :process_pending_tickets,
        %{number: road_number, pending_tickets: pending_tickets} = state
      ) do
    # Logger.info("Road #{road_number} process_pending_tickets #{inspect(pending_tickets)}")
    if pending_tickets != [] do
      case :pg.get_members("dispatcher:#{road_number}") do
        [] ->
          Process.send_after(self(), :process_pending_tickets, 100)
          {:noreply, state}

        [dispatcher | _] ->
          Logger.info(
            "Road #{road_number}: Dispatcher #{inspect(dispatcher)} found, sending pending_tickets #{inspect(pending_tickets)}"
          )

          {tickets_to_process, still_pending} = pending_tickets |> Enum.split(100)

          dispatch_tickets(dispatcher, tickets_to_process, state)

          Process.send_after(self(), :process_pending_tickets, 100)
          {:noreply, %{state | pending_tickets: still_pending}}
      end
    else
      # yuck
      Process.send_after(self(), :process_pending_tickets, 100)
      {:noreply, state}
    end
  end

  defp dispatch_tickets(
         dispatcher,
         tickets,
         %{number: road_number} = state
       ) do
    potential_new_tickets_by_plate =
      Enum.map(tickets, fn ticket_params ->
        {plate, first_mile, first_timestamp, second_mile, second_timestamp, speed} = ticket_params
        unix_days = unix_days_for_timerange(first_timestamp, second_timestamp)
        formatted_speed = trunc(speed * 100)
        plate_length = String.length(plate)

        ticket_message =
          <<0x21::8, plate_length::8, plate::binary-size(plate_length), road_number::16,
            first_mile::16, first_timestamp::32, second_mile::16, second_timestamp::32,
            formatted_speed::16>>

        {plate, unix_days, ticket_message, ticket_params}
      end)

    dispatch_socket = TcpTest.Speed.Client.get_socket(dispatcher)

    # |> Enum.uniq_by(fn {plate, [first_day | _], _, _} -> first_day end)
    potential_new_tickets_by_plate
    |> Enum.map(fn {plate, unix_days, ticket_message, ticket_params} ->
      first_day = List.first(unix_days)

      case Enum.flat_map(unix_days, fn day ->
             :ets.lookup(@dispatched_tickets_table, {plate, day})
           end) do
        [already_ticketed | _] ->
          Logger.info(
            "Road not dispatching ticket due to ets record plate: #{inspect(plate)} days: #{inspect(unix_days)} #{inspect(ticket_params)}"
          )

        [] ->
          if :ets.insert_new(@dispatched_tickets_table, {{plate, first_day}}) do
            Logger.info(
              "Sending ticket plate #{plate} for day #{inspect(first_day)} marking: #{inspect(unix_days)} #{inspect(ticket_params)}"
            )

            Enum.map(unix_days, fn day ->
              :ets.insert(@dispatched_tickets_table, {{plate, day}})
            end)

            case :gen_tcp.send(dispatch_socket, ticket_message) do
              :ok ->
                :ok

              error ->
                Logger.error("Road error sending ticket #{error} #{inspect(ticket_params)}")
            end
          else
            Logger.info(
              "Road upable to insert_new date record plate: #{inspect(plate)} days: #{inspect(unix_days)} #{inspect(ticket_params)}"
            )
          end
      end
    end)
  end

  defp unix_days_for_timerange(start_time, end_time) do
    start_day = floor(start_time / 86400)
    end_day = floor(end_time / 86400)

    days =
      Stream.unfold(start_day, fn start ->
        if start <= end_day do
          {start, start + 86400}
        else
          nil
        end
      end)
      |> Enum.to_list()

    days ++ [end_day]
  end

  defp add_pending_tickets(
         %{
           number: road_number,
           pending_tickets: pending_tickets
         } = state,
         plate,
         plate_observations,
         limit
       ) do
    new_tickets =
      plate_observations
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Enum.map(fn {{first_mile, first_timestamp} = first, index} ->
        {_, remaining} = Enum.split(plate_observations, index)

        Enum.map(remaining, fn {second_mile, second_timestamp} = second ->
          [{earlier_mile, earlier_timestamp}, {later_mile, later_timestamp}] =
            Enum.sort_by([first, second], fn {_mile, timestamp} -> timestamp end)

          miles_travelled = abs(later_mile - earlier_mile)
          time_elapsed_in_hours = abs(later_timestamp - earlier_timestamp) / 3600

          speed = Float.round(miles_travelled / time_elapsed_in_hours, 1)

          if speed > limit do
            Logger.info(
              "Plate speeding #{inspect(plate)} #{inspect(road_number)} #{inspect(speed)} #{inspect(limit)} #{inspect(miles_travelled)} #{inspect(time_elapsed_in_hours)}"
            )

            {plate, earlier_mile, earlier_timestamp, later_mile, later_timestamp, speed}
          else
            Logger.info(
              "Plate NOT speeding #{inspect(plate)} #{inspect(road_number)} #{inspect(speed)} #{inspect(limit)} #{inspect(miles_travelled)} #{inspect(time_elapsed_in_hours)}"
            )

            nil
          end
        end)
        |> Enum.reject(&is_nil(&1))
      end)
      |> List.flatten()

    Logger.info(
      "New tickets for road #{inspect(road_number)} limit #{limit}: #{inspect(new_tickets)}"
    )

    %{state | pending_tickets: pending_tickets ++ new_tickets}
  end
end
