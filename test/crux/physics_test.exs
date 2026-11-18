defmodule Crux.PhysicsTest do
  use ExUnit.Case, async: true

  alias Crux.Physics

  @fps 30

  describe "kinematics/3" do
    test "recovers constant acceleration from a parabola" do
      # y = 0.5 * a * t^2 with a = 3 m/s^2, x = 0.2 m/s * t
      points = for i <- 0..60, t = i / @fps, do: {0.2 * t, 0.5 * 3.0 * t * t}
      kin = Physics.kinematics(points, @fps)

      %{vel: {vx, _}, acc: {ax, ay}} = Enum.at(kin, 30)
      assert_in_delta vx, 0.2, 1.0e-9
      assert_in_delta ax, 0.0, 1.0e-9
      assert_in_delta ay, 3.0, 1.0e-9
    end

    test "is nil where the window is incomplete" do
      points = List.duplicate({0.0, 0.0}, 20) |> List.replace_at(10, nil)
      kin = Physics.kinematics(points, @fps, 5)

      assert Enum.at(kin, 0) == nil
      assert Enum.at(kin, 10) == nil
      assert Enum.at(kin, 15) != nil
    end
  end

  describe "contact_force/3" do
    test "hanging still on a vertical wall is one bodyweight, pointing up" do
      f = Physics.contact_force(%{acc: {0.0, 0.0}}, 70, 0)
      assert_in_delta f.bodyweights, 1.0, 1.0e-9
      {fx, fy} = f.in_plane
      assert_in_delta fx, 0.0, 1.0e-9
      assert fy < 0
    end

    test "still on an overhang is still one bodyweight in total" do
      f = Physics.contact_force(%{acc: {0.0, 0.0}}, 70, 45)
      assert_in_delta f.bodyweights, 1.0, 1.0e-9
    end

    test "free fall on a vertical wall needs no force" do
      f = Physics.contact_force(%{acc: {0.0, 9.81}}, 70, 0)
      assert_in_delta f.bodyweights, 0.0, 1.0e-9
    end

    test "accelerating upward at 1 g is two bodyweights" do
      f = Physics.contact_force(%{acc: {0.0, -9.81}}, 70, 0)
      assert_in_delta f.bodyweights, 2.0, 1.0e-9
    end
  end

  test "fill_gaps/2 interpolates short gaps only" do
    assert Physics.fill_gaps([{0.0, 0.0}, nil, {2.0, 4.0}]) == [{0.0, 0.0}, {1.0, 2.0}, {2.0, 4.0}]
    assert Physics.fill_gaps([{0.0, 0.0}, nil, nil, {3.0, 0.0}], 1) == [{0.0, 0.0}, nil, nil, {3.0, 0.0}]
  end
end
