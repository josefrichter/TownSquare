defmodule TownSquareBeam.Reading do
  @moduledoc """
  Reading-state sanitizer. The client may *send* a label, but the server always
  derives it from the URL so a visitor can't spoof what page someone is on.

  Ported from `sanitizeReadingUrl`, `labelFromReadingUrl`, and
  `sanitizeReadingState` in server.js.
  """

  @max_label_len 42
  @max_url_len 240

  @doc """
  Returns `{label, href}`. `client_origin` gates the URL the same way
  `readingUrlAllowedForClient` does for the default (no-site) scene: a URL is
  accepted only when its origin matches the connecting page's origin.
  """
  def sanitize(reading_url, client_origin) when is_binary(reading_url) do
    case parse(reading_url) do
      {:ok, uri, href} ->
        if allowed?(uri, client_origin), do: {label_from_url(uri), href}, else: {"", ""}

      :error ->
        {"", ""}
    end
  end

  def sanitize(_reading_url, _client_origin), do: {"", ""}

  defp parse(url) do
    trimmed = String.slice(url, 0, @max_url_len)
    uri = URI.parse(trimmed)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      {:ok, uri, href(uri)}
    else
      :error
    end
  end

  # Match the WHATWG URL.href normalization the Node server emits.
  defp href(%URI{} = uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    base = "#{uri.scheme}://#{authority(uri)}#{path}"
    base = if uri.query, do: base <> "?" <> uri.query, else: base
    if uri.fragment, do: base <> "#" <> uri.fragment, else: base
  end

  defp authority(%URI{host: host, port: port, scheme: scheme}) do
    default = if scheme == "https", do: 443, else: 80
    if port in [nil, default], do: host, else: "#{host}:#{port}"
  end

  defp origin(%URI{} = uri), do: "#{uri.scheme}://#{authority(uri)}"

  defp allowed?(uri, client_origin) do
    client_origin in [nil, ""] or origin(uri) == client_origin
  end

  # Mirror labelFromReadingUrl: last non-empty path segment, strip a file
  # extension, turn -/_ into spaces, collapse whitespace, lowercase-trim, cap 42.
  defp label_from_url(%URI{} = uri) do
    segment =
      (uri.path || "")
      |> String.split("/", trim: true)
      |> List.last()

    case segment do
      nil ->
        sanitize_label(String.replace(uri.host, ~r/^www\./, ""))

      "" ->
        sanitize_label(String.replace(uri.host, ~r/^www\./, ""))

      seg ->
        seg
        |> decode()
        |> String.replace(~r/\.[a-z0-9]+$/i, "")
        |> String.replace(~r/[-_]+/, " ")
        |> sanitize_label()
    end
  end

  defp decode(seg) do
    URI.decode(seg)
  rescue
    _ -> seg
  end

  defp sanitize_label(label) when is_binary(label) do
    label |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, @max_label_len)
  end
end
