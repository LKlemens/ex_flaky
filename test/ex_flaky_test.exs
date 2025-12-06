defmodule ExFlakyTest do
  use ExUnit.Case
  doctest ExFlaky

  test "greets the world" do
    assert ExFlaky.hello() == :world
  end
end
