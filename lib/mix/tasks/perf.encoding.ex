defmodule Mix.Tasks.Perf.Encoding do
  use Mix.Task

  alias MaveCore.EncodingBenchmark
  alias MaveCore.EncodingBenchmark.{Candidate, Corpus, Report}

  @shortdoc "Benchmark encoder settings on quality, size, time and playback reach"

  @moduledoc """
  Encodes a set of clips with several encoder settings and compares them with
  the production encoding profile on visual quality, file size, encoding time
  and playback compatibility.

      mix perf.encoding
      mix perf.encoding --tag ffmpeg-7.1 --compare tmp/encoding-benchmark/ffmpeg-6.1/results.json
      mix perf.encoding --source ~/Videos/benchmark --size fhd --duration 10
      mix perf.encoding --candidates production-h264,h264-crf23 --clips fractal-zoom

  Results are written to `--output` (default `tmp/encoding-benchmark/<tag>`)
  as `results.json` and a self-contained `report.html`.

  ## Options

    * `--source DIR` - measure the videos in DIR instead of the built-in
      synthetic clips
    * `--size SIZE` - rendition size: sd, hd, fhd, qhd or uhd (default hd)
    * `--duration SECONDS` - seconds measured per clip (default 6)
    * `--candidates IDS` - comma-separated candidate ids to measure
    * `--candidates-file FILE` - JSON file with additional candidates
    * `--clips IDS` - comma-separated clip ids to measure
    * `--baseline ID` - candidate the others are compared with
    * `--tolerance N` - quality drop that counts as a regression
    * `--tag NAME` - name of this run (default: UTC timestamp)
    * `--output DIR` - directory for the results and report
    * `--compare FILE` - earlier `results.json` to compare this run with
    * `--keep-media` - keep the references and encodes for inspection
    * `--list` - print the available clips and candidates and exit
    * `--report FILE` - render the report for an existing `results.json`
      without encoding anything

  The task needs `ffmpeg` and `ffprobe` on `PATH`. It does not start the
  application or touch a database. See `docs/encoding-benchmarks.md`.
  """

  @switches [
    source: :string,
    size: :string,
    duration: :integer,
    candidates: :string,
    candidates_file: :string,
    clips: :string,
    baseline: :string,
    tolerance: :float,
    tag: :string,
    output: :string,
    compare: :string,
    keep_media: :boolean,
    list: :boolean,
    report: :string
  ]
  @tag_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("Unknown arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}")
    end

    Mix.Task.run("app.config")

    cond do
      opts[:report] -> render_existing(opts)
      opts[:list] -> list(opts)
      true -> benchmark(opts)
    end
  end

  defp benchmark(opts) do
    size = Keyword.get(opts, :size, "hd")
    duration = positive!(Keyword.get(opts, :duration, 6), "--duration")
    tag = tag!(opts)
    previous = opts[:compare] && read_results!(opts[:compare])
    clips = clips!(opts, size)
    candidates = candidates!(opts, size)
    output = Path.expand(opts[:output] || Path.join(["tmp", "encoding-benchmark", tag]))

    info("Measuring #{length(clips)} clips × #{length(candidates)} candidates at #{size}")

    case EncodingBenchmark.run(
           clips: clips,
           candidates: candidates,
           work_dir: output,
           size: size,
           duration: duration,
           baseline: opts[:baseline],
           tag: tag,
           keep_media: Keyword.get(opts, :keep_media, false),
           on_progress: &progress/1
         ) do
      {:ok, results} ->
        results_path = Path.join(output, "results.json")
        File.write!(results_path, Jason.encode!(results, pretty: true))
        report_path = write_report!(results, output, previous, opts)

        info("\n" <> Report.text(results, tolerance: opts[:tolerance]))
        if previous, do: info(Report.comparison_text(results, previous))
        info("Results: #{results_path}")
        info("Report:  #{report_path}")

      {:error, reason} ->
        Mix.raise("Encoding benchmark failed: #{inspect(reason)}")
    end
  end

  defp render_existing(opts) do
    results = read_results!(opts[:report])
    previous = opts[:compare] && read_results!(opts[:compare])
    output = Path.expand(opts[:output] || Path.dirname(opts[:report]))
    report_path = write_report!(results, output, previous, opts)

    info(Report.text(results, tolerance: opts[:tolerance]))
    if previous, do: info(Report.comparison_text(results, previous))
    info("Report: #{report_path}")
  end

  defp list(opts) do
    size = Keyword.get(opts, :size, "hd")

    info("Clips")
    for clip <- clips!(opts, size), do: info("  #{clip.id}  #{clip.description}")

    info("\nCandidates at #{size}")

    for candidate <- candidates!(opts, size) do
      info("  #{candidate.id}  #{Candidate.settings(candidate)}")
    end
  end

  defp write_report!(results, output, previous, opts) do
    File.mkdir_p!(output)
    path = Path.join(output, "report.html")
    File.write!(path, Report.html(results, tolerance: opts[:tolerance], previous: previous))
    path
  end

  defp clips!(opts, size) do
    clips =
      case opts[:source] do
        nil -> Corpus.synthetic(size)
        directory -> Corpus.from_directory(Path.expand(directory))
      end
      |> ok!("Cannot load clips")

    select!(clips, opts[:clips], "clip")
  end

  defp candidates!(opts, size) do
    defaults = size |> Candidate.defaults() |> ok!("Cannot build candidates")

    custom =
      case opts[:candidates_file] do
        nil -> []
        path -> path |> Candidate.load_file() |> ok!("Cannot load #{path}")
      end

    case Enum.find(custom, fn candidate -> Enum.any?(defaults, &(&1.id == candidate.id)) end) do
      nil -> :ok
      %{id: id} -> Mix.raise("Candidate id #{id} is already used by a built-in candidate")
    end

    select!(defaults ++ custom, opts[:candidates], "candidate")
  end

  defp select!(items, nil, _kind), do: items

  defp select!(items, ids, kind) do
    ids
    |> String.split(",", trim: true)
    |> Enum.map(fn id ->
      Enum.find(items, &(&1.id == id)) ||
        Mix.raise("Unknown #{kind} #{id}. Available: #{Enum.map_join(items, ", ", & &1.id)}")
    end)
  end

  defp read_results!(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"schema" => 1, "results" => results} = decoded} when is_list(results) <-
           Jason.decode(body) do
      decoded
    else
      _other -> Mix.raise("#{path} is not an encoding benchmark results file")
    end
  end

  defp tag!(opts) do
    tag = opts[:tag] || Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

    if tag =~ @tag_pattern do
      tag
    else
      Mix.raise("--tag may only contain letters, digits, dots, dashes and underscores")
    end
  end

  defp positive!(value, _option) when is_integer(value) and value > 0, do: value
  defp positive!(_value, option), do: Mix.raise("#{option} must be a positive integer")

  defp ok!({:ok, value}, _message), do: value
  defp ok!({:error, reason}, message), do: Mix.raise("#{message}: #{inspect(reason)}")

  defp progress({:reference, clip}), do: info("  #{clip}: preparing lossless reference")

  defp progress({:result, %{"status" => "ok"} = result, done, total}) do
    quality =
      case result do
        %{"vmaf" => vmaf} when is_number(vmaf) -> "VMAF #{format(vmaf, 2)}"
        %{"ssim_db" => ssim} when is_number(ssim) -> "SSIM #{format(ssim, 2)} dB"
        _other -> "lossless"
      end

    info(
      "  [#{done}/#{total}] #{result["clip"]} · #{result["candidate"]}: " <>
        "#{format(result["bitrate_kbps"], 0)} kbit/s, #{quality}, " <>
        "#{format(result["encode_seconds"], 1)} s (#{format(result["speed"], 1)}× realtime)"
    )
  end

  defp progress({:result, result, done, total}) do
    info(
      "  [#{done}/#{total}] #{result["clip"]} · #{result["candidate"]}: FAILED #{result["error"]}"
    )
  end

  defp format(value, decimals), do: :erlang.float_to_binary(value / 1, decimals: decimals)

  defp info(message), do: Mix.shell().info(message)
end
