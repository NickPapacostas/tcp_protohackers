defmodule TcpTest.Supervisor do
  use Supervisor

  def start_link(args), do: Supervisor.start_link(__MODULE__, args)

  @impl true
  def init(args) do
    Supervisor.init(children(), args)
  end

  def children() do
    [
      {TcpTest.Server, [String.to_integer(System.get_env("TCP_PORT") || "5000")]}
    ]
  end
end
