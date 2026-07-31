# C++ Multithreaded HTTP Benchmark Client for Apache Solr

A high-performance HTTP load testing tool specifically designed for benchmarking Apache Solr query endpoints. Uses `std::thread` for concurrency and `libcurl` connection pooling for efficient HTTP requests.

## Features

- **Concurrent workers**: Each concurrency level spawns that many `std::thread` workers that loop requests for the configured duration
- **ConnectionPool**: Pre-initialized CURL handles with TCP keep-alive, DNS caching, and thread-safe checkout/return
- **Latency Percentiles**: Computes p50, p95, p99 latency (not available from Siege)
- **Siege-Compatible Output**: JSON format works directly with the existing `visualize.py` script
- **Configurable**: All parameters (URL, concurrency levels, duration, query terms) are CLI-configurable

## Architecture

```
┌──────────────────┐
│    main.cpp       │  CLI argument parsing, config
│    (entry point)  │
└────────┬─────────┘
         │
┌────────▼─────────┐
│  BenchmarkRunner  │  Orchestrates benchmark across concurrency levels
└────────┬─────────┘
         │
    ┌────┴────┐
    │         │
┌───▼───┐  ┌─▼────────────┐
│Worker  │  │ Connection   │
│threads │  │ Pool         │
│(N thds)│  │(CURL handles)│
└───┬───┘  └──────┬───────┘
    │              │
    └──────┬───────┘
           │
┌──────────▼──────────┐
│  MetricsCollector    │  Thread-safe aggregation, percentile calc
└─────────────────────┘
```

## Prerequisites

- **C++17** compiler (g++ 8+ or clang 7+)
- **CMake** 3.14+
- **libcurl** development headers (`libcurl4-openssl-dev` on Ubuntu/Debian)

### Install dependencies (Ubuntu/Debian):
```bash
sudo apt-get install build-essential cmake libcurl4-openssl-dev
```

## Build

```bash
cd benchmark
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

## Usage

```bash
# Basic usage (defaults: localhost:8983, concurrency 2-100, 10s each)
./solr_benchmark

# Custom Solr URL and concurrency levels
./solr_benchmark --url http://localhost:8983/solr/searchcore \
                 --concurrency 2,5,10,25,50 \
                 --duration 10

# With custom query file
./solr_benchmark --queries ../solr-apache/scripts/benchmark/siege-config/urls_terms.txt \
                 --output ./results/my_benchmark.json

# Full options
./solr_benchmark --url http://localhost:8983/solr/searchcore \
                 --concurrency 2,3,5,7,11,13,17,19,23,29 \
                 --duration 3 \
                 --pool-size 50 \
                 --pause 2 \
                 --output ./results/benchmark_results.json
```

### All Options

| Flag | Default | Description |
|------|---------|-------------|
| `--url` | `http://localhost:8983/solr/searchcore` | Solr core URL |
| `--concurrency` | `2,5,10,25,50,100` | Comma-separated concurrency levels |
| `--duration` | `10` | Seconds per concurrency level |
| `--pool-size` | auto | CURL connection pool size |
| `--queries` | built-in | File with query terms (one per line) |
| `--output` | `./benchmark_results.json` | JSON output path |
| `--pause` | `2` | Seconds between concurrency levels |

## Output Format

The JSON output is compatible with the existing `visualize.py` script, with additional latency percentile fields:

```json
{
  "benchmark_timestamp": "2025-05-03T10:30:00Z",
  "solr_url": "http://localhost:8983/solr/searchcore",
  "benchmark_tool": "cpp_multithreaded_client",
  "results": [
    {
      "concurrent_users": 10,
      "duration_seconds": 10,
      "transactions": 45000,
      "availability": 100.00,
      "elapsed_time": 10.01,
      "response_time": 0.002,
      "transaction_rate": 4495.50,
      "throughput": 12.34,
      "concurrency": 9.87,
      "successful_transactions": 45000,
      "failed_transactions": 0,
      "p50_latency_ms": 1.23,
      "p95_latency_ms": 3.45,
      "p99_latency_ms": 8.76,
      "min_latency_ms": 0.45,
      "max_latency_ms": 25.67
    }
  ]
}
```

## Visualize Results

```bash
cd ../solr-apache/scripts
python3 visualize.py ../../benchmark/build/benchmark_results.json
```
