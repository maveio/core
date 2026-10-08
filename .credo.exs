%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/", "mix.exs"],
        excluded: [~r"/_build/", ~r"/deps/"]
      }
    }
  ]
}
