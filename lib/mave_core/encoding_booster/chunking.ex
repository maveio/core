defmodule MaveCore.EncodingBooster.Chunking do
  @moduledoc """
  Shared execution boundary for full-timeline fragmented-MP4 booster work.

  A completed chunk is stored under a deterministic key so a retried flow step
  can reuse it instead of restarting the full transcode after a transport
  interruption.
  """

  @default_threshold_seconds 900
  @default_duration_seconds 600

  @type source_chunk :: %{start_seconds: float(), duration_seconds: float()}

  @spec source_chunks(number() | nil) :: [source_chunk()]
  def source_chunks(duration_seconds) when is_number(duration_seconds) and duration_seconds > 0 do
    duration_seconds = duration_seconds * 1.0

    if duration_seconds > threshold_seconds() do
      build_source_chunks(duration_seconds, duration_seconds_per_chunk())
    else
      [%{start_seconds: 0.0, duration_seconds: duration_seconds}]
    end
  end

  def source_chunks(_duration_seconds), do: [%{start_seconds: 0.0, duration_seconds: 0.0}]

  @spec chunked?([source_chunk()]) :: boolean()
  def chunked?([_single_chunk]), do: false
  def chunked?([_first, _second | _rest]), do: true

  @spec chunk_key(String.t(), keyword(), non_neg_integer()) :: String.t()
  def chunk_key(final_key, options, index)
      when is_binary(final_key) and is_list(options) and is_integer(index) and index >= 0 do
    fingerprint =
      options
      |> Keyword.drop([:input_referer, :on_chunk])
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 12)

    final_key <>
      ".booster/#{fingerprint}/chunk-#{index |> Integer.to_string() |> String.pad_leading(3, "0")}.mp4"
  end

  @spec cumulative_progress((non_neg_integer() -> any()) | nil, non_neg_integer()) ::
          (non_neg_integer() -> any()) | nil
  def cumulative_progress(nil, _completed_bytes), do: nil

  def cumulative_progress(on_chunk, completed_bytes) when is_function(on_chunk, 1) do
    fn chunk_bytes -> on_chunk.(completed_bytes + chunk_bytes) end
  end

  @spec threshold_seconds() :: pos_integer()
  def threshold_seconds do
    positive_integer(:chunking_threshold_seconds, @default_threshold_seconds)
  end

  @spec duration_seconds_per_chunk() :: pos_integer()
  def duration_seconds_per_chunk do
    positive_integer(:chunk_duration_seconds, @default_duration_seconds)
  end

  defp build_source_chunks(duration_seconds, chunk_duration_seconds) do
    chunk_count = ceil(duration_seconds / chunk_duration_seconds)

    Enum.map(0..(chunk_count - 1), fn index ->
      start_seconds = index * chunk_duration_seconds * 1.0

      %{
        start_seconds: start_seconds,
        duration_seconds: min(chunk_duration_seconds * 1.0, duration_seconds - start_seconds)
      }
    end)
  end

  defp positive_integer(key, fallback) do
    case Application.get_env(:mave_core, :encoding_booster, []) |> Keyword.get(key) do
      value when is_integer(value) and value > 0 -> value
      _other -> fallback
    end
  end
end
