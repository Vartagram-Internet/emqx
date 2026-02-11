defmodule EMQXDeliveryTimeout.MixProject do
  use Mix.Project

  def project do
    [
      app: :emqx_delivery_timeout,
      version: "0.1.0",
      build_path: "../../_build",
      erlc_options: [:debug_info],
      erlc_paths: ["src"],
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {:emqx_delivery_timeout_app, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:emqx, in_umbrella: true}
    ]
  end
end
