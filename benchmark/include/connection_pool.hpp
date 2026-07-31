#pragma once

#include <condition_variable>
#include <curl/curl.h>
#include <mutex>
#include <queue>
#include <string>

namespace solrbench {

/**
 *
 * Pre-initializes a fixed number of CURL easy handles and manages
 * thread-safe checkout/return. This avoids the overhead of creating
 * and destroying CURL handles per request.
 *
 * Usage:
 *   ConnectionPool pool(16, "http://localhost:8983");
 *   CURL* handle = pool.acquire();
 *   // ... use handle ...
 *   pool.release(handle);
 */
class ConnectionPool {
public:
    /**
     * Create a connection pool with the specified number of CURL handles.
     * @param pool_size Number of pre-initialized CURL handles.
     * @param base_url  Base URL for all connections (used for DNS caching).
     */
    ConnectionPool(size_t pool_size, const std::string& base_url);

    ~ConnectionPool();

    ConnectionPool(const ConnectionPool&) = delete;
    ConnectionPool& operator=(const ConnectionPool&) = delete;
    ConnectionPool(ConnectionPool&&) = delete;
    ConnectionPool& operator=(ConnectionPool&&) = delete;

    /**
     * Acquire a CURL handle from the pool. Blocks if none available.
     * @return A pre-configured CURL handle ready for use.
     */
    CURL* acquire();

    /**
     * Release a CURL handle back to the pool.
     * Resets the handle for reuse.
     * @param handle The CURL handle to return.
     */
    void release(CURL* handle);

    size_t size() const { return pool_size_; }

private:
    CURL* create_handle();
    size_t pool_size_;
    std::string base_url_;
    std::queue<CURL*> available_;
    std::mutex mutex_;
    std::condition_variable condition_;
};

} // namespace solrbench
