defmodule Flaky.CLI do
  @moduledoc """
  Command-line interface for the flaky test detector.
  """

  @help """
  Detects new tests in git diff (HEAD vs main) and runs them repeatedly to catch flaky tests.

  Usage:
      flaky [options]

  Options:
      -n, --iterations N    Number of times to repeat each test (default: 100)
      -b, --base BRANCH     Base branch to compare against (default: main)
      -s, --seed SEED       Specific seed for reproducibility
      --dry-run             Show which tests would be run without running them
      -p, --parallel N      Run tests in parallel with N concurrent processes
      -m, --mix             Distribute tests in batches across workers (with -p) or run all together (sequential)
      -f, --failed          Re-run only previously failed tests
      -l, --print-full-log  Show full error logs (default: 10 lines)
      -q, --quiet           Suppress error snippets and limit test list to 10
      -w, --watch-errors    Tail error log file in real-time
      -h, --help            Show this help message

  Examples:
      flaky
      flaky --iterations 50
      flaky --base develop
      flaky --seed 12345 --iterations 200
      flaky --dry-run
      flaky --parallel 3
      flaky -p 5 --mix
      flaky --failed
      flaky --print-full-log
  """

  @switches [
    iterations: :integer,
    base: :string,
    seed: :integer,
    dry_run: :boolean,
    parallel: :integer,
    mix: :boolean,
    failed: :boolean,
    print_full_log: :boolean,
    quiet: :boolean,
    watch_errors: :boolean,
    help: :boolean
  ]

  @aliases [
    n: :iterations,
    b: :base,
    s: :seed,
    p: :parallel,
    m: :mix,
    f: :failed,
    l: :print_full_log,
    q: :quiet,
    w: :watch_errors,
    h: :help
  ]

  @spec main(list(String.t())) :: no_return()
  def main(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      invalid != [] ->
        IO.puts(:stderr, "Invalid options: #{inspect(invalid)}")
        IO.puts(@help)
        System.halt(1)

      Keyword.get(opts, :help, false) ->
        IO.puts(@help)
        System.halt(0)

      true ->
        run_opts = %{
          iterations: Keyword.get(opts, :iterations, 100),
          base: Keyword.get(opts, :base, "main"),
          seed: Keyword.get(opts, :seed),
          dry_run: Keyword.get(opts, :dry_run, false),
          parallel: Keyword.get(opts, :parallel),
          mix: Keyword.get(opts, :mix, false),
          failed: Keyword.get(opts, :failed, false),
          print_full_log: Keyword.get(opts, :print_full_log, false),
          quiet: Keyword.get(opts, :quiet, false),
          watch_errors: Keyword.get(opts, :watch_errors, false)
        }

        case Flaky.run(run_opts) do
          :ok -> System.halt(0)
          {:error, _msg} -> System.halt(1)
        end
    end
  end
end
