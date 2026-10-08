defmodule MaveCoreWeb.Api.Flow.RunsController do
  use MaveCoreWeb, :controller

  def create(conn, params) do
    selector = params["template_id"] || params["template_slug"] || params["template"]
    input = params["input"] || %{}
    execution_mode = parse_execution_mode(params["execution"])

    opts =
      []
      |> maybe_add_version(params["version"])
      |> Keyword.put(:enqueue, parse_enqueue(params["enqueue"]))

    case selector do
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Missing template selector (template_id/template_slug/template)"})

      _ ->
        start_run(conn, selector, input, opts, execution_mode)
    end
  end

  def show(conn, %{"id" => run_id}) do
    case MaveCore.Flow.get_run(run_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Flow run not found"})

      run ->
        json(conn, %{data: serialize_run(run)})
    end
  end

  defp serialize_run(run) do
    %{
      id: run.id,
      template_id: run.flow_template_id,
      version_id: run.flow_version_id,
      status: run.status,
      input: run.input,
      context: run.context,
      error: run.error,
      started_at: run.started_at,
      completed_at: run.completed_at,
      steps:
        Enum.map(run.step_runs || [], fn step ->
          %{
            id: step.step_id,
            type: step.step_type,
            status: step.status,
            attempt: step.attempt,
            input: step.input,
            output: step.output,
            error: step.error
          }
        end),
      artifacts:
        Enum.map(run.artifact_refs || [], fn artifact ->
          %{
            producer_step_id: artifact.producer_step_id,
            name: artifact.name,
            uri: artifact.uri,
            media_type: artifact.media_type,
            size_bytes: artifact.size_bytes,
            metadata: artifact.metadata
          }
        end)
    }
  end

  defp maybe_add_version(opts, version) when is_integer(version),
    do: Keyword.put(opts, :version, version)

  defp maybe_add_version(opts, version) when is_binary(version) and version != "",
    do: Keyword.put(opts, :version, version)

  defp maybe_add_version(opts, _version), do: opts

  defp parse_enqueue(value) when value in [false, "false", "0", 0], do: false
  defp parse_enqueue(_), do: true

  defp parse_execution_mode(value) when value in ["inline", "sync"], do: :inline
  defp parse_execution_mode(_), do: :async

  defp start_run(conn, selector, input, opts, :async) do
    case MaveCore.Flow.start_run(selector, input, opts) do
      {:ok, run} ->
        conn
        |> put_status(:accepted)
        |> json(%{data: serialize_run(run)})

      {:error, reason} ->
        render_start_run_error(conn, reason)
    end
  end

  defp start_run(conn, selector, input, opts, :inline) do
    case MaveCore.Flow.run_inline(selector, input, opts) do
      {:ok, run} ->
        conn
        |> put_status(:ok)
        |> json(%{data: serialize_run(run)})

      {:error, reason} ->
        render_start_run_error(conn, reason)
    end
  end

  defp render_start_run_error(conn, :template_not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Template not found"})
  end

  defp render_start_run_error(conn, :no_active_version) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Template has no active flow version"})
  end

  defp render_start_run_error(conn, :version_not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Flow version not found"})
  end

  defp render_start_run_error(conn, :invalid_version) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid version value"})
  end

  defp render_start_run_error(conn, %Ecto.Changeset{} = changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: MaveCoreWeb.ErrorJSON)
    |> render(:"422", changeset: changeset)
  end

  defp render_start_run_error(conn, reason) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "Failed to start flow run", details: inspect(reason)})
  end
end
