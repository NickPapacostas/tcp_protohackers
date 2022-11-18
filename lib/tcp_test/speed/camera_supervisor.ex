defmodule TcpTest.Speed.CameraSupervisor do
  use DynamicSupervisor

  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def start_child(client_socket, inital_message) do
    spec = %{
      id: TcpTest.Speed.Camera,
      start: {TcpTest.Speed.Camera, :start_link, [client_socket, inital_message]}
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
