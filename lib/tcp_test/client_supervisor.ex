defmodule TcpTest.ClientSupervisor do
  use DynamicSupervisor

  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def start_child(client_socket) do
    spec = %{
      id: TcpTest.MaliciousClient,
      start: {TcpTest.MaliciousClient, :start_link, [client_socket]}
    }

    {:ok, pid} = DynamicSupervisor.start_child(__MODULE__, spec)
    :gen_tcp.controlling_process(client_socket, pid)
    {:ok, pid}
  end

  @impl true
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
