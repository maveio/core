defmodule MaveCore.Flow.DefinitionTest do
  use ExUnit.Case, async: true

  alias MaveCore.Flow.Definition

  test "valid definition passes" do
    definition = %{
      "steps" => [
        %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
        %{
          "id" => "manifest",
          "type" => "manifest.build",
          "name" => "Build Manifest",
          "depends_on" => ["source"]
        }
      ]
    }

    assert :ok = Definition.validate(definition)
  end

  test "accepts optional lane, priority, and required metadata" do
    definition = %{
      "steps" => [
        %{
          "id" => "source",
          "type" => "source.resolve",
          "name" => "Resolve Source",
          "lane" => "fast",
          "required" => false
        },
        %{
          "id" => "manifest",
          "type" => "manifest.build",
          "name" => "Build Manifest",
          "depends_on" => ["source"],
          "priority" => 75
        }
      ]
    }

    assert :ok = Definition.validate(definition)
  end

  test "rejects invalid required metadata" do
    definition = %{
      "steps" => [
        %{
          "id" => "source",
          "type" => "source.resolve",
          "name" => "Resolve Source",
          "required" => "yes"
        }
      ]
    }

    assert {:error, message} = Definition.validate(definition)
    assert message =~ "invalid required"
  end

  test "rejects invalid lane metadata" do
    definition = %{
      "steps" => [
        %{
          "id" => "source",
          "type" => "source.resolve",
          "name" => "Resolve Source",
          "lane" => "urgent"
        }
      ]
    }

    assert {:error, message} = Definition.validate(definition)
    assert message =~ "invalid lane"
  end

  test "next_ready_steps returns only the highest priority ready lane" do
    definition = %{
      "steps" => [
        %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
        %{
          "id" => "fast_thumb",
          "type" => "media.extract_frame",
          "name" => "Fast Thumbnail",
          "depends_on" => ["source"],
          "lane" => "fast"
        },
        %{
          "id" => "background_av1",
          "type" => "media.transcode_video",
          "name" => "Background AV1",
          "depends_on" => ["source"],
          "lane" => "background"
        }
      ]
    }

    step_runs_by_id = %{
      "source" => %{status: "succeeded"},
      "fast_thumb" => %{status: "queued"},
      "background_av1" => %{status: "queued"}
    }

    assert [%{"id" => "fast_thumb"}] = Definition.next_ready_steps(definition, step_runs_by_id)
  end

  test "next_ready_steps treats failed optional dependencies as satisfied" do
    definition = %{
      "steps" => [
        %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
        %{
          "id" => "poster",
          "type" => "media.extract_frame",
          "name" => "Poster",
          "depends_on" => ["source"],
          "required" => false
        },
        %{
          "id" => "manifest",
          "type" => "manifest.build",
          "name" => "Build Manifest",
          "depends_on" => ["source", "poster"]
        }
      ]
    }

    step_runs_by_id = %{
      "source" => %{status: "succeeded"},
      "poster" => %{status: "failed"},
      "manifest" => %{status: "queued"}
    }

    assert [%{"id" => "manifest"}] = Definition.next_ready_steps(definition, step_runs_by_id)
  end

  test "rejects unknown dependencies" do
    definition = %{
      "steps" => [
        %{
          "id" => "manifest",
          "type" => "manifest.build",
          "name" => "Build Manifest",
          "depends_on" => ["source"]
        }
      ]
    }

    assert {:error, message} = Definition.validate(definition)
    assert message =~ "unknown dependency"
  end

  test "rejects cyclic dependencies" do
    definition = %{
      "steps" => [
        %{
          "id" => "a",
          "type" => "media.inspect",
          "name" => "A",
          "depends_on" => ["b"]
        },
        %{
          "id" => "b",
          "type" => "manifest.build",
          "name" => "B",
          "depends_on" => ["a"]
        }
      ]
    }

    assert {:error, message} = Definition.validate(definition)
    assert message =~ "cycle"
  end
end
