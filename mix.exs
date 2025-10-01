defmodule NervesSystemShell.MixProject do
  use Mix.Project

  def project do
    [
      app: :nerves_system_shell,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssh]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:expty, "~> 0.2.1"}
    ]
  end
end
