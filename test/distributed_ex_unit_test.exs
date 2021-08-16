for letter <- ?A..?Z do
  defmodule String.to_atom("Elixir.DistributedExUnitTest.Test.#{[letter]}") do
    use ExUnit.Case, async: true

    test "calculates the fibonacci numbers" do
      for num <- 1..35 do
        assert fib(num) > 0
      end
    end

    defp fib(0) do 0 end
    defp fib(1) do 1 end
    defp fib(n) do fib(n-1) + fib(n-2) end
  end
end
