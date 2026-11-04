defmodule MaveCore.AudioDescriptionTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.AudioDescription
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space

  defmodule PaidOnly do
    @behaviour MaveCore.UsageLimits

    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_use_audio_description?(_space), do: {:error, :paid_plan_required}
  end

  setup do
    old_backend = Application.get_env(:mave_core, :usage_limits_backend)

    on_exit(fn ->
      if old_backend,
        do: Application.put_env(:mave_core, :usage_limits_backend, old_backend),
        else: Application.delete_env(:mave_core, :usage_limits_backend)
    end)

    {:ok, user} = Accounts.create_user("ad-#{System.unique_integer([:positive])}@example.com")
    %{space: user.current_space_membership.space}
  end

  test "spaces opt in; without a host policy every space may", %{space: space} do
    refute space.audio_description_enabled
    assert AudioDescription.run_input(space) == nil

    assert {:ok, %Space{audio_description_enabled: true} = space} =
             Spaces.update_space_features(space, %{audio_description_enabled: true})

    assert AudioDescription.run_input(space) == %{
             "languages" => ["original"],
             "fallback_language" => "en"
           }

    assert Repo.get!(Space, space.id).audio_description_enabled
  end

  test "the host decides who may turn it on", %{space: space} do
    Application.put_env(:mave_core, :usage_limits_backend, PaidOnly)

    assert {:error, :paid_plan_required} =
             Spaces.update_space_features(space, %{audio_description_enabled: true})

    refute Repo.get!(Space, space.id).audio_description_enabled
  end

  test "a space that lost access stops getting descriptions and can still turn them off", %{
    space: space
  } do
    {:ok, space} = Spaces.update_space_features(space, %{audio_description_enabled: true})
    Application.put_env(:mave_core, :usage_limits_backend, PaidOnly)

    refute Spaces.audio_description_active?(space)
    assert AudioDescription.run_input(space) == nil

    assert {:ok, %Space{audio_description_enabled: false}} =
             Spaces.update_space_features(space, %{audio_description_enabled: false})
  end

  test "English is always described first" do
    assert AudioDescription.requested_languages(%{}) == []

    assert AudioDescription.requested_languages(%{
             "audio_description" => %{"languages" => ["nl"]}
           }) == ["en", "nl"]
  end

  test "original language uses transcription and defaults to English when unknown" do
    assert AudioDescription.original_language(%{}, %{"transcribe_audio" => %{"language" => "nl"}}) ==
             "nl"

    assert AudioDescription.original_language(%{"language" => "fr-FR"}, %{}) == "fr"
    assert AudioDescription.original_language(%{}, %{}) == "en"
    assert AudioDescription.original_language(%{"language" => "und"}, %{}) == "en"

    assert AudioDescription.requested_languages(%{
             "audio_description" => %{"languages" => ["original"]}
           }) == ["original"]
  end

  test "a flow or step can specify its fallback without overriding detected speech" do
    input = %{"audio_description" => %{"fallback_language" => "nl"}}
    assert AudioDescription.original_language(input, %{}) == "nl"
    assert AudioDescription.original_language(input, %{}, "de") == "de"

    assert AudioDescription.original_language(
             input,
             %{"transcribe_audio" => %{"language" => "fr"}},
             "de"
           ) == "fr"
  end
end
