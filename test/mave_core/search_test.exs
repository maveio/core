defmodule MaveCore.SearchTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, Video}
  alias MaveCore.Collections.{Collection, CollectionEmbed}
  alias MaveCore.Embeds.Embed
  alias MaveCore.Search
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space

  defmodule DenyingLimits do
    def can_use_video_search?(_space), do: {:error, :plan}
  end

  describe "search/3" do
    test "finds a video by what is on screen and returns the moment" do
      space = space_fixture()
      tour = video_embed_fixture(space, "Harbour tour")
      _other = video_embed_fixture(space, "Budget review")

      index(tour, [
        visual(4.0, 6.0, "A harbour. A woman rides a red bicycle past the boats."),
        visual(30.0, 32.0, "A lighthouse on a cliff."),
        transcript(31.0, 35.0, "This lighthouse was built in 1890.")
      ])

      assert [%{embed: embed, matched_on: ["visual"], moments: [moment]}] =
               Search.search(space, "red bicycle")

      assert embed.id == tour.id
      assert %{source: "visual", start: 4.0, end: 6.0} = moment

      assert moment.snippet == [
               {"A harbour. A woman rides a ", false},
               {"red", true},
               {" ", false},
               {"bicycle", true},
               {" past the boats.", false}
             ]
    end

    test "matches spoken words, unfinished words, case and accents" do
      space = space_fixture()
      video = video_embed_fixture(space, "Interview")

      index(video, [transcript(12.0, 18.0, "We opened a café in Zürich last summer.")])

      for query <- ["cafe", "CAFÉ zur", "zurich sum"] do
        assert [%{matched_on: ["transcript"], moments: [%{start: 12.0}]}] =
                 Search.search(space, query),
               "expected a match for #{inspect(query)}"
      end

      assert [] = Search.search(space, "cafe berlin")
      assert [] = Search.search(space, "c")
      assert [] = Search.search(space, "  !!  ")
    end

    test "query syntax characters are treated as text" do
      space = space_fixture()
      video = video_embed_fixture(space, "Syntax")
      index(video, [visual(0.0, 2.0, "A sign reading open & ready.")])

      assert [%{moments: [_]}] = Search.search(space, "open & (ready) | !sign:* '")
      assert [] = Search.search(space, "' OR 1=1 --")
    end

    test "a title match ranks first and is combined with content matches" do
      space = space_fixture()
      content = video_embed_fixture(space, "Product demo")
      title = video_embed_fixture(space, "Whiteboard session")
      both = video_embed_fixture(space, "Whiteboard basics")

      index(content, [visual(8.0, 10.0, "A presenter draws on a whiteboard.")])
      index(both, [transcript(3.0, 6.0, "Grab a marker and walk to the whiteboard.")])

      results = Search.search(space, "whiteboard")

      assert Enum.map(results, & &1.embed.id) == [both.id, title.id, content.id]

      assert Enum.map(results, & &1.matched_on) == [
               ["title", "transcript"],
               ["title"],
               ["visual"]
             ]
    end

    test "returns the best distinct moments per video" do
      space = space_fixture()
      video = video_embed_fixture(space, "Factory")

      index(video, [
        visual(10.0, 12.0, "A robot arm lifts a box."),
        visual(12.0, 14.0, "A robot arm lowers a box."),
        visual(40.0, 42.0, "A robot arm welds a frame. The robot arm sparks."),
        visual(70.0, 72.0, "A robot rolls down an aisle."),
        visual(95.0, 97.0, "A second robot waits.")
      ])

      assert [%{moments: moments}] = Search.search(space, "robot", moments_per_video: 3)
      starts = Enum.map(moments, & &1.start)

      assert length(starts) == 3
      assert hd(starts) == 40.0
      refute 10.0 in starts and 12.0 in starts
    end

    test "only searches the current version of live videos in the space" do
      space = space_fixture()
      other_space = space_fixture()

      foreign = video_embed_fixture(other_space, "Foreign")
      deleted = video_embed_fixture(space, "Deleted", deleted_at: DateTime.utc_now())
      archived = video_embed_fixture(space, "Archived", archived: true)
      replaced = video_embed_fixture(space, "Replaced")

      for embed <- [foreign, deleted, archived, replaced] do
        index(embed, [visual(1.0, 2.0, "A green parrot on a perch.")])
      end

      # A new upload replaces the indexed version; its moments are not indexed yet.
      new_version = Repo.insert!(%Video{asset_id: replaced.asset_id, status: "ready"})

      Asset
      |> Repo.get!(replaced.asset_id)
      |> Ecto.Changeset.change(current_video_id: new_version.id)
      |> Repo.update!()

      assert [] = Search.search(space, "parrot")
      assert [%{embed: %{id: id}}] = Search.search(space, "parrot", archived: true)
      assert id == archived.id
      assert [%{embed: %{id: id}}] = Search.search(other_space, "parrot")
      assert id == foreign.id
    end

    test "a collection scope includes nested collections and nothing else" do
      space = space_fixture()
      courses = folder_embed_fixture(space, "Courses")
      baking = folder_embed_fixture(space, "Baking")
      marketing = folder_embed_fixture(space, "Marketing")
      link(courses, baking)

      in_courses = video_embed_fixture(space, "Intro")
      in_baking = video_embed_fixture(space, "Sourdough")
      in_marketing = video_embed_fixture(space, "Launch")
      at_root = video_embed_fixture(space, "Loose")
      link(courses, in_courses)
      link(baking, in_baking)
      link(marketing, in_marketing)

      for embed <- [in_courses, in_baking, in_marketing, at_root] do
        index(embed, [visual(1.0, 2.0, "Hands knead dough on a floured table.")])
      end

      ids = fn opts ->
        space |> Search.search("dough", opts) |> Enum.map(& &1.embed.id) |> Enum.sort()
      end

      assert ids.([]) == Enum.sort([in_courses.id, in_baking.id, in_marketing.id, at_root.id])
      assert ids.(collection: courses) == Enum.sort([in_courses.id, in_baking.id])
      assert ids.(collection: baking) == [in_baking.id]

      # A collection of another space never widens the scope.
      foreign_folder = folder_embed_fixture(space_fixture(), "Foreign")
      assert ids.(collection: foreign_folder) == []
      assert ids.(collection: in_courses) == []
    end
  end

  describe "index_video/4" do
    test "replaces the moments of a video version" do
      space = space_fixture()
      embed = video_embed_fixture(space, "Reindexed")
      video = current_video(embed)

      assert {:ok, 2} =
               Search.index_video(video, space.id, [
                 visual(0.0, 1.0, "A blue door."),
                 %{source: "visual", start: 2.0, end: 3.0, text: "…"}
                 | [transcript(1.0, 2.0, "Knock twice.")]
               ])

      assert Search.moment_count(video) == 2

      assert {:ok, 1} = Search.index_video(video, space.id, [visual(0.0, 1.0, "A yellow door.")])
      assert [] = Search.search(space, "blue door")
      assert [_] = Search.search(space, "yellow door")
    end
  end

  describe "snippet/2" do
    test "centres a long text on the first match" do
      text =
        String.duplicate("Rows of empty seats fill the hall. ", 6) <>
          "A violinist tunes her instrument on stage. " <>
          String.duplicate("The audience finds their places. ", 8)

      snippet = Search.snippet(text, ["violin"])
      plain = Enum.map_join(snippet, &elem(&1, 0))

      assert {"violinist", true} in snippet
      assert String.starts_with?(plain, "…")
      assert String.ends_with?(plain, "…")
      assert String.length(plain) < 220
    end
  end

  describe "space setting" do
    test "a space opts in and new runs then request both sources" do
      space = space_fixture()

      refute Spaces.video_search_active?(space)
      assert Search.run_input(space) == nil

      assert {:ok, %Space{video_search_enabled: true} = space} =
               Spaces.update_space_features(space, %{video_search_enabled: true})

      assert Search.run_input(space) == %{"sources" => ["visual", "transcript"]}

      assert Search.requested_sources(%{"search" => Search.run_input(space)}) ==
               ["visual", "transcript"]

      assert Search.requested_sources(%{"search" => %{"sources" => ["transcript", "x"]}}) ==
               ["transcript"]

      assert Search.requested_sources(%{}) == []
    end

    test "a host policy can refuse the feature and stops new indexing" do
      space = space_fixture()
      previous = Application.get_env(:mave_core, :usage_limits_backend)
      on_exit(fn -> restore(:usage_limits_backend, previous) end)

      {:ok, enabled} = Spaces.update_space_features(space, %{video_search_enabled: true})
      Application.put_env(:mave_core, :usage_limits_backend, DenyingLimits)

      assert {:error, :plan} = Spaces.update_space_features(space, %{video_search_enabled: true})
      refute Spaces.video_search_active?(enabled)
      assert Search.run_input(enabled) == nil

      assert {:ok, %Space{video_search_enabled: false}} =
               Spaces.update_space_features(enabled, %{video_search_enabled: false})
    end
  end

  defp restore(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore(key, value), do: Application.put_env(:mave_core, key, value)

  defp visual(start, stop, text), do: %{source: "visual", start: start, end: stop, text: text}

  defp transcript(start, stop, text),
    do: %{source: "transcript", start: start, end: stop, text: text}

  defp index(%Embed{} = embed, moments) do
    {:ok, _} = Search.index_video(current_video(embed), embed.space_id, moments, "en")
  end

  defp current_video(%Embed{asset_id: asset_id}) do
    asset = Repo.get!(Asset, asset_id)
    Repo.get!(Video, asset.current_video_id)
  end

  defp space_fixture do
    email = "search-test-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    user.current_space_membership.space
  end

  defp video_embed_fixture(%Space{} = space, name, attrs \\ []) do
    asset = Repo.insert!(%Asset{space_id: space.id, name: name})
    video = Repo.insert!(%Video{asset_id: asset.id, status: "ready", file_name: "#{name}.mp4"})
    asset |> Ecto.Changeset.change(current_video_id: video.id) |> Repo.update!()

    Repo.insert!(
      struct!(
        %Embed{space_id: space.id, asset_id: asset.id, hash: unique_embed_hash(), type: :video},
        attrs
      )
    )
  end

  defp folder_embed_fixture(%Space{} = space, name) do
    collection = Repo.insert!(%Collection{space_id: space.id, name: name, type: :folder})

    Repo.insert!(%Embed{
      space_id: space.id,
      collection_id: collection.id,
      hash: unique_embed_hash(),
      type: :collection
    })
  end

  defp link(%Embed{collection_id: collection_id}, %Embed{id: embed_id}) do
    Repo.insert!(%CollectionEmbed{collection_id: collection_id, embed_id: embed_id})
  end

  defp unique_embed_hash do
    System.unique_integer([:positive])
    |> Integer.to_string(36)
    |> String.pad_leading(10, "0")
    |> String.slice(-10, 10)
  end
end
