#include "benchmark_runner.hpp"

#include <atomic>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <thread>
#include <vector>

namespace solrbench {

// CURL write callback - captures response body
static size_t write_callback(char* /*ptr*/, size_t size, size_t nmemb, void* userdata) {
    size_t total = size * nmemb;
    auto* response_size = static_cast<size_t*>(userdata);
    *response_size += total;
    return total;
}

BenchmarkRunner::BenchmarkRunner(const BenchmarkConfig& config)
    : config_(config) {
    if (config_.queries.empty()) {
        // Default queries if none provided
        config_.queries = {"sample", "document", "test", "example", "author",
                           "category", "content", "search", "data", "system"};
    }
}

std::vector<BenchmarkMetrics> BenchmarkRunner::run() {
    std::cout << "========================================" << std::endl;
    std::cout << "  Solr C++ Multithreaded Benchmark" << std::endl;
    std::cout << "========================================" << std::endl;
    std::cout << "Target URL:       " << config_.solr_url << std::endl;
    std::cout << "Duration/level:   " << config_.duration_seconds << "s" << std::endl;
    std::cout << "Connection pool:  " << config_.connection_pool_size << " handles" << std::endl;
    std::cout << "Concurrency set:  [";
    for (size_t i = 0; i < config_.concurrency_levels.size(); ++i) {
        if (i > 0) std::cout << ", ";
        std::cout << config_.concurrency_levels[i];
    }
    std::cout << "]" << std::endl;
    std::cout << "Query terms:      " << config_.queries.size() << std::endl;
    std::cout << "========================================" << std::endl;

    std::vector<BenchmarkMetrics> all_results;

    for (size_t li = 0; li < config_.concurrency_levels.size(); ++li) {
        int level = config_.concurrency_levels[li];
        std::cout << "\n>> Running benchmark: " << level << " concurrent threads..." << std::endl;

        BenchmarkMetrics metrics = run_single(level);
        all_results.push_back(metrics);

        // Print summary for this level
        std::cout << "   Transactions:     " << metrics.total_transactions << std::endl;
        std::cout << "   Transaction Rate: " << std::fixed << std::setprecision(2)
                  << metrics.transaction_rate << " QPS" << std::endl;
        std::cout << "   Avg Latency:      " << metrics.avg_response_time_ms << " ms" << std::endl;
        std::cout << "   p50 Latency:      " << metrics.p50_latency_ms << " ms" << std::endl;
        std::cout << "   p95 Latency:      " << metrics.p95_latency_ms << " ms" << std::endl;
        std::cout << "   p99 Latency:      " << metrics.p99_latency_ms << " ms" << std::endl;
        std::cout << "   Availability:     " << metrics.availability << "%" << std::endl;
        std::cout << "   Concurrency:      " << metrics.concurrency << std::endl;

        // Pause between levels
        if (li + 1 < config_.concurrency_levels.size()) {
            std::cout << "\n   Pausing " << config_.pause_between_levels_seconds << "s before next level..." << std::endl;
            std::this_thread::sleep_for(std::chrono::seconds(config_.pause_between_levels_seconds));
        }
    }

    std::cout << "\n========================================" << std::endl;
    std::cout << "  Benchmark Complete!" << std::endl;
    std::cout << "========================================" << std::endl;

    return all_results;
}

BenchmarkMetrics BenchmarkRunner::run_single(int concurrency_level) {
    // Create a connection pool large enough for all threads
    int pool_size = std::max(concurrency_level, config_.connection_pool_size);
    ConnectionPool conn_pool(pool_size, config_.solr_url);

    MetricsCollector collector(concurrency_level, config_.duration_seconds);

    // Atomic flag to signal threads to stop
    std::atomic<bool> running{true};

    // Query index counter for round-robin distribution
    std::atomic<size_t> query_counter{0};

    // Start workers using std::thread directly (not the thread pool)
    // This gives us exact control over the number of concurrent threads
    std::vector<std::thread> workers;
    workers.reserve(concurrency_level);

    auto start_time = std::chrono::high_resolution_clock::now();

    for (int t = 0; t < concurrency_level; ++t) {
        workers.emplace_back([&, t]() {
            while (running.load(std::memory_order_relaxed)) {
                // Pick a query in round-robin fashion
                size_t idx = query_counter.fetch_add(1, std::memory_order_relaxed)
                             % config_.queries.size();
                std::string url = build_query_url(config_.queries[idx]);

                // Acquire a connection from the pool
                CURL* handle = conn_pool.acquire();

                // Execute the query
                RequestResult result = execute_query(handle, url);

                // Release connection back to pool
                conn_pool.release(handle);

                // Record the result
                collector.record(result);
            }
        });
    }

    // Wait for the specified duration
    std::this_thread::sleep_for(std::chrono::seconds(config_.duration_seconds));

    // Signal all threads to stop
    running.store(false, std::memory_order_relaxed);

    // Join all threads
    for (auto& w : workers) {
        if (w.joinable()) {
            w.join();
        }
    }

    auto end_time = std::chrono::high_resolution_clock::now();
    double elapsed = std::chrono::duration<double>(end_time - start_time).count();

    collector.set_elapsed_time(elapsed);
    return collector.compute();
}

RequestResult BenchmarkRunner::execute_query(CURL* handle, const std::string& url) {
    RequestResult result{};
    size_t response_size = 0;

    // Set URL
    curl_easy_setopt(handle, CURLOPT_URL, url.c_str());

    // Set write callback (discard body, just count bytes)
    curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response_size);

    // Suppress signals for thread safety
    curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L);

    // Measure latency
    auto start = std::chrono::high_resolution_clock::now();
    CURLcode res = curl_easy_perform(handle);
    auto end = std::chrono::high_resolution_clock::now();

    result.latency_ms = std::chrono::duration<double, std::milli>(end - start).count();
    result.response_bytes = response_size;

    if (res == CURLE_OK) {
        long http_code = 0;
        curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &http_code);
        result.http_status = static_cast<int>(http_code);
        result.success = (http_code >= 200 && http_code < 300);
    } else {
        result.http_status = 0;
        result.success = false;
    }

    return result;
}

std::string BenchmarkRunner::build_query_url(const std::string& query) const {
    // URL-encode the query (simple encoding for common chars)
    std::string encoded;
    for (char c : query) {
        if (c == ' ') {
            encoded += "%20";
        } else if (c == '&') {
            encoded += "%26";
        } else if (c == '=') {
            encoded += "%3D";
        } else {
            encoded += c;
        }
    }
    return config_.solr_url + "/select?q=" + encoded + "&wt=json&rows=10";
}

void BenchmarkRunner::save_results(const std::vector<BenchmarkMetrics>& results) const {
    // Generate timestamp
    auto now = std::chrono::system_clock::now();
    auto time_t = std::chrono::system_clock::to_time_t(now);
    std::tm tm = *std::gmtime(&time_t);
    std::ostringstream ts;
    ts << std::put_time(&tm, "%Y-%m-%dT%H:%M:%SZ");

    std::string json = MetricsCollector::to_json_report(results, config_.solr_url, ts.str());

    std::ofstream out(config_.output_file);
    if (!out.is_open()) {
        std::cerr << "ERROR: Could not open output file: " << config_.output_file << std::endl;
        return;
    }
    out << json;
    out.close();

    std::cout << "Results saved to: " << config_.output_file << std::endl;
}

} // namespace solrbench
