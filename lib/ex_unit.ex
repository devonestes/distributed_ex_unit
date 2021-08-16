defmodule Distributed.ExUnit do
  @type state ::
          nil | {:excluded, binary} | {:failed, failed} | {:invalid, module} | {:skipped, binary}

  @type failed :: [{Exception.kind(), reason :: term, Exception.stacktrace()}]

  @type suite_result :: %{
          excluded: non_neg_integer,
          failures: non_neg_integer,
          skipped: non_neg_integer,
          total: non_neg_integer
        }

  @type test_id :: {module, name :: atom}

  defmodule Test do
    defstruct [:name, :case, :module, :state, time: 0, tags: %{}, logs: ""]

    @type t :: %__MODULE__{
            name: atom,
            case: module,
            module: module,
            state: ExUnit.state(),
            time: non_neg_integer,
            tags: map,
            logs: String.t()
          }
  end

  defmodule TestModule do
    defstruct [:file, :name, :state, tests: []]

    @type t :: %__MODULE__{
            file: binary(),
            name: module,
            state: ExUnit.state(),
            tests: [ExUnit.Test.t()]
          }
  end

  defmodule TestCase do
    @moduledoc false
    defstruct [:name, :state, tests: []]

    @type t :: %__MODULE__{name: module, state: ExUnit.state(), tests: [ExUnit.Test.t()]}
  end

  defmodule TimeoutError do
    defexception [:timeout, :type]

    @impl true
    def message(%{timeout: timeout, type: type}) do
      """
      #{type} timed out after #{timeout}ms. You can change the timeout:

        1. per test by setting "@tag timeout: x" (accepts :infinity)
        2. per test module by setting "@moduletag timeout: x" (accepts :infinity)
        3. globally via "ExUnit.start(timeout: x)" configuration
        4. by running "mix test --timeout x" which sets timeout
        5. or by running "mix test --trace" which sets timeout to infinity
           (useful when using IEx.pry/0)

      where "x" is the timeout given as integer in milliseconds (defaults to 60_000).
      """
    end
  end

  use Application

  @doc false
  def start(_type, []) do
    children = [
      ExUnit.Server,
      ExUnit.CaptureServer,
      Distributed.ExUnit.OnExitHandler
    ]

    opts = [strategy: :one_for_one, name: ExUnit.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @spec start(Keyword.t()) :: :ok
  def start(options \\ []) do
    {:ok, _} = Application.ensure_all_started(:ex_unit)

    configure(options)

    if Application.fetch_env!(:ex_unit, :autorun) do
      Application.put_env(:ex_unit, :autorun, false)

      System.at_exit(fn
        0 ->
          time = ExUnit.Server.modules_loaded()
          options = persist_defaults(configuration())
          %{failures: failures} = Distributed.ExUnit.Runner.run(options, time)

          System.at_exit(fn _ ->
            if failures > 0, do: exit({:shutdown, 1})
          end)

        _ ->
          :ok
      end)
    else
      :ok
    end
  end

  @spec configure(Keyword.t()) :: :ok
  def configure(options) do
    Enum.each(options, fn {k, v} ->
      Application.put_env(:ex_unit, k, v)
    end)
  end

  @spec configuration() :: Keyword.t()
  def configuration do
    Application.get_all_env(:ex_unit)
    |> put_seed()
    |> put_slowest()
    |> put_max_cases()
  end

  @spec plural_rule(binary) :: binary
  def plural_rule(word) when is_binary(word) do
    Application.get_env(:ex_unit, :plural_rules, %{})
    |> Map.get(word, "#{word}s")
  end

  @spec plural_rule(binary, binary) :: :ok
  def plural_rule(word, pluralization) when is_binary(word) and is_binary(pluralization) do
    plural_rules =
      Application.get_env(:ex_unit, :plural_rules, %{})
      |> Map.put(word, pluralization)

    configure(plural_rules: plural_rules)
  end

  @spec run() :: suite_result()
  def run do
    _ = ExUnit.Server.modules_loaded()
    options = persist_defaults(configuration())
    Distributed.ExUnit.Runner.run(options, nil)
  end

  @doc since: "1.12.0"
  @spec async_run() :: Task.t()
  def async_run() do
    Task.async(fn ->
      options = persist_defaults(configuration())
      Distributed.ExUnit.Runner.run(options, nil)
    end)
  end

  @doc """
  Awaits for a test suite that has been started with `async_run/0`.
  """
  @doc since: "1.12.0"
  @spec await_run(Task.t()) :: suite_result()
  def await_run(task) do
    ExUnit.Server.modules_loaded()
    Task.await(task, :infinity)
  end

  @doc since: "1.8.0"
  @spec after_suite((suite_result() -> any)) :: :ok
  def after_suite(function) when is_function(function) do
    current_callbacks = Application.fetch_env!(:ex_unit, :after_suite)
    configure(after_suite: [function | current_callbacks])
  end

  @doc since: "1.11.0"
  @spec fetch_test_supervisor() :: {:ok, pid()} | :error
  def fetch_test_supervisor() do
    case Distributed.ExUnit.OnExitHandler.get_supervisor(self()) do
      {:ok, nil} ->
        opts = [strategy: :one_for_one, max_restarts: 1_000_000, max_seconds: 1]
        {:ok, sup} = Supervisor.start_link([], opts)
        Distributed.ExUnit.OnExitHandler.put_supervisor(self(), sup)
        {:ok, sup}

      {:ok, _} = ok ->
        ok

      :error ->
        :error
    end
  end

  defp persist_defaults(config) do
    config |> Keyword.take([:max_cases, :seed, :trace]) |> configure()
    config
  end

  defp put_seed(opts) do
    Keyword.put_new_lazy(opts, :seed, fn ->
      # We're using `rem System.system_time()` here
      # instead of directly using :os.timestamp or using the
      # :microsecond argument because the VM on Windows has odd
      # precision. Calling with :microsecond will give us a multiple
      # of 1000. Calling without it gives actual microsecond precision.
      System.system_time()
      |> System.convert_time_unit(:native, :microsecond)
      |> rem(1_000_000)
    end)
  end

  defp put_max_cases(opts) do
    Keyword.put(opts, :max_cases, max_cases(opts))
  end

  defp put_slowest(opts) do
    if opts[:slowest] > 0 do
      Keyword.put(opts, :trace, true)
    else
      opts
    end
  end

  defp max_cases(opts) do
    cond do
      opts[:trace] -> 1
      max = opts[:max_cases] -> max
      true -> System.schedulers_online() * 2
    end
  end
end
