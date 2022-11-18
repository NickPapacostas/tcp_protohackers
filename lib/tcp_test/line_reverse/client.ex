defmodule TcpTest.LineReverse.Client do
  require Logger

  use GenServer

  def start_link(socket, session_id, address, port) do
    Logger.info("LineReverse Client started #{session_id}...")
    GenServer.start_link(__MODULE__, [socket, session_id, address, port])
  end

  ## Callbacks

  @impl true
  def init([socket, session_id, address, port]) do
    GenServer.cast(self(), :connect_attempt)
    Process.send_after(self(), :check_timeout, 60_000)

    {:ok,
     %{
       socket: socket,
       session_id: session_id,
       address: address,
       port: port,
       total_bytes: 0,
       payload: "",
       acknowledged_bytes: %{},
       last_message_receieved_at: nil,
       sent_messages: []
     }}
  end

  @impl true
  def handle_cast(:connect_attempt, state) do
    reply(state, "/ack/#{state.session_id}/0/")
    {:noreply, %{state | last_message_receieved_at: NaiveDateTime.utc_now()}}
  end

  @impl true
  def handle_info(:check_timeout, state) do
    case state.last_message_receieved_at do
      nil ->
        Process.send_after(self(), :check_timeout, 20_000)
        {:noreply, state}

      last_message_receieved_at ->
        a_minute_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second)

        if NaiveDateTime.compare(last_message_receieved_at, a_minute_ago) == :lt do
          Logger.info("Client timed out #{state.session_id}")
          close_session(state)
        else
          Process.send_after(self(), :check_timeout, 20_000)
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:process_message, message}, state) do
    process_message(message, state)
  end

  @impl true
  def handle_info(
        {:check_and_retransmit, byte_count, message},
        %{acknowledged_bytes: acknowledged_bytes} = state
      ) do
    case Map.get(acknowledged_bytes, byte_count) do
      nil ->
        Logger.info(
          "No ack received for client #{state.session_id} byte #{byte_count} message: #{inspect(message)}"
        )

        reply(state, message, true)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  defp process_message(
         data,
         %{
           session_id: session_id,
           total_bytes: total_bytes,
           payload: payload,
           sent_replies: sent_replies
         } = state
       ) do
    case String.split(data, "/") do
      ["", "connect", _session_id, ""] ->
        GenServer.cast(self(), :connect_attempt)
        {:noreply, state}

      ["", "data", ^session_id, pos, data, ""] ->
        handle_data(pos, data, state)

      ["", "ack", session_id, length, ""] ->
        Logger.info(
          "Client #{session_id} received ack length #{length} current total_bytes #{total_bytes}"
        )
        handle_ack(length, state)

      ["", "close", _session_id, ""] ->
        close_session(state)

      invalid_message ->
        Logger.info("Client #{session_id} received invalid message #{inspect(invalid_message)}")
        close_session(state)
    end
  end

  defp handle_data(pos, data, state) do
    {position, ""} = Integer.parse(pos)

    if total_bytes == position do
      new_total_bytes = total_bytes + byte_size(data)
      state = %{state | total_bytes: new_total_bytes}
      reply(state, "/ack/#{session_id}/#{new_total_bytes}/")

      # Check if it ends in a new line, else save the last
      # bit for further processing
      {sent_replies, unfinished_line} = case Enum.reverse(String.split(data, "\n")) do
          ["" | _] = lines ->
            {generate_and_send_replies(lines), nil}
          [unfinished_line | lines] ->
            {generate_and_send_replies(lines), unfinished_line}              
        end

      updated_state = %{
        state
        | total_bytes: new_total_bytes,
          sent_replies: sent_replies
          payload: payload <> Enum.join(sent_replies, ""),
          last_message_receieved_at: NaiveDateTime.utc_now()
      }

      {:noreply, updated_state}
    else
      Logger.warning(
        "Client #{session_id} received data for pos #{pos} when total byte_size #{total_bytes}"
      )

      reply(state, "/ack/#{session_id}/#{total_bytes}/")
      {:noreply, state}
    end
  end

  defp generate_and_send_replies(lines) do
    lines
    |> Enum.map(fn
      "" ->
        nil

      line ->
        reversed =
          line
          |> unescape
          |> String.reverse()
          |> escape
          |> Kernel.<>("\n")

        reply(state, "/data/#{session_id}/#{reversed}/", true)
        Logger.info("client reversed #{inspect(line)} to #{inspect(reversed)}")
        reversed
    end)
    |> Enum.reject(&is_nil/1)
  end

  def unescape(line) do
    String.replace(line, <<92>> <> <<42>>, <<42>>)
    |> String.replace(<<92>> <> <<92>>, <<92>>)
  end

  def escape(line) do
    String.replace(line, <<92>>, <<92>> <> <<92>>)
    |> String.replace(<<42>>, <<92>> <> <<42>>)
  end

  defp handle_ack(length_str, %{total_bytes: total_bytes} = state) do
    {length_int, ""} = Integer.parse(length_str)

    case {length_int, total_bytes} do
      {l, tb} when l == tb ->
        {:noreply,
         %{
           state
           | last_message_receieved_at: NaiveDateTime.utc_now(),
             acknowledged_bytes: Map.put(state.acknowledged_bytes, length_int, true)
         }}

      {l, tb} when l < tb ->
        reply(state, "/data/#{session_id}/#{payload}/")

        {:noreply,
         %{
           state
           | last_message_receieved_at: NaiveDateTime.utc_now(),
             acknowledged_bytes: Map.put(state.acknowledged_bytes, length_int, true)
         }}

      {l, tb} when l > tb ->
        close_session(state)
    end
  end

  defp close_session(state) do
    Logger.info("Closing session #{state.session_id}...")
    reply(state, "/close/#{state.session_id}/")
    TcpTest.LineReverse.ClientSupervisor.close(self(), state.address, state.port)
    {:noreply, state}
  end

  defp reply(
         %{
           socket: socket,
           address: address,
           port: port,
           total_bytes: total_bytes
         },
         data,
         retransmit \\ false
       ) do
    Logger.info(
      "Replying to #{inspect(socket)} #{inspect(address)} #{inspect(port)}: #{inspect(data)}"
    )

    :gen_udp.send(socket, address, port, data)

    if retransmit do
      Process.send_after(self(), {:check_and_retransmit, total_bytes, data}, 3_000)
    end
  end
end
