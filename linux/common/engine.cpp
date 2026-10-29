#include "engine.h"

#include <cstring>

#include "user_dict.h"

namespace imejd {

Engine::Engine(std::shared_ptr<const UserDictBlob> dict) : dict_(std::move(dict)) {
    if (dict_) {
        ctx_ = jd_init(dict_->data(), dict_->size());
    }
    if (!ctx_) {
        // A blob this library has just built always validates. Should it
        // not, the built-in dictionary alone is still an engine.
        dict_.reset();
        ctx_ = jd_init(nullptr, 0);
    }
    if (ctx_) {
        state_ = jd_state_ptr(ctx_);
    }
}

Engine::~Engine() {
    if (ctx_) {
        jd_deinit(ctx_);
    }
}

KeyResult Engine::pressKey(char byte) {
    KeyResult result;
    if (!ctx_) {
        return result;
    }
    jd_press_key(ctx_, byte);
    // A commit arrives as up to three pieces: commit_a ++ commit_b ++
    // commit_lit, any of them absent.
    if (state_->commit_a) {
        result.commit += state_->commit_a;
    }
    if (state_->commit_b) {
        result.commit += state_->commit_b;
    }
    if (state_->commit_lit) {
        result.commit += state_->commit_lit;
    }
    result.committed = state_->commit_a || state_->commit_b || state_->commit_lit;
    result.optionsCount = state_->options_count;
    return result;
}

void Engine::backspace() {
    if (ctx_) {
        jd_backspace(ctx_);
    }
}

void Engine::reset() {
    if (ctx_) {
        jd_reset(ctx_);
    }
}

void Engine::setAnchor(unsigned index) {
    if (ctx_) {
        jd_set_anchor(ctx_, index);
    }
}

unsigned Engine::optionsCount() const {
    return state_ ? state_->options_count : 0;
}

std::vector<Candidate> Engine::readRange(unsigned start, unsigned count) {
    std::vector<Candidate> candidates;
    if (!ctx_ || count == 0) {
        return candidates;
    }
    std::vector<query_option> options(count);
    const unsigned read = jd_read_range(ctx_, start, count, options.data(), count);
    candidates.reserve(read);
    for (unsigned i = 0; i < read; ++i) {
        // Copied: a page outlives a dictionary swap, the blob may not.
        candidates.push_back({options[i].value,
                              std::string(options[i].hint, strnlen(options[i].hint, JD_HINT_CAP))});
    }
    return candidates;
}

bool Engine::abiMatches() {
    return jd_abi_layout(JD_ABI_SIZEOF_STATE) == sizeof(jd_state) &&
           jd_abi_layout(JD_ABI_SIZEOF_OPTION) == sizeof(query_option) &&
           jd_abi_layout(JD_ABI_HINT_CAP) == JD_HINT_CAP &&
           jd_abi_layout(JD_ABI_SIZEOF_USER_DICT_REPORT) == sizeof(jd_user_dict_report) &&
           jd_abi_layout(JD_ABI_USER_DICT_MAX_ENTRIES) == JD_USER_DICT_MAX_ENTRIES &&
           jd_abi_layout(JD_ABI_USER_DICT_VALUE_MAX) == JD_USER_DICT_VALUE_MAX &&
           jd_abi_layout(JD_ABI_SIZEOF_USER_DICT_INFO) == sizeof(jd_user_dict_info) &&
           jd_abi_layout(JD_ABI_SIZEOF_USER_DICT_NOTE) == sizeof(jd_user_dict_note);
}

} // namespace imejd
