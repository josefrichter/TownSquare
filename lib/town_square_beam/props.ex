defmodule TownSquareBeam.Props do
  @moduledoc """
  The default-scene props the server needs to arbitrate seats.

  Ported from `public/shared/site-config-core.mjs` (`createBench`/`createTree`)
  and `public/shared/scene-prop-geometry.mjs` (`isWithinPropSettleZone`). The
  widget owns the *rendering* of these; the server only needs each prop's
  position, pose, seat offsets, and settle half-width.
  """

  # Reference stage width and prop pixel sizes from site-config-core.mjs.
  @reference_stage_width 1200
  @bench_px_width 132
  @tree_px_width 150

  # Default scene: first bench sits at x=0.2, first tree at x=0.8 (the positions
  # the smoke test settles onto). `id` matches the widget's `uniqueId(kind, 0)`.
  @props %{
    "bench" => %{
      id: "bench",
      x: 0.2,
      pose: "sitting",
      seats: [-0.01, 0.01],
      half_width: @bench_px_width / 2 / @reference_stage_width
    },
    "tree" => %{
      id: "tree",
      x: 0.8,
      pose: "resting",
      seats: [-0.008, 0.008],
      half_width: @tree_px_width / 2 / @reference_stage_width
    }
  }

  def get(prop_id), do: Map.get(@props, prop_id)

  @doc "Mirror of isWithinPropSettleZone/2."
  def within_settle_zone?(%{half_width: half, x: px}, x) do
    half > 0 and abs(x - px) < half
  end
end
