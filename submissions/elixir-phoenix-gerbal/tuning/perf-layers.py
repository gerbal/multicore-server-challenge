"""Groups a perf profile of the BEAM by layer: the library or runtime part each sample's function belongs to.

    python3 tuning/perf-layers.py <script.txt>                    layers, then the top leaf functions
    python3 tuning/perf-layers.py <script.txt> --inclusive [N]    the N functions most samples pass through
    python3 tuning/perf-layers.py <script.txt> --callers REGEX    for leaves matching REGEX, their nearest callers
                                                                  outside the runtime, the stdlib and JIT helpers

<script.txt> is `perf script -F comm,tid,ip,sym` output of a call-graph recording (tuning/perf.sh writes it). Prints,
per layer, the share of samples whose leaf function is in it (self) and the share whose stack passes through it
(inclusive), then the top leaf functions. Erlang functions are named by the JIT's perf map; C code in beam.smp isn't
built with frame pointers, so a stack that enters C mostly stops there, and inclusive shares are lower bounds.
"""
import collections
import re
import sys

# First match wins: module-name patterns for Erlang code, then symbol patterns for the runtime's C code.
LAYERS = [
    ("app (Conduit)", r"Elixir\.Conduit"),
    ("Phoenix", r"Elixir\.Phoenix"),
    ("Plug", r"Elixir\.Plug"),
    ("Bandit", r"Elixir\.Bandit"),
    ("ThousandIsland", r"Elixir\.ThousandIsland"),
    ("Ecto", r"Elixir\.Ecto"),
    ("DBConnection", r"Elixir\.DBConnection"),
    ("Postgrex", r"Elixir\.Postgrex"),
    ("JSON", r"Elixir\.JSON|\bjson:"),
    ("Joken/JOSE/crypto", r"Elixir\.Joken|Elixir\.JOSE|\bjose|\bcrypto:"),
    ("telemetry", r"\btelemetry"),
    ("Logger", r"Elixir\.Logger|\blogger"),
    ("Elixir stdlib", r"Elixir\.(Enum|Map|Keyword|String|List|Access|Kernel|Integer|DateTime|Calendar|NaiveDateTime|"
                      r"Regex|Stream|IO|Inspect|Protocol|Range|MapSet|Tuple|Atom|Code|Module|System|Process|Base|URI)"),
    ("Erlang stdlib/kernel", r"\b(lists|maps|gen_server|gen|proc_lib|erlang|gen_tcp|inet|prim_inet|socket|binary|"
                             r"unicode|string|calendar|ets|persistent_term|queue|sets|io_lib|re|timer|ssl):"),
    ("JIT runtime helpers", r"^\$global::"),
    ("other Erlang", r"^\$|:.*/\d+$"),
    ("bcrypt (NIF)", r"Blowfish|bcrypt|blf_"),
    ("GC (C)", r"garbage_collect|erts_gc|sweep|^gc_|do_minor|do_major|fullsweep|shrink_new_heap|grow_new_heap|"
               r"move_boxed|move_cons|erts_shrink|offset_heap|offset_mqueue|young_gen"),
    ("memory allocators (C)", r"aoff_|aobf_|bf_|rbt_|alcu_|mbc_|sbc_|erts_alc|erts_alloc|erts_free|erts_realloc|"
                              r"carrier|get_free_block|link_free_block|unlink_free_block|^malloc|^free$|"
                              r"_int_malloc|_int_free"),
    ("message copying (C)", r"copy_struct|copy_shallow|size_object|erts_send_message|erts_queue_message"),
    ("socket I/O (C)", r"erts_ioq|iolist_size|iolist_to|io_list|inet_|tcp_|driver_|port_|erts_port|sock|"
                       r"^send|^recv|writev|readv|epoll|check_io|poll"),
    ("scheduler (C)", r"schedule|scheduler_wait|erts_thr|ethr_|futex|sched_|proc_|erts_proc_"),
    ("BIFs and runtime (C)", r"erts_|beam_|process_main|erl_|bif|enif_|\bbs_|db_|hash|cmp|eq$|term_to|"
                             r"binary_to|enc_|dec_|keyfind|maps_|binary_match|do_binary"),
    ("libc / other native", r"."),
]
COMPILED = [(name, re.compile(pattern)) for name, pattern in LAYERS]


def layer(sym):
    for name, pattern in COMPILED:
        if pattern.search(sym):
            return name
    return "unknown"


def samples(path):
    stack = None
    for line in open(path, errors="replace"):
        if not line.strip():
            if stack:
                yield stack
            stack = None
        elif not line[0].isspace():
            stack = []
        elif stack is not None:
            parts = line.split(None, 1)
            sym = parts[1].strip() if len(parts) > 1 else "[unknown]"
            stack.append(re.sub(r"\+0x[0-9a-f]+$", "", sym))
    if stack:
        yield stack


GENERIC = {"JIT runtime helpers", "Elixir stdlib", "Erlang stdlib/kernel", "other Erlang", "telemetry"}


def nearest_caller(stack):
    for sym in stack[1:]:
        name = layer(sym)
        if sym.startswith("$") and name not in GENERIC:
            return sym
    return "(none)"


if len(sys.argv) > 2 and sys.argv[2] == "--inclusive":
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 60
    counts, total = collections.Counter(), 0
    for stack in samples(sys.argv[1]):
        if stack:
            total += 1
            counts.update(set(stack))
    for sym, n in counts.most_common(limit):
        print(f"{100 * n / total:6.2f}%  {layer(sym):<22} {sym}")
    sys.exit()

if len(sys.argv) > 3 and sys.argv[2] == "--callers":
    wanted = re.compile(sys.argv[3])
    counts, matched, total = collections.Counter(), 0, 0
    for stack in samples(sys.argv[1]):
        if stack:
            total += 1
            if wanted.search(stack[0]):
                matched += 1
                counts[nearest_caller(stack)] += 1
    print(f"{matched} of {total} samples ({100 * matched / total:.2f}%) have a leaf matching {sys.argv[3]!r}")
    for sym, n in counts.most_common(25):
        print(f"{100 * n / total:6.2f}%  {sym}")
    sys.exit()

self_counts, incl_counts, leaf_counts = collections.Counter(), collections.Counter(), collections.Counter()
total = 0
for stack in samples(sys.argv[1]):
    if not stack:
        continue
    total += 1
    leaf = stack[0]
    leaf_counts[leaf] += 1
    self_counts[layer(leaf)] += 1
    for name in {layer(sym) for sym in stack}:
        incl_counts[name] += 1

print(f"{total} samples\n")
print(f"{'layer':<24} {'self':>7} {'inclusive':>10}")
for name, _ in sorted(self_counts.items(), key=lambda kv: -kv[1]):
    print(f"{name:<24} {100 * self_counts[name] / total:6.1f}% {100 * incl_counts[name] / total:9.1f}%")
print("\ntop leaf functions")
for sym, n in leaf_counts.most_common(40):
    print(f"{100 * n / total:6.2f}%  {layer(sym):<22} {sym}")
