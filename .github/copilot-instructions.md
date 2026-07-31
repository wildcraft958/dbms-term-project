# Copilot Instructions

A DBMS term project that benchmarks a high-QPS full-text search engine built on **Apache Solr 9.3.0** + **Apache ZooKeeper 3.8.1**. This is a benchmarking/research study, not a production service: the deliverable is a QPS-vs-concurrency analysis across standalone and SolrCloud deployments, plus a web dashboard.

The repo has two largely independent halves:
- `benchmark/` — a standalone **C++17** multithreaded HTTP load-test client (CMake).
- `solr-apache/` — Solr/ZooKeeper setup scripts, a static search webapp + Python proxy, and the Python visualization pipeline.

## Build & run commands

**C++ benchmark client** (`benchmark/`) — the only compiled artifact:
```bash
cd benchmark && mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)            # produces ./solr_benchmark
```
Run a single benchmark sweep (requires Solr already running):
```bash
./solr_benchmark --url http://localhost:8983/solr/searchcore \
                 --concurrency 2,5,10,25,50 --duration 10 --output results.json
```
There is **no unit-test suite and no linter config** anywhere in this repo. "Testing" a change means building the C++ client (`cmake --build`), validating scripts with `bash -n` / Python with `py_compile`, regenerating the data pipeline against existing results, and/or running a benchmark sweep against a live Solr.

**Infrastructure & data** (all from `solr-apache/scripts/`, in order):
```bash
./setup-solr.sh          # downloads + configures Solr 9.3.0 and a 3-node ZK ensemble
./start-services.sh      # starts ZK ensemble + 2 Solr nodes, creates `searchcore` collection
./index-sample-data.sh   # builds a Simple-English-Wikipedia corpus and indexes ~10k docs
```

**Webapp** (must be served, not opened as `file://`):
```bash
cd solr-apache && python3 webapp/server.py 9090   # serves UI + proxies /solr/* to :8983
```

**Visualization** (Python 3 + matplotlib/numpy/pandas): `visualize.py <results.json>` and `compare_configs.py`. These scripts assume an activated virtualenv (existing scripts source `~/solr-project/bin/activate`).

## Architecture & the data-flow contract

Request path at runtime: **browser → `webapp/server.py` (port 9090) → Solr (8983) → ZooKeeper ensemble (2181–2183)**.

Benchmark path: **siege scripts _or_ the C++ client → Solr**, each emitting the **same siege-compatible JSON schema** → `visualize.py` / `compare_configs.py` produce PNGs under `scripts/visualizations/`. The `benchmark.html` dashboard is fed separately from the canonical `webapp/data/configs.json` + `cpp_data.json` via `sync_dashboard_data.py`.

That shared JSON result schema (`concurrent_users`, `transactions`, `transaction_rate`, `availability`, `concurrency`, plus the C++ client's extra `p50/p95/p99_latency_ms`) is the **integration contract** between three producers and three consumers. If you add or rename a metric, update **both** the producers (`run-siege-benchmark.sh`, `benchmark/src/benchmark_runner.cpp`) **and** the consumers (`visualize.py`, `compare_configs.py`, `webapp/`). Keeping the C++ output siege-compatible is intentional so one `visualize.py` handles both tools.

C++ client internals: `main.cpp` (CLI parsing) → `BenchmarkRunner` (orchestrates one sweep per concurrency level, spawning raw `std::thread` workers) → shared `ConnectionPool` (reused `libcurl` handles) → `MetricsCollector` (percentiles; measured concurrency via Little's Law `L = λ × W`).

## Conventions specific to this repo

- **Scripts source `solr-apache/scripts/env.sh`** for shared, env-overridable defaults (`COLLECTION`, `SOLR_URL`, `NUM_SOLR_NODES`, `NUM_ZK_NODES`, ports, `SHARDS`, `REPLICATION_FACTOR`, `SIEGERC`). All shell scripts resolve their own location via `SCRIPT_DIR`, so they can be run from anywhere.
- **Benchmark data is canonical in `webapp/data/configs.json`.** Both `compare_configs.py` and the `benchmark.html` dashboard read from it; run `scripts/sync_dashboard_data.py` after editing it to regenerate the dashboard's inline `CONFIGS` (between the `CONFIGS_DATA` markers). Never hand-edit the dashboard data or reintroduce fabricated cross-engine numbers.
- **siege must emit JSON for the parser.** `run-siege-benchmark.sh` invokes `siege -R scripts/benchmark/siege-config/siegerc` (sets `json_output = true`); it fails loudly rather than writing zero rows if metrics can't be parsed.
- **Runtime dirs live under `solr-apache/scripts/`** and are gitignored: `downloads/`, `solr-nodes/`, `zookeeper/`, `benchmark_results/`, `visualizations/`. Generated charts under `webapp/images/` (`*_latest.png`) are also gitignored; the `.jpeg` screenshots are tracked. Solr config templates live in `solr-apache/scripts/solr-config/` (schema/handlers under `solr-config/searchcore/conf/`).
- **The collection is always `searchcore`**; canonical query URL `http://localhost:8983/solr/searchcore/select`. `start-services.sh` creates it with `-d solr-config/searchcore/conf` so the repo's configset (schema + solrconfig) is uploaded to ZooKeeper — schema changes require recreating/reloading the collection.
- **Webapp talks to Solr via relative `/solr/searchcore` URLs** (`webapp/js/app.js`) and depends on `server.py` proxying `/solr/*` to dodge CORS — there is no other backend. `server.py` binds `127.0.0.1` by default (override with `BIND_HOST`). A `file://` open of `index.html` cannot reach Solr.
- **Siege concurrency levels are prime numbers** (2,3,5,7,11,13,17,19,23,29,…) on purpose, to avoid synchronization/aliasing artifacts. Preserve this when editing benchmark scripts.
- **Solr schema uses query-time synonyms, not index-time** (`SynonymGraphFilter` only in the query analyzer) so synonyms can change without re-indexing. Keep new analyzer changes consistent with that split.
- **C++ style** (see `benchmark/include/*.hpp`): `namespace solrbench`, `#pragma once`, snake_case functions/variables, trailing-underscore private members (`config_`, `queue_mutex_`), Doxygen `/** */` comments, declarations in `include/` and implementations in `src/`. Add new source files to the `SOURCES` list in `benchmark/CMakeLists.txt`.
- Pinned toolchain: Solr 9.3.0, ZooKeeper 3.8.1, C++17, CMake ≥ 3.14, Java 11–17 (Solr 9.x won't start on Java 24+; `scripts/env.sh` auto-detects a compatible JDK and exports `JAVA_HOME`, or fails loudly via `require_compatible_java`).
