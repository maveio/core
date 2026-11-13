defmodule MaveCore.AudioDescription.Backend do
  @moduledoc """
  Optional host extension for narration generation. Configure `:backend` under
  `:mave_core, :audio_description`. Returning `:default` preserves the built-in
  observation/writer pipeline; speech fitting, mixing and publication stay shared.

  Persist provider selection in `run_input/2` so retries retain the same route.
  `describe/3` returns a validated script with cues, category, summary,
  essential_text and alignment_report, plus private evidence and provider metadata.
  """

  @callback run_input(struct(), map()) :: map()
  @callback describe(map(), map(), map()) ::
              :default | {:ok, map()} | {:error, term()}
  @callback writer_provider(map()) :: module() | nil
  @callback speech_config(map()) :: {module(), keyword()} | nil
  @optional_callbacks speech_config: 1
end
