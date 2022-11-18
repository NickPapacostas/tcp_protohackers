defmodule TcpTest.Speed.RoadSupervisor do
  require Logger

  use DynamicSupervisor

  @dispatched_tickets_table :dispatched_tickets

  def start_link(_args) do
    :ets.new(@dispatched_tickets_table, [:public, :named_table])
    DynamicSupervisor.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register(road) do
    case Process.whereis(:"#{road}") do
      nil ->
        Logger.info("RoadSupervisor starting child for road: #{road}")
        DynamicSupervisor.start_child(__MODULE__, road_spec(road))

      pid ->
        {:ok, pid}
    end
  end

  @impl true
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def child_spec(), do: nil

  def road_spec(road) do
    %{
      id: "road:#{road}",
      start: {TcpTest.Speed.Road, :start_link, [road]}
    }
  end
end
