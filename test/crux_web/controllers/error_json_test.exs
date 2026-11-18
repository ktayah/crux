defmodule CruxWeb.ErrorJSONTest do
  use CruxWeb.ConnCase, async: true

  test "renders 404" do
    assert CruxWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert CruxWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
