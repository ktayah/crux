defmodule Crux.Physics do
  @moduledoc """
  CoM kinematics and total contact force.

  Pose keypoints jitter, and acceleration is a second derivative, so raw
  finite differences are useless. We fit a local quadratic over a sliding
  window (Savitzky-Golay) and read position, velocity and acceleration off
  the fitted coefficients.

  Total contact force (sum over all holds) follows from Newton's second law:

      F_contact = m * (a_com - g)

  Coordinates are image coordinates in the wall plane (x right, y down). We
  assume the camera faces the wall square-on with image "down" along the
  wall's fall line. For a wall overhanging by `theta` from vertical, gravity
  splits into an in-plane part `g cos(theta)` (down the wall) and an
  out-of-plane part `g sin(theta)` (away from the wall) that the holds must
  also resist. Out-of-plane acceleration is not observable and assumed zero.
  """

  @g 9.81

  @doc """
  Fill short gaps in a list of `{x, y} | nil` by linear interpolation.
  Gaps longer than `max_gap` frames stay `nil`.
  """
  def fill_gaps(points, max_gap \\ 5) do
    indexed = Enum.with_index(points)
    known = for {p, i} <- indexed, p != nil, do: {i, p}

    fills =
      known
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [{i0, {x0, y0}}, {i1, {x1, y1}}] ->
        if i1 - i0 > 1 and i1 - i0 - 1 <= max_gap do
          for i <- (i0 + 1)..(i1 - 1)//1 do
            t = (i - i0) / (i1 - i0)
            {i, {x0 + (x1 - x0) * t, y0 + (y1 - y0) * t}}
          end
        else
          []
        end
      end)
      |> Map.new()

    for {p, i} <- indexed, do: p || Map.get(fills, i)
  end

  @doc """
  Savitzky-Golay (quadratic) smoothing and derivatives of a 2D track.

  Returns a list aligned with `points`; each entry is `nil` (window not
  fully observed) or `%{pos: {x, y}, vel: {vx, vy}, acc: {ax, ay}}` in input
  units per second (per second squared for `acc`).
  """
  def kinematics(points, fps, window \\ 13) when rem(window, 2) == 1 do
    half = div(window, 2)
    dt = 1 / fps
    coeffs = sg_coefficients(window)
    track = List.to_tuple(points)
    n = tuple_size(track)

    for i <- 0..(n - 1)//1 do
      win = if i - half >= 0 and i + half < n, do: for(j <- (i - half)..(i + half), do: elem(track, j))

      if win && Enum.all?(win, & &1) do
        # {window, 2} -> fitted {3, 2}: rows are [a, b, c] of a + b*t + c*t^2
        fit = Nx.dot(coeffs, Nx.tensor(Enum.map(win, &Tuple.to_list/1), type: :f64))
        [[px, py], [bx, by], [cx, cy]] = Nx.to_list(fit)
        %{pos: {px, py}, vel: {bx / dt, by / dt}, acc: {2 * cx / dt ** 2, 2 * cy / dt ** 2}}
      end
    end
  end

  @doc """
  Total contact force per frame for a climber of `mass_kg` on a wall
  overhanging by `wall_angle_deg`, given kinematics in metres.

  Returns `nil` or `%{bodyweights: float, newtons: float, in_plane: {fx, fy}}`
  with `in_plane` in newtons (image axes).
  """
  def contact_force(nil, _mass_kg, _wall_angle_deg), do: nil

  def contact_force(%{acc: {ax, ay}}, mass_kg, wall_angle_deg) do
    theta = wall_angle_deg * :math.pi() / 180
    fx = mass_kg * ax
    fy = mass_kg * (ay - @g * :math.cos(theta))
    fz = mass_kg * @g * :math.sin(theta)
    newtons = :math.sqrt(fx * fx + fy * fy + fz * fz)
    %{newtons: newtons, bodyweights: newtons / (mass_kg * @g), in_plane: {fx, fy}}
  end

  # Least-squares fit of [1, t, t^2] over t = -half..half: pinv(A) is {3, window}.
  defp sg_coefficients(window) do
    half = div(window, 2)
    a = Nx.tensor(for(t <- -half..half, do: [1, t, t * t]), type: :f64)
    at = Nx.transpose(a)
    Nx.dot(Nx.LinAlg.invert(Nx.dot(at, a)), at)
  end
end
