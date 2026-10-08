defmodule MaveCoreWeb.Api.Upload.TusdHooksControllerTest do
  use MaveCoreWeb.ConnCase
  import Ecto.Query

  alias MaveCore.Accounts
  alias MaveCore.Assets
  alias MaveCore.Assets.{Asset, AudioTrack, Subtitle, Video}
  alias MaveCore.Collections.CollectionEmbed
  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Flow
  alias MaveCore.Flow.Run
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space
  alias MaveCore.TestSupport.FlowStorageAdapterStub
  alias MaveCore.Uploads.Token

  defmodule UploadSizeBlockedUsageLimits do
    @behaviour MaveCore.UsageLimits

    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok

    def can_upload_file?(_space, size) when is_integer(size) and size > 5_000_000_000,
      do: {:error, :upload_file_size_limit_exceeded}

    def can_upload_file?(_space, _size), do: :ok
  end

  defmodule EncodingBoosterPrewarmerStub do
    @moduledoc false

    def warmup_async(space_hash) do
      owner = Application.fetch_env!(:mave_core, :encoding_booster_prewarmer_owner)
      send(owner, {:prewarm, space_hash})
      :ok
    end
  end

  @definition %{
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
  @upload_source_region "us-east-1"

  setup do
    old_upload_config = Application.get_env(:mave_core, :upload, [])
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_cache_purger = Application.get_env(:mave_core, :cdn_cache_purger)
    old_usage_limits_backend = Application.get_env(:mave_core, :usage_limits_backend)
    old_media_input = Application.get_env(:mave_core, :media_input)
    old_prewarmer = Application.get_env(:mave_core, :encoding_booster_prewarmer)
    old_prewarmer_owner = Application.get_env(:mave_core, :encoding_booster_prewarmer_owner)

    Application.put_env(
      :mave_core,
      :upload,
      endpoint: "http://localhost:1080/files",
      bucket: "mave-upload",
      source_base_url: "http://storage.local",
      source_region: @upload_source_region,
      object_acl: true,
      hook_secret: "hook_secret",
      default_template: "upload_test"
    )

    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      restore_env(:upload, old_upload_config)
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:cdn_cache_purger, old_cache_purger)
      restore_env(:usage_limits_backend, old_usage_limits_backend)
      restore_env(:media_input, old_media_input)
      restore_env(:encoding_booster_prewarmer, old_prewarmer)
      restore_env(:encoding_booster_prewarmer_owner, old_prewarmer_owner)
      FlowStorageAdapterStub.reset!()
    end)

    :ok
  end

  test "requires a valid hook secret", %{conn: conn} do
    conn =
      post(conn, ~p"/internal/upload-hooks/tusd", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "Storage" => %{"Bucket" => "mave-upload", "Key" => "uploads/video.mp4"}
          }
        }
      })

    assert response(conn, 403)
  end

  test "rejects the legacy internal secret header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-mave-secret", "hook_secret")
      |> post(~p"/internal/upload-hooks/tusd", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "Storage" => %{"Bucket" => "mave-upload", "Key" => "uploads/video.mp4"}
          }
        }
      })

    assert response(conn, 403)
  end

  test "rejects upload hook secret header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-mave-upload-secret", "hook_secret")
      |> post(~p"/internal/upload-hooks/tusd", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "Storage" => %{"Bucket" => "mave-upload", "Key" => "uploads/video.mp4"}
          }
        }
      })

    assert response(conn, 403)
  end

  test "accepts pre-create hook payload with a signed upload JWT", %{conn: conn} do
    space = space_fixture()
    space_hash = space.hash
    embed = placeholder_video_embed_fixture(space, %{name: "Pre Create Upload"})

    Application.put_env(:mave_core, :encoding_booster_prewarmer, EncodingBoosterPrewarmerStub)
    Application.put_env(:mave_core, :encoding_booster_prewarmer_owner, self())

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "pre-create",
        "Event" => %{
          "Upload" => %{
            "Size" => 100_000_000,
            "MetaData" =>
              upload_metadata(embed, %{
                "filetype" => "video/mp4",
                "space_hash" => "spoofed"
              })
          }
        }
      })

    assert %{
             "ChangeFileInfo" => %{
               "ID" => upload_id,
               "MetaData" => sanitized_metadata
             }
           } = json_response(conn, 200)

    assert upload_id =~ ~r|\A#{Regex.escape(space_hash)}/[A-Za-z0-9_-]{32}\.mp4\z|
    refute Map.has_key?(sanitized_metadata, "token")
    assert sanitized_metadata["filetype"] == "video/mp4"
    assert sanitized_metadata["space_hash"] == "spoofed"
    assert sanitized_metadata["mave_upload_key_id"]
    assert sanitized_metadata["mave_upload_space_hash"] == space_hash

    assert sanitized_metadata["mave_upload_subject"] ==
             SettingsSerializer.public_embed_id(space, embed)

    assert sanitized_metadata["mave_upload_expires_at"]
    assert_receive {:prewarm, ^space_hash}

    post_receive_conn =
      post(build_conn(), ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-receive",
        "Event" => %{
          "Upload" => %{
            "ID" => upload_id,
            "Size" => 100_000_000,
            "Offset" => 50_000_000,
            "MetaData" => sanitized_metadata
          }
        }
      })

    assert %{"status" => "ok", "action" => "encoding_booster_warmup"} =
             json_response(post_receive_conn, 200)
  end

  test "pre-create cannot replay or expand persisted upload authorization", %{conn: conn} do
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Scoped Upload"})

    payload = %{
      "Type" => "pre-create",
      "Event" => %{
        "Upload" => %{
          "Size" => 1_000,
          "MetaData" => upload_metadata(embed, %{"filetype" => "video/mp4"})
        }
      }
    }

    created = post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", payload)
    assert %{"ChangeFileInfo" => %{"MetaData" => metadata}} = json_response(created, 200)

    for forged <- [
          metadata,
          Map.merge(metadata, %{
            "mave_upload_subject" => space.hash,
            "mave_upload_expires_at" => to_string(System.system_time(:second) + 86_400)
          }),
          Map.new(metadata, fn {key, value} -> {String.replace(key, "_", "-"), value} end)
        ] do
      rejected =
        post(
          build_conn(),
          ~p"/internal/upload-hooks/tusd?secret=hook_secret",
          put_in(payload, ["Event", "Upload", "MetaData"], forged)
        )

      assert %{"RejectUpload" => true, "HTTPResponse" => %{"StatusCode" => 403}} =
               json_response(rejected, 200)
    end
  end

  test "signed pre-create overwrites forged persisted authorization", %{conn: conn} do
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Signed Upload"})

    metadata =
      upload_metadata(embed, %{
        "mave-upload-subject" => space.hash,
        "mave_upload_expires_at" => "9999999999"
      })

    created =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "pre-create",
        "Event" => %{"Upload" => %{"Size" => 1_000, "MetaData" => metadata}}
      })

    assert %{"ChangeFileInfo" => %{"MetaData" => sanitized}} = json_response(created, 200)
    assert sanitized["mave_upload_subject"] == SettingsSerializer.public_embed_id(space, embed)
    refute Map.has_key?(sanitized, "mave-upload-subject")
    refute sanitized["mave_upload_expires_at"] == "9999999999"
  end

  test "refreshes encoding booster capacity while an upload is receiving data", %{conn: conn} do
    space = space_fixture()
    space_hash = space.hash
    embed = placeholder_video_embed_fixture(space, %{name: "Receiving Upload"})

    Application.put_env(:mave_core, :encoding_booster_prewarmer, EncodingBoosterPrewarmerStub)
    Application.put_env(:mave_core, :encoding_booster_prewarmer_owner, self())

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-receive",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-receiving-123",
            "Size" => 100_000_000,
            "Offset" => 50_000_000,
            "MetaData" => upload_metadata(embed, %{"filetype" => "video/mp4"})
          }
        }
      })

    assert %{
             "status" => "ok",
             "action" => "encoding_booster_warmup"
           } = json_response(conn, 200)

    assert_receive {:prewarm, ^space_hash}
  end

  test "trusted tus metadata rechecks the upload key access level", %{conn: conn} do
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Trusted Metadata Upload"})

    pre_create_conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "pre-create",
        "Event" => %{
          "Upload" => %{
            "Size" => 100_000_000,
            "MetaData" => upload_metadata(embed, %{"filetype" => "video/mp4"})
          }
        }
      })

    assert %{"ChangeFileInfo" => %{"ID" => upload_id, "MetaData" => metadata}} =
             json_response(pre_create_conn, 200)

    key = Repo.get!(MaveCore.Spaces.Key, metadata["mave_upload_key_id"])
    assert {:ok, _key} = Spaces.make_key_read_only(key)

    post_receive_conn =
      post(build_conn(), ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-receive",
        "Event" => %{
          "Upload" => %{
            "ID" => upload_id,
            "Size" => 100_000_000,
            "Offset" => 50_000_000,
            "MetaData" => metadata
          }
        }
      })

    assert %{"status" => "error", "error" => error} = json_response(post_receive_conn, 200)
    assert error =~ "invalid_upload_jwt"
  end

  test "scopes custom media upload objects to their authenticated space", %{conn: conn} do
    space = space_fixture()
    space_hash = space.hash
    embed = video_embed_fixture(space, %{name: "Private Custom Upload"})

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "pre-create",
        "Event" => %{
          "Upload" => %{
            "Size" => 1_000_000,
            "MetaData" =>
              upload_metadata(embed, %{
                "custom_thumbnail" => "true",
                "filetype" => "image/png"
              })
          }
        }
      })

    assert %{"ChangeFileInfo" => %{"ID" => upload_id}} = json_response(conn, 200)
    assert upload_id =~ ~r|\A#{Regex.escape(space_hash)}/[A-Za-z0-9_-]{32}\.png\z|
  end

  test "rejects an existing upload JWT after its signing key becomes read-only", %{conn: conn} do
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Read-only Key Upload"})
    {:ok, key} = Spaces.create_key(space)
    token = Token.sign_api_key(key, SettingsSerializer.public_embed_id(space, embed))

    assert {:ok, _key} = Spaces.make_key_read_only(key)

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "pre-create",
        "Event" => %{
          "Upload" => %{
            "MetaData" => %{
              "token" => token,
              "filetype" => "video/mp4"
            }
          }
        }
      })

    assert %{
             "RejectUpload" => true,
             "HTTPResponse" => %{"StatusCode" => 403, "Body" => body}
           } = json_response(conn, 200)

    assert Jason.decode!(body) == %{"error" => "upload authentication failed"}
  end

  test "accepts pre-create hook payload during maintenance", %{conn: conn} do
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Maintenance Upload"})

    with_maintenance(fn ->
      conn =
        post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
          "Type" => "pre-create",
          "Event" => %{
            "Upload" => %{
              "Size" => 100_000_000,
              "MetaData" =>
                upload_metadata(embed, %{
                  "filetype" => "video/mp4"
                })
            }
          }
        })

      assert %{"ChangeFileInfo" => %{"ID" => upload_id}} = json_response(conn, 200)
      assert String.ends_with?(upload_id, ".mp4")
    end)
  end

  test "rejects pre-create hook payload when usage limits reject the upload size", %{conn: conn} do
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Large Upload"})
    Application.put_env(:mave_core, :usage_limits_backend, UploadSizeBlockedUsageLimits)

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "pre-create",
        "Event" => %{
          "Upload" => %{
            "Size" => 5_000_000_001,
            "MetaData" =>
              upload_metadata(embed, %{
                "filetype" => "video/mp4"
              })
          }
        }
      })

    assert %{
             "RejectUpload" => true,
             "HTTPResponse" => %{
               "StatusCode" => 413,
               "Body" => body,
               "Header" => %{"Content-Type" => "application/json"}
             }
           } = json_response(conn, 200)

    assert Jason.decode!(body) == %{"error" => "upload file size limit exceeded"}
  end

  test "rejects pre-create when the upload size is unknown", %{conn: conn} do
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Unknown Upload Size"})

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "pre-create",
        "Event" => %{
          "Upload" => %{
            "MetaData" => upload_metadata(embed, %{"filetype" => "video/mp4"})
          }
        }
      })

    assert %{
             "RejectUpload" => true,
             "HTTPResponse" => %{"StatusCode" => 413, "Body" => body}
           } = json_response(conn, 200)

    assert Jason.decode!(body) == %{"error" => "upload size is required"}
  end

  test "rejects deferred upload length", %{conn: conn} do
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Deferred Upload Size"})

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "pre-create",
        "Event" => %{
          "Upload" => %{
            "Size" => 0,
            "SizeIsDeferred" => true,
            "MetaData" => upload_metadata(embed, %{"filetype" => "video/mp4"})
          }
        }
      })

    assert %{
             "RejectUpload" => true,
             "HTTPResponse" => %{"StatusCode" => 413, "Body" => body}
           } = json_response(conn, 200)

    assert Jason.decode!(body) == %{"error" => "upload size is required"}
  end

  test "Core hard cap cannot be relaxed by the host usage backend", %{conn: conn} do
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Core Hard Cap"})
    Application.put_env(:mave_core, :media_input, max_bytes: 5)
    Application.put_env(:mave_core, :usage_limits_backend, UploadSizeBlockedUsageLimits)

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "pre-create",
        "Event" => %{
          "Upload" => %{
            "Size" => 6,
            "MetaData" => upload_metadata(embed, %{"filetype" => "video/mp4"})
          }
        }
      })

    assert %{
             "RejectUpload" => true,
             "HTTPResponse" => %{"StatusCode" => 413, "Body" => body}
           } = json_response(conn, 200)

    assert Jason.decode!(body) == %{"error" => "upload file size limit exceeded"}
  end

  test "rejects pre-create hook payload without a signed upload JWT", %{conn: conn} do
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Raw Pre Create Upload"})

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "pre-create",
        "Event" => %{
          "Upload" => %{
            "MetaData" => %{
              "embed_id" => "#{space.hash}#{embed.hash}",
              "filetype" => "video/mp4"
            }
          }
        }
      })

    assert %{
             "RejectUpload" => true,
             "HTTPResponse" => %{
               "StatusCode" => 403,
               "Body" => body,
               "Header" => %{"Content-Type" => "application/json"}
             }
           } = json_response(conn, 200)

    assert Jason.decode!(body) == %{"error" => "upload authentication failed"}
  end

  test "rejects pre-create hook payload with an expired upload JWT", %{conn: conn} do
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Expired Upload"})
    {:ok, key} = Spaces.create_key(space)

    token =
      Token.sign_api_key(key, SettingsSerializer.public_embed_id(space, embed), max_age: -120)

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "pre-create",
        "Event" => %{
          "Upload" => %{
            "MetaData" => %{
              "token" => token,
              "filetype" => "video/mp4"
            }
          }
        }
      })

    assert %{
             "RejectUpload" => true,
             "HTTPResponse" => %{
               "StatusCode" => 403,
               "Body" => body,
               "Header" => %{"Content-Type" => "application/json"}
             }
           } = json_response(conn, 200)

    assert Jason.decode!(body) == %{"error" => "upload authentication failed"}
  end

  test "starts a flow run from post-finish hook payload", %{conn: conn} do
    upload_config = Application.fetch_env!(:mave_core, :upload)

    Application.put_env(
      :mave_core,
      :upload,
      Keyword.put(upload_config, :public_base_url, "https://storage.video-dns.test")
    )

    {:ok, _template} = Flow.create_template(%{"slug" => "upload_test", "name" => "Upload Test"})
    {:ok, _version} = Flow.create_version("upload_test", %{"definition" => @definition})
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Hook Upload"})

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-123",
            "Size" => 123,
            "MetaData" =>
              upload_metadata(embed, %{
                "template" => "upload_test",
                "filetype" => "video/mp4",
                "enqueue" => "false"
              }),
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => "uploads/video.mp4"
            }
          }
        }
      })

    assert %{"status" => "ok", "flow_run_id" => flow_run_id} = json_response(conn, 200)

    assert flow_run = Flow.get_run(flow_run_id)
    assert flow_run.status == "running"

    assert flow_run.input["space_hash"] == space.hash
    assert flow_run.input["embed_hash"] == embed.hash
    assert flow_run.input["source_bucket"] == "mave-upload"
    assert flow_run.input["source_key"] == "uploads/video.mp4"
    assert flow_run.input["region"] == space.region
    assert flow_run.input["source_content_type"] == "video/mp4"
    assert flow_run.input["source_url"] == "http://storage.local/mave-upload/uploads/video.mp4"
    assert flow_run.input["video_id"] == Repo.get!(Asset, embed.asset_id).current_video_id

    assert FlowStorageAdapterStub.public?(
             "mave-upload",
             "uploads/video.mp4",
             @upload_source_region
           )

    assert flow_run.input["upload_ffmpeg_input_url"] ==
             "http://storage.local/mave-upload/uploads/video.mp4"

    assert flow_run.input["upload_public_url"] ==
             "https://storage.video-dns.test/uploads/video.mp4"

    refute Map.has_key?(flow_run.input["upload_metadata"], "token")
    assert flow_run.input["upload_metadata"]["template"] == "upload_test"
    assert flow_run.input["version"] == 0
  end

  test "replayed post-finish hook for one bucket and key reuses the existing flow run", %{
    conn: conn
  } do
    {:ok, _template} =
      Flow.create_template(%{"slug" => "upload_test", "name" => "Upload Test"})

    {:ok, _version} = Flow.create_version("upload_test", %{"definition" => @definition})
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Idempotent Hook Upload"})

    payload = %{
      "Type" => "post-finish",
      "Event" => %{
        "Upload" => %{
          "ID" => "upload-replayed",
          "Size" => 123,
          "MetaData" =>
            upload_metadata(embed, %{
              "template" => "upload_test",
              "filetype" => "video/mp4",
              "enqueue" => "false"
            }),
          "Storage" => %{
            "Bucket" => "mave-upload",
            "Key" => "uploads/replayed-video.mp4"
          }
        }
      }
    }

    first_conn = post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", payload)

    second_conn =
      post(build_conn(), ~p"/internal/upload-hooks/tusd?secret=hook_secret", payload)

    assert %{"status" => "ok", "flow_run_id" => flow_run_id} =
             json_response(first_conn, 200)

    assert %{"status" => "ok", "flow_run_id" => ^flow_run_id} =
             json_response(second_conn, 200)

    assert Repo.aggregate(Run, :count) == 1

    assert Repo.aggregate(
             from(video in Video, where: video.asset_id == ^embed.asset_id),
             :count
           ) == 1

    assert %Run{input: %{"video_id" => video_id}} = Flow.get_run(flow_run_id)
    assert Repo.get!(Asset, embed.asset_id).current_video_id == video_id
  end

  test "starts a flow run when multiple active spaces use the trial hash", %{conn: conn} do
    {:ok, _template} = Flow.create_template(%{"slug" => "upload_test", "name" => "Upload Test"})
    {:ok, _version} = Flow.create_version("upload_test", %{"definition" => @definition})

    target_space = space_fixture() |> force_space_hash!("trial")
    _decoy_space = space_fixture() |> force_space_hash!("trial")
    embed = placeholder_video_embed_fixture(target_space, %{name: "Trial Hook Upload"})

    pre_create_conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "pre-create",
        "Event" => %{
          "Upload" => %{
            "Size" => 100_000_000,
            "MetaData" =>
              upload_metadata(embed, %{
                "template" => "upload_test",
                "filetype" => "video/mp4",
                "enqueue" => "false"
              })
          }
        }
      })

    assert %{"ChangeFileInfo" => %{"MetaData" => sanitized_metadata}} =
             json_response(pre_create_conn, 200)

    refute Map.has_key?(sanitized_metadata, "token")

    post_finish_conn =
      post(build_conn(), ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-trial",
            "Size" => 123,
            "MetaData" => sanitized_metadata,
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => "uploads/trial-video.mp4"
            }
          }
        }
      })

    assert %{"status" => "ok", "flow_run_id" => flow_run_id} =
             json_response(post_finish_conn, 200)

    assert %Run{} = flow_run = Flow.get_run(flow_run_id)
    assert flow_run.input["space_hash"] == "trial"
    assert flow_run.input["embed_hash"] == embed.hash
    assert flow_run.input["region"] == target_space.region
    assert flow_run.flow_template.slug == "upload_test"
  end

  test "replacement uploads start the flow with the next video version", %{conn: conn} do
    {:ok, _template} = Flow.create_template(%{"slug" => "upload_test", "name" => "Upload Test"})
    {:ok, _version} = Flow.create_version("upload_test", %{"definition" => @definition})
    space = space_fixture()
    embed = video_embed_fixture(space, %{name: "Replacement Upload"})

    original_asset = Repo.get!(Asset, embed.asset_id) |> Repo.preload([:current_video])
    original_video_id = original_asset.current_video_id

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-replacement",
            "Size" => 123,
            "MetaData" =>
              upload_metadata(embed, %{
                "template" => "upload_test",
                "filetype" => "video/mp4",
                "enqueue" => "false"
              }),
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => "uploads/replacement.mp4"
            }
          }
        }
      })

    assert %{"status" => "ok", "flow_run_id" => flow_run_id} = json_response(conn, 200)

    assert flow_run = Flow.get_run(flow_run_id)
    assert flow_run.input["version"] == 1

    assert refreshed_asset = Repo.get!(Asset, embed.asset_id)
    refute refreshed_asset.current_video_id == original_video_id

    assert refreshed_video = Repo.get!(Video, refreshed_asset.current_video_id)
    assert refreshed_video.status == "preparing"
  end

  test "space default flow template is used when upload metadata does not override it", %{
    conn: conn
  } do
    {:ok, _template} =
      Flow.create_template(%{"slug" => "space_default_test", "name" => "Space Default Test"})

    {:ok, _version} = Flow.create_version("space_default_test", %{"definition" => @definition})
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Space Default Upload"})

    assert {:ok, _space} =
             Spaces.update_space_processing(space, %{
               default_flow_template: "space_default_test"
             })

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-space-default",
            "Size" => 321,
            "MetaData" =>
              upload_metadata(embed, %{
                "filetype" => "video/mp4",
                "enqueue" => "false"
              }),
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => "uploads/space-default.mp4"
            }
          }
        }
      })

    assert %{"status" => "ok", "flow_run_id" => flow_run_id} = json_response(conn, 200)

    assert %Run{} = flow_run = Flow.get_run(flow_run_id)
    assert flow_run.flow_template.slug == "space_default_test"
  end

  test "upload metadata template overrides the space default template", %{conn: conn} do
    {:ok, _template} =
      Flow.create_template(%{"slug" => "upload_test", "name" => "Upload Test"})

    {:ok, _version} = Flow.create_version("upload_test", %{"definition" => @definition})

    {:ok, _template} =
      Flow.create_template(%{"slug" => "space_default_test", "name" => "Space Default Test"})

    {:ok, _version} = Flow.create_version("space_default_test", %{"definition" => @definition})

    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Metadata Override Upload"})

    assert {:ok, _space} =
             Spaces.update_space_processing(space, %{
               default_flow_template: "space_default_test"
             })

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-metadata-override",
            "Size" => 654,
            "MetaData" =>
              upload_metadata(embed, %{
                "template" => "upload_test",
                "filetype" => "video/mp4",
                "enqueue" => "false"
              }),
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => "uploads/metadata-override.mp4"
            }
          }
        }
      })

    assert %{"status" => "ok", "flow_run_id" => flow_run_id} = json_response(conn, 200)

    assert %Run{} = flow_run = Flow.get_run(flow_run_id)
    assert flow_run.flow_template.slug == "upload_test"
  end

  test "known built-in presets auto-install when selected by metadata", %{conn: conn} do
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Built In Preset Upload"})

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-built-in-preset",
            "Size" => 777,
            "MetaData" =>
              upload_metadata(embed, %{
                "template" => "publish_local",
                "filetype" => "video/mp4",
                "enqueue" => "false"
              }),
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => "uploads/built-in-preset.mp4"
            }
          }
        }
      })

    assert %{"status" => "ok", "flow_run_id" => flow_run_id} = json_response(conn, 200)

    assert %Run{} = flow_run = Flow.get_run(flow_run_id)
    assert flow_run.flow_template.slug == "publish_local"
    assert flow_run.flow_version.version == 1
  end

  test "rejects raw embed_id metadata without a signed upload JWT", %{conn: conn} do
    {:ok, _template} = Flow.create_template(%{"slug" => "upload_test", "name" => "Upload Test"})
    {:ok, _version} = Flow.create_version("upload_test", %{"definition" => @definition})
    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Combined Upload"})

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-embed-id",
            "Size" => 456,
            "MetaData" => %{
              "template" => "upload_test",
              "embed_id" => "#{space.hash}#{embed.hash}",
              "enqueue" => "false"
            },
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => "uploads/embed-id-video.mp4"
            }
          }
        }
      })

    assert %{"status" => "error", "error" => error} = json_response(conn, 200)

    assert error =~ "missing_upload_jwt"
    assert Repo.aggregate(Run, :count, :id) == 0
  end

  test "rejects invalid upload JWT metadata", %{conn: conn} do
    {:ok, _template} = Flow.create_template(%{"slug" => "upload_test", "name" => "Upload Test"})
    {:ok, _version} = Flow.create_version("upload_test", %{"definition" => @definition})

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-invalid-token",
            "Size" => 456,
            "MetaData" => %{
              "template" => "upload_test",
              "token" => "not-a-valid-jwt",
              "enqueue" => "false"
            },
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => "uploads/invalid-token-video.mp4"
            }
          }
        }
      })

    assert %{"status" => "error", "error" => error} = json_response(conn, 200)

    assert error =~ "invalid_upload_jwt"
    assert Repo.aggregate(Run, :count, :id) == 0
  end

  test "API-key upload JWT metadata resolves the upload target and creates a current video", %{
    conn: conn
  } do
    {:ok, _template} = Flow.create_template(%{"slug" => "upload_test", "name" => "Upload Test"})
    {:ok, _version} = Flow.create_version("upload_test", %{"definition" => @definition})

    space = space_fixture()
    embed = placeholder_video_embed_fixture(space, %{name: "Token Upload"})
    {:ok, key} = Spaces.create_key(space)
    token = Token.sign_api_key(key, SettingsSerializer.public_embed_id(space, embed))

    assert [_, _, _] = String.split(token, ".")
    assert {:ok, %{claims: claims}} = Spaces.validate_api_jwt(token, false)
    assert claims["sub"] == SettingsSerializer.public_embed_id(space, embed)

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-token",
            "Size" => 654,
            "MetaData" => %{
              "template" => "upload_test",
              "token" => token,
              "title" => "Token Upload.mp4",
              "enqueue" => "false"
            },
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => "uploads/token-video.mp4"
            }
          }
        }
      })

    assert %{"status" => "ok", "flow_run_id" => flow_run_id} = json_response(conn, 200)

    assert flow_run = Flow.get_run(flow_run_id)
    assert flow_run.input["space_hash"] == space.hash
    assert flow_run.input["embed_hash"] == embed.hash

    reloaded_asset = Repo.get!(Asset, embed.asset_id)
    assert is_binary(reloaded_asset.current_video_id)

    current_video = Repo.get!(Video, reloaded_asset.current_video_id)
    assert current_video.status == "preparing"
    assert current_video.file_name == "Token Upload.mp4"
    assert current_video.original_file_size == 654
  end

  test "API-key upload JWT scoped to a space shortuuid creates a new root video", %{conn: conn} do
    {:ok, _template} = Flow.create_template(%{"slug" => "upload_test", "name" => "Upload Test"})
    {:ok, _version} = Flow.create_version("upload_test", %{"definition" => @definition})

    space = space_fixture()
    {:ok, key} = Spaces.create_key(space)
    token = Token.sign_api_key(key, space.id)

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-space-token",
            "Size" => 321,
            "MetaData" => %{
              "template" => "upload_test",
              "token" => token,
              "title" => "New API Upload.mp4",
              "enqueue" => "false"
            },
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => "uploads/api-space-video.mp4"
            }
          }
        }
      })

    assert %{"status" => "ok", "flow_run_id" => flow_run_id} = json_response(conn, 200)

    assert flow_run = Flow.get_run(flow_run_id)
    assert flow_run.input["space_hash"] == space.hash
    assert flow_run.input["source_key"] == "uploads/api-space-video.mp4"

    assert %Embed{type: :video, asset: %{current_video: %Video{} = video}} =
             Embeds.get_embed_by_hashes(space.hash, flow_run.input["embed_hash"])

    assert video.status == "preparing"
    assert video.file_name == "New API Upload.mp4"
  end

  test "API-key upload JWT scoped to a collection public id creates a child video", %{conn: conn} do
    {:ok, _template} = Flow.create_template(%{"slug" => "upload_test", "name" => "Upload Test"})
    {:ok, _version} = Flow.create_version("upload_test", %{"definition" => @definition})

    space = space_fixture()
    {:ok, folder} = Embeds.create_folder_embed(space, %{name: "Uploads"})
    {:ok, key} = Spaces.create_key(space)
    token = Token.sign_api_key(key, SettingsSerializer.public_embed_id(space, folder))

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-collection-token",
            "Size" => 654,
            "MetaData" => %{
              "template" => "upload_test",
              "token" => token,
              "title" => "Collection Upload.mp4",
              "enqueue" => "false"
            },
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => "uploads/api-collection-video.mp4"
            }
          }
        }
      })

    assert %{"status" => "ok", "flow_run_id" => flow_run_id} = json_response(conn, 200)

    flow_run = Flow.get_run(flow_run_id)
    created_embed = Embeds.get_embed_by_hashes(space.hash, flow_run.input["embed_hash"])

    assert %Embed{type: :video} = created_embed

    assert Repo.get_by(CollectionEmbed,
             collection_id: folder.collection_id,
             embed_id: created_embed.id
           )
  end

  test "API-key upload JWT scoped to a video public id replaces that video", %{conn: conn} do
    {:ok, _template} = Flow.create_template(%{"slug" => "upload_test", "name" => "Upload Test"})
    {:ok, _version} = Flow.create_version("upload_test", %{"definition" => @definition})

    space = space_fixture()
    embed = video_embed_fixture(space, %{name: "API Replacement"})
    original_asset = Repo.get!(Asset, embed.asset_id)
    {:ok, key} = Spaces.create_key(space)
    token = Token.sign_api_key(key, SettingsSerializer.public_embed_id(space, embed))

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-video-token",
            "Size" => 987,
            "MetaData" => %{
              "template" => "upload_test",
              "token" => token,
              "title" => "API Replacement.mp4",
              "enqueue" => "false"
            },
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => "uploads/api-replacement-video.mp4"
            }
          }
        }
      })

    assert %{"status" => "ok", "flow_run_id" => flow_run_id} = json_response(conn, 200)

    assert flow_run = Flow.get_run(flow_run_id)
    assert flow_run.input["space_hash"] == space.hash
    assert flow_run.input["embed_hash"] == embed.hash

    refreshed_asset = Repo.get!(Asset, embed.asset_id)
    refute refreshed_asset.current_video_id == original_asset.current_video_id
  end

  @tag :poster_booster
  test "custom thumbnail upload hooks offload every format and keep the source private", %{
    conn: conn
  } do
    configure_thumbnail_booster()
    space = space_fixture()
    embed = video_embed_fixture(space, %{name: "Booster Poster"})
    source_key = "uploads/posters/#{embed.hash}.jpg"

    {:ok, _} =
      FlowStorageAdapterStub.put(
        "mave-upload",
        source_key,
        <<0xFF, 0xD8, 0xFF, "poster-signature">>,
        "image/jpeg",
        @upload_source_region
      )

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-booster-poster",
            "Size" => 901_913,
            "MetaData" =>
              upload_metadata(embed, %{"custom_thumbnail" => "true", "filetype" => "image/jpeg"}),
            "Storage" => %{"Bucket" => "mave-upload", "Key" => source_key}
          }
        }
      })

    assert %{"status" => "ok", "action" => "custom_thumbnail"} = json_response(conn, 200)
    assert Repo.aggregate(Run, :count, :id) == 0

    for codec <- ~w(jpg webp avif) do
      assert_receive {:thumbnail_booster_request, input_url, options}
      assert input_url == "https://storage.example/mave-upload/#{source_key}?signature=test"
      assert options[:operation] == "frame"
      assert options[:frame_role] == "custom_thumbnail"
      assert options[:frame_codec] == codec

      assert {:ok, body} =
               FlowStorageAdapterStub.get(
                 "space-#{space.hash}",
                 "#{embed.hash}/thumbnail.#{codec}",
                 space.region
               )

      assert body == "converted-#{codec}"
    end

    # The API validates the signature; conversion stays on the booster.
    refute FlowStorageAdapterStub.public?("mave-upload", source_key, @upload_source_region)
    updated = Repo.get!(Embed, embed.id) |> Repo.preload(:settings)
    assert updated.settings.poster == :upload
    assert updated.settings.external_poster =~ "/thumbnail.jpg"
  end

  @tag :poster_booster
  test "failed poster boosts return the error without running FFmpeg on the API node" do
    configure_thumbnail_booster()
    Application.put_env(:mave_core, :thumbnail_booster_test_error, :encoding_booster_busy)
    space = space_fixture()
    embed = video_embed_fixture(space, %{name: "Failed Booster Poster"})

    {:ok, _} =
      FlowStorageAdapterStub.put(
        "mave-upload",
        "uploads/poster.jpg",
        <<0xFF, 0xD8, 0xFF, "poster-signature">>,
        "image/jpeg",
        @upload_source_region
      )

    assert {:error, {:media_extract_frame_failed, :encoding_booster_busy}} =
             Assets.ingest_uploaded_thumbnail(embed, "mave-upload", "uploads/poster.jpg")

    assert_receive {:thumbnail_booster_request, _input_url, options}
    assert options[:frame_codec] == "jpg"
    refute_receive {:thumbnail_booster_request, _, _}
    assert Repo.aggregate(Run, :count, :id) == 0
    assert Repo.get!(Embed, embed.id) |> Repo.preload(:settings) |> Map.get(:settings) == nil
  end

  defp configure_thumbnail_booster do
    overrides = [
      encoding_booster: [enabled: true, fallback_enabled: true],
      encoding_booster_adapter: MaveCore.TestSupport.CustomThumbnailBoosterStub,
      thumbnail_booster_test_pid: self(),
      thumbnail_booster_test_error: nil
    ]

    previous =
      Enum.map(overrides, fn {key, _value} -> {key, Application.get_env(:mave_core, key)} end)

    Enum.each(overrides, fn {key, value} -> Application.put_env(:mave_core, key, value) end)
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)
  end

  test "custom_thumbnail uploads update embed settings without starting a flow run", %{conn: conn} do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      assert true
    else
      test_pid = self()

      Application.put_env(:mave_core, :cdn_cache_purger, fn space_hash, region, paths ->
        send(test_pid, {:purged, space_hash, region, paths})
        :ok
      end)

      space =
        space_fixture()
        |> Ecto.Changeset.change(%{region: "eu"})
        |> Repo.update!()

      embed = video_embed_fixture(space, %{name: "Poster Target"})
      source_key = "uploads/posters/#{embed.hash}.png"
      destination_key = "#{embed.hash}/thumbnail.jpg"

      tmp_dir =
        Path.join(System.tmp_dir!(), "mave_poster_upload_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      input_path = Path.join(tmp_dir, "poster.png")

      {_output, 0} =
        System.cmd(
          ffmpeg_bin,
          [
            "-y",
            "-f",
            "lavfi",
            "-i",
            "color=c=red:s=320x180",
            "-frames:v",
            "1",
            input_path
          ],
          stderr_to_stdout: true
        )

      assert {:ok, _} =
               FlowStorageAdapterStub.put(
                 "mave-upload",
                 source_key,
                 File.read!(input_path),
                 "image/png",
                 @upload_source_region
               )

      conn =
        post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
          "Type" => "post-finish",
          "Event" => %{
            "Upload" => %{
              "ID" => "upload-poster",
              "Size" => 789,
              "MetaData" =>
                upload_metadata(embed, %{
                  "custom_thumbnail" => "true",
                  "filetype" => "image/png"
                }),
              "Storage" => %{
                "Bucket" => "mave-upload",
                "Key" => source_key
              }
            }
          }
        })

      assert %{
               "status" => "ok",
               "action" => "custom_thumbnail",
               "embed_hash" => embed_hash
             } = json_response(conn, 200)

      assert embed_hash == embed.hash
      assert Repo.aggregate(Run, :count, :id) == 0

      refute FlowStorageAdapterStub.public?("mave-upload", source_key, @upload_source_region)

      updated_embed =
        Repo.get!(Embed, embed.id)
        |> Repo.preload([:settings, asset: [:current_video]])

      assert updated_embed.settings.poster == :upload

      assert updated_embed.settings.external_poster ==
               SettingsSerializer.storage_object_url("space-#{space.hash}", destination_key)

      assert {:ok, <<0xFF, 0xD8, _rest::binary>>} =
               FlowStorageAdapterStub.get("space-#{space.hash}", destination_key, space.region)

      assert {:ok, manifest_json} =
               FlowStorageAdapterStub.get(
                 "space-#{space.hash}",
                 "#{embed.hash}/manifest.json",
                 space.region
               )

      assert %{"poster" => %{"image_src" => expected_thumbnail_url}} =
               Jason.decode!(manifest_json)

      assert expected_thumbnail_url ==
               SettingsSerializer.storage_object_url("space-#{space.hash}", destination_key)

      expected_containers = available_thumbnail_containers(ffmpeg_bin)

      Enum.each(expected_containers, fn container ->
        assert {:ok, _body} =
                 FlowStorageAdapterStub.get(
                   "space-#{space.hash}",
                   "#{embed.hash}/thumbnail.#{container}",
                   space.region
                 )
      end)

      current_video_id = updated_embed.asset.current_video_id

      custom_thumbnails =
        Repo.all(
          from(r in "renditions",
            where: r.video_id == type(^current_video_id, MaveCore.Ecto.LegacyShortUUID),
            where: r.type == "custom_thumbnail",
            select: %{
              rendition_key: r.rendition_key,
              container: r.container,
              progress: r.progress
            }
          )
        )

      assert MapSet.new(Enum.map(custom_thumbnails, & &1.container)) ==
               MapSet.new(expected_containers)

      assert Enum.all?(custom_thumbnails, &(&1.progress == 100.0))
      assert Enum.any?(custom_thumbnails, &(&1.rendition_key == destination_key))

      {:ok, custom_jpg} =
        FlowStorageAdapterStub.get("space-#{space.hash}", destination_key, space.region)

      assert {:ok, _body} =
               FlowStorageAdapterStub.put_public(
                 "space-#{space.hash}",
                 destination_key,
                 "late-generated-thumbnail",
                 "image/jpeg",
                 space.region
               )

      assert :ok = Assets.sync_public_thumbnail(updated_embed)

      assert {:ok, ^custom_jpg} =
               FlowStorageAdapterStub.get(
                 "space-#{space.hash}",
                 destination_key,
                 space.region
               )

      purged_paths =
        for _ <- 1..2, reduce: [] do
          paths ->
            assert_receive {:purged, purged_space_hash, "eu", next_paths}
            assert purged_space_hash == space.hash
            paths ++ next_paths
        end

      assert "#{embed.hash}/manifest.json" in purged_paths
      assert "#{embed.hash}/" in purged_paths

      Enum.each(expected_containers, fn container ->
        assert "#{embed.hash}/thumbnail.#{container}" in purged_paths
        assert "#{embed.hash}/custom_thumbnail.#{container}" in purged_paths
      end)
    end
  end

  test "custom media rejects disguised playlists and documents before publishing" do
    space = space_fixture()
    embed = video_embed_fixture(space, %{name: "Custom source validation"})

    for body <- [
          "#EXTM3U\nhttps://127.0.0.1/private",
          "ffconcat version 1.0\nfile '/private'",
          "<MPD></MPD>",
          "<svg></svg>",
          "<html></html>"
        ] do
      {:ok, _} =
        FlowStorageAdapterStub.put(
          "mave-upload",
          "disguised.png",
          body,
          "image/png",
          @upload_source_region
        )

      {:ok, _} =
        FlowStorageAdapterStub.put(
          "mave-upload",
          "disguised.mp3",
          body,
          "text/html",
          @upload_source_region
        )

      assert {:error, :unsupported_image_signature} =
               Assets.ingest_uploaded_thumbnail(embed, "mave-upload", "disguised.png", %{
                 content_type: "image/png"
               })

      assert {:error, :unsupported_audio_signature} =
               Assets.ingest_uploaded_audio_track(
                 embed,
                 %{filename: "disguised.mp3", content_type: "text/html"},
                 "mave-upload",
                 "disguised.mp3"
               )

      assert {:ok, []} =
               FlowStorageAdapterStub.list_prefix_keys("space-#{space.hash}", "", space.region)
    end
  end

  test "custom audio track uploads create an audio track and package hls audio", %{conn: conn} do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      assert true
    else
      space = space_fixture()
      embed = video_embed_fixture(space, %{name: "Audio Target"})

      tmp_dir =
        Path.join(System.tmp_dir!(), "mave_audio_upload_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      input_path = Path.join(tmp_dir, "commentary.mp3")

      {_output, 0} =
        System.cmd(
          ffmpeg_bin,
          [
            "-y",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=1000:duration=2",
            "-codec:a",
            "libmp3lame",
            "-b:a",
            "128k",
            input_path
          ],
          stderr_to_stdout: true
        )

      assert {:ok, _} =
               FlowStorageAdapterStub.put(
                 "mave-upload",
                 "uploads/commentary.mp3",
                 File.read!(input_path),
                 "audio/mpeg",
                 @upload_source_region
               )

      conn =
        post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
          "Type" => "post-finish",
          "Event" => %{
            "Upload" => %{
              "ID" => "upload-audio-track",
              "Size" => 12_345,
              "MetaData" =>
                upload_metadata(embed, %{
                  "custom_audio_track" => "true",
                  "label" => "Commentary",
                  "language" => "nl",
                  "filetype" => "audio/mpeg"
                }),
              "Storage" => %{
                "Bucket" => "mave-upload",
                "Key" => "uploads/commentary.mp3"
              }
            }
          }
        })

      assert %{
               "status" => "ok",
               "action" => "custom_audio_track",
               "audio_track_id" => track_id
             } = json_response(conn, 200)

      asset = Repo.get!(Asset, embed.asset_id)
      assert %AudioTrack{} = track = Repo.get(AudioTrack, track_id)
      assert track.video_id == asset.current_video_id
      assert track.label == "Commentary"
      assert track.language == "nl"
      assert track.filename == "commentary.mp3"

      assert {:ok, _} =
               Assets.ingest_uploaded_audio_track(
                 embed,
                 %{
                   filename: "safe-type.mp3",
                   label: "Safe type",
                   language: "en",
                   content_type: "text/html"
                 },
                 "mave-upload",
                 "uploads/commentary.mp3"
               )

      assert {:ok, %{content_type: "application/octet-stream"}} =
               FlowStorageAdapterStub.object_info(
                 "space-#{space.hash}",
                 "#{embed.hash}/safe-type.mp3",
                 space.region
               )

      assert {:ok, _body} =
               FlowStorageAdapterStub.get(
                 "space-#{space.hash}",
                 "#{embed.hash}/commentary.mp3",
                 space.region
               )

      assert {:ok, playlist_body} =
               FlowStorageAdapterStub.get(
                 "space-#{space.hash}",
                 "#{embed.hash}/commentary_hls/playlist.m3u8",
                 space.region
               )

      assert String.contains?(playlist_body, "#EXTM3U")
      File.rm_rf(tmp_dir)
    end
  end

  test "custom audio track uploads can replace an existing audio track", %{conn: conn} do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      assert true
    else
      space = space_fixture()
      embed = video_embed_fixture(space, %{name: "Audio Replace Target"})
      asset = Repo.get!(Asset, embed.asset_id)

      track =
        %AudioTrack{}
        |> AudioTrack.changeset(%{
          video_id: asset.current_video_id,
          label: "Original Commentary",
          language: "en",
          codec: "mp3",
          filename: "original-commentary.mp3",
          default: false
        })
        |> Repo.insert!()

      tmp_dir =
        Path.join(System.tmp_dir!(), "mave_audio_replace_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      input_path = Path.join(tmp_dir, "replacement-commentary.mp3")

      {_output, 0} =
        System.cmd(
          ffmpeg_bin,
          [
            "-y",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=1200:duration=2",
            "-codec:a",
            "libmp3lame",
            "-b:a",
            "128k",
            input_path
          ],
          stderr_to_stdout: true
        )

      assert {:ok, _} =
               FlowStorageAdapterStub.put(
                 "mave-upload",
                 "uploads/replacement-commentary.mp3",
                 File.read!(input_path),
                 "audio/mpeg",
                 @upload_source_region
               )

      conn =
        post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
          "Type" => "post-finish",
          "Event" => %{
            "Upload" => %{
              "ID" => "upload-audio-track-replace",
              "Size" => 23_456,
              "MetaData" =>
                upload_metadata(embed, %{
                  "custom_audio_track" => "true",
                  "audio_track_id" => track.id,
                  "label" => "Dutch Commentary",
                  "language" => "nl",
                  "filetype" => "audio/mpeg"
                }),
              "Storage" => %{
                "Bucket" => "mave-upload",
                "Key" => "uploads/replacement-commentary.mp3"
              }
            }
          }
        })

      assert %{
               "status" => "ok",
               "action" => "custom_audio_track",
               "audio_track_id" => returned_track_id
             } = json_response(conn, 200)

      assert returned_track_id == track.id

      assert %AudioTrack{} = updated_track = Repo.get(AudioTrack, track.id)
      assert updated_track.label == "Dutch Commentary"
      assert updated_track.language == "nl"
      assert updated_track.filename == "replacement-commentary.mp3"

      assert {:ok, _body} =
               FlowStorageAdapterStub.get(
                 "space-#{space.hash}",
                 "#{embed.hash}/replacement-commentary.mp3",
                 space.region
               )

      File.rm_rf(tmp_dir)
    end
  end

  test "custom audio track uploads reject replacement IDs from another space", %{conn: conn} do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      assert true
    else
      space = space_fixture()
      embed = video_embed_fixture(space, %{name: "Audio Replace Scoped Target"})

      foreign_space = space_fixture()
      foreign_embed = video_embed_fixture(foreign_space, %{name: "Audio Replace Foreign Target"})
      foreign_asset = Repo.get!(Asset, foreign_embed.asset_id)

      foreign_track =
        %AudioTrack{}
        |> AudioTrack.changeset(%{
          video_id: foreign_asset.current_video_id,
          label: "Foreign Commentary",
          language: "en",
          codec: "mp3",
          filename: "foreign-commentary.mp3",
          default: false
        })
        |> Repo.insert!()

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "mave_audio_foreign_replace_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      input_path = Path.join(tmp_dir, "foreign-replacement.mp3")

      {_output, 0} =
        System.cmd(
          ffmpeg_bin,
          [
            "-y",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=800:duration=2",
            "-codec:a",
            "libmp3lame",
            "-b:a",
            "128k",
            input_path
          ],
          stderr_to_stdout: true
        )

      assert {:ok, _} =
               FlowStorageAdapterStub.put(
                 "mave-upload",
                 "uploads/foreign-replacement.mp3",
                 File.read!(input_path),
                 "audio/mpeg",
                 @upload_source_region
               )

      conn =
        post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
          "Type" => "post-finish",
          "Event" => %{
            "Upload" => %{
              "ID" => "upload-audio-track-foreign-replace",
              "Size" => 23_456,
              "MetaData" =>
                upload_metadata(embed, %{
                  "custom_audio_track" => "true",
                  "audio_track_id" => foreign_track.id,
                  "label" => "Hijacked Commentary",
                  "language" => "nl",
                  "filetype" => "audio/mpeg"
                }),
              "Storage" => %{
                "Bucket" => "mave-upload",
                "Key" => "uploads/foreign-replacement.mp3"
              }
            }
          }
        })

      assert %{"status" => "error", "error" => error} = json_response(conn, 200)
      assert error =~ "audio_track_not_found"

      assert %AudioTrack{} = unchanged_track = Repo.get(AudioTrack, foreign_track.id)
      assert unchanged_track.video_id == foreign_track.video_id
      assert unchanged_track.label == "Foreign Commentary"
      assert unchanged_track.language == "en"
      assert unchanged_track.filename == "foreign-commentary.mp3"

      File.rm_rf(tmp_dir)
    end
  end

  test "custom subtitle uploads create a subtitle and republish the manifest", %{conn: conn} do
    space = space_fixture()
    embed = video_embed_fixture(space, %{name: "Subtitle Target"})
    asset = Repo.get!(Asset, embed.asset_id)
    source_key = "uploads/subtitles/#{embed.hash}.vtt"
    destination_key = "#{embed.hash}/subtitle_nl.vtt"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(asset.current_video_id),
        rendition_key: "#{embed.hash}/h264_sd_hls/playlist.m3u8",
        type: "video",
        codec: "h264",
        container: "hls",
        size: "sd",
        progress: 100.0,
        file_size: 123,
        inserted_at: now,
        updated_at: now
      }
    ])

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               "mave-upload",
               source_key,
               "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHallo wereld\n",
               "text/vtt",
               @upload_source_region
             )

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-subtitle",
            "Size" => 54,
            "MetaData" =>
              upload_metadata(embed, %{
                "custom_subtitle" => "true",
                "language" => "nl"
              }),
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => source_key
            }
          }
        }
      })

    assert %{
             "status" => "ok",
             "action" => "custom_subtitle",
             "subtitle_id" => subtitle_id
           } = json_response(conn, 200)

    assert Repo.aggregate(Run, :count, :id) == 0

    assert %Subtitle{} = subtitle = Repo.get(Subtitle, subtitle_id)
    assert subtitle.video_id == asset.current_video_id
    assert subtitle.language == "nl"
    assert subtitle.path == destination_key

    assert {:ok, subtitle_body} =
             FlowStorageAdapterStub.get("space-#{space.hash}", destination_key, space.region)

    assert subtitle_body =~ "WEBVTT"

    assert {:ok, manifest_body} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/manifest.json",
               space.region
             )

    manifest = Jason.decode!(manifest_body)

    assert manifest["subtitles"] == [
             %{
               "language" => "nl",
               "label" => "Dutch",
               "path" =>
                 SettingsSerializer.storage_object_url("space-#{space.hash}", destination_key) <>
                   "?e=#{DateTime.to_unix(subtitle.updated_at, :microsecond)}"
             }
           ]

    assert {:ok, playlist_body} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/playlist.m3u8",
               space.region
             )

    assert playlist_body =~ "#EXT-X-MEDIA:TYPE=SUBTITLES"
    assert playlist_body =~ ~s(URI="subtitle_nl_hls/playlist.m3u8")
    assert playlist_body =~ ~s(SUBTITLES="subtitles")

    assert {:ok, subtitle_playlist} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/subtitle_nl_hls/playlist.m3u8",
               space.region
             )

    assert subtitle_playlist =~ "../subtitle_nl.vtt"
  end

  test "custom subtitle uploads cannot reassign a subtitle from another space", %{conn: conn} do
    space = space_fixture()
    embed = video_embed_fixture(space, %{name: "Scoped Subtitle Upload"})
    asset = Repo.get!(Asset, embed.asset_id)

    foreign_space = space_fixture()
    foreign_embed = video_embed_fixture(foreign_space, %{name: "Foreign Subtitle Upload"})
    foreign_asset = Repo.get!(Asset, foreign_embed.asset_id)

    foreign_subtitle =
      %Subtitle{}
      |> Subtitle.changeset(%{
        video_id: foreign_asset.current_video_id,
        language: "en",
        path: "#{foreign_embed.hash}/subtitle_en.vtt"
      })
      |> Repo.insert!()

    source_key = "uploads/subtitles/#{embed.hash}-scoped.vtt"

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               "mave-upload",
               source_key,
               "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHallo wereld\n",
               "text/vtt",
               @upload_source_region
             )

    conn =
      post(conn, ~p"/internal/upload-hooks/tusd?secret=hook_secret", %{
        "Type" => "post-finish",
        "Event" => %{
          "Upload" => %{
            "ID" => "upload-subtitle-foreign-replace",
            "Size" => 54,
            "MetaData" =>
              upload_metadata(embed, %{
                "custom_subtitle" => "true",
                "subtitle_id" => foreign_subtitle.id,
                "language" => "nl"
              }),
            "Storage" => %{
              "Bucket" => "mave-upload",
              "Key" => source_key
            }
          }
        }
      })

    assert %{
             "status" => "ok",
             "action" => "custom_subtitle",
             "subtitle_id" => local_subtitle_id
           } = json_response(conn, 200)

    refute local_subtitle_id == foreign_subtitle.id

    assert %Subtitle{} = local_subtitle = Repo.get(Subtitle, local_subtitle_id)
    assert local_subtitle.video_id == asset.current_video_id
    assert local_subtitle.language == "nl"

    assert %Subtitle{} = unchanged_foreign = Repo.get(Subtitle, foreign_subtitle.id)
    assert unchanged_foreign.video_id == foreign_subtitle.video_id
    assert unchanged_foreign.language == "en"
    assert unchanged_foreign.path == foreign_subtitle.path
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp with_maintenance(fun) do
    previous = Application.get_env(:mave_core, :maintenance_mode)
    Application.put_env(:mave_core, :maintenance_mode, true)

    try do
      fun.()
    after
      restore_env(:maintenance_mode, previous)
    end
  end

  defp space_fixture do
    email = "upload-hook-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    user.current_space_membership.space
  end

  defp force_space_hash!(space, hash) do
    space
    |> Ecto.Changeset.change(%{hash: hash})
    |> Repo.update!()
  end

  defp video_embed_fixture(%Space{} = space, attrs) do
    asset =
      %Asset{}
      |> Asset.changeset(%{
        space_id: space.id,
        name: Map.get(attrs, :name, "Upload Video")
      })
      |> Repo.insert!()

    video =
      %Video{}
      |> Video.changeset(%{
        asset_id: asset.id,
        status: "ready",
        file_name: "#{Map.get(attrs, :name, "upload")}.mp4",
        max_width: 1920,
        max_height: 1080,
        max_frame_rate: 30.0,
        max_bitrate: 10_000_000,
        duration: 40.0,
        aspect_ratio: "16/9",
        original_file_size: 100_000_000
      })
      |> Repo.insert!()

    asset
    |> Ecto.Changeset.change(current_video_id: video.id)
    |> Repo.update!()

    %Embed{}
    |> Embed.changeset(%{
      space_id: space.id,
      asset_id: asset.id,
      hash: unique_embed_hash(),
      type: :video
    })
    |> Repo.insert!()
  end

  defp placeholder_video_embed_fixture(%Space{} = space, attrs) do
    asset =
      %Asset{}
      |> Asset.changeset(%{
        space_id: space.id,
        name: Map.get(attrs, :name, "Upload Video")
      })
      |> Repo.insert!()

    %Embed{}
    |> Embed.changeset(%{
      space_id: space.id,
      asset_id: asset.id,
      hash: unique_embed_hash(),
      type: :video
    })
    |> Repo.insert!()
  end

  defp upload_metadata(%Embed{} = embed, attrs) do
    Map.put(attrs, "token", upload_token(embed))
  end

  defp upload_token(%Embed{} = embed) do
    space = Repo.preload(embed, :space).space
    {:ok, key} = Spaces.ensure_key(space)
    Token.sign_api_key(key, SettingsSerializer.public_embed_id(space, embed))
  end

  defp available_thumbnail_containers(ffmpeg_bin) do
    case System.cmd(ffmpeg_bin, ["-hide_banner", "-encoders"], stderr_to_stdout: true) do
      {output, 0} ->
        ["jpg"] ++
          if(String.contains?(output, "libwebp"), do: ["webp"], else: []) ++
          if(String.contains?(output, "libsvtav1"), do: ["avif"], else: [])

      _ ->
        ["jpg"]
    end
  end

  defp unique_embed_hash do
    System.unique_integer([:positive])
    |> Integer.to_string(36)
    |> String.pad_leading(10, "0")
    |> String.slice(-10, 10)
  end
end
