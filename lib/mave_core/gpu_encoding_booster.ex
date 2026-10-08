defmodule MaveCore.GpuEncodingBooster do
  @moduledoc """
  Routes eligible video renditions through the private GPU encoding booster.

  Availability is controlled by deployment configuration.
  """

  alias MaveCore.EncodingBooster

  @gpu_h264_sizes ~w(hd fhd qhd uhd)
  @gpu_codecs ~w(hevc av1)

  @spec enabled?() :: boolean()
  def enabled?, do: EncodingBooster.enabled?(:gpu)

  @spec fallback_enabled?() :: boolean()
  def fallback_enabled?, do: EncodingBooster.fallback_enabled?(:gpu)

  @spec encode_to_file(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def encode_to_file(input_url, output_path, opts \\ []) do
    EncodingBooster.encode_to_file(input_url, output_path, Keyword.put(opts, :booster, :gpu))
  end

  @spec eligible_step?(map()) :: boolean()
  def eligible_step?(%{"type" => "media.transcode_h264_ladder"} = step) do
    step
    |> Map.get("params", %{})
    |> requested_sizes()
    |> Enum.all?(&(&1 in @gpu_h264_sizes))
  end

  def eligible_step?(%{"type" => "media.transcode_video"} = step) do
    params = Map.get(step, "params", %{})
    codec = normalize(Map.get(params, "codec", "h264"))
    size = normalize(Map.get(params, "size", "sd"))

    codec in @gpu_codecs or (codec == "h264" and size in @gpu_h264_sizes)
  end

  def eligible_step?(_step), do: false

  defp requested_sizes(params) do
    params
    |> Map.get("sizes", Map.get(params, "variants", Map.get(params, "size", ["sd"])))
    |> List.wrap()
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ["sd"]
      sizes -> sizes
    end
  end

  defp normalize(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize(value) when is_atom(value), do: value |> Atom.to_string() |> normalize()
  defp normalize(_value), do: nil
end
