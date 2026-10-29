#include <cstdio>

#include "check.h"

namespace check {

namespace {
int failures = 0;
const char *current = "";
} // namespace

std::vector<Test> &tests() {
    static std::vector<Test> all;
    return all;
}

void failure(const char *file, int line, const std::string &what) {
    ++failures;
    std::fprintf(stderr, "%s:%d: %s: %s\n", file, line, current, what.c_str());
}

} // namespace check

int main() {
    for (const auto &test : check::tests()) {
        check::current = test.name;
        test.run();
    }
    std::printf("%zu tests, %d failures\n", check::tests().size(), check::failures);
    return check::failures == 0 ? 0 : 1;
}
