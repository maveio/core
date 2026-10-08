defmodule MaveCore.Media.RenditionSizingTest do
  use ExUnit.Case, async: true

  alias MaveCore.Media.RenditionSizing

  test "keeps a source-capped top rendition between profile thresholds" do
    source = %{"width" => 1080, "height" => 1080}

    assert RenditionSizing.source_allows_size?(source, "sd")
    assert RenditionSizing.source_allows_size?(source, "hd")
    refute RenditionSizing.source_allows_size?(source, "fhd")

    assert RenditionSizing.filter_sizes(~w(sd hd fhd qhd uhd), source, true) == ~w(sd hd)
    assert RenditionSizing.capped_target_long_edge("hd", source) == {:ok, 1080}
    assert RenditionSizing.scaled_resolution("sd", source) == {:ok, "640x640"}
    assert RenditionSizing.scaled_resolution("hd", source) == {:ok, "1080x1080"}
  end

  test "does not create a duplicate capped rendition at an exact profile boundary" do
    source = %{"width" => 1280, "height" => 720}

    assert RenditionSizing.source_allows_size?(source, "hd")
    refute RenditionSizing.source_allows_size?(source, "fhd")
    assert RenditionSizing.filter_sizes(~w(sd hd fhd), source, true) == ~w(sd hd)
  end

  test "normalizes an odd source-capped UHD long edge" do
    portrait_source = %{"width" => 3098, "height" => 3397}
    landscape_source = %{"width" => 3397, "height" => 3098}

    assert RenditionSizing.source_allows_size?(portrait_source, "uhd")
    assert RenditionSizing.capped_target_long_edge("qhd", portrait_source) == {:ok, 2560}
    assert RenditionSizing.capped_target_long_edge("uhd", portrait_source) == {:ok, 3396}
    assert RenditionSizing.scaled_resolution("uhd", portrait_source) == {:ok, "3096x3396"}
    assert RenditionSizing.scaled_resolution("uhd", landscape_source) == {:ok, "3396x3096"}
  end
end
