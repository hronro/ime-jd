// HTTPS through the system's libcurl, loaded when first needed rather than
// linked: every distro has libcurl.so.4 — Debian and Ubuntu often only its
// GnuTLS build, libcurl-gnutls.so.4 — but each versions its symbols its own
// way, so a program linked to one distro's would not start on another's.
// libcurl brings the distro's TLS and certificates, and takes proxies from
// the environment, as curl does.
#pragma once

#include <functional>
#include <string>
#include <string_view>
#include <vector>

namespace imejd::http {

struct Request {
    std::string url;
    std::string userAgent;
    std::vector<std::string> headers;
    /// A download: no limit on the whole transfer's time, only on its
    /// stalling.
    bool download = false;
    /// Plain http too, for a test's server on this machine; https alone
    /// otherwise, redirects included.
    bool allowHttp = false;
};

struct Response {
    /// The HTTP status; 0 when none came.
    long status = 0;
    /// Why the transfer failed, in curl's words; empty when it did not.
    std::string error;
};

/// GETs the request's URL, following redirects, and passes the body to
/// `sink` piece by piece; `sink` returning false aborts the transfer.
Response get(const Request &request, const std::function<bool(std::string_view)> &sink);

} // namespace imejd::http
