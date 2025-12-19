# ExFlaky

Detects new tests in git diff (HEAD vs base branch) and runs them repeatedly to catch flaky tests.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:ex_flaky, "~> 0.1.2", only: :dev}
  ]
end
```

Or build the standalone escript:

```bash
mix flaky.install
```

## Usage

```bash
# Run as mix task
mix flaky

# Run as escript
./flaky
```

## Options

| Option | Alias | Description | Default |
|--------|-------|-------------|---------|
| `--iterations` | `-n` | Number of times to repeat each test | 100 |
| `--base` | `-b` | Base branch to compare against | main |
| `--seed` | `-s` | Specific seed for reproducibility | - |
| `--dry-run` | - | Show which tests would be run without running them | false |
| `--parallel` | `-p` | Run tests in parallel with N concurrent processes | - |
| `--failed` | `-f` | Re-run only previously failed tests | false |
| `--print-full-log` | `-l` | Show full error logs instead of snippet | false |
| `--watch-errors` | `-w` | Tail error log file in real-time (standalone mode) | - |

## Examples

```bash
mix flaky                          # Run with defaults
mix flaky -n 50                    # 50 iterations
mix flaky -b develop               # Compare against develop branch
mix flaky -p 5                     # Run with 5 parallel workers
mix flaky --dry-run                # Preview tests without running
mix flaky --failed                 # Re-run previously failed tests
mix flaky -l                       # Show full error logs
mix flaky -w                       # Watch errors (run in separate terminal)
```

## Output

Failed test logs are saved to `.flaky/`:
- Individual logs: `.flaky/<test_name>.log`
- Combined log: `.flaky/all_failures.log`
- Failed tests list: `.flaky/failed_tests.txt`
