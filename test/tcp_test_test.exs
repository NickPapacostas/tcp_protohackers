defmodule TcpTestTest do
  use ExUnit.Case
  doctest TcpTest

  test "greets the world" do
    assert TcpTest.hello() == :world
  end
end
