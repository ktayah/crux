defmodule Crux.Analysis do
  @moduledoc """
  The end-to-end pipeline: normalise video -> pose per frame -> CoM ->
  scale -> smoothed kinematics -> total contact force.
  """

  alias Crux.{Body, Physics, Pose, Video}

  @type params :: %{weight_kg: float, height_m: float, wall_angle_deg: float}

  @doc """
  Analyse the video at `src`. `on_progress` is called with
  `{:progress, stage, done, total}`.

  Returns `{:ok, result}` where `result` is JSON-serialisable for the overlay.
  """
  @spec run(binary(), params(), function() | none()) :: {:ok, map()} | {:error, any()}
  def run(src, params, on_progress \\ fn _ -> :ok end) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    playback = Path.join(uploads_dir(), "#{id}.mp4")
    File.mkdir_p!(uploads_dir())

    on_progress.({:progress, :transcoding, 0, 1})

    with :ok <- Video.normalize(src, playback),
         {:ok, info} <- Video.probe(playback),
         poses = estimate_poses(playback, info, on_progress),
         {:ok, m_per_px} <- Body.meters_per_pixel(Enum.reject(poses, &is_nil/1), params.height_m) do
      coms = poses |> Enum.map(&Body.center_of_mass(&1 && &1.keypoints)) |> Physics.fill_gaps()

      kinematics =
        coms
        |> Enum.map(fn
          nil -> nil
          {x, y} -> {x * m_per_px, y * m_per_px}
        end)
        |> Physics.kinematics(info.fps)

      forces =
        Enum.map(kinematics, &Physics.contact_force(&1, params.weight_kg, params.wall_angle_deg))

      frames =
        [poses, coms, forces]
        |> Enum.zip_with(fn [pose, com, force] -> frame_json(pose, com, force) end)

      {:ok,
       %{
         video_url: "/uploads/#{id}.mp4",
         width: info.width,
         height: info.height,
         fps: info.fps,
         px_per_m: 1 / m_per_px,
         frames: frames,
         summary: summarize(poses, forces, info)
       }}
    else
      {:error, _} = error ->
        File.rm(playback)
        error
    end
  end

  def uploads_dir, do: Application.app_dir(:crux, "priv/static/uploads")

  defp estimate_poses(path, info, on_progress) do
    model = Pose.model()
    lb = Video.letterbox(info.width, info.height)

    path
    |> Video.frames(lb)
    |> Stream.with_index(1)
    |> Enum.map(fn {frame, i} ->
      if rem(i, 10) == 0, do: on_progress.({:progress, :pose, i, info.frame_count})
      Pose.detect(model, frame, lb)
    end)
  end

  defp frame_json(pose, com, force) do
    %{
      k: pose && Enum.map(pose.keypoints, fn {x, y, c} -> [r(x), r(y), r(c, 2)] end),
      c: com && Tuple.to_list(com) |> Enum.map(&r/1),
      f:
        force &&
          %{
            bw: r(force.bodyweights, 3),
            n: r(force.newtons),
            v: force.in_plane |> Tuple.to_list() |> Enum.map(&r/1)
          }
    }
  end

  defp summarize(poses, forces, info) do
    bws = for %{bodyweights: bw} <- forces, do: bw
    detected = Enum.count(poses, & &1)

    %{
      frames: length(poses),
      detected: detected,
      duration: r(info.duration, 2),
      peak_bw: if(bws == [], do: nil, else: r(Enum.max(bws), 2)),
      mean_bw: if(bws == [], do: nil, else: r(Enum.sum(bws) / length(bws), 2))
    }
  end

  defp r(x, digits \\ 1), do: Float.round(x / 1, digits)
end
