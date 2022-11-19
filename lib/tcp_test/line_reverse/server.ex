defmodule TcpTest.LineReverse.Server do
  require Logger

  use GenServer

  def start_link(listening_port) do
    GenServer.start_link(__MODULE__, listening_port, name: __MODULE__)
  end

  def close(pid) do
    GenServer.cast(__MODULE__, {:close, pid})
  end

  ## Callbacks

  @impl true
  def init(port) do
    res = :gen_udp.open(port, [:binary, active: true])

    {:ok, socket} = res
    Logger.info("Listening socket #{inspect(socket)}")
    {:ok, %{socket: socket, active_sessions: %{}}}
  end

  @impl true
  def handle_cast({:close, pid}, %{active_sessions: sessions} = state) do
    case Enum.find(sessions, fn {{address, port}, client_pid} ->
           client_pid == pid
         end) do
      {session_key, _} ->
        Logger.info(
          "Server removing address port #{inspect(session_key)}pid #{inspect(pid)}from sessions"
        )

        {:noreply, %{state | active_sessions: Map.delete(sessions, session_key)}}

      _ ->
        Logger.info(
          "Server FAILED removing address port pid #{inspect(pid)}from sessions #{inspect(sessions)}"
        )

        {:noreply, state}
    end
  end

  def handle_info(
        {:udp, _socket, address, port, data},
        %{socket: socket, active_sessions: sessions} = state
      ) do
    Logger.info("SERVER UDP PACKET #{data}")
    updated_sessions = process_message(socket, {address, port, data}, sessions)

    {:noreply, %{socket: socket, active_sessions: updated_sessions}}
  end

  def handle_info({:udp_closed, _}, state), do: {:stop, :normal, state}
  def handle_info({:udp_error, _}, state), do: {:stop, :normal, state}

  def handle_info(unkown_message, state) do
    Logger.warning("Server received unkown_message #{inspect(unkown_message)}")
    {:noreply, state}
  end

  defp process_message(socket, {address, port, data}, sessions) do
    case Map.get(sessions, {address, port}) do
      nil ->
        case String.split(data, "/") do
          ["", "connect", session_id, ""] ->
            case Integer.parse(session_id) do
              {int, ""} when int > 0 ->
                {:ok, new_client_pid} =
                  TcpTest.LineReverse.ClientSupervisor.start_child(
                    socket,
                    session_id,
                    address,
                    port
                  )

                Map.put(sessions, {address, port}, new_client_pid)

              bad_session_id ->
                Logger.info("Server received bad session id #{inspect(bad_session_id)}")
                sessions
            end

          non_connect_message ->
            Logger.info("Server non connect #{inspect(non_connect_message)} #{inspect(sessions)}")
            sessions
        end

      client_pid ->
        GenServer.cast(client_pid, {:process_message, data})
        sessions
    end
  end
end
