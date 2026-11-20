defmodule Mix.Tasks.Perf.EncodingTest do
  use ExUnit.Case, async: false

  import MaveCore.TestSupport.EncodingBenchmarkFixtures

  alias Mix.Tasks.Perf.Encoding

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  defp output do
    receive do
      {:mix_shell, :info, [line]} -> line <> "\n" <> output()
    after
      0 -> ""
    end
  end

  test "--list prints the clips and candidates without encoding" do
    Encoding.run(["--list", "--size", "fhd"])

    listing = output()
    assert listing =~ "fractal-zoom"
    assert listing =~ "production-h264  libx264, preset faster, CRF 20, 8M cap"
  end

  @tag :tmp_dir
  test "--report renders stored results and compares them with an earlier run", %{
    tmp_dir: tmp_dir
  } do
    current = Path.join(tmp_dir, "results.json")
    earlier = Path.join(tmp_dir, "earlier.json")
    File.write!(current, Jason.encode!(results()))
    File.write!(earlier, Jason.encode!(results(%{"tag" => "earlier"})))

    Encoding.run(["--report", current, "--compare", earlier])

    summary = output()
    assert summary =~ "Encoding benchmark fixture"
    assert summary =~ "Compared with earlier"
    assert File.read!(Path.join(tmp_dir, "report.html")) =~ "Changes since earlier"
  end

  @tag :tmp_dir
  test "rejects unknown selections, bad tags and foreign files", %{tmp_dir: tmp_dir} do
    assert_raise Mix.Error, ~r/Unknown candidate nope/, fn ->
      Encoding.run(["--list", "--candidates", "nope"])
    end

    assert_raise Mix.Error, ~r/--tag may only contain/, fn ->
      Encoding.run(["--tag", "../outside"])
    end

    assert_raise Mix.Error, ~r/Unknown arguments/, fn -> Encoding.run(["--bogus"]) end

    path = Path.join(tmp_dir, "other.json")
    File.write!(path, ~s({"schema": 2}))

    assert_raise Mix.Error, ~r/not an encoding benchmark results file/, fn ->
      Encoding.run(["--report", path])
    end
  end
end
