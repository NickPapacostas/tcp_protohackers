defmodule TcpTest.Speed.Supervisor do
  use Supervisor

  def start_link(tcp_port), do: Supervisor.start_link(__MODULE__, tcp_port)

  @impl true
  def init(tcp_port) do
    Supervisor.init(children(tcp_port), strategy: :one_for_one, name: TcpTest.Speed.Supervisor)
  end

  def children(tcp_port) do
    [
      %{
        id: :pg,
        start: {:pg, :start_link, []}
      },
      {TcpTest.Speed.RoadSupervisor, []},
      {TcpTest.Speed.ClientSupervisor, []},
      {TcpTest.Speed.SocketListener, tcp_port}
    ]
  end
end
