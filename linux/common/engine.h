// The engine as the Linux frontends use it: one jd_context, plus the user
// dictionary it reads, which must outlive it (core/include/jd.h).
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "jd.h"

namespace imejd {

class UserDictBlob;

struct Candidate {
    std::string value;
    /// The keys still needed below this candidate; empty when none.
    std::string hint;
};

/// What a key left: the text it committed, if any, and how many candidates
/// the composition has now.
struct KeyResult {
    bool committed = false;
    std::string commit;
    unsigned optionsCount = 0;
};

class Engine {
public:
    /// An engine over the built-in dictionary, plus `dict` when there is one.
    explicit Engine(std::shared_ptr<const UserDictBlob> dict = nullptr);
    ~Engine();

    Engine(const Engine &) = delete;
    Engine &operator=(const Engine &) = delete;

    KeyResult pressKey(char byte);
    void backspace();
    void reset();
    void setAnchor(unsigned index);
    unsigned optionsCount() const;
    /// Candidates [start, start + count), clipped to what there is.
    std::vector<Candidate> readRange(unsigned start, unsigned count);

    /// Whether jd.h's declarations match the library linked in; a mismatch
    /// would corrupt memory, so a frontend checks once and refuses to run.
    static bool abiMatches();

private:
    std::shared_ptr<const UserDictBlob> dict_;
    jd_context *ctx_ = nullptr;
    const jd_state *state_ = nullptr;
};

} // namespace imejd
