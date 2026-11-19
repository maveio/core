defmodule MaveCore.AudioDescription.Publication do
  @moduledoc "Optional observer for newly published description tracks and editor revisions."

  def published(embed, video, language, operation, reference, quantity) do
    if observer = observer() do
      observer.published(embed, video, language, operation, reference, quantity)
    else
      :ok
    end
  end

  def reserve_flow(ctx, language, duration) do
    if observer = observer(), do: observer.reserve_flow(ctx, language, round(duration)), else: :ok
  end

  def reserve_edit(embed, description, render_id, text) do
    if observer = observer() do
      digest = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
      observer.reserve_edit(embed, description, render_id, digest, String.length(text))
    else
      :ok
    end
  end

  def generation_notice(space, user, access_context, skipped) do
    with module when not is_nil(module) <- observer(),
         true <- Code.ensure_loaded?(module) and function_exported?(module, :generation_notice, 4) do
      module.generation_notice(space, user, access_context, skipped)
    else
      _ -> nil
    end
  end

  def unavailable_notice do
    if observer = observer(), do: observer.unavailable_notice()
  end

  defp observer, do: Application.get_env(:mave_core, :audio_description_publication)
end
