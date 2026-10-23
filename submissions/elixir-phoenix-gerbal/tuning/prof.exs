# Attaches to the node started by tuning/profile.sh and traces call time for 10 s. Run by profile.sh.
node = :"conduitprof@#{elem(:inet.gethostname(), 1)}"
true = Node.connect(node)
out = System.get_env("OUT", ".")

rpc = fn m, f, a -> :erpc.call(node, m, f, a, 120_000) end
# Mix prunes the server's code path to the project's deps; :tprof is in OTP's tools application.
true = rpc.(:code, :add_patha, [:filename.join(:code.lib_dir(:tools), ~c"ebin")])
rpc.(:tprof, :start, [%{type: :call_time}])
rpc.(:tprof, :enable_trace, [:all])
rpc.(:tprof, :set_pattern, [:_, :_, :_])
Process.sleep(10_000)
rpc.(:tprof, :disable_trace, [:all])
{:call_time, rows} = rpc.(:tprof, :collect, [])
rpc.(:tprof, :stop, [])

time = fn per -> per |> Enum.map(&elem(&1, 2)) |> Enum.sum() end
calls = fn per -> per |> Enum.map(&elem(&1, 1)) |> Enum.sum() end
pct = fn t, total -> :erlang.float_to_binary(t * 100 / total, decimals: 2) end
total = rows |> Enum.map(fn {_m, _f, _a, per} -> time.(per) end) |> Enum.sum()

by_mod =
  rows
  |> Enum.group_by(&elem(&1, 0), fn {_m, _f, _a, per} -> time.(per) end)
  |> Enum.map(fn {m, ts} -> {m, Enum.sum(ts)} end)
  |> Enum.sort_by(&elem(&1, 1), :desc)

File.write!(
  Path.join(out, "profile-mods.txt"),
  Enum.map_join(Enum.take(by_mod, 50), "\n", fn {m, t} -> "#{pct.(t, total)}%  #{inspect(m)}" end)
)

by_fun =
  rows
  |> Enum.map(fn {m, f, a, per} -> {{m, f, a}, calls.(per), time.(per)} end)
  |> Enum.sort_by(&(-elem(&1, 2)))

File.write!(
  Path.join(out, "profile-funs.txt"),
  Enum.map_join(Enum.take(by_fun, 80), "\n", fn {{m, f, a}, c, t} ->
    "#{pct.(t, total)}%  #{c} calls  #{inspect(m)}.#{f}/#{a}"
  end)
)

IO.puts("traced #{total} µs; wrote #{out}/profile-mods.txt and profile-funs.txt")
