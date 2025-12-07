defmodule Mix.Tasks.Flaky do
  @moduledoc """
  Detects new tests in git diff (HEAD vs main) and runs them repeatedly to catch flaky tests.

  ## Usage

      mix flaky [options]

  ## Options

    * `--iterations`, `-n` - Number of times to repeat each test (default: 100)
    * `--base`, `-b` - Base branch to compare against (default: main)
    * `--seed`, `-s` - Specific seed for reproducibility
    * `--dry-run` - Show which tests would be run without running them
    * `--parallel`, `-p` - Run tests in parallel with N concurrent processes (default: 3)
    * `--failed`, `-f` - Re-run only previously failed tests from .flaky/failed_tests.txt
    * `--print-full-log`, `-l` - Show full error logs (default: 10 lines)
    * `--watch-errors`, `-w` - Tail error log file in real-time
    * `--help`, `-h` - Show this help message

  ## Examples

      mix flaky
      mix flaky --iterations 50
      mix flaky --base develop
      mix flaky --seed 12345 --iterations 200
      mix flaky --dry-run
      mix flaky --parallel 3
      mix flaky -p 5
      mix flaky --failed
      mix flaky --print-full-log
  """

  use Mix.Task

  @shortdoc "Run new tests repeatedly to detect flaky tests"

  @switches [
    iterations: :integer,
    base: :string,
    seed: :integer,
    dry_run: :boolean,
    parallel: :integer,
    failed: :boolean,
    print_full_log: :boolean,
    watch_errors: :boolean,
    help: :boolean
  ]

  @aliases [
    n: :iterations,
    b: :base,
    s: :seed,
    p: :parallel,
    f: :failed,
    l: :print_full_log,
    w: :watch_errors,
    h: :help
  ]

  @spec run(list(String.t())) :: :ok | no_return()
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    if Keyword.get(opts, :help, false) do
      Mix.shell().info(@moduledoc)
    else
      run_opts = %{
        iterations: Keyword.get(opts, :iterations, 100),
        base: Keyword.get(opts, :base, "main"),
        seed: Keyword.get(opts, :seed),
        dry_run: Keyword.get(opts, :dry_run, false),
        parallel: Keyword.get(opts, :parallel),
        failed: Keyword.get(opts, :failed, false),
        print_full_log: Keyword.get(opts, :print_full_log, false),
        watch_errors: Keyword.get(opts, :watch_errors, false)
      }

      case Flaky.run(run_opts) do
        :ok -> :ok
        {:error, msg} -> Mix.raise(msg)
      end
    end
  end
end
