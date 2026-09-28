#include <curl/curl.h>
// Variadic curl_easy_setopt / getinfo are not importable into Swift — typed wrappers.
static inline CURLcode ramp_curl_setopt_long(CURL *h, CURLoption o, long v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode ramp_curl_setopt_ptr(CURL *h, CURLoption o, const void *v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode ramp_curl_setopt_off(CURL *h, CURLoption o, curl_off_t v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode ramp_curl_getinfo_long(CURL *h, CURLINFO i, long *v) { return curl_easy_getinfo(h, i, v); }
static inline CURLcode ramp_curl_getinfo_off(CURL *h, CURLINFO i, curl_off_t *v) { return curl_easy_getinfo(h, i, v); }
// Phase 9 (09-02): callbacks, string getinfo, handle-level string options.
static inline CURLcode ramp_curl_setopt_write(CURL *h, CURLoption o, curl_write_callback cb) { return curl_easy_setopt(h, o, cb); }
static inline CURLcode ramp_curl_setopt_read(CURL *h, CURLoption o, curl_read_callback cb) { return curl_easy_setopt(h, o, cb); }
static inline CURLcode ramp_curl_setopt_xferinfo(CURL *h, CURLoption o, curl_xferinfo_callback cb) { return curl_easy_setopt(h, o, cb); }
static inline CURLcode ramp_curl_setopt_str(CURL *h, CURLoption o, const char *v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode ramp_curl_setopt_slist(CURL *h, CURLoption o, struct curl_slist *v) { return curl_easy_setopt(h, o, v); }
static inline CURLcode ramp_curl_getinfo_str(CURL *h, CURLINFO i, char **v) { return curl_easy_getinfo(h, i, v); }
