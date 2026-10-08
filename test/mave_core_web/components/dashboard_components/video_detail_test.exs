defmodule MaveCoreWeb.DashboardComponents.VideoDetailTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MaveCoreWeb.DashboardComponents.VideoDetail

  test "highlighting never renders snippet text as active markup" do
    for snippet <- [
          ~s(a"<img/src='https://example.com/pixel'>),
          ~s(<mave-player width="a"<img/src='https://example.com/pixel'>"></mave-player>),
          ~s(<iframe src="https://example.com/a?b=1&c=2"></iframe><),
          ~s(<Player width="640" /> & < unfinished),
          "<mave-player\n  width=\"640\"\n  controls>>\n</mave-player>",
          ~s(日本語 <mave-clip embed="abc"/> &lt;not-a-tag&gt;)
        ] do
      rendered =
        render_component(&VideoDetail.video_snippet/1, snippet: snippet, line_numbers: [])

      code = rendered |> LazyHTML.from_fragment() |> LazyHTML.query("#snippet-code")

      assert LazyHTML.query(code, "img, iframe, script, style, mave-player, mave-clip, player")
             |> LazyHTML.to_tree() == []

      assert code |> LazyHTML.query(".highlight") |> LazyHTML.text() == snippet
      assert code |> LazyHTML.query(".mave-snippet-tag") |> LazyHTML.to_tree() != []
    end
  end
end
