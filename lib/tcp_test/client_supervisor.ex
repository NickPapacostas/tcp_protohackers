defmodule TcpTest.ClientSupervisor do
  use DynamicSupervisor

  def start_link(listening_socket) do
    DynamicSupervisor.start_link(__MODULE__, listening_socket, name: __MODULE__)
  end

  def start_child(client_socket) do
    spec = %{id: TcpTest.Client, start: {TcpTest.Client, :start_link, [client_socket]}}
    {:ok, pid} = DynamicSupervisor.start_child(__MODULE__, spec)
    :gen_tcp.controlling_process(client_socket, pid)
    {:ok, pid}
  end

  @impl true
  def init(init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
