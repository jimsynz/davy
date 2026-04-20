defmodule DavyTest do
  use ExUnit.Case
  doctest Davy

  test "greets the world" do
    assert Davy.hello() == :world
  end
end
