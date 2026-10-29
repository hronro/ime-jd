// A small test harness, so the tests build wherever the frontends do:
//
//   TEST(name) { CHECK(condition); CHECK_EQ(actual, expected); }
#pragma once

#include <sstream>
#include <string>
#include <vector>

namespace check {

struct Test {
    const char *name;
    void (*run)();
};

std::vector<Test> &tests();
void failure(const char *file, int line, const std::string &what);

struct Registration {
    Registration(const char *name, void (*run)()) { tests().push_back({name, run}); }
};

template <typename T> std::string show(const T &value) {
    std::ostringstream out;
    out << value;
    return out.str();
}

} // namespace check

#define TEST(name)                                                                                     \
    static void name();                                                                                \
    static const ::check::Registration name##_registration(#name, name);                               \
    static void name()

#define CHECK(condition)                                                                               \
    do {                                                                                               \
        if (!(condition)) {                                                                            \
            ::check::failure(__FILE__, __LINE__, #condition);                                          \
        }                                                                                              \
    } while (false)

#define CHECK_EQ(actual, expected)                                                                     \
    do {                                                                                               \
        const auto &check_actual_ = (actual);                                                          \
        const auto &check_expected_ = (expected);                                                      \
        if (!(check_actual_ == check_expected_)) {                                                     \
            ::check::failure(__FILE__, __LINE__,                                                       \
                             std::string(#actual " == " #expected ": got ") +                          \
                                 ::check::show(check_actual_) + ", expected " +                        \
                                 ::check::show(check_expected_));                                      \
        }                                                                                              \
    } while (false)
