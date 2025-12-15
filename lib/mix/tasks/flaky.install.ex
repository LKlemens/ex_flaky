defmodule Mix.Tasks.Flaky.Install do
  @moduledoc """
  Build and install the flaky binary locally.

  ## Usage

      mix flaky.install

  This task can be run from:
  - The ex_flaky project itself
  - Any project that has ex_flaky as a dependency
  """

  use Mix.Task

  @shortdoc "Build and install flaky binary"

  @spec run(list(String.t())) :: :ok | no_return()
  def run(_args) do
    flaky_path = find_flaky_path()
    escript_path = Path.join(flaky_path, "flaky")

    Mix.shell().info("Building escript in #{flaky_path}...")

    case System.cmd("mix", ["escript.build"],
           cd: flaky_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        Mix.raise("Failed to build escript:\n#{output}")
    end

    Mix.shell().info("Installing #{escript_path}...")

    case System.cmd("mix", ["escript.install", "--force", escript_path], stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(output)
        :ok

      {output, _code} ->
        Mix.raise("Failed to install escript:\n#{output}")
    end
  end

  @spec find_flaky_path() :: String.t()
  defp find_flaky_path do
    cond do
      Mix.Project.config()[:app] == :ex_flaky ->
        File.cwd!()

      dep_path = Mix.Project.deps_paths()[:ex_flaky] ->
        dep_path

      true ->
        Mix.raise("Could not find ex_flaky project")
    end
  end
end
