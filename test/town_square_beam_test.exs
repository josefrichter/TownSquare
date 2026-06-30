defmodule TownSquareBeam.ReadingTest do
  use ExUnit.Case, async: true

  alias TownSquareBeam.Reading

  @origin "http://127.0.0.1:8788"

  test "derives the label from the last path segment, ignoring any client label" do
    assert Reading.sanitize("#{@origin}/notes/launch", @origin) ==
             {"launch", "#{@origin}/notes/launch"}

    assert Reading.sanitize("#{@origin}/docs/api", @origin) == {"api", "#{@origin}/docs/api"}
  end

  test "turns dashes into spaces and strips a file extension" do
    assert {"real page", _} = Reading.sanitize("#{@origin}/docs/real-page", @origin)
    assert {"about", _} = Reading.sanitize("#{@origin}/about.html", @origin)
  end

  test "rejects an off-origin URL for the default scene" do
    assert Reading.sanitize("https://attacker.example/status", @origin) == {"", ""}
  end

  test "rejects non-http(s) and garbage" do
    assert Reading.sanitize("javascript:alert(1)", @origin) == {"", ""}
    assert Reading.sanitize("not a url", @origin) == {"", ""}
    assert Reading.sanitize(nil, @origin) == {"", ""}
  end
end
