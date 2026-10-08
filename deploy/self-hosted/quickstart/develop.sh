#!/bin/sh
set -eu
mix deps.get
mix ecto.create -r MaveCore.Repo -r MaveCore.ClickHouseRepo
mix ecto.migrate -r MaveCore.Repo -r MaveCore.ClickHouseRepo
mix assets.setup
mix assets.build
mix ua_inspector.download --force
