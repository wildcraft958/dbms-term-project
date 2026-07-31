# Demo Runbook

Everything needed to bring the system up, show it, and shut it down cleanly.

This machine has ~7.4 GB RAM with browsers usually holding 4+ GB of it, so the demo runs a
**trimmed topology: 1 ZooKeeper + 1 Solr node, 2 shards**. That is still a real SolrCloud
deployment coordinated by ZooKeeper. The multi node comparison in the benchmark dashboard comes
from the recorded study results, not from this laptop.

**Before you start: close Firefox or Brave.** Solr needs roughly 1 GB and the JVM will thrash
without it.

---

## Start

From `solr-apache/scripts/`:

```bash
export NUM_ZK_NODES=1 NUM_SOLR_NODES=1 SHARDS=2 REPLICATION_FACTOR=1
export SOLR_HEAP=512m JVMFLAGS="-Xms64m -Xmx256m"

./start-services.sh              # ZooKeeper on 2181, Solr on 8983, creates searchcore
```

Then the web UI, from `solr-apache/`:

```bash
python3 webapp/server.py 9090
```

Open **http://localhost:9090/index.html**. Do not open the file directly from disk; the page
reaches Solr through the proxy in `server.py`, and a `file://` page cannot.

Health check before you present:

```bash
curl -s "localhost:8983/solr/searchcore/select?q=*:*&rows=0&wt=json"
```

`numFound` should be in the thousands. If it is 0, run `./index-sample-data.sh`.

## Stop

```bash
fuser -k 9090/tcp                                    # web UI
./stop-services.sh                                   # Solr then ZooKeeper
```

---

## The three demo beats

### 1. Live full text search

Search **`india`** or **`computer`**. Point at:

- The **response time badge** next to the search box, typically single or low double digit ms.
- **Highlighted match terms** in the snippets, done by Solr's highlighter, not the browser.
- The **Filter by File** and **Tags** facets in the sidebar. Tick one and the result set narrows.
- Type three letters and pause: the **autocomplete dropdown** is Solr's FuzzyLookup suggester.

Good line to have ready: results are grouped by source document, so multiple matching paragraphs
from one file collapse into a single result instead of flooding the page.

### 2. Index a document live

Scroll to **Index a Document**, drop in a PDF or `.txt`, press Index Document. Then search a
distinctive phrase from that file and it comes back.

Worth saying out loud: the PDF is split per paragraph in the browser with pdf.js, and each
paragraph is indexed as its own Solr document with page and paragraph numbers. That is why the
highlighter can point at the exact paragraph rather than just naming the file.

### 3. Benchmark dashboard

Open **http://localhost:9090/benchmark.html** (also live at the GitHub Pages URL).

The story in the QPS vs concurrency curves:

- Throughput climbs with concurrency, then plateaus when CPU saturates.
- **Standalone beats SolrCloud on a single machine.** That is the interesting result and it is
  not a bug. In SolrCloud, whichever node receives the query becomes the coordinator, fans out to
  one replica per shard, waits for the slowest, then merges and re ranks. On one box those shards
  compete for the same cores, so you pay all the distributed coordination cost and get none of the
  parallelism benefit. Sharding pays off when shards sit on separate hardware.
- Concurrency levels are prime numbers on purpose, to avoid synchronization and aliasing artifacts
  between client threads.

If asked how it was measured: two independent load generators, siege and a custom C++17 client
using `std::thread` with a libcurl connection pool, both emitting the same JSON schema so one
`visualize.py` handles both. The C++ client also reports p50/p95/p99 latency and derives measured
concurrency from Little's Law.

---

## Running a live benchmark

Only if the machine is idle, and keep it short. Full sweeps go to 83 concurrent users and will
make the laptop unusable mid interview.

```bash
cd benchmark && mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release && make -j$(nproc)
./solr_benchmark --url http://localhost:8983/solr/searchcore \
                 --concurrency 2,5,10 --duration 5 --output /tmp/run.json
```

```bash
CONCURRENT_USERS="2 3 5" DURATION=5 QUERY_ENDPOINT="/select?q=india" ./run-siege-benchmark.sh
```

**Do not run `update_dashboard_from_run.py`.** It overwrites `webapp/data/configs.json` and
`cpp_data.json`, which hold the real recorded study results. Numbers from this single node laptop
would replace them and the dashboard would then understate the project.

---

## After changing schema or solrconfig

Solr configs live in ZooKeeper, so editing the files on disk and restarting does nothing. Re upload
the configset and reload the collection:

```bash
cd solr-apache/scripts
./solr-nodes/node1/bin/solr zk upconfig -n searchcore \
    -d solr-config/searchcore/conf -z localhost:2181
curl -s "localhost:8983/solr/admin/collections?action=RELOAD&name=searchcore"
```

Rebuild the autocomplete dictionary after a bulk index:

```bash
curl -s "localhost:8983/solr/searchcore/suggest?suggest.build=true"
```

## Scaling up to the full topology

If a reboot frees memory and you want the 3 ZooKeeper + 2 Solr layout from the report, wipe the
runtime dirs and redo setup with the defaults:

```bash
./stop-services.sh
rm -rf zookeeper solr-nodes            # keeps downloads/, so nothing re downloads
./setup-solr.sh && ./start-services.sh # defaults are 3 ZK + 2 Solr
./index-sample-data.sh
```

Budget 3 to 4 GB of free RAM for this.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Port 8983 is already being used` | Old Solr still running. `./stop-services.sh`, or `./solr-nodes/node1/bin/solr stop -all` |
| Solr never becomes ready | `start-services.sh` waits a fixed 10s, too short on a swapping box. Wait and re run it; it skips work already done |
| `numFound` is 0 | Collection exists but is empty. `./index-sample-data.sh` |
| Search page shows "An error occurred while searching" | Solr is down, or the page was opened as `file://` instead of through `localhost:9090` |
| Autocomplete shows nothing | Dictionary not built. `curl "localhost:8983/solr/searchcore/suggest?suggest.build=true"` |
| Uploading a PDF does nothing | pdf.js is loaded from a CDN, so the upload path needs internet access |
| Solr killed by the OOM killer | Close browsers. Failing that, re index with `SAMPLE_COUNT=3000` |
| ZooKeeper will not start | Stale `zookeeper/data/zk1/` lock. `./stop-services.sh` then retry |

## Ports

| Port | Service |
|---|---|
| 9090 | Web UI and Solr proxy (`webapp/server.py`) |
| 8983 | Solr |
| 2181 | ZooKeeper |

## One security note, in case it comes up

`webapp/server.py` proxies every `/solr/*` path, including `update`, `delete`, and `/solr/admin`.
It binds to `127.0.0.1` deliberately for that reason. It is a demo proxy for local use, not
something to expose. Putting this on a public host would need a read only allowlist limiting it to
`/select` and `/suggest`. Worth saying yourself if an interviewer asks about production readiness.
