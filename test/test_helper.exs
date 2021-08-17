:erlang.system_flag(:schedulers_online, 2)

defmodule Clustering do
  @moduledoc false

  @doc false
  def spawn(nodes, opts) do
    # Turn node into a distributed node with the given long name
    :net_kernel.start([:"primary@127.0.0.1"])

    # Allow spawned nodes to fetch all code from this node
    :erl_boot_server.start([])
    {:ok, ipv4} = "127.0.0.1" |> to_charlist() |> :inet.parse_ipv4_address()
    :erl_boot_server.add_slave(ipv4)

    nodes
    |> Enum.with_index(1)
    |> Enum.map(&Task.async(fn -> spawn_node(&1, opts) end))
    |> Enum.map(&Task.await(&1, 30_000))
    |> Enum.map(fn {:ok, node} ->
      Node.connect(node)
      node
    end)
  end

  defp spawn_node({node_host, node_num}, opts) do
    inet_loader_args =
      to_charlist("+S 2:2 -loader inet -hosts 127.0.0.1 -setcookie #{:erlang.get_cookie()}")

    {:ok, node} = :slave.start(to_charlist("127.0.0.1"), node_name(node_host), inet_loader_args)
    rpc(node, :code, :add_paths, [:code.get_path()])
    transfer_configuration(opts[:transfer_configuration], node, node_num)
    ensure_applications_started(opts[:ensure_applications_started], node, node_num)

    # Reset the config that ExUnit overrides when it starts
    for {key, val} <- Application.get_all_env(:ex_unit) do
      rpc(node, Application, :put_env, [:ex_unit, key, val])
    end

    {:ok, node}
  end

  defp transfer_configuration(fun, node, node_num) when is_function(fun, 2) do
    fun.(node, node_num)
  end

  defp transfer_configuration(_, node, _) do
    for {app_name, _, _} <- Application.loaded_applications() do
      for {key, val} <- Application.get_all_env(app_name) do
        rpc(node, Application, :put_env, [app_name, key, val])
      end
    end
  end

  defp ensure_applications_started(fun, node, node_num) when is_function(fun, 2) do
    fun.(node, node_num)
  end

  defp ensure_applications_started(_, node, _node_num) do
    rpc(node, Application, :ensure_all_started, [:mix])
    rpc(node, Mix, :env, [Mix.env()])

    for {app_name, _, _} <- Application.loaded_applications() do
      rpc(node, Application, :ensure_all_started, [app_name])
    end
  end

  defp node_name(node_host) do
    node_host
    |> to_string
    |> String.split("@")
    |> Enum.at(0)
    |> String.to_atom()
  end

  defp rpc(node, module, function, args), do: :rpc.block_call(node, module, function, args)
end

Clustering.spawn((for num <- 1..3, do: "drone#{num}"), [])

runner = ~S'''
defmodule ExUnit.Runner do
  @moduledoc false

  alias ExUnit.EventManager, as: EM

  @rand_algorithm :exs1024
  @current_key __MODULE__

  def run(opts, load_us) when (is_integer(load_us) or is_nil(load_us)) and is_list(opts) do
    runner = self()
    id = {__MODULE__, runner}

    try do
      # It may fail on Windows, so we ignore the result.
      _ =
        System.trap_signal(:sigquit, id, fn ->
          ref = Process.monitor(runner)
          send(runner, {ref, self(), :sigquit})

          receive do
            ^ref -> :ok
            {:DOWN, ^ref, _, _, _} -> :ok
          after
            5_000 -> :ok
          end

          Process.demonitor(ref, [:flush])
          :ok
        end)

      run_with_trap(opts, load_us)
    after
      System.untrap_signal(:sigquit, id)
    end
  end

  defp run_with_trap(opts, load_us) do
    opts = normalize_opts(opts)
    {:ok, manager} = EM.start_link()
    {:ok, stats_pid} = EM.add_handler(manager, ExUnit.RunnerStats, opts)
    config = configure(opts, manager, self(), stats_pid)
    :erlang.system_flag(:backtrace_depth, Keyword.fetch!(opts, :stacktrace_depth))

    Process.sleep(1000)
    start_time = System.monotonic_time()
    EM.suite_started(config.manager, opts)
    stream = Stream.cycle([Node.self() | Node.list()])
    async_stop_time = loop(config, :async, %{}, false, stream)
    stop_time = System.monotonic_time()

    if max_failures_reached?(config) do
      EM.max_failures_reached(config.manager)
    end

    async_us =
      async_stop_time &&
        System.convert_time_unit(async_stop_time - start_time, :native, :microsecond)

    run_us = System.convert_time_unit(stop_time - start_time, :native, :microsecond)
    times_us = %{async: async_us, load: load_us, run: run_us}
    EM.suite_finished(config.manager, times_us)

    stats = ExUnit.RunnerStats.stats(stats_pid)
    EM.stop(config.manager)
    after_suite_callbacks = Application.fetch_env!(:ex_unit, :after_suite)
    Enum.each(after_suite_callbacks, fn callback -> callback.(stats) end)
    stats
  end

  defp configure(opts, manager, runner_pid, stats_pid) do
    Enum.each(opts[:formatters], &EM.add_handler(manager, &1, opts))

    %{
      capture_log: opts[:capture_log],
      exclude: opts[:exclude],
      include: opts[:include],
      manager: manager,
      max_cases: opts[:max_cases],
      max_failures: opts[:max_failures],
      only_test_ids: opts[:only_test_ids],
      runner_pid: runner_pid,
      seed: opts[:seed],
      stats_pid: stats_pid,
      timeout: opts[:timeout],
      trace: opts[:trace]
    }
  end

  defp normalize_opts(opts) do
    {include, exclude} = ExUnit.Filters.normalize(opts[:include], opts[:exclude])

    opts
    |> Keyword.put(:exclude, exclude)
    |> Keyword.put(:include, include)
  end

  defp loop(config, :async, running, async_once?, stream) do
    available = config.max_cases - map_size(running)

    cond do
      # No modules available, wait for one
      available <= 0 ->
        wait_until_available(config, :async, running, async_once?, stream)

      # Slots are available, start with async modules
      modules = ExUnit.Server.take_async_modules(available) ->
        stream = Stream.drop(stream, 1)
        spawn_modules(config, modules, :async, running, true, stream)

      true ->
        modules = ExUnit.Server.take_sync_modules()
        loop(config, modules, running, async_once?, stream)
    end
  end

  defp loop(config, modules, running, async_stop_time, stream) do
    case modules do
      _ when running != %{} ->
        wait_until_available(config, modules, running, async_stop_time, stream)

      # So we can start all sync modules
      [head | tail] ->
        spawn_modules(config, [head], tail, running, async_stop_time(async_stop_time), stream)

      # No more modules, we are done!
      [] ->
        async_stop_time(async_stop_time)
    end
  end

  defp async_stop_time(false = _async_once?), do: nil
  defp async_stop_time(true = _async_once?), do: System.monotonic_time()
  defp async_stop_time(async_stop_time), do: async_stop_time

  # Loop expecting down messages from the spawned modules.
  #
  # We first look at the sigquit signal because we don't want
  # to spawn new test cases when we know we will have to handle
  # sigquit next.
  #
  # Otherwise, whenever a module has finished executing, update
  # the runnig modules and attempt to spawn new ones.
  defp wait_until_available(config, modules, running, async_timing, stream) do
    receive do
      {ref, pid, :sigquit} ->
        sigquit(config, ref, pid, running)
    after
      0 ->
        receive do
          {ref, pid, :sigquit} ->
            sigquit(config, ref, pid, running)

          {:DOWN, ref, _, _, _} when is_map_key(running, ref) ->
            loop(config, modules, Map.delete(running, ref), async_timing, stream)
        end
    end
  end

  defp spawn_modules(config, [], modules_remaining, running, async_timing, stream) do
    loop(config, modules_remaining, running, async_timing, stream)
  end

  defp spawn_modules(config, [module | modules], modules_remaining, running, async_timing, stream) do
    if max_failures_reached?(config) do
      loop(config, modules_remaining, running, async_timing, stream)
    else
      {pid, ref} = spawn_monitor(fn -> run_module(config, module, stream) end)
      spawn_modules(config, modules, modules_remaining, Map.put(running, ref, pid), async_timing, stream)
    end
  end

  ## stacktrace

  # Assertions can pop-up in the middle of the stack
  def prune_stacktrace([{ExUnit.Assertions, _, _, _} | t]), do: prune_stacktrace(t)

  # As soon as we see a Runner, it is time to ignore the stacktrace
  def prune_stacktrace([{__MODULE__, _, _, _} | _]), do: []

  # All other cases
  def prune_stacktrace([h | t]), do: [h | prune_stacktrace(t)]
  def prune_stacktrace([]), do: []

  ## sigquit

  defp sigquit(config, ref, pid, running) do
    # Stop all child processes from running and get their current state.
    # We need to stop these processes because they may invoke the event
    # manager and we must stop the event manager to guarantee the sigquit
    # data has been flushed.
    current =
      Enum.map(running, fn {ref, pid} ->
        current = safe_pdict_current(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, _, _, _} -> current
        end
      end)

    EM.sigquit(config.manager, Enum.reject(current, &is_nil/1))
    EM.stop(config.manager)

    # Reply to the event manager and wait until it shuts down the VM.
    send(pid, ref)
    Process.sleep(:infinity)
  end

  defp safe_pdict_current(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
        {@current_key, current} <- List.keyfind(dictionary, @current_key, 0),
        do: current
  rescue
    _ -> nil
  end

  ## Running modules


  defp prepare_tests(config, tests) do
    tests = shuffle(config, tests)
    include = config.include
    exclude = config.exclude
    test_ids = config.only_test_ids

    for test <- tests, include_test?(test_ids, test) do
      tags = Map.merge(test.tags, %{test: test.name, module: test.module})

      case ExUnit.Filters.eval(include, exclude, tags, tests) do
        :ok -> %{test | tags: tags}
        excluded_or_skipped -> %{test | state: excluded_or_skipped}
      end
    end
  end

  defp include_test?(test_ids, test) do
    test_ids == nil or MapSet.member?(test_ids, {test.module, test.name})
  end

  def run_module(_config, test_module, []) do
    {test_module, [], []}
  end

  def run_module(config, test_module, tests) when is_list(tests) do
    {module_pid, module_ref} = run_setup_all(test_module, self())

    {test_module, invalid_tests, finished_tests} =
      receive do
        {^module_pid, :setup_all, {:ok, context}} ->
          finished_tests =
            if max_failures_reached?(config), do: [], else: run_tests(config, tests, context)

          :ok = exit_setup_all(module_pid, module_ref)
          {test_module, [], finished_tests}

        {^module_pid, :setup_all, {:error, test_module}} ->
          invalid_tests = Enum.map(tests, &%{&1 | state: {:invalid, test_module}})
          :ok = exit_setup_all(module_pid, module_ref)
          {test_module, invalid_tests, []}

        {:DOWN, ^module_ref, :process, ^module_pid, error} ->
          test_module = %{test_module | state: failed({:EXIT, module_pid}, error, [])}
          {test_module, [], []}
      end

    timeout = get_timeout(config, %{})
    {exec_on_exit(test_module, module_pid, timeout), invalid_tests, finished_tests}
  end

  def run_module(config, module, stream) do
    test_module = module.__ex_unit__()
    EM.module_started(config.manager, test_module)

    # Prepare tests, selecting which ones should be run or skipped
    tests = prepare_tests(config, test_module.tests)
    {excluded_and_skipped_tests, to_run_tests} = Enum.split_with(tests, & &1.state)

    for excluded_or_skipped_test <- excluded_and_skipped_tests do
      EM.test_started(config.manager, excluded_or_skipped_test)
      EM.test_finished(config.manager, excluded_or_skipped_test)
    end

    node = Enum.take(stream, 1) |> hd()
    key = :rpc.async_call(node, __MODULE__, :run_module, [config, test_module, to_run_tests])
    {:value, {test_module, invalid_tests, finished_tests}} = :rpc.nb_yield(key, :infinity)

    pending_tests =
      case process_max_failures(config, test_module) do
        :no ->
          invalid_tests

        {:reached, n} ->
          Enum.take(invalid_tests, n)

        :surpassed ->
          nil
      end

    # If pending_tests is [], EM.module_finished is still called.
    # Only if process_max_failures/2 returns :surpassed it is not.
    if pending_tests do
      for pending_test <- pending_tests do
        EM.test_started(config.manager, pending_test)
        EM.test_finished(config.manager, pending_test)
      end

      test_module = %{test_module | tests: Enum.reverse(finished_tests, pending_tests)}
      EM.module_finished(config.manager, test_module)
    end
  end

  defp run_setup_all(%ExUnit.TestModule{name: module} = test_module, parent_pid) do
    Process.put(@current_key, test_module)

    spawn_monitor(fn ->
      ExUnit.OnExitHandler.register(self())

      result =
        try do
          {:ok, module.__ex_unit__(:setup_all, %{module: module, case: module})}
        catch
          kind, error ->
            failed = failed(kind, error, prune_stacktrace(__STACKTRACE__))
            {:error, %{test_module | state: failed}}
        end

      send(parent_pid, {self(), :setup_all, result})

      # We keep the process alive so all of its resources
      # stay alive until we run all tests in this case.
      ref = Process.monitor(parent_pid)

      receive do
        {^parent_pid, :exit} -> :ok
        {:DOWN, ^ref, _, _, _} -> :ok
      end
    end)
  end

  defp exit_setup_all(pid, ref) do
    send(pid, {self(), :exit})

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  defp run_tests(config, tests, context) do
    Enum.reduce_while(tests, [], fn test, acc ->
      Process.put(@current_key, test)

      case run_test(config, test, context) do
        {:ok, test} -> {:cont, [test | acc]}
        :max_failures_reached -> {:halt, acc}
      end
    end)
  end

  defp run_test(config, %{tags: tags} = test, context) do
    EM.test_started(config.manager, test)

    context = maybe_create_tmp_dir(test, context, tags)
    capture_log = Map.get(tags, :capture_log, config.capture_log)
    test = run_test_with_capture_log(capture_log, config, test, Map.merge(tags, context))

    case process_max_failures(config, test) do
      :no ->
        EM.test_finished(config.manager, test)
        {:ok, test}

      {:reached, 1} ->
        EM.test_finished(config.manager, test)
        :max_failures_reached

      :surpassed ->
        :max_failures_reached
    end
  end

  defp maybe_create_tmp_dir(test, context, %{tmp_dir: true}) do
    create_tmp_dir!(test, "", context)
  end

  defp maybe_create_tmp_dir(test, context, %{tmp_dir: path}) when is_binary(path) do
    create_tmp_dir!(test, path, context)
  end

  defp maybe_create_tmp_dir(_, context, %{tmp_dir: false}) do
    context
  end

  defp maybe_create_tmp_dir(_, _, %{tmp_dir: other}) do
    raise ArgumentError, "expected :tmp_dir to be a boolean or a string, got: #{inspect(other)}"
  end

  defp maybe_create_tmp_dir(_, context, _) do
    context
  end

  defp create_tmp_dir!(test, extra_path, context) do
    module = escape_path(inspect(test.module))
    name = escape_path(to_string(test.name))
    path = ["tmp", module, name, extra_path] |> Path.join() |> Path.expand()
    File.rm_rf!(path)
    File.mkdir_p!(path)
    Map.put(context, :tmp_dir, path)
  end

  @escape Enum.map(' [~#%&*{}\\:<>?/+|"]', &<<&1::utf8>>)

  defp escape_path(path) do
    String.replace(path, @escape, "-")
  end

  defp run_test_with_capture_log(true, config, test, context) do
    run_test_with_capture_log([], config, test, context)
  end

  defp run_test_with_capture_log(false, config, test, context) do
    spawn_test(config, test, context)
  end

  defp run_test_with_capture_log(capture_log_opts, config, test, context) do
    ref = make_ref()

    try do
      ExUnit.CaptureLog.capture_log(capture_log_opts, fn ->
        send(self(), {ref, spawn_test(config, test, context)})
      end)
    catch
      :exit, :noproc ->
        message =
          "could not run test, it uses @tag :capture_log" <>
            " but the :logger application is not running"

        %{test | state: failed(:error, RuntimeError.exception(message), [])}
    else
      logged ->
        receive do
          {^ref, test} -> %{test | logs: logged}
        end
    end
  end

  defp spawn_test(config, test, context) do
    parent_pid = self()
    timeout = get_timeout(config, test.tags)
    {test_pid, test_ref} = spawn_test_monitor(config, test, parent_pid, context)
    test = receive_test_reply(test, test_pid, test_ref, timeout)
    exec_on_exit(test, test_pid, timeout)
  end

  defp spawn_test_monitor(%{seed: seed}, test, parent_pid, context) do
    spawn_monitor(fn ->
      ExUnit.OnExitHandler.register(self())
      generate_test_seed(seed, test)

      {time, test} =
        :timer.tc(fn ->
          case exec_test_setup(test, context) do
            {:ok, test} -> exec_test(test)
            {:error, test} -> test
          end
        end)

      send(parent_pid, {self(), :test_finished, %{test | time: time}})
      exit(:shutdown)
    end)
  end

  defp receive_test_reply(test, test_pid, test_ref, timeout) do
    receive do
      {^test_pid, :test_finished, test} ->
        Process.demonitor(test_ref, [:flush])
        test

      {:DOWN, ^test_ref, :process, ^test_pid, error} ->
        %{test | state: failed({:EXIT, test_pid}, error, [])}
    after
      timeout ->
        case Process.info(test_pid, :current_stacktrace) do
          {:current_stacktrace, stacktrace} ->
            Process.demonitor(test_ref, [:flush])
            Process.exit(test_pid, :kill)

            exception =
              ExUnit.TimeoutError.exception(
                timeout: timeout,
                type: Atom.to_string(test.tags.test_type)
              )

            %{test | state: failed(:error, exception, stacktrace)}

          nil ->
            receive_test_reply(test, test_pid, test_ref, timeout)
        end
    end
  end

  defp exec_test_setup(%ExUnit.Test{module: module} = test, context) do
    {:ok, %{test | tags: module.__ex_unit__(:setup, context)}}
  catch
    kind, error ->
      {:error, %{test | state: failed(kind, error, prune_stacktrace(__STACKTRACE__))}}
  end

  defp exec_test(%ExUnit.Test{module: module, name: name, tags: context} = test) do
    apply(module, name, [context])
    test
  catch
    kind, error ->
      %{test | state: failed(kind, error, prune_stacktrace(__STACKTRACE__))}
  end

  defp exec_on_exit(test_or_case, pid, timeout) do
    case ExUnit.OnExitHandler.run(pid, timeout) do
      :ok ->
        test_or_case

      {kind, reason, stack} ->
        state = test_or_case.state || failed(kind, reason, prune_stacktrace(stack))
        %{test_or_case | state: state}
    end
  end

  ## Helpers

  defp generate_test_seed(seed, %ExUnit.Test{module: module, name: name}) do
    :rand.seed(@rand_algorithm, {:erlang.phash2(module), :erlang.phash2(name), seed})
  end

  defp process_max_failures(%{max_failures: :infinity}, _), do: :no

  defp process_max_failures(config, %ExUnit.TestModule{state: {:failed, _}, tests: tests}) do
    process_max_failures(config.stats_pid, config.max_failures, length(tests))
  end

  defp process_max_failures(config, %ExUnit.Test{state: {:failed, _}}) do
    process_max_failures(config.stats_pid, config.max_failures, 1)
  end

  defp process_max_failures(config, _test_module_or_test) do
    if max_failures_reached?(config), do: :surpassed, else: :no
  end

  defp process_max_failures(stats_pid, max_failures, bump) do
    previous = ExUnit.RunnerStats.increment_failure_counter(stats_pid, bump)

    cond do
      previous >= max_failures -> :surpassed
      previous + bump < max_failures -> :no
      true -> {:reached, max_failures - previous}
    end
  end

  defp max_failures_reached?(%{stats_pid: stats_pid, max_failures: max_failures}) do
    max_failures != :infinity and
      ExUnit.RunnerStats.get_failure_counter(stats_pid) >= max_failures
  end

  defp get_timeout(config, tags) do
    if config.trace do
      :infinity
    else
      Map.get(tags, :timeout, config.timeout)
    end
  end

  defp shuffle(%{seed: 0}, list) do
    Enum.reverse(list)
  end

  defp shuffle(%{seed: seed}, list) do
    _ = :rand.seed(@rand_algorithm, {seed, seed, seed})
    Enum.shuffle(list)
  end

  defp failed(:error, %ExUnit.MultiError{errors: errors}, _stack) do
    errors =
      Enum.map(errors, fn {kind, reason, stack} ->
        {kind, Exception.normalize(kind, reason, stack), prune_stacktrace(stack)}
      end)

    {:failed, errors}
  end

  defp failed(kind, reason, stack) do
    {:failed, [{kind, Exception.normalize(kind, reason, stack), stack}]}
  end
end
'''

compiler = ~S'''
defmodule Mix.Compilers.Test do
  @moduledoc false

  require Mix.Compilers.Elixir, as: CE

  import Record

  defrecordp :source,
    source: nil,
    compile_references: [],
    runtime_references: [],
    external: []

  # Necessary to avoid warnings during bootstrap
  @compile {:no_warn_undefined, ExUnit}
  @stale_manifest "compile.test_stale"
  @manifest_vsn 1

  @doc """
  Requires and runs test files.

  It expects all of the test patterns, the test files that were matched for the
  test patterns, the test paths, and the opts from the test task.
  """
  def require_and_run(matched_test_files, test_paths, opts) do
    stale = opts[:stale]

    {test_files, stale_manifest_pid, parallel_require_callbacks} =
      if stale do
        set_up_stale(matched_test_files, test_paths, opts)
      else
        {matched_test_files, nil, []}
      end

    if test_files == [] do
      :noop
    else
      task = ExUnit.async_run()

      try do
        {results, _} = :rpc.multicall(Kernel.ParallelCompiler, :require, [test_files, parallel_require_callbacks])

        Enum.each(results, fn
          {:ok, _, _} -> :ok
          {:error, _, _} -> exit({:shutdown, 1})
        end)

        %{failures: failures} = results = ExUnit.await_run(task)

        if failures == 0 do
          agent_write_manifest(stale_manifest_pid)
        end

        {:ok, results}
      catch
        kind, reason ->
          # In case there is an error, shut down the runner task
          # before the error propagates up and trigger links.
          Task.shutdown(task)
          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        agent_stop(stale_manifest_pid)
      end
    end
  end

  defp set_up_stale(matched_test_files, test_paths, opts) do
    manifest = manifest()
    modified = Mix.Utils.last_modified(manifest)
    all_sources = read_manifest()

    removed =
      for source(source: source) <- all_sources, source not in matched_test_files, do: source

    config_mtime = Mix.Project.config_mtime()
    test_helpers = Enum.map(test_paths, &Path.join(&1, "test_helper.exs"))
    force = opts[:force] || Mix.Utils.stale?([config_mtime | test_helpers], [modified])

    changed =
      if force do
        # Let's just require everything
        matched_test_files
      else
        sources_mtimes = mtimes(all_sources)

        # Otherwise let's start with the new sources
        # Plus the sources that have changed in disk
        for(
          source <- matched_test_files,
          not List.keymember?(all_sources, source, source(:source)),
          do: source
        ) ++
          for(
            source(source: source, external: external) <- all_sources,
            times = Enum.map([source | external], &Map.fetch!(sources_mtimes, &1)),
            Mix.Utils.stale?(times, [modified]),
            do: source
          )
      end

    stale = MapSet.new(changed -- removed)
    sources = update_stale_sources(all_sources, removed, changed)

    test_files_to_run =
      sources
      |> tests_with_changed_references()
      |> MapSet.union(stale)
      |> MapSet.to_list()

    if test_files_to_run == [] do
      write_manifest(sources)
      {[], nil, nil}
    else
      {:ok, pid} = Agent.start_link(fn -> sources end)
      cwd = File.cwd!()

      parallel_require_callbacks = [
        each_module: &each_module(pid, cwd, &1, &2, &3),
        each_file: &each_file(pid, cwd, &1, &2)
      ]

      {test_files_to_run, pid, parallel_require_callbacks}
    end
  end

  defp agent_write_manifest(nil), do: :noop

  defp agent_write_manifest(pid) do
    Agent.cast(pid, fn sources ->
      write_manifest(sources)
      sources
    end)
  end

  defp agent_stop(nil), do: :noop

  defp agent_stop(pid) do
    Agent.stop(pid, :normal, :infinity)
  end

  ## Setup helpers

  defp mtimes(sources) do
    Enum.reduce(sources, %{}, fn source(source: source, external: external), map ->
      Enum.reduce([source | external], map, fn file, map ->
        Map.put_new_lazy(map, file, fn -> Mix.Utils.last_modified(file) end)
      end)
    end)
  end

  defp update_stale_sources(sources, removed, changed) do
    sources = Enum.reject(sources, fn source(source: source) -> source in removed end)

    sources =
      Enum.reduce(changed, sources, &List.keystore(&2, &1, source(:source), source(source: &1)))

    sources
  end

  ## Manifest

  defp manifest, do: Path.join(Mix.Project.manifest_path(), @stale_manifest)

  defp read_manifest() do
    try do
      [@manifest_vsn | sources] = manifest() |> File.read!() |> :erlang.binary_to_term()
      sources
    rescue
      _ -> []
    end
  end

  defp write_manifest([]) do
    File.rm(manifest())
    :ok
  end

  defp write_manifest(sources) do
    manifest = manifest()
    File.mkdir_p!(Path.dirname(manifest))

    manifest_data = :erlang.term_to_binary([@manifest_vsn | sources], [:compressed])
    File.write!(manifest, manifest_data)
  end

  ## Test changed dependency resolution

  defp tests_with_changed_references(test_sources) do
    test_manifest = manifest()
    [elixir_manifest] = Mix.Tasks.Compile.Elixir.manifests()

    if Mix.Utils.stale?([elixir_manifest], [test_manifest]) do
      compile_path = Mix.Project.compile_path()
      {elixir_modules, elixir_sources} = CE.read_manifest(elixir_manifest)

      stale_modules =
        for CE.module(module: module) <- elixir_modules,
            beam = Path.join(compile_path, Atom.to_string(module) <> ".beam"),
            Mix.Utils.stale?([beam], [test_manifest]),
            do: module,
            into: MapSet.new()

      stale_modules = find_all_dependent_on(stale_modules, elixir_modules, elixir_sources)

      for module <- stale_modules,
          source(source: source, runtime_references: r, compile_references: c) <- test_sources,
          module in r or module in c,
          do: source,
          into: MapSet.new()
    else
      MapSet.new()
    end
  end

  defp find_all_dependent_on(modules, all_modules, sources, resolved \\ MapSet.new()) do
    new_modules =
      for module <- modules,
          module not in resolved,
          dependent_module <- dependent_modules(module, all_modules, sources),
          do: dependent_module,
          into: modules

    if MapSet.size(new_modules) == MapSet.size(modules) do
      new_modules
    else
      find_all_dependent_on(new_modules, all_modules, sources, modules)
    end
  end

  defp dependent_modules(module, modules, sources) do
    for CE.source(
          source: source,
          runtime_references: r,
          compile_references: c,
          export_references: e
        ) <- sources,
        module in r or module in c or module in e,
        CE.module(sources: sources, module: dependent_module) <- modules,
        source in sources,
        do: dependent_module
  end

  ## ParallelRequire callback

  defp each_module(pid, cwd, file, module, _binary) do
    external = get_external_resources(module, cwd)

    if external != [] do
      Agent.update(pid, fn sources ->
        file = Path.relative_to(file, cwd)
        {source, sources} = List.keytake(sources, file, source(:source))
        [source(source, external: external ++ source(source, :external)) | sources]
      end)
    end

    :ok
  end

  defp each_file(pid, cwd, file, lexical) do
    Agent.update(pid, fn sources ->
      file = Path.relative_to(file, cwd)
      {source, sources} = List.keytake(sources, file, source(:source))

      {compile_references, export_references, runtime_references, _compile_env} =
        Kernel.LexicalTracker.references(lexical)

      source =
        source(
          source,
          compile_references: compile_references ++ export_references,
          runtime_references: runtime_references
        )

      [source | sources]
    end)
  end

  defp get_external_resources(module, cwd) do
    for file <- Module.get_attribute(module, :external_resource), do: Path.relative_to(file, cwd)
  end
end
'''

:rpc.multicall(Code, :compile_string, [runner, __ENV__.file])
:rpc.multicall(Code, :compile_string, [compiler, __ENV__.file])

ExUnit.start()
