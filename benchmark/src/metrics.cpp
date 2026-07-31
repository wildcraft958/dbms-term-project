#include "metrics.hpp"
#include <algorithm>
#include <cmath>
#include <iomanip>
#include <numeric>
#include <sstream>

namespace solrbench {

MetricsCollector::MetricsCollector(int concurrent_users, int duration_seconds)
    : concurrent_users_(concurrent_users), duration_seconds_(duration_seconds) {
    results_.reserve(100000); // Pre-allocate for high throughput
}

void MetricsCollector::record(const RequestResult& result) {
    std::lock_guard<std::mutex> lock(mutex_);
    results_.push_back(result);
}

void MetricsCollector::set_elapsed_time(double elapsed_s) {
    elapsed_time_s_ = elapsed_s;
}

BenchmarkMetrics MetricsCollector::compute() const {
    std::lock_guard<std::mutex> lock(mutex_);

    BenchmarkMetrics m{};
    m.concurrent_users = concurrent_users_;
    m.duration_seconds = duration_seconds_;
    m.total_transactions = static_cast<int>(results_.size());
    m.elapsed_time_s = elapsed_time_s_;

    if (results_.empty()) {
        return m;
    }

    // Count successes and failures
    m.successful_transactions = 0;
    m.failed_transactions = 0;
    double total_latency = 0.0;
    size_t total_bytes = 0;

    std::vector<double> latencies;
    latencies.reserve(results_.size());

    for (const auto& r : results_) {
        if (r.success) {
            m.successful_transactions++;
        } else {
            m.failed_transactions++;
        }
        total_latency += r.latency_ms;
        total_bytes += r.response_bytes;
        latencies.push_back(r.latency_ms);
    }

    // Availability
    m.availability = (m.total_transactions > 0)
        ? (static_cast<double>(m.successful_transactions) / m.total_transactions * 100.0)
        : 0.0;

    // Transaction rate (QPS)
    m.transaction_rate = (m.elapsed_time_s > 0)
        ? (static_cast<double>(m.total_transactions) / m.elapsed_time_s)
        : 0.0;

    // Average response time
    m.avg_response_time_ms = total_latency / m.total_transactions;

    // Throughput in MB/s
    m.throughput_mbps = (m.elapsed_time_s > 0)
        ? (static_cast<double>(total_bytes) / (1024.0 * 1024.0) / m.elapsed_time_s)
        : 0.0;

    // Measured concurrency (Little's Law: concurrency = throughput * avg_latency)
    m.concurrency = m.transaction_rate * (m.avg_response_time_ms / 1000.0);

    // Sort latencies for percentile computation
    std::sort(latencies.begin(), latencies.end());

    m.min_latency_ms = latencies.front();
    m.max_latency_ms = latencies.back();
    m.p50_latency_ms = compute_percentile(latencies, 50.0);
    m.p95_latency_ms = compute_percentile(latencies, 95.0);
    m.p99_latency_ms = compute_percentile(latencies, 99.0);

    return m;
}

double MetricsCollector::compute_percentile(std::vector<double>& sorted_data, double p) {
    if (sorted_data.empty()) return 0.0;
    if (sorted_data.size() == 1) return sorted_data[0];

    double index = (p / 100.0) * (sorted_data.size() - 1);
    size_t lower = static_cast<size_t>(std::floor(index));
    size_t upper = static_cast<size_t>(std::ceil(index));

    if (lower == upper) return sorted_data[lower];

    double fraction = index - lower;
    return sorted_data[lower] * (1.0 - fraction) + sorted_data[upper] * fraction;
}

std::string MetricsCollector::to_json(const BenchmarkMetrics& m) {
    std::ostringstream ss;
    ss << std::fixed << std::setprecision(2);
    ss << "    {\n";
    ss << "      \"concurrent_users\": " << m.concurrent_users << ",\n";
    ss << "      \"duration_seconds\": " << m.duration_seconds << ",\n";
    ss << "      \"transactions\": " << m.total_transactions << ",\n";
    ss << "      \"availability\": " << m.availability << ",\n";
    ss << "      \"elapsed_time\": " << m.elapsed_time_s << ",\n";
    ss << "      \"response_time\": " << (m.avg_response_time_ms / 1000.0) << ",\n"; // Convert to seconds for siege compat
    ss << "      \"transaction_rate\": " << m.transaction_rate << ",\n";
    ss << "      \"throughput\": " << m.throughput_mbps << ",\n";
    ss << "      \"concurrency\": " << m.concurrency << ",\n";
    ss << "      \"successful_transactions\": " << m.successful_transactions << ",\n";
    ss << "      \"failed_transactions\": " << m.failed_transactions << ",\n";
    ss << "      \"p50_latency_ms\": " << m.p50_latency_ms << ",\n";
    ss << "      \"p95_latency_ms\": " << m.p95_latency_ms << ",\n";
    ss << "      \"p99_latency_ms\": " << m.p99_latency_ms << ",\n";
    ss << "      \"min_latency_ms\": " << m.min_latency_ms << ",\n";
    ss << "      \"max_latency_ms\": " << m.max_latency_ms << "\n";
    ss << "    }";
    return ss.str();
}

std::string MetricsCollector::to_json_report(
    const std::vector<BenchmarkMetrics>& results,
    const std::string& solr_url,
    const std::string& timestamp)
{
    std::ostringstream ss;
    ss << "{\n";
    ss << "  \"benchmark_timestamp\": \"" << timestamp << "\",\n";
    ss << "  \"solr_url\": \"" << solr_url << "\",\n";
    ss << "  \"benchmark_tool\": \"cpp_multithreaded_client\",\n";
    ss << "  \"results\": [\n";

    for (size_t i = 0; i < results.size(); ++i) {
        ss << to_json(results[i]);
        if (i < results.size() - 1) {
            ss << ",";
        }
        ss << "\n";
    }

    ss << "  ]\n";
    ss << "}\n";
    return ss.str();
}

} // namespace solrbench
