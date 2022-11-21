defmodule TcpTest.LineReverse.ClientSupervisor do
  require Logger

  use DynamicSupervisor

  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def start_child(socket, session_id, address, port) do
    spec = %{
      id: TcpTest.LineReverse.Client,
      start: {TcpTest.LineReverse.Client, :start_link, [socket, session_id, address, port]}
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @impl true
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one, restart: :transient)
  end

  def close_session(session_id) do
    case :pg.get_members(session_id) do
      [pid] ->
        TcpTest.LineReverse.Server.close(pid, session_id)
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      _ ->
        Logger.warning(
          "CLIENTSUPERVISOR unable to find server for session_id: #{inspect(session_id)} to kill"
        )
    end
  end
end
