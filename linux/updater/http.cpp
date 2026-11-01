#include "http.h"

#include <dlfcn.h>

namespace imejd::http {

namespace {

// libcurl's ABI, as curl/curl.h has it since 7.x: no header is needed to
// build, as no library is needed to link.

using Curl = void;
struct Slist;
using Code = int;

constexpr int kOptUrl = 10002;
constexpr int kOptWriteData = 10001;
constexpr int kOptWriteFunction = 20011;
constexpr int kOptUserAgent = 10018;
constexpr int kOptHttpHeader = 10023;
constexpr int kOptErrorBuffer = 10010;
constexpr int kOptFollowLocation = 52;
constexpr int kOptMaxRedirs = 68;
constexpr int kOptTimeout = 13;
constexpr int kOptConnectTimeout = 78;
constexpr int kOptLowSpeedLimit = 19;
constexpr int kOptLowSpeedTime = 20;
constexpr int kOptNoSignal = 99;
// The long forms, deprecated in 7.85 for string ones Ubuntu 22.04's 7.81
// lacks; libcurl keeps taking them.
constexpr int kOptProtocols = 181;
constexpr int kOptRedirProtocols = 182;
constexpr int kInfoResponseCode = 0x200002;
constexpr long kProtoHttp = 1 << 0;
constexpr long kProtoHttps = 1 << 1;
constexpr long kGlobalDefault = 3;
constexpr size_t kErrorSize = 256;

/// The functions used, from whichever libcurl loads.
struct Library {
    Code (*globalInit)(long);
    Curl *(*easyInit)();
    Code (*easySetopt)(Curl *, int, ...);
    Code (*easyPerform)(Curl *);
    Code (*easyGetinfo)(Curl *, int, ...);
    void (*easyCleanup)(Curl *);
    const char *(*easyStrerror)(Code);
    Slist *(*slistAppend)(Slist *, const char *);
    void (*slistFreeAll)(Slist *);
};

template <typename Function> bool bind(void *handle, const char *name, Function &function) {
    function = reinterpret_cast<Function>(dlsym(handle, name));
    return function != nullptr;
}

/// libcurl, loaded on first use; nothing when no build of it is installed.
const Library *library() {
    static const Library *loaded = []() -> const Library * {
        void *handle = nullptr;
        for (const char *name : {"libcurl.so.4", "libcurl-gnutls.so.4"}) {
            if ((handle = dlopen(name, RTLD_NOW | RTLD_LOCAL))) {
                break;
            }
        }
        static Library curl;
        if (!handle || !bind(handle, "curl_global_init", curl.globalInit) ||
            !bind(handle, "curl_easy_init", curl.easyInit) || !bind(handle, "curl_easy_setopt", curl.easySetopt) ||
            !bind(handle, "curl_easy_perform", curl.easyPerform) ||
            !bind(handle, "curl_easy_getinfo", curl.easyGetinfo) ||
            !bind(handle, "curl_easy_cleanup", curl.easyCleanup) ||
            !bind(handle, "curl_easy_strerror", curl.easyStrerror) ||
            !bind(handle, "curl_slist_append", curl.slistAppend) ||
            !bind(handle, "curl_slist_free_all", curl.slistFreeAll) || curl.globalInit(kGlobalDefault) != 0) {
            return nullptr;
        }
        return &curl;
    }();
    return loaded;
}

size_t onData(char *data, size_t size, size_t count, void *context) {
    const auto &sink = *static_cast<const std::function<bool(std::string_view)> *>(context);
    // Anything short of the whole piece aborts the transfer.
    return sink(std::string_view(data, size * count)) ? size * count : 0;
}

} // namespace

Response get(const Request &request, const std::function<bool(std::string_view)> &sink) {
    Response response;
    const Library *curl = library();
    if (!curl) {
        response.error = "找不到 libcurl（libcurl.so.4）";
        return response;
    }
    Curl *easy = curl->easyInit();
    if (!easy) {
        response.error = "无法初始化 libcurl";
        return response;
    }
    Slist *headers = nullptr;
    for (const auto &header : request.headers) {
        headers = curl->slistAppend(headers, header.c_str());
    }
    char error[kErrorSize] = {};
    const long protocols = request.allowHttp ? kProtoHttp | kProtoHttps : kProtoHttps;

    // A long where libcurl reads a long: the options are variadic.
    curl->easySetopt(easy, kOptUrl, request.url.c_str());
    curl->easySetopt(easy, kOptUserAgent, request.userAgent.c_str());
    curl->easySetopt(easy, kOptHttpHeader, headers);
    curl->easySetopt(easy, kOptErrorBuffer, error);
    curl->easySetopt(easy, kOptWriteFunction, onData);
    curl->easySetopt(easy, kOptWriteData, &sink);
    curl->easySetopt(easy, kOptProtocols, protocols);
    curl->easySetopt(easy, kOptRedirProtocols, protocols);
    curl->easySetopt(easy, kOptFollowLocation, 1L);
    curl->easySetopt(easy, kOptMaxRedirs, 5L);
    curl->easySetopt(easy, kOptNoSignal, 1L);
    curl->easySetopt(easy, kOptConnectTimeout, 30L);
    if (request.download) {
        // Under 1 KB/s for a minute.
        curl->easySetopt(easy, kOptLowSpeedLimit, 1024L);
        curl->easySetopt(easy, kOptLowSpeedTime, 60L);
    } else {
        curl->easySetopt(easy, kOptTimeout, 60L);
    }

    const Code code = curl->easyPerform(easy);
    curl->easyGetinfo(easy, kInfoResponseCode, &response.status);
    if (code != 0) {
        response.error = error[0] ? error : curl->easyStrerror(code);
    }
    curl->easyCleanup(easy);
    curl->slistFreeAll(headers);
    return response;
}

} // namespace imejd::http
