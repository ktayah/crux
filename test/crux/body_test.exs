defmodule Crux.BodyTest do
  use ExUnit.Case, async: true

  alias Crux.Body

  # A symmetric standing figure, 1 px = 1 cm, for a 175 cm person.
  # x is mirrored around 100, so CoM x must be 100.
  @standing [
    {100, 10, 1.0},
    {96, 8, 1.0}, {104, 8, 1.0},
    {92, 10, 1.0}, {108, 10, 1.0},
    {80, 30, 1.0}, {120, 30, 1.0},
    {75, 62.6, 1.0}, {125, 62.6, 1.0},
    {72, 88.2, 1.0}, {128, 88.2, 1.0},
    {90, 80, 1.0}, {110, 80, 1.0},
    {90, 122.9, 1.0}, {110, 122.9, 1.0},
    {90, 166, 1.0}, {110, 166, 1.0}
  ]

  test "centre of mass of a symmetric figure lies on the midline, near the hips" do
    {x, y} = Body.center_of_mass(@standing)
    assert_in_delta x, 100, 1.0e-6
    # trunk-heavy model: CoM sits a little above the hip line
    assert y > 55 and y < 85
  end

  test "no trunk means no centre of mass" do
    hidden = List.replace_at(@standing, 11, {90, 80, 0.1})
    assert Body.center_of_mass(hidden) == nil
  end

  test "scale is recovered from height" do
    poses = List.duplicate(%{keypoints: @standing}, 10)
    {:ok, m_per_px} = Body.meters_per_pixel(poses, 1.75)
    # limb lengths were built at 1 cm per px
    assert_in_delta m_per_px, 0.01, 0.0015
  end
end
