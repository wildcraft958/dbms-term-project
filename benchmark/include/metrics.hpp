#pragma once

#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <vector>

namespace solrbench {

/**
 * RequestResult - Stores the outcome of a single HTTP request.
 */
struct RequestResult {
    double latency_ms;       // Request latency in milliseconds
    int http_status;         // HTTP status code (200, 404, 500, etc.)
    bool success;            // true if HTTP 2xx
    size_t response_bytes;   // Response body size in bytes
};

/**
 * BenchmarkMetrics - Aggregated metrics for a single concurrency level.
 */
struct BenchmarkMetrics {
    int concurrent_users;
    int duration_seconds;
    int total_transactions;
    int successful_transactions;
    int failed_transactions;
    double elapsed_time_s;
    double availability;         // percentage (0-100)
    double transaction_rate;     // QPS (queries per second)
    double avg_response_time_ms;
    double throughput_mbps;      // MB/s
    double concurrency;          // measured concurrency

    // Latency percentiles (not available from siege — unique to C++ client)
    double p50_latency_ms;
    double p95_latency_ms;
    double p99_latency_ms;
    double min_latency_ms;
    double max_latency_ms;
};

/**
 * MetricsCollector - Thread-safe metrics aggregator.
 *
 * Collects individual request results from multiple threads and
 * computes aggregate statistics including latency percentiles.
 */
class MetricsCollector {
public:
    explicit MetricsCollector(int concurrent_users, int duration_seconds);

    /**
     * Record a single request result. Thread-safe.
     */
    void record(const RequestResult& result);

    /**
     * Set the total elapsed wall-clock time for the benchmark run.
     */
    void set_elapsed_time(double elapsed_s);

    /**
     * Compute and return the aggregated benchmark metrics.
     * Should be called after all requests are completed.
     */
    BenchmarkMetrics compute() const;

    /**
     * Export metrics as a JSON string compatible with siege output format.
     */
    static std::string to_json(const BenchmarkMetrics& m);

    /**
     * Export a full benchmark run (multiple concurrency levels) as JSON.
     * Compatible with the existing visualize.py script.
     */
    static std::string to_json_report(
        const std::vector<BenchmarkMetrics>& results,
        const std::string& solr_url,
        const std::string& timestamp);

private:
    static double compute_percentile(std::vector<double>& sorted_data, double p);

    int concurrent_users_;
    int duration_seconds_;
    double elapsed_time_s_{0.0};

    mutable std::mutex mutex_;
    std::vector<RequestResult> results_;
};

} // namespace solrbench
