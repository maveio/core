defmodule MaveCore.EncodingBenchmark.CorpusTest do
  use ExUnit.Case, async: true

  alias MaveCore.EncodingBenchmark.Corpus

  test "synthetic/1 sizes the built-in clips for the rendition" do
    assert {:ok, clips} = Corpus.synthetic("fhd")

    assert Enum.map(clips, & &1.id) == ~w(motion-graphics fractal-zoom grainy-gradient slides)
    assert Enum.all?(clips, fn %{source: {:synthetic, graph}} -> graph =~ "size=1920x1080" end)
    assert {:error, {:unsupported_size, "8k"}} = Corpus.synthetic("8k")
  end

  @tag :tmp_dir
  test "from_directory/1 lists videos with unique, path-safe ids", %{tmp_dir: tmp_dir} do
    for name <- ["Interview (final).MOV", "interview final.mp4", "notes.txt", "../b roll.mkv"] do
      File.write!(Path.join(tmp_dir, Path.basename(name)), "")
    end

    assert {:ok, clips} = Corpus.from_directory(tmp_dir)

    assert Enum.map(clips, & &1.id) == ["interview-final", "b-roll", "interview-final-2"]
    assert {:file, path} = hd(clips).source
    assert path == Path.join(tmp_dir, "Interview (final).MOV")
  end

  @tag :tmp_dir
  test "from_directory/1 rejects a directory without videos", %{tmp_dir: tmp_dir} do
    assert {:error, {:no_videos_found, ^tmp_dir}} = Corpus.from_directory(tmp_dir)

    assert {:error, {:unreadable_source_directory, _path, :enoent}} =
             Corpus.from_directory(Path.join(tmp_dir, "missing"))
  end

  test "reference_args/4 writes a lossless 8-bit reference at the rendition size" do
    {:ok, [clip | _]} = Corpus.synthetic("sd")

    assert {:ok, args} = Corpus.reference_args(clip, "sd", 3, "ref.mp4")
    assert Enum.join(args, " ") =~ "-f lavfi -i testsrc2=size=640x360:rate=30 -t 3"

    assert Enum.join(args, " ") =~
             "-c:v libx264 -qp 0 -preset ultrafast -pix_fmt yuv420p -an ref.mp4"

    file_clip = %{id: "upload", description: "upload.mov", source: {:file, "/videos/upload.mov"}}

    assert {:ok, args} = Corpus.reference_args(file_clip, "hd", 6, "ref.mp4")

    assert Enum.join(args, " ") =~
             "-i /videos/upload.mov -vf scale=iw*sar:ih,setsar=1,scale=w=1280:h=1280"
  end
end
