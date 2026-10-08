defmodule MaveCore.SafeFile do
  @moduledoc false

  @default_stream_chunk 64_000
  @max_kubeconfig_bytes 1_000_000

  def readable_path(path, opts \\ []) do
    expanded = Path.expand(path)

    with :ok <- validate_regular_file(expanded),
         :ok <- validate_file_size(expanded, opts) do
      {:ok, expanded}
    end
  end

  def writable_path(path) do
    expanded = Path.expand(path)
    parent = Path.dirname(expanded)

    with :ok <- validate_directory(parent),
         :ok <- validate_destination(expanded) do
      {:ok, expanded}
    end
  end

  def stat_regular(path) do
    case readable_path(path) do
      {:ok, expanded} -> File.stat(expanded)
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  def stream_write!(path, modes \\ [:write, :binary]) do
    {:ok, expanded} = writable_path(path)
    File.stream!(expanded, modes)
  end

  # sobelow_skip ["Traversal.FileModule"]
  def stream_read!(path, modes \\ [], chunk_size \\ @default_stream_chunk) do
    {:ok, expanded} = readable_path(path)
    File.stream!(expanded, modes, chunk_size)
  end

  # sobelow_skip ["Traversal.FileModule"]
  def read!(path, opts \\ []) do
    {:ok, expanded} = readable_path(path, opts)
    File.read!(expanded)
  end

  # sobelow_skip ["Traversal.FileModule"]
  def read(path, opts \\ []) do
    with {:ok, expanded} <- readable_path(path, opts) do
      File.read(expanded)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  def write(path, body) do
    with {:ok, expanded} <- writable_path(path) do
      File.write(expanded, body)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  def exists?(path) do
    case File.lstat(Path.expand(path)) do
      {:ok, %File.Stat{type: :regular}} -> true
      {:ok, %File.Stat{type: :directory}} -> true
      _ -> false
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  def rm(path) do
    with {:ok, expanded} <- removable_path(path) do
      File.rm(expanded)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  def mkdir_p(path) do
    with {:ok, expanded} <- writable_directory_path(path) do
      File.mkdir_p(expanded)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  def mkdir_p!(path) do
    case writable_directory_path(path) do
      {:ok, expanded} -> File.mkdir_p!(expanded)
      {:error, reason} -> raise ArgumentError, "invalid directory path: #{inspect(reason)}"
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  def rm_rf(path) do
    with {:ok, expanded} <- removable_directory_path(path) do
      File.rm_rf(expanded)
    end
  end

  def kubeconfig_bytes_limit, do: @max_kubeconfig_bytes

  defp removable_path(path) do
    expanded = Path.expand(path)

    case File.lstat(expanded) do
      {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] ->
        {:ok, expanded}

      {:ok, %File.Stat{type: _type}} ->
        {:error, {:invalid_file_type, path}}

      {:error, :enoent} ->
        {:ok, expanded}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp removable_directory_path(path) do
    expanded = Path.expand(path)

    case File.lstat(expanded) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, expanded}

      {:ok, %File.Stat{type: _type}} ->
        {:error, {:invalid_directory, path}}

      {:error, :enoent} ->
        {:ok, expanded}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_regular_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: _type}} -> {:error, {:invalid_file_type, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_file_size(path, opts) do
    case Keyword.get(opts, :max_bytes) do
      nil ->
        :ok

      max_bytes when is_integer(max_bytes) and max_bytes > 0 ->
        case File.stat(path) do
          {:ok, %File.Stat{size: size}} when size <= max_bytes -> :ok
          {:ok, %File.Stat{size: _size}} -> {:error, {:file_too_large, path}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp validate_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: _type}} -> {:error, {:invalid_directory, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp writable_directory_path(path) do
    expanded = Path.expand(path)
    parent = Path.dirname(expanded)

    with :ok <- validate_directory(parent),
         :ok <- validate_directory_destination(expanded) do
      {:ok, expanded}
    end
  end

  defp validate_destination(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: _type}} -> {:error, {:invalid_destination, path}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_directory_destination(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: _type}} -> {:error, {:invalid_directory, path}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
