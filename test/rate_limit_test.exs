defmodule TownSquareBeam.RateLimitTest do
  # async: false — shares the single named ETS table started by the application.
  use ExUnit.Case, async: false

  alias TownSquareBeam.RateLimit

  # Each test uses a unique key so they don't collide in the shared table.
  defp key(name), do: "#{name}-#{System.unique_integer([:positive])}"

  test "permits hits up to the limit, then rate-limits within the window" do
    k = key("burst")
    assert RateLimit.take(k, 3, 60_000) == :ok
    assert RateLimit.take(k, 3, 60_000) == :ok
    assert RateLimit.take(k, 3, 60_000) == :ok
    assert RateLimit.take(k, 3, 60_000) == :rate_limited
    assert RateLimit.take(k, 3, 60_000) == :rate_limited
  end

  test "a non-positive limit disables the check" do
    k = key("disabled")
    for _ <- 1..100, do: assert(RateLimit.take(k, 0, 60_000) == :ok)
  end

  test "counts are isolated per key" do
    a = key("a")
    b = key("b")
    assert RateLimit.take(a, 1, 60_000) == :ok
    assert RateLimit.take(a, 1, 60_000) == :rate_limited
    # b has its own bucket and is unaffected.
    assert RateLimit.take(b, 1, 60_000) == :ok
  end

  test "a new window resets the budget" do
    k = key("rollover")
    # A 1ms window rolls to a new bucket almost immediately.
    assert RateLimit.take(k, 1, 1) == :ok
    Process.sleep(5)
    assert RateLimit.take(k, 1, 1) == :ok
  end
end
