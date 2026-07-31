#include "benchmark_runner.hpp"

#include <algorithm>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

/**
 * Solr C++ Multithreaded Benchmark Client
 *
 * Features:
 *   - Configurable concurrency levels (tests multiple levels sequentially)
 *   - Connection pooling with CURL handle reuse
 *   - Latency percentile computation (p50, p95, p99)
 *   - JSON output compatible with siege format (works with visualize.py)
 *   - Round-robin query distribution across multiple search terms
 *
 * Usage:
 *   ./solr_benchmark --url http://localhost:8983/solr/searchcore \
 *                    --concurrency 2,5,10,25,50 \
 *                    --duration 10 \
 *                    --output results.json
 */

void print_usage(const char* prog) {
    std::cout << "Usage: " << prog << " [OPTIONS]\n\n"
              << "Options:\n"
              << "  --url URL           Solr core URL (default: http://localhost:8983/solr/searchcore)\n"
              << "  --concurrency LIST  Comma-separated concurrency levels (default: 2,5,10,25,50,100)\n"
              << "  --duration SECS     Duration per concurrency level in seconds (default: 10)\n"
              << "  --pool-size N       Connection pool size (default: auto = max concurrency)\n"
              << "  --queries FILE      File with query terms, one per line\n"
              << "  --output FILE       JSON output file path (default: ./benchmark_results.json)\n"
              << "  --pause SECS        Pause between concurrency levels (default: 2)\n"
              << "  --help              Show this help message\n\n"
              << "Examples:\n"
              << "  " << prog << " --url http://localhost:8983/solr/searchcore --concurrency 2,5,10,25 --duration 10\n"
              << "  " << prog << " --queries queries.txt --output results.json\n"
              << std::endl;
}

std::vector<int> parse_concurrency_list(const std::string& input) {
    std::vector<int> levels;
    std::istringstream stream(input);
    std::string token;
    while (std::getline(stream, token, ',')) {
        try {
            int val = std::stoi(token);
            if (val > 0) {
                levels.push_back(val);
            }
        } catch (...) {
            std::cerr << "Warning: Ignoring invalid concurrency value: " << token << std::endl;
        }
    }
    return levels;
}

std::vector<std::string> load_queries_from_file(const std::string& filepath) {
    std::vector<std::string> queries;
    std::ifstream file(filepath);
    if (!file.is_open()) {
        std::cerr << "Warning: Could not open queries file: " << filepath << std::endl;
        return queries;
    }

    std::string line;
    while (std::getline(file, line)) {
        // Trim whitespace
        size_t start = line.find_first_not_of(" \t\r\n");
        size_t end = line.find_last_not_of(" \t\r\n");
        if (start != std::string::npos) {
            std::string query = line.substr(start, end - start + 1);
            // Skip comments and empty lines
            if (!query.empty() && query[0] != '#') {
                queries.push_back(query);
            }
        }
    }

    return queries;
}

int main(int argc, char* argv[]) {
    solrbench::BenchmarkConfig config;
    config.solr_url = "http://localhost:8983/solr/searchcore";
    config.concurrency_levels = {2, 5, 10, 25, 50, 100};
    config.duration_seconds = 10;
    config.connection_pool_size = 0; // Auto (= max concurrency)
    config.output_file = "./benchmark_results.json";
    config.pause_between_levels_seconds = 2;

    std::string queries_file;

    // Parse command-line arguments
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];

        if (arg == "--help" || arg == "-h") {
            print_usage(argv[0]);
            return 0;
        } else if (arg == "--url" && i + 1 < argc) {
            config.solr_url = argv[++i];
        } else if (arg == "--concurrency" && i + 1 < argc) {
            config.concurrency_levels = parse_concurrency_list(argv[++i]);
        } else if (arg == "--duration" && i + 1 < argc) {
            config.duration_seconds = std::stoi(argv[++i]);
        } else if (arg == "--pool-size" && i + 1 < argc) {
            config.connection_pool_size = std::stoi(argv[++i]);
        } else if (arg == "--queries" && i + 1 < argc) {
            queries_file = argv[++i];
        } else if (arg == "--output" && i + 1 < argc) {
            config.output_file = argv[++i];
        } else if (arg == "--pause" && i + 1 < argc) {
            config.pause_between_levels_seconds = std::stoi(argv[++i]);
        } else {
            std::cerr << "Unknown argument: " << arg << std::endl;
            print_usage(argv[0]);
            return 1;
        }
    }

    // Load queries from file if specified
    if (!queries_file.empty()) {
        config.queries = load_queries_from_file(queries_file);
        if (config.queries.empty()) {
            std::cerr << "No valid queries loaded from file. Using defaults." << std::endl;
        }
    }

    // Validate configuration before using the concurrency levels.
    if (config.concurrency_levels.empty()) {
        std::cerr << "Error: No concurrency levels specified." << std::endl;
        return 1;
    }
    if (config.duration_seconds <= 0) {
        std::cerr << "Error: Duration must be positive." << std::endl;
        return 1;
    }

    // Auto-size connection pool if not specified (now safe: list is non-empty).
    if (config.connection_pool_size == 0) {
        config.connection_pool_size = *std::max_element(
            config.concurrency_levels.begin(), config.concurrency_levels.end());
    }

    // Run the benchmark
    try {
        solrbench::BenchmarkRunner runner(config);
        auto results = runner.run();
        runner.save_results(results);
    } catch (const std::exception& e) {
        std::cerr << "Fatal error: " << e.what() << std::endl;
        return 1;
    }

    std::cout << "\nDone! Visualize results with:\n"
              << "  python3 visualize.py " << config.output_file << std::endl;

    return 0;
}
