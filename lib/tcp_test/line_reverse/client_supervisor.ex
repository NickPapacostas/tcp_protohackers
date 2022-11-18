defmodule TcpTest.LineReverse.ClientSupervisor do
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

  def close(pid, address, port) do
    TcpTest.LineReverse.Server.close(address, port)
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
