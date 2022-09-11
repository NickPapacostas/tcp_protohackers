defmodule TcpTest.Application do
  require Logger

  use Application

  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: TcpTest.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  def stop(_state), do: Logger.info("Application shutdown gracefully")

  def children() do
    Logger.info("HELLLO")

    [
      {TcpTest.Server, String.to_integer(System.get_env("TCP_PORT") || "8000")}
    ]
  end
end
