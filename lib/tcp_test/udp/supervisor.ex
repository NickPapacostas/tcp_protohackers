defmodule TcpTest.Udp.Supervisor do
  use Supervisor

  def start_link(tcp_port), do: Supervisor.start_link(__MODULE__, tcp_port)

  @impl true
  def init(tcp_port) do
    Supervisor.init(children(tcp_port), strategy: :one_for_one, name: TcpTest.Udp.Supervisor)
  end

  def children(tcp_port) do
    [
      {TcpTest.Udp.Server, tcp_port}
    ]
  end
end
