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
    :pg.join(session_id, self())
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
    reply(state, "/ack/#{state.session_id}/#{state.total_bytes}/")
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
          close_session(state.session_id, state)
        else
          Process.send_after(self(), :check_timeout, 20_000)
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info(
        {:check_and_retransmit, start_byte, message},
        %{
          acknowledged_bytes: acknowledged_bytes,
          retries: retries,
          session_id: session_id
        } = state
      ) do
    max_acked =
      case Map.keys(acknowledged_bytes) do
        [] -> 0
        bytes -> Enum.max(bytes)
      end

    ["", "data", _session_id, _pos | data_bytes] = String.split(message, "/")
    data = Enum.drop(data_bytes, -1) |> Enum.join("/")
    message_end_byte = start_byte + byte_size(data)

    if max_acked == 0 || max_acked < message_end_byte do
      previous_count = Map.get(retries, start_byte, 0)
      state = %{state | retries: Map.put(retries, start_byte, previous_count + 1)}

      Logger.info(
        "Client #{session_id} retrying #{start_byte}, expecting: #{inspect(start_byte + byte_size(data))} count: #{previous_count + 1} max acked #{max_acked}"
      )

      if previous_count + 1 > 30 do
        Logger.info("RETRY TIMEOUT #{session_id} #{start_byte}")
        {:noreply, state}
      else
        reply(state, "/ack/#{session_id}/#{message_end_byte}/")
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
    if valid_message(data) do
      case String.split(data, "/") do
        ["", "connect", _session_id, ""] ->
          GenServer.cast(self(), :connect_attempt)
          {:noreply, state}

        ["", "data", ^session_id, pos | data_bytes] ->
          data = Enum.drop(data_bytes, -1) |> Enum.join("/")
          handle_data(pos, data, state)

        ["", "data", session_id, pos, data, ""] ->
          Logger.info("OTHER SESSION DATA #{session_id} raw receieved: #{inspect(data <> <<0>>)}")
          {:noreply, state}

        ["", "ack", session_id, length, ""] ->
          Logger.info(
            "Client #{session_id} received ack length #{length} current total_bytes #{total_bytes}"
          )

          handle_ack(length, state)

        ["", "close", session_id, ""] ->
          close_session(session_id, state)

        invalid_message ->
          Logger.warning(
            "Client #{session_id} received invalid message #{inspect(invalid_message)}"
          )

          {:noreply, state}
      end
    else
      Logger.warning("CLIENT #{session_id} IGNORING INVALID #{inspect(data)}")
      reply(state, "/ack/#{session_id}/#{total_bytes}/")
      {:noreply, state}
    end
  end

  defp valid_message(data) do
    case String.split(data, "/") do
      ["", "connect", session_id, ""] ->
        case Integer.parse(session_id) do
          {int, ""} -> true
          _ -> false
        end

      ["", "data", session_id, position_str | data_bytes] = message ->
        data =
          data_bytes
          |> Enum.drop(-1)
          |> Enum.join("/")

        slash_count =
          data
          |> String.split("/")
          |> Enum.count()

        escaped_slash_count =
          data
          |> String.split(<<92>> <> <<47>>)
          |> Enum.count()

        with {_step, true} <- {:slashes, slash_count == escaped_slash_count},
             {_step, true} <- {:byte_size, byte_size(data) < 1_000},
             {_step, {_session_int, ""}} <- {:session_id, Integer.parse(session_id)},
             {_step, {_position_int, ""}} <- {:position_int, Integer.parse(position_str)},
             {_step, true} <- {:ending_slash, String.ends_with?(Enum.join(data_bytes, "/"), "/")} do
          true
        else
          {step, _} ->
            Logger.warning("DATA INVALID AT STEP #{step} data: #{inspect(message)}")
            false
        end

      ["", "ack", session_id, position_str, ""] ->
        with {_session_int, ""} <- Integer.parse(session_id),
             {_position_int, ""} <- Integer.parse(position_str) do
          true
        else
          _ ->
            false
        end

      ["", "close", session_id, ""] ->
        case Integer.parse(session_id) do
          {int, ""} -> true
          _ -> false
        end

      invalid_message ->
        false
    end
  end

  defp handle_data(
         position_str,
         data,
         %{
           session_id: session_id,
           total_bytes: total_bytes,
           sent_replies: sent_replies,
           data_received: data_received,
           unfinished_line: unfinished_line
         } = state
       ) do
    {position, ""} = Integer.parse(position_str)

    position_already_received = position == 0 || Enum.member?(Map.keys(data_received), position)

    if position_already_received || position >= total_bytes do
      existing_data_for_position = Map.get(data_received, position)

      case {existing_data_for_position, data} do
        {nil, _} ->
          state = %{state | data_received: Map.put(data_received, position, data)}
          {:noreply, process_all_data_received(state)}

        {e, d} when e == d ->
          reply(state, "/ack/#{session_id}/#{total_bytes}/")
          {:noreply, state}

        {existing_payload, different_data} ->
          if byte_size(existing_payload) < byte_size(data) do
            state = %{state | data_received: Map.put(data_received, position, data)}
            {:noreply, process_all_data_received(state)}
          else
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

  defp process_all_data_received(
         %{data_received: data_received, total_bytes: total_bytes} = state
       ) do
    process_up_to =
      data_received
      |> Enum.sort()
      |> Enum.reduce_while(0, fn {data_start, data}, counter ->
        if data_start == counter do
          {:cont, counter + byte_size(data)}
        else
          {:halt, counter}
        end
      end)

    updated_state =
      data_received
      |> Enum.sort()
      |> Enum.filter(fn {data_start, _} -> data_start < process_up_to end)
      |> Enum.reduce(state, fn {position, payload}, state_acc ->
        send_and_store_replies(position, payload, state_acc)
      end)

    Logger.info("CLIENT REPROCESSED new state: #{inspect(updated_state)}")
    %{updated_state | unfinished_line: {nil, nil}}
  end

  defp send_and_store_replies(
         total_bytes,
         data,
         %{
           session_id: session_id,
           unfinished_line: {unfinished_line_start, unfinished_line},
           sent_replies: sent_replies
         } = state
       ) do
    message_byte_finish = total_bytes + byte_size(unescape(data))

    new_total_bytes =
      if message_byte_finish > state.total_bytes do
        message_byte_finish
      else
        state.total_bytes
      end

    reply(state, "/ack/#{session_id}/#{new_total_bytes}/")

    state = %{state | total_bytes: new_total_bytes}

    {line_start_byte, data_with_unfinished} =
      case unfinished_line_start do
        nil ->
          {total_bytes, data}

        start_byte ->
          {start_byte, unfinished_line <> data}
      end

    {newly_sent_replies, new_unfinished_line} =
      case Enum.reverse(String.split(unescape(data_with_unfinished), "\n")) do
        _just_newline when data_with_unfinished == "\n" ->
          replies = generate_and_send_replies(["\n"], line_start_byte, state)
          {replies, {nil, nil}}

        ["" | lines] ->
          replies = generate_and_send_replies(Enum.reverse(lines), line_start_byte, state)
          {replies, {nil, nil}}

        [unfinished_line] ->
          {[], {line_start_byte, unfinished_line}}

        [unfinished_line | lines] ->
          case generate_and_send_replies(Enum.reverse(lines), line_start_byte, state) do
            nil ->
              {[], {line_start_byte, unfinished_line}}

            replies ->
              {last_reply_start_byte, last_reply} =
                replies
                |> Enum.sort()
                |> List.last()

              unfinished_starts_at = last_reply_start_byte + byte_size(last_reply)
              {replies, {unfinished_starts_at, unfinished_line}}
          end
      end

    updated_sent =
      case newly_sent_replies do
        [] ->
          sent_replies

        replies ->
          Enum.reduce(replies, sent_replies, fn {reply_start_byte, reply}, sent ->
            Map.put(sent, reply_start_byte, reply)
          end)
      end

    %{
      state
      | total_bytes: new_total_bytes,
        sent_replies: updated_sent,
        unfinished_line: new_unfinished_line,
        last_message_receieved_at: NaiveDateTime.utc_now()
    }
  end

  defp generate_and_send_replies(lines, start_byte, state) do
    Logger.info("GENERATING REPLIES FOR LINES: #{inspect(lines)}")

    lines
    |> Enum.map(fn
      "\n" ->
        "\n"

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
        []
      else
        full_reply
        |> String.split("")
        |> Stream.chunk_every(900)
        |> Stream.with_index()
        |> Enum.reduce({start_byte, []}, fn {reply_chunk_list, index},
                                            {last_chunk_end_at, replies} ->
          reply_chunk = Enum.join(reply_chunk_list, "")

          Logger.info(
            "CLIENT DATA REPLY CHUNK #{state.session_id} index: #{index} start_byte: #{last_chunk_end_at} reversed #{inspect(reply_chunk)}"
          )

          reply(
            state,
            "/data/#{state.session_id}/#{last_chunk_end_at}/#{reply_chunk}/",
            last_chunk_end_at
          )

          {last_chunk_end_at + byte_size(reply_chunk),
           replies ++ [{last_chunk_end_at, reply_chunk}]}
        end)
        |> then(fn {_end_at, replies} -> replies end)
      end
    end)
  end

  def unescape(line) do
    String.replace(line, <<92>> <> <<47>>, <<47>>)
    |> String.replace(<<92>> <> <<92>>, <<92>>)
  end

  def escape(line) do
    String.replace(line, <<92>>, <<92>> <> <<92>>)
    |> String.replace(<<47>>, <<92>> <> <<47>>)
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

    max_sent =
      sent_replies
      |> Enum.sort()
      |> List.last()
      |> then(fn
        nil ->
          0

        {last_sent_byte, last_sent_message} ->
          last_sent_byte + byte_size(last_sent_message)
      end)

    if length_int < max_acked do
      {:noreply, state}
    else
      if length_int <= max_sent do
        {:noreply,
         %{
           state
           | last_message_receieved_at: NaiveDateTime.utc_now(),
             acknowledged_bytes: Map.put(state.acknowledged_bytes, length_int, true)
         }}
      else
        close_session(session_id, state)
      end
    end
  end

  defp close_session(session_id, state) do
    Logger.info("Closing session #{session_id}...")
    reply(state, "/close/#{session_id}/")
    TcpTest.LineReverse.ClientSupervisor.close_session(session_id)
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
      "REPLYING to #{inspect(socket)} #{inspect(address)} #{inspect(port)}: #{inspect(data)}"
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
