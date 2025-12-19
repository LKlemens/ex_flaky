defmodule ExFlaky.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_flaky,
      version: "0.1.2",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      description: "Detects new tests in git diff and runs them repeatedly to catch flaky tests",
      package: package()
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/LKlemens/ex_flaky"}
    ]
  end

  defp escript do
    [
      main_module: Flaky.CLI,
      name: "flaky"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:termite, "~> 0.1"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
