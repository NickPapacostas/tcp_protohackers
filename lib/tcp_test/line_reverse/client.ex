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
       acknowledged_bytes: %{},
       unfinished_line: {nil, nil},
       last_message_receieved_at: nil,
       sent_replies: %{},
       retries: %{},
       data_received: %{}
     }}
  end

  @impl true
  def handle_cast(:connect_attempt, state) do
    reply(state, "/ack/#{state.session_id}/0/")
    {:noreply, %{state | last_message_receieved_at: NaiveDateTime.utc_now()}}
  end

  @impl true
  def handle_cast({:process_message, message}, state) do
    process_message(message, state)
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
  def handle_info(
        {:check_and_retransmit, start_byte, message},
        %{acknowledged_bytes: acknowledged_bytes, retries: retries} = state
      ) do
    max_acked =
      case Map.keys(acknowledged_bytes) do
        [] -> 0
        bytes -> Enum.max(bytes)
      end

    Logger.info("RETRANSMIT: start byte: #{start_byte} max_acked: #{max_acked} data: #{message}")

    ["", "data", _session_id, _pos, data, ""] = String.split(message, "/")

    if max_acked == 0 || max_acked < start_byte + byte_size(data) do
      previous_count = Map.get(retries, start_byte, 0)
      state = %{state | retries: Map.put(retries, start_byte, previous_count + 1)}

      Logger.info(
        "Client #{state.session_id} retrying #{start_byte}, count: #{previous_count + 1} max acked #{max_acked}"
      )

      if previous_count + 1 > 30 do
        close_session(state)
      else
        reply(state, message, start_byte)
        {:noreply, state}
      end
    else
      {:noreply, %{state | retries: Map.put(retries, start_byte, 0)}}
    end
  end

  defp process_message(
         data,
         %{
           session_id: session_id,
           total_bytes: total_bytes
         } = state
       ) do
    case String.split(data, "/") do
      ["", "connect", _session_id, ""] ->
        GenServer.cast(self(), :connect_attempt)
        {:noreply, state}

      ["", "data", _session_id, pos, data, ""] ->
        Logger.info("Client #{session_id} raw receieved: #{inspect(data <> <<0>>)}")
        handle_data(pos, data, state)

      ["", "ack", session_id, length, ""] ->
        Logger.info(
          "Client #{session_id} received ack length #{length} current total_bytes #{total_bytes}"
        )

        handle_ack(length, state)

      ["", "close", ^session_id, ""] ->
        close_session(state)

      invalid_message ->
        Logger.warning(
          "Client #{session_id} received invalid message #{inspect(invalid_message)}"
        )

        {:noreply, state}
    end
  end

  defp handle_data(
         position_str,
         data,
         %{
           session_id: session_id,
           total_bytes: total_bytes,
           sent_replies: sent_replies,
           data_received: data_received
         } = state
       ) do
    {position, ""} = Integer.parse(position_str)

    if position <= total_bytes do
      existing_data_for_position = Map.get(data_received, position)

      case {existing_data_for_position, data} do
        {nil, _} ->
          state = %{state | data_received: Map.put(data_received, position, data)}
          send_and_store_replies(total_bytes, data, state)

        {e, d} when e == d ->
          reply(state, "/ack/#{session_id}/#{total_bytes}/")
          {:noreply, state}

        {existing_payload, different_data} ->
          {last_data_start, _last_data_payload} =
            data_received
            |> Enum.sort()
            |> List.last()

          if position == last_data_start do
            if byte_size(existing_payload) < byte_size(different_data) do
              state = %{
                state
                | data_received: Map.put(data_received, position, data),
                  unfinished_line: {nil, nil},
                  total_bytes: position
              }

              Logger.warning(
                "Client #{session_id} OVERWRITING LAST MESSAGE #{inspect(existing_payload)} WITH #{inspect(different_data)}" <>
                  "setting state to: #{inspect(state)}"
              )

              send_and_store_replies(last_data_start, data, state)
            end
          else
            Logger.warning(
              "Client #{session_id} IGNORING shorter message for position #{position} #{inspect(existing_payload)} #{inspect(different_data)}"
            )

            {:noreply, state}
          end
      end
    else
      Logger.warning(
        "Client #{session_id} received data for pos #{position_str} when total byte_size #{total_bytes}"
      )

      {:noreply, state}
    end
  end

  defp send_and_store_replies(
         total_bytes,
         data,
         %{
           session_id: session_id,
           unfinished_line: unfinished_line,
           sent_replies: sent_replies
         } = state
       ) do
    new_total_bytes = total_bytes + byte_size(unescape(data))
    state = %{state | total_bytes: new_total_bytes}
    reply(state, "/ack/#{session_id}/#{new_total_bytes}/")

    {start_byte, data} =
      case unfinished_line do
        {nil, nil} -> {total_bytes, data}
        {unfinished_start_byte, unfinished} -> {unfinished_start_byte, unfinished <> data}
      end

    # if start of unfinished line
    # start byte is new_total_bytes - unfinished
    # if all unfinished
    # start byte is either total bytes, or start_byte of previously started
    # when sending, 

    # Check if it ends in a new line, else save the last
    # bit for further processing
    {newly_sent_reply, unfinished_start_byte_and_line} =
      case Enum.reverse(String.split(data, "\n")) do
        ["" | _] = lines ->
          reply = generate_and_send_reply(Enum.reverse(lines), start_byte, state)
          {reply, {nil, nil}}

        [unfinished_line] ->
          {nil, {start_byte, unfinished_line}}

        [unfinished_line | lines] ->
          reply = generate_and_send_reply(Enum.reverse(lines), start_byte, state)
          {reply, {start_byte + byte_size(reply), unfinished_line}}
      end

    Logger.info("CLIENT NEWLY SENT: #{inspect(newly_sent_reply)}")
    Logger.info("CLIENT UNFINISHED: #{inspect(unfinished_start_byte_and_line)}")

    updated_sent =
      if newly_sent_reply do
        Map.put(sent_replies, start_byte, newly_sent_reply)
      else
        sent_replies
      end

    updated_state = %{
      state
      | total_bytes: new_total_bytes,
        sent_replies: updated_sent,
        unfinished_line: unfinished_start_byte_and_line,
        last_message_receieved_at: NaiveDateTime.utc_now()
    }

    {:noreply, updated_state}
  end

  defp generate_and_send_reply(lines, start_byte, state) do
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

        reversed
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
    |> then(fn full_reply ->
      if String.length(full_reply) == 0 do
        nil
      else
        Logger.info("Client #{state.session_id} sending reversed reply #{inspect(full_reply)}")
        reply(state, "/data/#{state.session_id}/#{start_byte}/#{full_reply}/", start_byte)
        full_reply
      end
    end)
  end

  def unescape(line) do
    String.replace(line, <<92>> <> <<42>>, <<42>>)
    |> String.replace(<<92>> <> <<92>>, <<92>>)
    |> String.replace(<<92>> <> <<10>>, <<10>>)
  end

  def escape(line) do
    String.replace(line, <<92>>, <<92>> <> <<92>>)
    |> String.replace(<<42>>, <<92>> <> <<42>>)
    |> String.replace(<<10>>, <<92>> <> <<10>>)
  end

  defp handle_ack(
         length_str,
         %{
           session_id: session_id,
           sent_replies: sent_replies,
           total_bytes: total_bytes,
           acknowledged_bytes: acknowledged_bytes
         } = state
       ) do
    max_acked =
      case Map.keys(acknowledged_bytes) do
        [] -> 0
        bytes -> Enum.max(bytes)
      end

    {length_int, ""} = Integer.parse(length_str)

    if max_acked >= length_int do
      {:noreply, state}
    else
      case {length_int, total_bytes} do
        {l, tb} when l == tb ->
          {:noreply,
           %{
             state
             | last_message_receieved_at: NaiveDateTime.utc_now(),
               acknowledged_bytes: Map.put(state.acknowledged_bytes, length_int, true)
           }}

        {l, tb} when l < tb ->
          {sent_before_l, sent_after_l} =
            sent_replies
            |> Enum.split_with(fn {byte, _reply} ->
              byte < length_int
            end)

          sent_replies =
            case List.last(sent_before_l) do
              nil -> sent_after_l
              previous -> [previous] ++ sent_after_l
            end

          sent_replies
          |> Enum.map(fn {bytes, reply} ->
            reply(state, "/data/#{session_id}/#{bytes}/#{reply}/", bytes)
          end)

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
         ack_position \\ nil
       ) do
    Logger.info(
      "Replying to #{inspect(socket)} #{inspect(address)} #{inspect(port)}: #{inspect(data)}"
    )

    if byte_size(data) > 1000 do
      Logger.error(
        "Oversized message: #{inspect(socket)} #{inspect(address)} #{inspect(port)}: #{inspect(data)}"
      )
    end

    :gen_udp.send(socket, address, port, data)

    if ack_position do
      Process.send_after(self(), {:check_and_retransmit, ack_position, data}, 3_000)
    end
  end
end
