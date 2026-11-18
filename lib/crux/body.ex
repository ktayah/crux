defmodule Crux.Body do
  @moduledoc """
  Segmental body model on top of COCO-17 keypoints.

  Centre of mass uses de Leva (1996) segment mass fractions and CoM locations
  (male values; female table is a TODO). Pixel scale is recovered from the
  climber's entered height via standard segment-length ratios.

  COCO-17 indices:
    0 nose, 1/2 eyes, 3/4 ears, 5/6 shoulders, 7/8 elbows, 9/10 wrists,
    11/12 hips, 13/14 knees, 15/16 ankles   (left/right)
  """

  @min_conf 0.4
  # Below this fraction of body mass visible, a CoM estimate is mostly guess.
  @min_mass_coverage 0.75

  # {mass fraction, proximal, distal, CoM fraction from proximal}
  @limb_segments [
    # upper arm, forearm, hand (hand CoM approximated at the wrist)
    {0.0271, :shoulder, :elbow, 0.5772},
    {0.0162, :elbow, :wrist, 0.4574},
    {0.0061, :wrist, :wrist, 0.0},
    # thigh, shank, foot (foot CoM approximated at the ankle)
    {0.1416, :hip, :knee, 0.4095},
    {0.0433, :knee, :ankle, 0.4459},
    {0.0137, :ankle, :ankle, 0.0}
  ]

  @sides %{
    left: %{shoulder: 5, elbow: 7, wrist: 9, hip: 11, knee: 13, ankle: 15},
    right: %{shoulder: 6, elbow: 8, wrist: 10, hip: 12, knee: 14, ankle: 16}
  }

  # Segment length as a fraction of standing height (Drillis & Contini).
  @length_ratios [
    {:shoulder, :elbow, 0.186},
    {:elbow, :wrist, 0.146},
    {:hip, :knee, 0.245},
    {:knee, :ankle, 0.246}
  ]

  @doc """
  Whole-body centre of mass `{x, y}` in pixels, or `nil` when the trunk is
  not visible or too little of the body is.
  """
  def center_of_mass(nil), do: nil

  def center_of_mass(keypoints) do
    kp = List.to_tuple(keypoints)

    with shoulders when shoulders != nil <- mid(point(kp, 5), point(kp, 6)),
         hips when hips != nil <- mid(point(kp, 11), point(kp, 12)) do
      head = mid(point(kp, 3), point(kp, 4)) || point(kp, 0)

      parts =
        [
          {0.0694, head},
          {0.4346, along(shoulders, hips, 0.4486)}
        ] ++
          for {_side, idx} <- @sides, {mass, prox, dist, frac} <- @limb_segments do
            {mass, along(point(kp, idx[prox]), point(kp, idx[dist]), frac)}
          end

      visible = Enum.reject(parts, fn {_m, p} -> is_nil(p) end)
      coverage = visible |> Enum.map(&elem(&1, 0)) |> Enum.sum()

      if coverage >= @min_mass_coverage do
        {sx, sy} =
          Enum.reduce(visible, {0.0, 0.0}, fn {m, {x, y}}, {ax, ay} -> {ax + m * x, ay + m * y} end)

        {sx / coverage, sy / coverage}
      end
    end
  end

  @doc """
  Estimate metres-per-pixel for a clip from the climber's height.

  Each limb segment's pixel length only ever shrinks under foreshortening, so
  per segment we take a high percentile across frames as its "true" length,
  convert each to an implied standing height in pixels, and take the median.
  """
  def meters_per_pixel(poses, height_m) do
    implied_heights =
      for {_side, idx} <- @sides, {a, b, ratio} <- @length_ratios do
        lengths =
          for %{keypoints: kps} <- poses,
              kp = List.to_tuple(kps),
              p = point(kp, idx[a]),
              q = point(kp, idx[b]),
              p != nil and q != nil,
              do: dist(p, q)

        if length(lengths) >= 5, do: percentile(lengths, 0.9) / ratio
      end
      |> Enum.reject(&is_nil/1)

    case implied_heights do
      [] -> {:error, "not enough visible limbs to estimate scale"}
      hs -> {:ok, height_m / percentile(hs, 0.5)}
    end
  end

  defp point(kp, i) do
    case elem(kp, i) do
      {x, y, c} when c >= @min_conf -> {x, y}
      _ -> nil
    end
  end

  defp mid(nil, _), do: nil
  defp mid(_, nil), do: nil
  defp mid({ax, ay}, {bx, by}), do: {(ax + bx) / 2, (ay + by) / 2}

  defp along(nil, _, _), do: nil
  defp along(_, nil, _), do: nil
  defp along({ax, ay}, {bx, by}, t), do: {ax + (bx - ax) * t, ay + (by - ay) * t}

  defp dist({ax, ay}, {bx, by}), do: :math.sqrt((bx - ax) ** 2 + (by - ay) ** 2)

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, round(p * (length(sorted) - 1)))
  end
end
