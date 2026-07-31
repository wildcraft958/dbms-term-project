#include "connection_pool.hpp"
#include <iostream>
#include <stdexcept>

namespace solrbench {

ConnectionPool::ConnectionPool(size_t pool_size, const std::string& base_url)
    : pool_size_(pool_size), base_url_(base_url) {
    // Initialize libcurl globally (once per process)
    static bool curl_initialized = false;
    if (!curl_initialized) {
        curl_global_init(CURL_GLOBAL_ALL);
        curl_initialized = true;
    }

    // Pre-create all CURL handles
    for (size_t i = 0; i < pool_size_; ++i) {
        CURL* handle = create_handle();
        if (!handle) {
            throw std::runtime_error("Failed to create CURL handle #" + std::to_string(i));
        }
        available_.push(handle);
    }

    std::cout << "[ConnectionPool] Initialized " << pool_size_ << " CURL handles for " << base_url_ << std::endl;
}

ConnectionPool::~ConnectionPool() {
    std::lock_guard<std::mutex> lock(mutex_);
    while (!available_.empty()) {
        CURL* handle = available_.front();
        available_.pop();
        curl_easy_cleanup(handle);
    }
}

CURL* ConnectionPool::acquire() {
    std::unique_lock<std::mutex> lock(mutex_);
    condition_.wait(lock, [this] { return !available_.empty(); });

    CURL* handle = available_.front();
    available_.pop();
    return handle;
}

void ConnectionPool::release(CURL* handle) {
    if (!handle) return;

    // Reset handle for reuse but keep connection alive
    curl_easy_reset(handle);

    // Re-apply base settings
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPALIVE, 1L);
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPIDLE, 120L);
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPINTVL, 60L);
    curl_easy_setopt(handle, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, 10L);

    {
        std::lock_guard<std::mutex> lock(mutex_);
        available_.push(handle);
    }
    condition_.notify_one();
}

CURL* ConnectionPool::create_handle() {
    CURL* handle = curl_easy_init();
    if (!handle) return nullptr;

    // Configure for high-performance HTTP requests
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPALIVE, 1L);
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPIDLE, 120L);
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPINTVL, 60L);
    curl_easy_setopt(handle, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, 10L);

    // Enable connection reuse
    curl_easy_setopt(handle, CURLOPT_FORBID_REUSE, 0L);

    // Enable HTTP/1.1 keep-alive
    curl_easy_setopt(handle, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);

    // DNS cache timeout (seconds)
    curl_easy_setopt(handle, CURLOPT_DNS_CACHE_TIMEOUT, 300L);

    return handle;
}

} // namespace solrbench
