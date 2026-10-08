defmodule MaveCore.FolderConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias MaveCore.Collections.Collection
  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  test "opposite moves on independent database connections cannot create a cycle" do
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      space = Repo.insert!(%Space{hash: "race-#{Ecto.UUID.generate()}", region: "default"})

      try do
        for _ <- 1..10 do
          {:ok, a} = Embeds.create_folder_embed(space, %{name: "A"})
          {:ok, b} = Embeds.create_folder_embed(space, %{name: "B"})
          owner = self()

          tasks =
            for {source, target} <- [{a, b}, {b, a}] do
              Task.Supervisor.async(supervisor, fn ->
                Sandbox.unboxed_run(Repo, fn ->
                  send(owner, {:ready, self()})
                  receive do: (:move -> Embeds.move_embed(source, target))
                end)
              end)
            end

          assert_receive {:ready, first}
          assert_receive {:ready, second}
          send(first, :move)
          send(second, :move)

          results = Enum.map(tasks, &Task.await/1)
          assert Enum.count(results, &match?({:ok, _}, &1)) == 1
          assert {:error, :invalid_target_folder} in results
        end
      after
        # Only this test's committed fixtures; membership rows cascade with embeds.
        Repo.delete_all(from(e in Embed, where: e.space_id == ^space.id))
        Repo.delete_all(from(c in Collection, where: c.space_id == ^space.id))
        Repo.delete!(space)
      end
    end)
  end
end
