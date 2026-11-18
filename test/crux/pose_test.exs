defmodule Crux.PoseTest do
  use ExUnit.Case, async: true

  alias Crux.{Pose, Video}

  @moduletag :model

  setup_all do
    if File.exists?(Pose.model_path()),
      do: :ok,
      else: {:skip, "run `uv run python/export_pose.py` to export the model"}
  end

  test "runs the ONNX model and finds nobody in a blank frame" do
    lb = Video.letterbox(1280, 720)
    gray = for _ <- 1..(3 * 640 * 640), into: <<>>, do: <<0.45::float-32-little>>

    assert Pose.detect(Pose.model(), gray, lb) == nil
  end

  test "letterbox maps model coordinates back to the source" do
    lb = Video.letterbox(1280, 720)
    assert {lb.scaled_w, lb.scaled_h, lb.pad_x, lb.pad_y} == {640, 360, 0, 140}
    assert Video.Letterbox.to_source(lb, {320, 320}) == {640.0, 360.0}
  end
end
