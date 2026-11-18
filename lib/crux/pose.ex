defmodule Crux.Pose do
  @moduledoc """
  Single-person 2D pose estimation with a YOLO pose model running in ONNX
  Runtime (via Ortex). See `python/export_pose.py` for the model contract.

  Keypoints follow the COCO-17 order; see `Crux.Body` for indices.
  """

  alias Crux.Video.Letterbox

  @min_person_score 0.25
  @num_keypoints 17

  def model do
    case :persistent_term.get({__MODULE__, :model}, nil) do
      nil ->
        model = Ortex.load(model_path())
        :persistent_term.put({__MODULE__, :model}, model)
        model

      model ->
        model
    end
  end

  def model_path, do: Application.app_dir(:crux, "priv/models/pose.onnx")

  @doc """
  Detect the most confident person in a planar RGB float32 frame.

  Returns `nil` or `%{score: float, keypoints: [{x, y, conf}]}` with
  coordinates in source-video pixels.
  """
  def detect(model, rgb_frame, %Letterbox{} = lb) do
    input = rgb_frame |> Nx.from_binary(:f32) |> Nx.reshape({1, 3, lb.size, lb.size})
    {output} = Ortex.run(model, input)
    {_, rows, anchors} = Nx.shape(output)
    output = output |> Nx.backend_transfer(Nx.BinaryBackend) |> Nx.reshape({rows, anchors})

    scores = output[4]
    best = scores |> Nx.argmax() |> Nx.to_number()
    score = scores[best] |> Nx.to_number()

    if score < @min_person_score do
      nil
    else
      [_cx, _cy, _w, _h, _score | kps] = Nx.to_flat_list(output[[.., best]])

      keypoints =
        kps
        |> Enum.chunk_every(3)
        |> Enum.take(@num_keypoints)
        |> Enum.map(fn [x, y, conf] ->
          {sx, sy} = Letterbox.to_source(lb, {x, y})
          {sx, sy, conf}
        end)

      %{score: score, keypoints: keypoints}
    end
  end
end
