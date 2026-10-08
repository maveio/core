defmodule MaveCore.EncodingBooster.Bundle do
  @moduledoc false

  import Bitwise, only: [band: 2]

  alias MaveCore.SafeFile

  @media_entry "encoded.mp4"
  @playlist_entry "hls/playlist.m3u8"
  @init_entry "hls/init.mp4"
  @segment_entry ~r/\Ahls\/segment_[0-9]{3,6}\.m4s\z/
  @max_entries 20_000
  @local_file_header_bytes 30
  @data_descriptor_bytes 16
  @copy_chunk_bytes 1_048_576

  @spec extract(String.t(), String.t()) :: {:ok, %{hls_dir: String.t()}} | {:error, term()}
  def extract(bundle_path, output_path)
      when is_binary(bundle_path) and is_binary(output_path) do
    extract_root = output_path <> ".bundle"

    try do
      with :ok <- SafeFile.mkdir_p(extract_root),
           {:ok, entries} <- list_entries(bundle_path),
           :ok <- validate_entries(entries, true),
           :ok <- extract_entries(bundle_path, extract_root, entries),
           :ok <- move_media_file(extract_root, output_path),
           {:ok, hls_dir} <- validate_hls_dir(extract_root) do
        {:ok, %{hls_dir: hls_dir}}
      else
        {:error, reason} ->
          _ = SafeFile.rm_rf(extract_root)
          {:error, reason}
      end
    rescue
      _error ->
        _ = SafeFile.rm_rf(extract_root)
        {:error, :invalid_encoding_booster_bundle}
    catch
      _kind, _reason ->
        _ = SafeFile.rm_rf(extract_root)
        {:error, :invalid_encoding_booster_bundle}
    end
  end

  def extract(_bundle_path, _output_path), do: {:error, :invalid_encoding_booster_bundle}

  @spec extract_hls(String.t(), String.t()) ::
          {:ok, %{hls_dir: String.t()}} | {:error, term()}
  def extract_hls(bundle_path, extract_root)
      when is_binary(bundle_path) and is_binary(extract_root) do
    with :ok <- SafeFile.mkdir_p(extract_root),
         {:ok, entries} <- list_entries(bundle_path),
         :ok <- validate_entries(entries, false),
         :ok <- extract_entries(bundle_path, extract_root, entries),
         {:ok, hls_dir} <- validate_hls_dir(extract_root) do
      {:ok, %{hls_dir: hls_dir}}
    else
      {:error, reason} ->
        _ = SafeFile.rm_rf(extract_root)
        {:error, reason}
    end
  rescue
    _error ->
      _ = SafeFile.rm_rf(extract_root)
      {:error, :invalid_encoding_booster_bundle}
  catch
    _kind, _reason ->
      _ = SafeFile.rm_rf(extract_root)
      {:error, :invalid_encoding_booster_bundle}
  end

  def extract_hls(_bundle_path, _extract_root),
    do: {:error, :invalid_encoding_booster_bundle}

  defp list_entries(bundle_path) do
    case :zip.list_dir(String.to_charlist(bundle_path)) do
      {:ok, entries} -> {:ok, Enum.filter(entries, &match?({:zip_file, _, _, _, _, _}, &1))}
      {:error, reason} -> {:error, {:invalid_encoding_booster_bundle, reason}}
    end
  end

  defp validate_entries(entries, require_media?) when length(entries) <= @max_entries do
    names = Enum.map(entries, &entry_name/1)

    with :ok <- validate_entry_names(names),
         :ok <- validate_required_entries(names, require_media?),
         true <- Enum.all?(entries, &valid_entry?(&1, require_media?)) do
      :ok
    else
      false -> {:error, :invalid_encoding_booster_bundle_entry}
      {:error, _reason} = error -> error
    end
  end

  defp validate_entries(_entries, _require_media?),
    do: {:error, :encoding_booster_bundle_too_large}

  defp validate_entry_names(names) do
    cond do
      Enum.any?(names, &is_nil/1) ->
        {:error, :invalid_encoding_booster_bundle_entry}

      length(names) != length(Enum.uniq(names)) ->
        {:error, :duplicate_encoding_booster_bundle_entry}

      true ->
        :ok
    end
  end

  defp validate_required_entries(names, require_media?) do
    cond do
      not (@playlist_entry in names and @init_entry in names) ->
        {:error, :incomplete_encoding_booster_bundle}

      require_media? and @media_entry not in names ->
        {:error, :incomplete_encoding_booster_bundle}

      not require_media? and @media_entry in names ->
        {:error, :invalid_encoding_booster_bundle_entry}

      true ->
        :ok
    end
  end

  defp valid_entry?(
         {:zip_file, name, file_info, _comment, _offset, compressed_size},
         allow_media?
       ) do
    name = List.to_string(name)
    size = elem(file_info, 1)
    type = elem(file_info, 2)

    type == :regular and compressed_size == size and allowed_name?(name, allow_media?)
  end

  defp valid_entry?(_entry, _allow_media?), do: false

  defp allowed_name?(@media_entry, allow_media?), do: allow_media?
  defp allowed_name?(@playlist_entry, _allow_media?), do: true
  defp allowed_name?(@init_entry, _allow_media?), do: true
  defp allowed_name?(name, _allow_media?), do: Regex.match?(@segment_entry, name)

  defp entry_name({:zip_file, name, _file_info, _comment, _offset, _compressed_size}),
    do: List.to_string(name)

  defp entry_name(_entry), do: nil

  defp extract_entries(bundle_path, extract_root, entries) do
    file_list = Enum.map(entries, fn entry -> entry |> entry_name() |> String.to_charlist() end)

    case :zip.extract(String.to_charlist(bundle_path),
           cwd: String.to_charlist(extract_root),
           file_list: file_list
         ) do
      {:ok, _files} -> :ok
      {:error, :badarg} -> extract_streamed_store_entries(bundle_path, extract_root, entries)
      {:error, reason} -> {:error, {:invalid_encoding_booster_bundle, reason}}
    end
  end

  # Go's archive/zip writes data descriptors when entries are streamed to an
  # HTTP response. OTP can list those archives but :zip.extract/2 rejects them
  # with :badarg, so copy the already-validated stored entries by their central
  # directory offsets and verify each data descriptor while doing so.
  defp extract_streamed_store_entries(bundle_path, extract_root, entries) do
    with {:ok, safe_bundle_path} <- SafeFile.readable_path(bundle_path),
         {:ok, bundle} <- :file.open(String.to_charlist(safe_bundle_path), [:read, :binary, :raw]) do
      try do
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          case extract_streamed_store_entry(bundle, extract_root, entry) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
      after
        :ok = :file.close(bundle)
      end
    else
      {:error, reason} -> {:error, {:invalid_encoding_booster_bundle, reason}}
    end
  end

  defp extract_streamed_store_entry(
         bundle,
         extract_root,
         {:zip_file, name, file_info, _comment, local_header_offset, compressed_size}
       ) do
    name = List.to_string(name)
    size = elem(file_info, 1)

    with true <- is_integer(size) and size >= 0 and size <= 0xFFFFFFFF,
         true <- compressed_size == size,
         {:ok, data_offset} <- streamed_entry_data_offset(bundle, local_header_offset, name),
         destination = Path.join(extract_root, name),
         :ok <- SafeFile.mkdir_p(Path.dirname(destination)),
         {:ok, safe_destination} <- SafeFile.writable_path(destination),
         {:ok, output} <-
           :file.open(String.to_charlist(safe_destination), [:write, :binary, :raw]) do
      try do
        case copy_stored_entry(bundle, output, data_offset, size, 0) do
          {:ok, crc32} -> validate_data_descriptor(bundle, data_offset + size, crc32, size)
          {:error, _reason} = error -> error
        end
      after
        :ok = :file.close(output)
      end
    else
      false -> {:error, :invalid_encoding_booster_bundle_entry}
      {:error, _reason} = error -> error
    end
  end

  defp extract_streamed_store_entry(_bundle, _extract_root, _entry),
    do: {:error, :invalid_encoding_booster_bundle_entry}

  defp streamed_entry_data_offset(bundle, local_header_offset, expected_name)
       when is_integer(local_header_offset) and local_header_offset >= 0 do
    with {:ok,
          <<0x04034B50::little-32, _version::little-16, flags::little-16, 0::little-16,
            _timestamps_and_sizes::binary-size(16), name_size::little-16, extra_size::little-16>>} <-
           :file.pread(bundle, local_header_offset, @local_file_header_bytes),
         true <- band(flags, 0x1) == 0 and band(flags, 0x8) == 0x8,
         {:ok, name} <-
           :file.pread(bundle, local_header_offset + @local_file_header_bytes, name_size),
         true <- name == expected_name do
      {:ok, local_header_offset + @local_file_header_bytes + name_size + extra_size}
    else
      _other -> {:error, :invalid_encoding_booster_bundle_entry}
    end
  end

  defp streamed_entry_data_offset(_bundle, _local_header_offset, _expected_name),
    do: {:error, :invalid_encoding_booster_bundle_entry}

  defp copy_stored_entry(_bundle, _output, _offset, 0, crc32), do: {:ok, crc32}

  defp copy_stored_entry(bundle, output, offset, remaining, crc32) do
    chunk_size = min(remaining, @copy_chunk_bytes)

    with {:ok, chunk} when byte_size(chunk) == chunk_size <-
           :file.pread(bundle, offset, chunk_size),
         :ok <- :file.write(output, chunk) do
      copy_stored_entry(
        bundle,
        output,
        offset + chunk_size,
        remaining - chunk_size,
        :erlang.crc32(crc32, chunk)
      )
    else
      _other -> {:error, :incomplete_encoding_booster_bundle}
    end
  end

  defp validate_data_descriptor(bundle, offset, crc32, size) do
    case :file.pread(bundle, offset, @data_descriptor_bytes) do
      {:ok, <<0x08074B50::little-32, ^crc32::little-32, ^size::little-32, ^size::little-32>>} ->
        :ok

      _other ->
        {:error, :incomplete_encoding_booster_bundle}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp move_media_file(extract_root, output_path) do
    source_path = Path.join(extract_root, @media_entry)

    with {:ok, safe_source_path} <- SafeFile.readable_path(source_path),
         {:ok, safe_output_path} <- SafeFile.writable_path(output_path) do
      case File.rename(safe_source_path, safe_output_path) do
        :ok -> :ok
        {:error, reason} -> {:error, {:invalid_encoding_booster_bundle, reason}}
      end
    end
  end

  defp validate_hls_dir(extract_root) do
    hls_dir = Path.join(extract_root, "hls")

    with {:ok, _playlist} <- SafeFile.stat_regular(Path.join(hls_dir, "playlist.m3u8")),
         {:ok, _init} <- SafeFile.stat_regular(Path.join(hls_dir, "init.mp4")) do
      {:ok, hls_dir}
    else
      _ -> {:error, :incomplete_encoding_booster_bundle}
    end
  end
end
