defmodule TcpTest.LineReverse.Server do
  require Logger

  use GenServer

  def start_link(listening_port) do
    GenServer.start_link(__MODULE__, listening_port, name: __MODULE__)
  end

  def close(address, port) do
    GenServer.cast(__MODULE__, {:close, address, port})
  end

  ## Callbacks

  @impl true
  def init(port) do
    res = :gen_udp.open(port, [:binary, active: false])

    IO.inspect("RES")
    IO.inspect(res)
    {:ok, socket} = res
    Logger.info("Listening socket #{inspect(socket)}")
    GenServer.cast(self(), :listen_and_dispatch)
    {:ok, %{socket: socket, active_sessions: %{}}}
  end

  @impl true
  def handle_cast(:listen_and_dispatch, %{socket: socket, active_sessions: sessions}) do
    updated_state = listen_and_dispatch(socket, sessions)
    GenServer.cast(self(), :listen_and_dispatch)
    {:noreply, updated_state}
  end

  @impl true
  def handle_cast({:close, address, port}, %{active_sessions: sessions} = state) do
    Logger.info("Server removing address #{inspect(address)} port #{inspect(port)} from sessions")
    GenServer.cast(self(), :listen_and_dispatch)
    {:noreply, %{state | active_sessions: Map.delete(sessions, {address, port})}}
  end

  defp listen_and_dispatch(socket, sessions) do
    case :gen_udp.recv(socket, 0, 200) do
      {:ok, message} ->
        Logger.info("Received: #{inspect(message)}")
        updated_sessions = process_message(socket, message, sessions)
        %{socket: socket, active_sessions: updated_sessions}

      error ->
        %{socket: socket, active_sessions: sessions}
    end
  end

  defp process_message(socket, {address, port, data}, sessions) do
    Logger.info("Server processing #{data} #{inspect(sessions)}")

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

  def handle_info(unkown_message, state) do
    Logger.warning("Server received unkown_message #{inspect(unkown_message)}")
    {:noreply, state}
  end

  defp reply(socket, address, port, data) do
    Logger.info(
      "Replying to #{inspect(socket)} #{inspect(address)} #{inspect(port)}: #{inspect(data)}"
    )

    :gen_udp.send(socket, address, port, data)
  end
end
