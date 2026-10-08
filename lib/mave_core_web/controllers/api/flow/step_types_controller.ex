defmodule MaveCoreWeb.Api.Flow.StepTypesController do
  use MaveCoreWeb, :controller

  def index(conn, _params) do
    json(conn, %{data: MaveCore.Flow.list_step_types()})
  end
end
