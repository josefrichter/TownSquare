defmodule TownSquareBeam.RateLimit do
  @moduledoc """
  A tiny per-key fixed-window rate limiter backed by a single ETS table.

  Used to cap how many new `/live` connections one IP may open per window, so a
  bot can't flood the server with sockets. The same idea as the Node server's
  per-key bucket store, but the hot path here is a lock-free `:ets.update_counter`
  — no GenServer call per hit. This process owns the table and periodically sweeps
  expired window buckets so memory stays bounded.

  Each hit is recorded under `{key, bucket}` where `bucket = div(now_ms, window)`,
  so a window rolls over by simply moving to a new bucket; the value also carries
  an absolute expiry the sweep deletes by. A `limit <= 0` disables the check.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval_ms 60_000

  # --- public API -----------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Count one hit for `key` and return `:ok` while it stays at or under the
  configured per-IP connection budget, else `:rate_limited`.
  """
  def take(key) do
    take(
      key,
      Application.get_env(:town_square_beam, :max_conns_per_ip, 30),
      Application.get_env(:town_square_beam, :conn_window_ms, 10_000)
    )
  end

  @doc """
  Atomically record one hit for `key` in the current `window_ms` window and say
  whether `key` is still at or under `limit`. `limit <= 0` disables the check.
  """
  def take(_key, limit, _window_ms) when limit <= 0, do: :ok

  def take(key, limit, window_ms) do
    now = now_ms()
    bucket = div(now, window_ms)
    entry = {key, bucket}
    # Default object is inserted on the first hit (count 0) carrying the window's
    # absolute expiry at position 3; later hits only bump the counter at pos 2.
    expires_at = (bucket + 1) * window_ms + window_ms
    count = :ets.update_counter(@table, entry, {2, 1}, {entry, 0, expires_at})
    if count <= limit, do: :ok, else: :rate_limited
  end

  # --- GenServer ------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Delete every bucket whose window has fully expired (pos 3 < now).
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now_ms()}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp now_ms, do: System.system_time(:millisecond)
end
