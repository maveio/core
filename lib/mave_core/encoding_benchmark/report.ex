defmodule MaveCore.EncodingBenchmark.Report do
  @moduledoc """
  Renders stored `MaveCore.EncodingBenchmark` results as a terminal summary or
  as a self-contained HTML report.

  The HTML report has no external assets, so it can be archived next to the
  results and opened later without network access.
  """

  alias MaveCore.EncodingBenchmark.Summary

  @codec_order ~w(h264 hevc av1)
  @codec_labels %{"h264" => "H.264", "hevc" => "HEVC", "av1" => "AV1"}
  @tier_labels %{
    "universal" => "universal",
    "needs_fallback" => "needs fallback",
    "not_web_safe" => "not web-safe"
  }

  # Terminal summary

  @doc "Formats the candidate and per-video tables for terminal output."
  @spec text(map(), keyword()) :: String.t()
  def text(results, opts \\ []) do
    metric = Summary.metric(results)
    tolerance = Keyword.get(opts, :tolerance) || metric.tolerance
    rows = Summary.candidates(results, tolerance)
    picks = Summary.per_clip_picks(results, tolerance)
    quality_heading = String.trim("#{metric.label} #{metric.unit}")

    candidate_table =
      table(
        ["Candidate", "Codec", "Size", "vs base", quality_heading, "Δ avg", "Δ worst clip"] ++
          ["Time", "vs base", "Playback"],
        Enum.map(rows, fn row ->
          [
            row.id <> if(row.baseline?, do: " *", else: ""),
            Map.get(@codec_labels, row.codec, row.codec),
            bytes(row.bytes),
            if(row.baseline?, do: "—", else: percent(row.size_change)),
            number(row.quality, 2),
            if(row.baseline?, do: "—", else: signed(row.quality_delta, 2)),
            worst_cell(row),
            seconds(row.encode_seconds),
            if(row.baseline?, do: "—", else: times(row.time_ratio)),
            tier_label(row.compatibility) <> failed_suffix(row)
          ]
        end)
      )

    pick_table =
      table(
        ["Clip", "Smallest qualifying encode", "Size", "vs base", "Δ quality"],
        Enum.map(picks.picks, fn pick ->
          [
            pick.clip,
            pick.candidate,
            bytes(pick.bytes),
            percent(pick.size_change),
            signed(pick.quality_delta, 2)
          ]
        end)
      )

    """
    #{headline(results)}
    #{environment_line(results)}

    #{candidate_table}
    * baseline. ! marks a clip that loses more than #{number(tolerance, 2)} #{quality_heading}.

    Per-video selection: smallest encode within #{number(tolerance, 2)} #{quality_heading} of the baseline, same playback reach
    #{pick_table}
    #{picks_line(picks)}
    """
    |> append_warnings(results)
  end

  @doc "Formats the differences between two runs for terminal output."
  @spec comparison_text(map(), map()) :: String.t()
  def comparison_text(current, previous) do
    metric = Summary.metric(current)

    changes =
      case Summary.environment_changes(current, previous) do
        [] -> "Same FFmpeg version, CPU count and settings."
        changes -> "Changed between runs: " <> Enum.join(changes, "; ")
      end

    rows =
      current
      |> Summary.compare(previous)
      |> Enum.map(fn row ->
        [
          row.clip,
          row.candidate,
          percent(row.size_change),
          signed(row.quality_delta, 2),
          percent(row.time_change)
        ]
      end)

    """
    Compared with #{previous["tag"]} (#{previous["started_at"]})
    #{changes}

    #{table(["Clip", "Candidate", "Size", "Δ #{metric.label}", "Time"], rows)}
    """
  end

  defp headline(results) do
    settings = results["settings"]

    "Encoding benchmark #{results["tag"]}: #{length(results["clips"])} clips × " <>
      "#{length(results["candidates"])} candidates at #{settings["size"]}, " <>
      "#{settings["duration_seconds"]} s per clip"
  end

  defp environment_line(results) do
    environment = results["environment"]

    "FFmpeg #{environment["ffmpeg_version"]}, #{environment["logical_cpus"]} logical CPUs, " <>
      "production profile #{environment["production_profile"]}" <>
      if(environment["vmaf"], do: "", else: ". VMAF not measured: FFmpeg has no libvmaf filter")
  end

  defp picks_line(%{picks: []}), do: "No clip has a successful baseline encode."

  defp picks_line(picks) do
    best =
      case picks.best_single do
        nil ->
          "no other candidate qualifies on every clip"

        %{candidate: candidate, size_change: change} ->
          "smallest candidate that qualifies on every clip: #{candidate} (#{percent(change)})"
      end

    "Total #{bytes(picks.bytes)} (#{percent(picks.size_change)} vs baseline); #{best}"
  end

  defp append_warnings(text, %{"warnings" => [_ | _] = warnings}),
    do: text <> "\n" <> Enum.map_join(warnings, "\n", &"Warning: #{&1}") <> "\n"

  defp append_warnings(text, _results), do: text

  defp worst_cell(%{baseline?: true}), do: "—"
  defp worst_cell(%{worst_delta: nil}), do: "n/a"

  defp worst_cell(row) do
    "#{signed(row.worst_delta, 2)} #{row.worst_clip}" <>
      if(row.regressions > 0, do: " !", else: "")
  end

  defp failed_suffix(%{failed: 0}), do: ""
  defp failed_suffix(%{failed: failed}), do: " (#{failed} failed)"

  defp table(headers, rows) do
    widths =
      [headers | rows]
      |> Enum.zip_with(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    line = fn cells ->
      cells
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
      |> String.trim_trailing()
    end

    Enum.map_join([headers, Enum.map(widths, &String.duplicate("-", &1)) | rows], "\n", line)
  end

  # HTML report

  @doc """
  Renders the HTML report.

  Options: `:tolerance` overrides the quality tolerance and `:previous` adds a
  section comparing against an earlier run.
  """
  @spec html(map(), keyword()) :: String.t()
  def html(results, opts \\ []) do
    metric = Summary.metric(results)
    tolerance = Keyword.get(opts, :tolerance) || metric.tolerance
    rows = Summary.candidates(results, tolerance)
    picks = Summary.per_clip_picks(results, tolerance)
    quality_heading = String.trim("#{metric.label} #{metric.unit}")

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Encoding benchmark #{esc(results["tag"])}</title>
    <style>#{css()}</style>
    </head>
    <body>
    <main>
    <header>
      <p class="eyebrow">Encoding benchmark</p>
      <h1>#{esc(results["tag"])}</h1>
      <p class="meta">#{esc(headline(results))}. #{esc(environment_line(results))}. Started #{esc(results["started_at"])}.</p>
    </header>
    #{warnings_html(results)}
    <section>
      <h2>Candidates against the baseline</h2>
      <p class="note">Size and time cover the clips both encodes completed. A clip regresses when it loses more than #{number(tolerance, 2)} #{esc(quality_heading)} against the baseline.</p>
      #{candidates_html(rows, quality_heading)}
    </section>
    <section>
      <h2>Per-video selection</h2>
      <p class="note">The smallest encode per clip that stays within #{number(tolerance, 2)} #{esc(quality_heading)} of the baseline and keeps its playback reach. #{esc(picks_line(picks))}.</p>
      #{picks_html(picks)}
    </section>
    <section>
      <h2>Size against quality per clip</h2>
      <p class="note">Up and to the left is better: higher quality at a lower bitrate. The ringed point is the baseline.</p>
      #{legend_html(results)}
      <div class="charts">#{Enum.map_join(results["clips"], "\n", &chart_html(&1, results, metric))}</div>
    </section>
    #{comparison_html(results, Keyword.get(opts, :previous), metric)}
    <section>
      <h2>All measurements</h2>
      #{measurements_html(results)}
    </section>
    <section>
      <h2>Candidate settings</h2>
      #{settings_html(results)}
    </section>
    <footer>
      <p>Encodes are compared with a lossless reference at the rendition size, so the numbers isolate encoder settings from source decoding and scaling. Encoding time is one wall-clock measurement on this machine. Playback reach is a static assessment of codec, profile and pixel format, not a device test.</p>
    </footer>
    </main>
    </body>
    </html>
    """
  end

  defp warnings_html(%{"warnings" => [_ | _] = warnings}) do
    items = Enum.map_join(warnings, "", &"<li>#{esc(&1)}</li>")
    ~s(<section class="warnings"><h2>Warnings</h2><ul>#{items}</ul></section>)
  end

  defp warnings_html(_results), do: ""

  defp candidates_html(rows, quality_heading) do
    body =
      Enum.map_join(rows, "\n", fn row ->
        """
        <tr#{if row.baseline?, do: ~s( class="baseline"), else: ""}>
          <th scope="row">#{codec_dot(row.codec)}#{esc(row.id)}#{if row.baseline?, do: ~s( <span class="tag">baseline</span>), else: ""}<small>#{esc(row.settings)}</small></th>
          <td class="num">#{bytes(row.bytes)}</td>
          <td class="num strong">#{if row.baseline?, do: "—", else: percent(row.size_change)}</td>
          <td class="num">#{number(row.quality, 2)}</td>
          <td class="num">#{if row.baseline?, do: "—", else: signed(row.quality_delta, 2)}</td>
          <td>#{verdict_html(row)}</td>
          <td class="num">#{seconds(row.encode_seconds)}</td>
          <td class="num">#{if row.baseline?, do: "—", else: times(row.time_ratio)}</td>
          <td>#{esc(tier_label(row.compatibility))}#{esc(failed_suffix(row))}</td>
          <td class="num">#{keyframes(row.max_keyframe_interval)}</td>
        </tr>
        """
      end)

    """
    <div class="scroll"><table>
    <thead><tr>
      <th scope="col">Candidate</th><th scope="col" class="num">Size</th><th scope="col" class="num">vs baseline</th>
      <th scope="col" class="num">#{esc(quality_heading)}</th><th scope="col" class="num">Δ average</th><th scope="col">Worst clip</th>
      <th scope="col" class="num">Encode time</th><th scope="col" class="num">vs baseline</th><th scope="col">Playback</th>
      <th scope="col" class="num">Longest GOP</th>
    </tr></thead>
    <tbody>#{body}</tbody>
    </table></div>
    """
  end

  defp verdict_html(%{baseline?: true}), do: "—"
  defp verdict_html(%{worst_delta: nil}), do: "n/a"

  defp verdict_html(%{regressions: 0} = row) do
    ~s(<span class="status ok">✓ within tolerance</span><small>#{signed(row.worst_delta, 2)} on #{esc(row.worst_clip)}</small>)
  end

  defp verdict_html(row) do
    clips =
      if row.regressions == 1, do: "1 clip regresses", else: "#{row.regressions} clips regress"

    ~s(<span class="status warn">⚠ #{clips}</span><small>#{signed(row.worst_delta, 2)} on #{esc(row.worst_clip)}</small>)
  end

  defp picks_html(%{picks: []}), do: ""

  defp picks_html(picks) do
    body =
      Enum.map_join(picks.picks, "\n", fn pick ->
        """
        <tr><th scope="row">#{esc(pick.clip)}</th><td>#{esc(pick.candidate)}</td>
        <td class="num">#{bytes(pick.bytes)}</td><td class="num strong">#{percent(pick.size_change)}</td>
        <td class="num">#{signed(pick.quality_delta, 2)}</td></tr>
        """
      end)

    """
    <div class="scroll"><table>
    <thead><tr><th scope="col">Clip</th><th scope="col">Smallest qualifying encode</th><th scope="col" class="num">Size</th>
    <th scope="col" class="num">vs baseline</th><th scope="col" class="num">Δ quality</th></tr></thead>
    <tbody>#{body}</tbody>
    <tfoot><tr><th scope="row">Total</th><td></td><td class="num">#{bytes(picks.bytes)}</td>
    <td class="num strong">#{percent(picks.size_change)}</td><td></td></tr></tfoot>
    </table></div>
    """
  end

  defp legend_html(results) do
    codecs = results["candidates"] |> Enum.map(& &1["codec"]) |> Enum.uniq()

    items =
      @codec_order
      |> Enum.filter(&(&1 in codecs))
      |> Enum.map_join("", &"<li>#{codec_dot(&1)}#{Map.fetch!(@codec_labels, &1)}</li>")

    ~s(<ul class="legend">#{items}<li><span class="ring"></span>baseline</li></ul>)
  end

  defp measurements_html(results) do
    vmaf? = results["environment"]["vmaf"]

    body =
      Enum.map_join(results["results"], "\n", fn
        %{"status" => "ok"} = result ->
          """
          <tr><th scope="row">#{esc(result["clip"])}</th><td>#{esc(result["candidate"])}</td>
          <td class="num">#{bytes(result["bytes"])}</td><td class="num">#{number(result["bitrate_kbps"], 0)}</td>
          #{if vmaf?, do: ~s(<td class="num">#{number(result["vmaf"], 2)}</td>), else: ""}
          <td class="num">#{number(result["ssim_db"], 2)}</td><td class="num">#{number(result["psnr"], 2)}</td>
          <td class="num">#{seconds(result["encode_seconds"])}</td><td class="num">#{times(result["speed"])}</td>
          <td>#{esc(result["profile"])} #{esc(result["pixel_format"])}</td>
          <td title="#{esc(result["compatibility_note"])}">#{esc(tier_label(result["compatibility"]))}</td></tr>
          """

        result ->
          """
          <tr><th scope="row">#{esc(result["clip"])}</th><td>#{esc(result["candidate"])}</td>
          <td colspan="#{if vmaf?, do: 9, else: 8}"><span class="status warn">⚠ failed</span> #{esc(result["error"])}</td></tr>
          """
      end)

    """
    <div class="scroll"><table>
    <thead><tr><th scope="col">Clip</th><th scope="col">Candidate</th><th scope="col" class="num">Size</th>
    <th scope="col" class="num">kbit/s</th>#{if vmaf?, do: ~s(<th scope="col" class="num">VMAF</th>), else: ""}
    <th scope="col" class="num">SSIM dB</th><th scope="col" class="num">PSNR dB</th>
    <th scope="col" class="num">Encode time</th><th scope="col" class="num">Speed</th>
    <th scope="col">Stream</th><th scope="col">Playback</th></tr></thead>
    <tbody>#{body}</tbody>
    </table></div>
    """
  end

  defp settings_html(results) do
    body =
      Enum.map_join(results["candidates"], "\n", fn candidate ->
        args = candidate["ffmpeg_args"] |> List.wrap() |> Enum.join(" ")

        """
        <tr><th scope="row">#{codec_dot(candidate["codec"])}#{esc(candidate["id"])}<small>#{esc(candidate["description"])}</small></th>
        <td><code>ffmpeg #{esc(args)}</code></td></tr>
        """
      end)

    """
    <div class="scroll"><table>
    <thead><tr><th scope="col">Candidate</th><th scope="col">Command</th></tr></thead>
    <tbody>#{body}</tbody>
    </table></div>
    """
  end

  defp comparison_html(_results, nil, _metric), do: ""

  defp comparison_html(results, previous, metric) do
    changes =
      case Summary.environment_changes(results, previous) do
        [] -> "Same FFmpeg version, CPU count and settings."
        changes -> "Changed between runs: " <> Enum.join(changes, "; ") <> "."
      end

    body =
      results
      |> Summary.compare(previous)
      |> Enum.map_join("\n", fn row ->
        """
        <tr><th scope="row">#{esc(row.clip)}</th><td>#{esc(row.candidate)}</td>
        <td class="num strong">#{percent(row.size_change)}</td><td class="num">#{signed(row.quality_delta, 2)}</td>
        <td class="num">#{percent(row.time_change)}</td></tr>
        """
      end)

    """
    <section>
      <h2>Changes since #{esc(previous["tag"])}</h2>
      <p class="note">#{esc(changes)} Encoding time is only comparable on the same hardware.</p>
      <div class="scroll"><table>
      <thead><tr><th scope="col">Clip</th><th scope="col">Candidate</th><th scope="col" class="num">Size</th>
      <th scope="col" class="num">Δ #{esc(metric.label)}</th><th scope="col" class="num">Encode time</th></tr></thead>
      <tbody>#{body}</tbody>
      </table></div>
    </section>
    """
  end

  # Charts

  @chart_width 520
  @chart_height 320
  @plot %{left: 52, right: 16, top: 14, bottom: 40}

  defp chart_html(clip, results, metric) do
    baseline_id = results["settings"]["baseline"]
    codecs = Map.new(results["candidates"], &{&1["id"], &1["codec"]})

    points =
      results["results"]
      |> Enum.filter(&(&1["clip"] == clip["id"] and &1["status"] == "ok"))
      |> Enum.map(fn result ->
        %{
          id: result["candidate"],
          codec: Map.get(codecs, result["candidate"]),
          bitrate: result["bitrate_kbps"] / 1,
          quality: Summary.quality(result, metric),
          bytes: result["bytes"],
          baseline?: result["candidate"] == baseline_id
        }
      end)

    body =
      case points do
        [] -> ~s(<p class="note">No successful encodes for this clip.</p>)
        points -> scatter_svg(points, metric, clip["id"])
      end

    """
    <figure>
      <figcaption><strong>#{esc(clip["id"])}</strong><span>#{esc(clip["description"])}</span></figcaption>
      #{body}
    </figure>
    """
  end

  defp scatter_svg(points, metric, clip_id) do
    plot_width = @chart_width - @plot.left - @plot.right
    plot_height = @chart_height - @plot.top - @plot.bottom
    x_ticks = ticks(0.0, points |> Enum.map(& &1.bitrate) |> Enum.max())
    {quality_min, quality_max} = points |> Enum.map(& &1.quality) |> Enum.min_max()
    y_ticks = ticks(quality_min, quality_max)
    {x_min, x_max} = {hd(x_ticks), List.last(x_ticks)}
    {y_min, y_max} = {hd(y_ticks), List.last(y_ticks)}
    x = fn value -> @plot.left + (value - x_min) / (x_max - x_min) * plot_width end
    y = fn value -> @plot.top + plot_height - (value - y_min) / (y_max - y_min) * plot_height end
    quality_title = String.trim("#{metric.label} #{metric.unit}")

    grid =
      Enum.map_join(y_ticks, "", fn tick ->
        ~s(<line class="grid" x1="#{@plot.left}" x2="#{@chart_width - @plot.right}" y1="#{px(y.(tick))}" y2="#{px(y.(tick))}"/>) <>
          ~s(<text class="tick" x="#{@plot.left - 8}" y="#{px(y.(tick) + 4)}" text-anchor="end">#{tick_label(tick)}</text>)
      end) <>
        Enum.map_join(x_ticks, "", fn tick ->
          ~s(<text class="tick" x="#{px(x.(tick))}" y="#{@chart_height - @plot.bottom + 16}" text-anchor="middle">#{tick_label(tick)}</text>)
        end)

    placed =
      points
      |> Enum.map(&Map.merge(&1, %{cx: x.(&1.bitrate), cy: y.(&1.quality)}))
      |> place_labels(plot_width)

    marks =
      Enum.map_join(placed, "", fn point ->
        ring =
          if point.baseline?,
            do: ~s(<circle class="ring" cx="#{px(point.cx)}" cy="#{px(point.cy)}" r="9"/>),
            else: ""

        """
        <g class="point">
          <title>#{esc(point.id)}: #{number(point.bitrate, 0)} kbit/s, #{esc(quality_title)} #{number(point.quality, 2)}, #{bytes(point.bytes)}</title>
          #{ring}<circle class="dot #{esc(point.codec)}" cx="#{px(point.cx)}" cy="#{px(point.cy)}" r="5"/>
          <circle class="hit" cx="#{px(point.cx)}" cy="#{px(point.cy)}" r="14"/>
          #{leader_svg(point)}<text class="label" x="#{px(point.label_x)}" y="#{px(point.label_y)}" text-anchor="#{point.anchor}">#{esc(point.id)}</text>
        </g>
        """
      end)

    """
    <svg viewBox="0 0 #{@chart_width} #{@chart_height}" role="img" aria-label="#{esc(quality_title)} against bitrate for #{esc(clip_id)}">
      #{grid}
      <line class="axis" x1="#{@plot.left}" x2="#{@chart_width - @plot.right}" y1="#{@chart_height - @plot.bottom}" y2="#{@chart_height - @plot.bottom}"/>
      <text class="axis-title" x="#{@plot.left + plot_width / 2}" y="#{@chart_height - 6}" text-anchor="middle">Bitrate (kbit/s)</text>
      <text class="axis-title" x="#{@plot.left}" y="10" text-anchor="start">#{esc(quality_title)}</text>
      #{marks}
    </svg>
    """
  end

  defp leader_svg(%{displaced?: false}), do: ""

  defp leader_svg(point) do
    ~s(<line class="leader" x1="#{px(point.cx)}" y1="#{px(point.cy)}" x2="#{px(point.label_x)}" y2="#{px(point.label_y - 4)}"/>)
  end

  # Labels sit beside their point. When that spot is taken, the other side and
  # then rows further away are tried; a displaced label gets a leader line.
  defp place_labels(points, plot_width) do
    bounds =
      {@plot.left + 2, @plot.left + plot_width, @plot.top + 8, @chart_height - @plot.bottom - 3}

    points
    |> Enum.sort_by(&{&1.cy, &1.cx})
    |> Enum.reduce([], fn point, placed ->
      width = String.length(point.id) * 6.4
      prefer_left? = point.cx > @plot.left + plot_width * 0.62
      sides = if prefer_left?, do: [:left, :right], else: [:right, :left]

      slots =
        for row <- [0, 1, -1, 2, -2, 3, -3, 4, -4], side <- sides do
          label_slot(point, side, row, width)
        end

      slot =
        Enum.find(slots, &(inside?(&1, bounds) and free?(&1, placed))) ||
          Enum.find(slots, &free?(&1, placed)) || hd(slots)

      [Map.merge(point, slot) | placed]
    end)
    |> Enum.reverse()
  end

  defp label_slot(point, side, row, width) do
    label_x = if side == :left, do: point.cx - 12, else: point.cx + 12

    %{
      label_x: label_x,
      label_y: point.cy + 4 + row * 13,
      span: if(side == :left, do: {label_x - width, label_x}, else: {label_x, label_x + width}),
      anchor: if(side == :left, do: "end", else: "start"),
      displaced?: row != 0
    }
  end

  defp inside?(%{span: {from, to}, label_y: label_y}, {left, right, top, bottom}) do
    from >= left and to <= right and label_y >= top and label_y <= bottom
  end

  defp free?(%{span: {from, to}, label_y: label_y}, placed) do
    not Enum.any?(placed, fn other ->
      {other_from, other_to} = other.span

      (abs(other.label_y - label_y) < 13 and from < other_to + 4 and other_from < to + 4) or
        (abs(other.cy + 4 - label_y) < 10 and other.cx > from - 8 and other.cx < to + 8)
    end)
  end

  # Returns four to six round tick values that enclose the data range.
  defp ticks(min, max) do
    span = if max - min <= 0, do: max(abs(max), 1.0) * 0.1, else: max - min
    raw = span / 4
    magnitude = :math.pow(10, Float.floor(:math.log10(raw)))
    step = Enum.find([1, 2, 2.5, 5, 10], &(&1 * magnitude >= raw)) * magnitude
    first = Float.floor(min / step) * step
    last = Float.ceil(max / step) * step
    last = if last == first, do: first + step, else: last
    count = round((last - first) / step)
    Enum.map(0..count, &(first + &1 * step))
  end

  defp tick_label(value) do
    cond do
      value == Float.round(value) ->
        Integer.to_string(round(value))

      Float.round(value, 1) == Float.round(value, 2) ->
        :erlang.float_to_binary(value, decimals: 1)

      true ->
        :erlang.float_to_binary(value, decimals: 2)
    end
  end

  defp px(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  defp codec_dot(codec) when codec in @codec_order, do: ~s(<span class="swatch #{codec}"></span>)
  defp codec_dot(_codec), do: ""

  # Formatting

  defp bytes(nil), do: "n/a"
  defp bytes(bytes) when bytes >= 1_000_000, do: "#{number(bytes / 1_000_000, 2)} MB"
  defp bytes(bytes), do: "#{number(bytes / 1000, 1)} kB"

  defp percent(nil), do: "n/a"
  defp percent(value), do: signed(value, 1) <> "%"

  defp signed(nil, _decimals), do: "n/a"

  defp signed(value, decimals) do
    rounded = Float.round(value / 1, decimals)

    cond do
      rounded > 0 -> "+" <> number(rounded, decimals)
      rounded < 0 -> "−" <> number(abs(rounded), decimals)
      true -> number(0.0, decimals)
    end
  end

  defp number(nil, _decimals), do: "n/a"
  defp number(value, decimals), do: :erlang.float_to_binary(value / 1, decimals: decimals)

  defp seconds(nil), do: "n/a"
  defp seconds(value), do: number(value, 1) <> " s"

  defp times(nil), do: "n/a"
  defp times(value), do: number(value, 2) <> "×"

  defp keyframes(nil), do: "n/a"
  defp keyframes(value), do: number(value, 1) <> " s"

  defp tier_label(nil), do: "n/a"

  defp tier_label(tier), do: Map.get(@tier_labels, tier, to_string(tier))

  defp esc(nil), do: ""
  defp esc(value), do: value |> to_string() |> Plug.HTML.html_escape()

  defp css do
    """
    :root{color-scheme:light;--surface:#fcfcfb;--raised:#f3f2ee;--border:#dedcd4;--text:#0b0b0b;--muted:#52514e;
    --h264:#2a78d6;--hevc:#eb6834;--av1:#1baf7a;--ok:#1d6b3a;--warn:#8a4b00}
    @media (prefers-color-scheme:dark){:root{color-scheme:dark;--surface:#1a1a19;--raised:#242422;--border:#3a3a37;
    --text:#f0efec;--muted:#c3c2b7;--h264:#3987e5;--hevc:#d95926;--av1:#199e70;--ok:#6fcf8f;--warn:#f0b35a}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--surface);color:var(--text);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
    main{max-width:1240px;margin:0 auto;padding:32px 16px 56px}
    h1{font-size:28px;line-height:1.2;margin:0 0 8px}
    h2{font-size:18px;margin:0 0 6px}
    section{margin-top:40px}
    .eyebrow{margin:0;color:var(--muted);font-size:13px;letter-spacing:.06em;text-transform:uppercase}
    .meta,.note,footer p{color:var(--muted);max-width:78ch;margin:0 0 14px}
    footer{margin-top:40px;border-top:1px solid var(--border);padding-top:16px;font-size:13px}
    .scroll{overflow-x:auto;border:1px solid var(--border);border-radius:8px}
    table{border-collapse:collapse;width:100%;font-size:14px}
    th,td{padding:8px 10px;text-align:left;border-bottom:1px solid var(--border);vertical-align:top;white-space:nowrap}
    tbody tr:last-child>*{border-bottom:0}
    thead th,tfoot th,tfoot td{background:var(--raised);font-weight:600}
    thead th{font-size:12px;color:var(--muted)}
    tfoot th,tfoot td{border-top:1px solid var(--border);border-bottom:0}
    tbody th{font-weight:600}
    .num{text-align:right;font-variant-numeric:tabular-nums}
    .strong{font-weight:600}
    small{display:block;color:var(--muted);font-weight:400;font-size:12px}
    tr.baseline>*{background:var(--raised)}
    .tag{font-size:11px;font-weight:600;border:1px solid var(--border);border-radius:99px;padding:1px 7px;margin-left:6px;color:var(--muted)}
    .status{font-weight:600}.status.ok{color:var(--ok)}.status.warn{color:var(--warn)}
    code{font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:normal;word-break:break-word}
    .warnings ul{margin:0;padding-left:20px;color:var(--warn)}
    .swatch{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:7px}
    .swatch.h264,.dot.h264{background:var(--h264);fill:var(--h264)}
    .swatch.hevc,.dot.hevc{background:var(--hevc);fill:var(--hevc)}
    .swatch.av1,.dot.av1{background:var(--av1);fill:var(--av1)}
    .legend{display:flex;flex-wrap:wrap;gap:6px 18px;list-style:none;margin:0 0 12px;padding:0;font-size:13px;color:var(--muted)}
    .legend li{display:flex;align-items:center}
    .legend .ring{display:inline-block;width:14px;height:14px;border-radius:50%;border:2px solid var(--text);margin-right:7px}
    .charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,440px),1fr));gap:16px}
    figure{margin:0;border:1px solid var(--border);border-radius:8px;padding:12px}
    figcaption{display:flex;flex-direction:column;margin-bottom:6px}
    figcaption span{color:var(--muted);font-size:13px}
    svg{display:block;width:100%;height:auto}
    .grid{stroke:var(--border);stroke-width:1}
    .leader{stroke:var(--muted);stroke-width:1;opacity:.6}
    .axis{stroke:var(--muted);stroke-width:1}
    .tick,.axis-title{fill:var(--muted);font-size:11px}
    .label{fill:var(--text);font-size:11px}
    .dot{stroke:var(--surface);stroke-width:2}
    svg .ring{fill:none;stroke:var(--text);stroke-width:2}
    .hit{fill:transparent}
    .point:hover .dot{stroke:var(--text)}
    .point:hover .label{font-weight:700}
    """
  end
end
