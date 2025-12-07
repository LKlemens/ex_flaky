defmodule Flaky do
  @moduledoc """
  Detects new tests in git diff and runs them repeatedly to catch flaky tests.
  """

  alias Termite.{Screen, Style}

  @failed_tests_file ".flaky/failed_tests.txt"

  # ANSI color codes (0=black, 1=red, 2=green, 3=yellow, 6=cyan)
  @green 2
  @red 1
  @yellow 3
  @cyan 6

  # ANSI escape not in Termite
  @clear_line "\e[2K"

  @type opts :: %{
          iterations: pos_integer(),
          base: String.t(),
          seed: integer() | nil,
          dry_run: boolean(),
          parallel: pos_integer() | nil,
          mix: boolean(),
          failed: boolean(),
          print_full_log: boolean(),
          quiet: boolean(),
          watch_errors: boolean()
        }

  @default_error_lines 10
  @combined_log_file ".flaky/all_failures.log"
  @quiet_limit 5

  @doc """
  Runs the flaky test detection with the given options.

  ## Options
    * `:iterations` - Number of times to repeat each test (default: 100)
    * `:base` - Base branch to compare against (default: "main")
    * `:seed` - Specific seed for reproducibility (default: nil)
    * `:dry_run` - Show which tests would be run without running them (default: false)
    * `:parallel` - Number of concurrent processes (default: nil = sequential)
    * `:failed` - Re-run only previously failed tests (default: false)
  """
  @spec run(opts()) :: :ok | {:error, String.t()}
  def run(opts) do
    cond do
      opts[:watch_errors] ->
        run_error_watcher()

      opts[:failed] ->
        print_run_info(opts)
        run_failed_tests(opts)

      true ->
        print_run_info(opts)
        run_new_tests(opts)
    end
  end

  @spec run_error_watcher() :: no_return()
  defp run_error_watcher do
    IO.puts(color("Watching #{@combined_log_file} for errors... (Ctrl+C to stop)\n", @cyan))
    tail_loop(0)
  end

  @spec print_run_info(opts()) :: :ok
  defp print_run_info(opts) do
    IO.puts(color("Base branch: #{opts[:base]}\n", @cyan))
  end

  @spec run_failed_tests(opts()) :: :ok | {:error, String.t()}
  defp run_failed_tests(opts) do
    IO.puts(color("Loading previously failed tests from #{@failed_tests_file}...", @cyan))

    case load_failed_tests() do
      [] ->
        IO.puts(color("No failed tests found. Run `flaky` first.", @yellow))
        :ok

      test_targets ->
        IO.puts(color("Found #{length(test_targets)} failed test(s):\n", @green))
        print_test_targets(test_targets, opts[:quiet])

        if opts[:dry_run] do
          IO.puts(color("\nDry run - not executing tests.", @yellow))
          :ok
        else
          run_test_targets(test_targets, opts)
        end
    end
  end

  @spec run_new_tests(opts()) :: :ok | {:error, String.t()}
  defp run_new_tests(opts) do
    clear_flaky_logs()
    base_branch = opts[:base] || "main"
    IO.puts(color("Detecting new tests comparing HEAD to #{base_branch}...", @cyan))

    case find_new_tests(base_branch) do
      {:ok, []} ->
        IO.puts(color("No new tests found in diff.", @green))
        :ok

      {:ok, tests} ->
        IO.puts(color("Found #{length(tests)} new test(s):\n", @green))
        print_tests(tests, opts[:quiet])

        if opts[:dry_run] do
          IO.puts(color("\nDry run - not executing tests.", @yellow))
          :ok
        else
          run_tests(tests, opts)
        end

      {:error, reason} ->
        IO.puts(color("Failed to get git diff: #{reason}", @red))
        IO.puts(color("Consider change base branch - current is '#{base_branch}'", @yellow))
        {:error, "Failed to get git diff: #{reason}"}
    end
  end

  @spec find_new_tests(String.t()) :: {:ok, list(map())} | {:error, String.t()}
  defp find_new_tests(base_branch) do
    base = resolve_base_branch(base_branch)

    with {:ok, diff_output} <- get_diff(base),
         test_names_by_file <- parse_diff_for_test_names(diff_output),
         tests <- resolve_line_numbers(test_names_by_file) do
      {:ok, tests}
    end
  end

  @spec get_diff(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp get_diff(base) do
    case System.cmd("git", ["diff", "#{base}...HEAD"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {error, _code} -> {:error, error}
    end
  end

  @spec resolve_base_branch(String.t()) :: String.t()
  defp resolve_base_branch(branch) do
    case System.cmd("git", ["rev-parse", "--verify", branch], stderr_to_stdout: true) do
      {_, 0} -> branch
      _ -> "origin/#{branch}"
    end
  end

  @spec parse_diff_for_test_names(String.t()) :: %{String.t() => list(String.t())}
  defp parse_diff_for_test_names(diff_output) do
    diff_output
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, fn line, {current_file, acc} ->
      cond do
        String.starts_with?(line, "+++ b/test/") && String.ends_with?(line, "_test.exs") ->
          file = String.trim_leading(line, "+++ b/")
          {file, Map.put_new(acc, file, [])}

        current_file != nil && is_new_test_line?(line) ->
          name = extract_test_name(line)
          {current_file, Map.update!(acc, current_file, &[name | &1])}

        true ->
          {current_file, acc}
      end
    end)
    |> elem(1)
    |> Map.new(fn {file, names} -> {file, Enum.reverse(names)} end)
  end

  @spec resolve_line_numbers(%{String.t() => list(String.t())}) :: list(map())
  defp resolve_line_numbers(test_names_by_file) do
    Enum.flat_map(test_names_by_file, fn {file, names} ->
      Enum.map(names, fn name ->
        line = grep_test_line(file, name)
        %{file: file, line: line, name: name}
      end)
    end)
  end

  @spec grep_test_line(String.t(), String.t()) :: pos_integer()
  defp grep_test_line(file, test_name) do
    escaped = Regex.escape(test_name)
    pattern = "(test) \"#{escaped}\""

    case System.cmd("grep", ["-n", "-E", pattern, file], stderr_to_stdout: true) do
      {output, 0} ->
        output |> String.split(":") |> hd() |> String.to_integer()

      _ ->
        1
    end
  end

  @spec is_new_test_line?(String.t()) :: boolean()
  defp is_new_test_line?(line) do
    String.starts_with?(line, "+") &&
      Regex.match?(~r/^\+\s*(test)\s+"/, line)
  end

  @spec extract_test_name(String.t()) :: String.t()
  defp extract_test_name(line) do
    case Regex.run(~r/^\+\s*(?:test)\s+"([^"]+)"/, line) do
      [_, name] -> name
      _ -> "unknown"
    end
  end

  @spec print_test(map()) :: :ok
  defp print_test(%{file: file, line: line, name: name}) do
    IO.puts("  - #{file}:#{line} - \"#{name}\"")
  end

  @spec print_tests(list(map()), boolean()) :: :ok
  defp print_tests(tests, quiet?) do
    {to_print, remaining} =
      if quiet? do
        {Enum.take(tests, @quiet_limit), length(tests) - @quiet_limit}
      else
        {tests, 0}
      end

    Enum.each(to_print, &print_test/1)

    if remaining > 0 do
      IO.puts("  ... and #{remaining} more")
    end

    :ok
  end

  @spec print_test_targets(list(String.t()), boolean()) :: :ok
  defp print_test_targets(targets, quiet?) do
    {to_print, remaining} =
      if quiet? do
        {Enum.take(targets, @quiet_limit), length(targets) - @quiet_limit}
      else
        {targets, 0}
      end

    Enum.each(to_print, &IO.puts("  - #{&1}"))

    if remaining > 0 do
      IO.puts("  ... and #{remaining} more")
    end

    :ok
  end

  @spec run_tests(list(map()), opts()) :: :ok | {:error, String.t()}
  defp run_tests(tests, opts) do
    test_targets =
      tests
      |> Enum.map(fn %{file: file, line: line} -> "#{file}:#{line}" end)
      |> Enum.uniq()

    run_test_targets(test_targets, opts)
  end

  @spec run_test_targets(list(String.t()), opts()) :: :ok | {:error, String.t()}
  defp run_test_targets(test_targets, opts) do
    iterations = opts[:iterations] || 100
    parallel = opts[:parallel]
    seed = opts[:seed]
    mix_mode = opts[:mix] || false

    if mix_mode do
      run_test_targets_mix(test_targets, iterations, seed, parallel)
    else
      run_test_targets_grouped(test_targets, iterations, seed, parallel)
    end
    |> then(fn failed_tests -> print_summary(test_targets, failed_tests, iterations, opts) end)
  end

  @spec run_test_targets_grouped(list(String.t()), pos_integer(), integer() | nil, pos_integer() | nil) ::
          list({String.t(), String.t()})
  defp run_test_targets_grouped(test_targets, iterations, seed, parallel) do
    grouped_targets = group_by_file(test_targets)
    file_count = length(grouped_targets)

    mode = if parallel, do: "in parallel (#{parallel} workers)", else: "sequentially"

    IO.puts(
      color(
        "\nRunning #{file_count} file(s) #{mode} with --repeat-until-failure #{iterations}...\n",
        @cyan
      )
    )

    if parallel do
      run_tests_parallel(grouped_targets, iterations, seed, parallel)
    else
      run_tests_sequential(grouped_targets, iterations, seed)
    end
  end

  @spec run_test_targets_mix(list(String.t()), pos_integer(), integer() | nil, pos_integer() | nil) ::
          list({String.t(), String.t()})
  defp run_test_targets_mix(test_targets, iterations, seed, parallel) do
    test_count = length(test_targets)

    if parallel do
      batch_size = ceil(test_count / parallel)
      batch_count = ceil(test_count / batch_size)

      IO.puts(
        color(
          "\nRunning #{test_count} test(s) in #{batch_count} batch(es) across #{parallel} workers with --repeat-until-failure #{iterations}...\n",
          @cyan
        )
      )

      run_tests_mix_parallel(test_targets, iterations, seed, parallel)
    else
      IO.puts(
        color(
          "\nRunning #{test_count} test(s) together with --repeat-until-failure #{iterations}...\n",
          @cyan
        )
      )

      run_tests_mix_sequential(test_targets, iterations, seed)
    end
  end

  @spec run_tests_sequential(list({String.t(), list(String.t())}), pos_integer(), integer() | nil) ::
          list({String.t(), String.t()})
  defp run_tests_sequential(grouped_targets, iterations, seed) do
    total = length(grouped_targets)

    grouped_targets
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {{file, targets}, index}, failures ->
      IO.puts(
        color("[#{index}/#{total}]", @cyan) <> " Running: #{file} (#{length(targets)} test(s))"
      )

      case run_file_tests(targets, iterations, seed) do
        :passed ->
          IO.puts(color("  ✓ PASSED\n", @green))
          failures

        {:failed, output} ->
          log_path = save_failure_output(file, output)
          IO.puts(color("  ✗ FAILED (output saved to #{log_path})\n", @red))
          # Return only the tests that actually failed
          actually_failed = parse_failed_tests(output, targets)
          failed_targets = Enum.map(actually_failed, fn target -> {target, log_path} end)
          failed_targets ++ failures
      end
    end)
    |> Enum.reverse()
  end

  @spec run_tests_parallel(
          list({String.t(), list(String.t())}),
          pos_integer(),
          integer() | nil,
          pos_integer()
        ) ::
          list({String.t(), String.t()})
  defp run_tests_parallel(grouped_targets, iterations, seed, concurrency) do
    total_files = length(grouped_targets)
    {:ok, tracker} = Agent.start_link(fn -> init_tracker(concurrency, total_files, "files") end)

    # Print header and placeholder lines for workers
    IO.puts(color("  0/#{total_files} files", @yellow))
    for i <- 1..concurrency, do: IO.puts("  Worker #{i}: [waiting]")

    # Placeholder for failures section
    IO.puts("")

    grouped_targets
    |> Task.async_stream(
      fn {file, targets} ->
        slot = claim_slot(tracker, file)

        result =
          run_file_tests_parallel(targets, iterations, seed, tracker, slot, concurrency, file)

        increment_completed(tracker, concurrency)

        case result do
          :passed ->
            :ok

          {:failed, output} ->
            log_path = save_failure_output(file, output)
            add_failures(tracker, targets, output, log_path, concurrency, file)
        end

        release_slot(tracker, slot)
        {file, result}
      end,
      max_concurrency: concurrency,
      timeout: :infinity
    )
    |> Stream.run()

    # Get failures from tracker
    failures = Agent.get(tracker, & &1.failures)
    Agent.stop(tracker)

    failures
  end

  @spec run_tests_mix_sequential(list(String.t()), pos_integer(), integer() | nil) ::
          list({String.t(), String.t()})
  defp run_tests_mix_sequential(test_targets, iterations, seed) do
    IO.puts("Running all tests together...")

    case run_file_tests(test_targets, iterations, seed) do
      :passed ->
        IO.puts(color("  ✓ PASSED\n", @green))
        []

      {:failed, output} ->
        log_path = save_failure_output("mix_all", output)
        IO.puts(color("  ✗ FAILED (output saved to #{log_path})\n", @red))
        actually_failed = parse_failed_tests(output, test_targets)
        Enum.map(actually_failed, fn target -> {target, log_path} end)
    end
  end

  @spec run_tests_mix_parallel(list(String.t()), pos_integer(), integer() | nil, pos_integer()) ::
          list({String.t(), String.t()})
  defp run_tests_mix_parallel(test_targets, iterations, seed, concurrency) do
    # Chunk tests into batches - one batch per worker
    batch_size = ceil(length(test_targets) / concurrency)
    batches = Enum.chunk_every(test_targets, batch_size)
    batch_count = length(batches)

    {:ok, tracker} = Agent.start_link(fn -> init_tracker(concurrency, batch_count, "batches") end)

    # Print header and placeholder lines for workers
    IO.puts(color("  0/#{batch_count} batches", @yellow))
    for i <- 1..concurrency, do: IO.puts("  Worker #{i}: [waiting]")

    # Placeholder for failures section
    IO.puts("")

    batches
    |> Enum.with_index()
    |> Task.async_stream(
      fn {batch_targets, batch_index} ->
        batch_label = "batch #{batch_index + 1} (#{length(batch_targets)} tests)"
        slot = claim_slot(tracker, batch_label)

        result =
          run_batch_tests_parallel(batch_targets, iterations, seed, tracker, slot, concurrency, batch_label)

        increment_completed(tracker, concurrency)

        case result do
          :passed ->
            :ok

          {:failed, output} ->
            log_path = save_failure_output("batch_#{batch_index + 1}", output)
            add_batch_failures(tracker, batch_targets, output, log_path, concurrency)
        end

        release_slot(tracker, slot)
        {batch_targets, result}
      end,
      max_concurrency: concurrency,
      timeout: :infinity
    )
    |> Stream.run()

    # Get failures from tracker
    failures = Agent.get(tracker, & &1.failures)
    Agent.stop(tracker)

    failures
  end

  @spec run_batch_tests_parallel(
          list(String.t()),
          pos_integer(),
          integer() | nil,
          pid(),
          non_neg_integer(),
          pos_integer(),
          String.t()
        ) :: :passed | {:failed, String.t()}
  defp run_batch_tests_parallel(targets, iterations, seed, tracker, slot, concurrency, label) do
    args =
      ["test"] ++
        targets ++
        ["--repeat-until-failure", to_string(iterations)] ++
        seed_args(seed)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("mix")},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    collect_output_parallel(port, iterations, 0, [], tracker, slot, concurrency, label)
  end

  @spec add_batch_failures(pid(), list(String.t()), String.t(), String.t(), pos_integer()) :: :ok
  defp add_batch_failures(tracker, batch_targets, output, log_path, _concurrency) do
    # Parse output to find only the tests that actually failed
    actually_failed = parse_failed_tests(output, batch_targets)
    failed_targets = Enum.map(actually_failed, fn target -> {target, log_path} end)

    Agent.update(tracker, fn state ->
      %{state | failures: state.failures ++ failed_targets}
    end)

    append_to_combined_log("batch", log_path)
    failed_count = length(actually_failed)
    IO.puts("  #{color("✗ FAILED:", @red)} #{failed_count} test(s) -> #{log_path}")
  end

  @spec init_tracker(pos_integer(), pos_integer(), String.t()) :: map()
  defp init_tracker(concurrency, total, unit) do
    slots = for i <- 0..(concurrency - 1), into: %{}, do: {i, nil}
    %{slots: slots, concurrency: concurrency, completed: 0, total: total, unit: unit, failures: []}
  end

  @spec claim_slot(pid(), String.t()) :: non_neg_integer()
  defp claim_slot(tracker, target) do
    Agent.get_and_update(tracker, fn state ->
      slot = find_free_slot(state.slots)
      new_slots = Map.put(state.slots, slot, %{target: target, progress: 0})
      {slot, %{state | slots: new_slots}}
    end)
  end

  @spec find_free_slot(map()) :: non_neg_integer()
  defp find_free_slot(slots) do
    Enum.find_value(slots, fn {slot, val} -> if val == nil, do: slot end)
  end

  @spec release_slot(pid(), non_neg_integer()) :: :ok
  defp release_slot(tracker, slot) do
    Agent.update(tracker, fn state ->
      %{state | slots: Map.put(state.slots, slot, nil)}
    end)
  end

  @spec update_slot_progress(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  defp update_slot_progress(tracker, slot, progress) do
    Agent.update(tracker, fn state ->
      case state.slots[slot] do
        nil ->
          state

        slot_data ->
          %{state | slots: Map.put(state.slots, slot, %{slot_data | progress: progress})}
      end
    end)
  end

  @spec increment_completed(pid(), pos_integer()) :: :ok
  defp increment_completed(tracker, concurrency) do
    {completed, total, unit, failure_count} =
      Agent.get_and_update(tracker, fn state ->
        new_completed = state.completed + 1

        {{new_completed, state.total, state.unit, length(state.failures)},
         %{state | completed: new_completed}}
      end)

    update_header(completed, total, unit, concurrency, failure_count)
  end

  @spec add_failures(pid(), list(String.t()), String.t(), String.t(), pos_integer(), String.t()) ::
          :ok
  defp add_failures(tracker, targets, output, log_path, concurrency, file) do
    # Parse output to find only the tests that actually failed
    actually_failed = parse_failed_tests(output, targets)
    failed_targets = Enum.map(actually_failed, fn target -> {target, log_path} end)

    Agent.update(tracker, fn state ->
      %{state | failures: state.failures ++ failed_targets}
    end)

    append_to_combined_log(file, log_path)
    print_failure(file, log_path, concurrency, length(actually_failed), tracker)
  end

  @spec print_failure(String.t(), String.t(), pos_integer(), pos_integer(), pid()) :: :ok
  defp print_failure(file, log_path, _concurrency, test_count, _tracker) do
    IO.puts("  #{color("✗ FAILED:", @red)} #{file} (#{test_count} test(s)) -> #{log_path}")
  end

  @spec update_header(non_neg_integer(), pos_integer(), String.t(), pos_integer(), non_neg_integer()) ::
          :ok
  defp update_header(completed, total, unit, concurrency, failure_count) do
    # header(1) + workers + empty(1) + failures
    lines_up = concurrency + 2 + failure_count
    header_color = if completed == total, do: @green, else: @yellow
    update_line(lines_up, color("  #{completed}/#{total} #{unit}", header_color))
  end

  @spec run_file_tests(list(String.t()), pos_integer(), integer() | nil) ::
          :passed | {:failed, String.t()}
  defp run_file_tests(targets, iterations, seed) do
    args =
      ["test"] ++
        targets ++
        ["--repeat-until-failure", to_string(iterations)] ++
        seed_args(seed)

    run_with_progress(args, iterations)
  end

  @spec run_file_tests_parallel(
          list(String.t()),
          pos_integer(),
          integer() | nil,
          pid(),
          non_neg_integer(),
          pos_integer(),
          String.t()
        ) :: :passed | {:failed, String.t()}
  defp run_file_tests_parallel(targets, iterations, seed, tracker, slot, concurrency, file) do
    args =
      ["test"] ++
        targets ++
        ["--repeat-until-failure", to_string(iterations)] ++
        seed_args(seed)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("mix")},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    collect_output_parallel(port, iterations, 0, [], tracker, slot, concurrency, file)
  end

  @spec run_with_progress(list(String.t()), pos_integer()) :: :passed | {:failed, String.t()}
  defp run_with_progress(args, iterations) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("mix")},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    collect_output(port, iterations, 0, [])
  end

  @spec collect_output(port(), pos_integer(), non_neg_integer(), list(String.t())) ::
          :passed | {:failed, String.t()}
  defp collect_output(port, iterations, current, output_acc) do
    receive do
      {^port, {:data, data}} ->
        new_count = current + count_finished(data)
        print_progress(new_count, iterations)
        collect_output(port, iterations, new_count, [data | output_acc])

      {^port, {:exit_status, 0}} ->
        clear_progress()
        :passed

      {^port, {:exit_status, _code}} ->
        clear_progress()
        {:failed, output_acc |> Enum.reverse() |> Enum.join()}
    end
  end

  @spec collect_output_parallel(
          port(),
          pos_integer(),
          non_neg_integer(),
          list(String.t()),
          pid(),
          non_neg_integer(),
          pos_integer(),
          String.t()
        ) :: :passed | {:failed, String.t()}
  defp collect_output_parallel(
         port,
         iterations,
         current,
         output_acc,
         tracker,
         slot,
         concurrency,
         target
       ) do
    receive do
      {^port, {:data, data}} ->
        new_count = current + count_finished(data)
        update_slot_progress(tracker, slot, new_count)
        print_worker_progress(slot, new_count, iterations, concurrency, target, tracker)

        collect_output_parallel(
          port,
          iterations,
          new_count,
          [data | output_acc],
          tracker,
          slot,
          concurrency,
          target
        )

      {^port, {:exit_status, 0}} ->
        print_worker_done(slot, concurrency, "[done]", tracker)
        :passed

      {^port, {:exit_status, _code}} ->
        print_worker_done(slot, concurrency, "[FAILED]", tracker)
        {:failed, output_acc |> Enum.reverse() |> Enum.join()}
    end
  end

  @spec count_finished(String.t()) :: non_neg_integer()
  defp count_finished(data) do
    data
    |> String.split("\n")
    |> Enum.count(&String.contains?(&1, "Finished in"))
  end

  @spec print_progress(non_neg_integer(), pos_integer()) :: :ok
  defp print_progress(current, total) do
    progress = color("[#{current}/#{total}]", @yellow)
    IO.write("\r  running: " <> progress)
  end

  @spec clear_progress() :: :ok
  defp clear_progress do
    IO.write("\r                              \r")
  end

  @spec print_worker_progress(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          String.t(),
          pid()
        ) :: :ok
  defp print_worker_progress(slot, current, total, concurrency, target, tracker) do
    failure_count = Agent.get(tracker, fn state -> length(state.failures) end)
    # workers below this slot + empty line + failures
    lines_up = concurrency - slot + 1 + failure_count
    short_target = Path.basename(target)

    progress =
      if current == 0,
        do: color("[..loading]", @yellow),
        else: color("[#{current}/#{total}]", @yellow)

    update_line(lines_up, "  Worker #{slot + 1}: #{progress} #{short_target}")
  end

  @spec print_worker_done(non_neg_integer(), pos_integer(), String.t(), pid()) :: :ok
  defp print_worker_done(slot, concurrency, status, tracker) do
    failure_count = Agent.get(tracker, fn state -> length(state.failures) end)
    lines_up = concurrency - slot + 1 + failure_count
    status_color = if status == "[done]", do: @green, else: @red
    update_line(lines_up, "  Worker #{slot + 1}: #{color(status, status_color)}")
  end

  # Terminal helpers using Termite
  @spec color(String.t(), non_neg_integer()) :: String.t()
  defp color(text, color_code) do
    Style.foreground(color_code) |> Style.render_to_string(text)
  end

  @spec update_line(pos_integer(), String.t()) :: :ok
  defp update_line(lines_up, content) do
    cursor_up = Screen.escape_sequence(:cursor_up, [lines_up])
    cursor_down = Screen.escape_sequence(:cursor_down, [lines_up])
    IO.write("#{cursor_up}#{@clear_line}\r#{content}#{cursor_down}\r")
  end

  @spec unit_label(opts(), pos_integer()) :: String.t()
  defp unit_label(opts, count) do
    mix_mode = opts[:mix] || false
    parallel = opts[:parallel]

    if mix_mode && parallel do
      batch_count = min(parallel, count)
      "#{count} test(s) in #{batch_count} batch(es)"
    else
      "#{count} test(s)"
    end
  end

  @spec print_summary(list(String.t()), list({String.t(), String.t()}), pos_integer(), opts()) ::
          :ok | {:error, String.t()}
  defp print_summary(all_tests, [], iterations, opts) do
    IO.puts("")
    IO.puts(color("========================================", @green))
    IO.puts(color("SUMMARY", @green))
    IO.puts(color("========================================", @green))
    IO.puts(color("All #{unit_label(opts, length(all_tests))} passed #{iterations} iterations!", @green))
    IO.puts("")

    :ok
  end

  defp print_summary(all_tests, failed_tests, iterations, opts) do
    save_failed_tests(failed_tests)
    create_combined_log(failed_tests)
    full_log = opts[:print_full_log]
    quiet? = opts[:quiet]

    IO.puts("")
    IO.puts(color("========================================", @yellow))
    IO.puts(color("SUMMARY (#{iterations} iterations each)", @yellow))
    IO.puts(color("========================================", @yellow))
    IO.puts(color("Failed: #{length(failed_tests)}/#{unit_label(opts, length(all_tests))}", @red))
    IO.puts("")

    Enum.each(failed_tests, fn {target, log_path} ->
      IO.puts("#{color("✗ #{target}", @red)}")

      unless quiet? do
        snippet = extract_error_snippet(log_path, full_log)
        IO.puts(snippet)
        IO.puts("")
      end
    end)

    IO.puts("")
    IO.puts(color("Full logs: #{@combined_log_file}", @cyan))
    IO.puts(color("Re-run failed tests with: flaky --failed", @cyan))

    {:error, "Flaky test(s) detected!"}
  end

  @spec extract_error_snippet(String.t(), boolean()) :: String.t()
  defp extract_error_snippet(log_path, full?) do
    case File.read(log_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        error_lines = find_error_section(lines)

        display_lines =
          if full? do
            error_lines
          else
            Enum.take(error_lines, @default_error_lines)
          end

        formatted = Enum.map(display_lines, &("    " <> &1))

        if not full? and length(error_lines) > 10 do
          Enum.join(formatted, "\n") <> "\n    ..."
        else
          Enum.join(formatted, "\n")
        end

      {:error, _} ->
        "    (could not read log file)"
    end
  end

  @spec find_error_section(list(String.t())) :: list(String.t())
  defp find_error_section(lines) do
    # Find the first failure marker and take lines from there
    start_index =
      Enum.find_index(lines, fn line ->
        String.contains?(line, "  1)") or String.contains?(line, "** (")
      end)

    case start_index do
      nil -> Enum.take(lines, 10)
      idx -> Enum.slice(lines, idx, 20)
    end
  end

  @spec create_combined_log(list({String.t(), String.t()})) :: :ok
  defp create_combined_log(failures) do
    content =
      failures
      |> Enum.map(fn {target, log_path} ->
        log_content = File.read!(log_path)

        """
        ================================================================================
        #{target}
        ================================================================================
        #{log_content}
        """
      end)
      |> Enum.join("\n")

    File.write!(@combined_log_file, content)
    :ok
  end

  @spec append_to_combined_log(String.t(), String.t()) :: :ok
  defp append_to_combined_log(target, log_path) do
    content = File.read!(log_path)

    entry = """
    ================================================================================
    #{target}
    ================================================================================
    #{content}
    """

    File.write!(@combined_log_file, entry, [:append])
    :ok
  end

  @spec tail_loop(non_neg_integer()) :: no_return()
  defp tail_loop(position) do
    case File.stat(@combined_log_file) do
      {:ok, %{size: size}} when size > position ->
        {:ok, file} = File.open(@combined_log_file, [:read])
        {:ok, _} = :file.position(file, position)
        content = IO.read(file, :eof)
        File.close(file)
        IO.write(content)
        tail_loop(size)

      _ ->
        Process.sleep(100)
        tail_loop(position)
    end
  end

  @spec clear_flaky_logs() :: :ok
  defp clear_flaky_logs do
    Path.wildcard(".flaky/*.{log,txt}")
    |> Enum.each(&File.rm/1)
  end

  @spec save_failure_output(String.t(), String.t()) :: String.t()
  defp save_failure_output(target, output) do
    File.mkdir_p!(".flaky")
    filename = target_to_filename(target)
    path = Path.join(".flaky", filename)
    File.write!(path, output)
    path
  end

  @spec target_to_filename(String.t()) :: String.t()
  defp target_to_filename(target) do
    target
    |> String.replace("test/", "")
    |> String.replace("/", "_")
    |> String.replace(":", "_")
    |> String.replace(".exs", "")
    |> Kernel.<>(".log")
  end

  @spec load_failed_tests() :: list(String.t())
  defp load_failed_tests do
    case File.read(@failed_tests_file) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _} -> []
    end
  end

  @spec save_failed_tests(list({String.t(), String.t()})) :: :ok
  defp save_failed_tests(failed_tests) do
    File.mkdir_p!(".flaky")
    content = failed_tests |> Enum.map(fn {target, _log} -> target end) |> Enum.join("\n")
    File.write!(@failed_tests_file, content)
    :ok
  end

  @spec seed_args(integer() | nil) :: list(String.t())
  defp seed_args(nil), do: []
  defp seed_args(seed), do: ["--seed", to_string(seed)]

  @spec group_by_file(list(String.t())) :: list({String.t(), list(String.t())})
  defp group_by_file(test_targets) do
    test_targets
    |> Enum.group_by(fn target ->
      target |> String.split(":") |> hd()
    end)
    |> Enum.map(fn {file, targets} -> {file, targets} end)
  end

  @spec parse_failed_tests(String.t(), list(String.t())) :: list(String.t())
  defp parse_failed_tests(output, targets) do
    # Extract file:line patterns from test output that indicate failures
    # Mix test output shows failed test locations like: "test/path/file_test.exs:123"
    failed_locations =
      Regex.scan(~r/(test\/[^\s:]+_test\.exs):(\d+)/, output)
      |> Enum.map(fn [_full, file, line] -> "#{file}:#{line}" end)
      |> Enum.uniq()

    # Filter targets to only those that actually failed
    Enum.filter(targets, fn target -> target in failed_locations end)
  end
end
