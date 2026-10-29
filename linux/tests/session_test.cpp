// A session driven through a fake host: what reaches the application for
// each key, as the macOS InputController behaves.
#include <string>
#include <vector>

#include "check.h"
#include "engine.h"
#include "session.h"
#include "temp_dir.h"
#include "user_dict.h"

using imejd::Candidate;
using imejd::KeyInput;
using imejd::Session;

namespace {

/// The input context, as the application would see it.
struct FakeHost final : imejd::Host {
    std::string committed;
    std::string preedit;
    std::vector<Candidate> page;

    void commit(const std::string &text) override {
        committed += text;
        preedit.clear();
    }
    void setPreedit(const std::string &text) override { preedit = text; }
    void showCandidates(const std::vector<Candidate> &shown) override { page = shown; }
    void hideCandidates() override { page.clear(); }
};

KeyInput typed(char c) {
    KeyInput key;
    key.keysym = static_cast<unsigned char>(c);
    key.unicode = static_cast<unsigned char>(c);
    return key;
}

KeyInput named(uint32_t keysym) {
    KeyInput key;
    key.keysym = keysym;
    return key;
}

constexpr uint32_t kBackSpace = 0xff08;
constexpr uint32_t kReturn = 0xff0d;
constexpr uint32_t kEscape = 0xff1b;

bool type(Session &session, FakeHost &host, const std::string &keys) {
    bool consumed = true;
    for (const char c : keys) {
        consumed = session.handleKey(typed(c), host) && consumed;
    }
    return consumed;
}

/// A session over a store with no phrases file.
struct Fixture {
    TempDir dir;
    imejd::UserDictStore store{dir.path()};
    Session session{store};
    FakeHost host;
};

bool contains(const std::vector<Candidate> &page, const std::string &value) {
    for (const auto &candidate : page) {
        if (candidate.value == value) {
            return true;
        }
    }
    return false;
}

} // namespace

TEST(typingComposesAndShowsAPage) {
    Fixture f;
    CHECK(type(f.session, f.host, "n"));
    CHECK(f.session.isComposing());
    CHECK_EQ(f.host.preedit, "n");
    CHECK(!f.host.page.empty());
    CHECK(f.host.page.size() <= Session::pageSize);
    CHECK(f.host.committed.empty());
}

TEST(spaceCommitsTheFirstCandidate) {
    Fixture f;
    type(f.session, f.host, "n");
    const std::string first = f.host.page.at(0).value;
    CHECK(type(f.session, f.host, " "));
    CHECK_EQ(f.host.committed, first);
    CHECK(f.host.preedit.empty());
    CHECK(f.host.page.empty());
    CHECK(!f.session.isComposing());
}

TEST(aDigitSelectsFromThePage) {
    Fixture f;
    type(f.session, f.host, "j");
    const std::string second = f.host.page.at(1).value;
    CHECK(type(f.session, f.host, "2"));
    CHECK_EQ(f.host.committed, second);
    CHECK(f.host.page.empty());
}

TEST(aDigitWithNoCandidateGoesToTheEngine) {
    Fixture f;
    // `[` opens a window of fewer than nine brackets, the first 「.
    type(f.session, f.host, "[");
    CHECK(!f.host.page.empty());
    CHECK(f.host.page.size() < 9);
    CHECK_EQ(f.host.page.at(0).value, "「");
    CHECK(type(f.session, f.host, "9"));
    CHECK_EQ(f.host.committed, "「9");
}

TEST(pagingMovesTheWindowAndTheAnchor) {
    Fixture f;
    type(f.session, f.host, "j");
    imejd::Engine reference;
    reference.pressKey('j');
    const auto secondPage = reference.readRange(Session::pageSize, Session::pageSize);

    CHECK(type(f.session, f.host, "="));
    CHECK_EQ(f.host.page.size(), secondPage.size());
    CHECK_EQ(f.host.page.at(0).value, secondPage.at(0).value);

    // Space now commits what is first on screen.
    CHECK(type(f.session, f.host, " "));
    CHECK_EQ(f.host.committed, secondPage.at(0).value);
}

TEST(minusPagesBack) {
    Fixture f;
    type(f.session, f.host, "j");
    const std::string first = f.host.page.at(0).value;
    type(f.session, f.host, "=");
    CHECK(f.host.page.at(0).value != first);
    type(f.session, f.host, "-");
    CHECK_EQ(f.host.page.at(0).value, first);
}

TEST(backspaceShrinksThenEnds) {
    Fixture f;
    type(f.session, f.host, "jd");
    CHECK_EQ(f.host.preedit, "jd");
    CHECK(f.session.handleKey(named(kBackSpace), f.host));
    CHECK_EQ(f.host.preedit, "j");
    CHECK(!f.host.page.empty());
    CHECK(f.session.handleKey(named(kBackSpace), f.host));
    CHECK(f.host.preedit.empty());
    CHECK(f.host.page.empty());
    CHECK(!f.session.isComposing());
    CHECK(f.host.committed.empty());
}

TEST(escapeCancels) {
    Fixture f;
    type(f.session, f.host, "jd");
    CHECK(f.session.handleKey(named(kEscape), f.host));
    CHECK(f.host.preedit.empty());
    CHECK(f.host.page.empty());
    CHECK(f.host.committed.empty());
    CHECK(!f.session.isComposing());
}

TEST(returnCommitsTheLetters) {
    Fixture f;
    type(f.session, f.host, "jd");
    CHECK(f.session.handleKey(named(kReturn), f.host));
    CHECK_EQ(f.host.committed, "jd");
    CHECK(f.host.page.empty());
}

TEST(aPeriodAloneCommitsTheChineseFullStop) {
    Fixture f;
    CHECK(type(f.session, f.host, "."));
    CHECK_EQ(f.host.committed, "。");
    CHECK(!f.session.isComposing());
}

TEST(aPeriodWhileComposingCommitsTheCandidateAndTheStop) {
    Fixture f;
    type(f.session, f.host, "n");
    const std::string first = f.host.page.at(0).value;
    CHECK(type(f.session, f.host, "."));
    CHECK_EQ(f.host.committed, first + "。");
    CHECK(!f.session.isComposing());
}

TEST(aChordPassesThrough) {
    Fixture f;
    KeyInput key = typed('a');
    key.control = true;
    CHECK(!f.session.handleKey(key, f.host));
    CHECK(f.host.committed.empty());
    CHECK(!f.session.isComposing());
}

TEST(deactivationCommitsTheLetters) {
    Fixture f;
    type(f.session, f.host, "jd");
    f.session.deactivate(f.host);
    CHECK_EQ(f.host.committed, "jd");
    CHECK(f.host.page.empty());
    CHECK(!f.session.isComposing());
}

TEST(cancellingLeavesTheLettersToTheFramework) {
    Fixture f;
    type(f.session, f.host, "jd");
    f.session.cancelComposition(f.host);
    CHECK(f.host.committed.empty());
    CHECK(f.host.preedit.empty());
    CHECK(f.host.page.empty());
    CHECK(!f.session.isComposing());
}

TEST(aClickSelects) {
    Fixture f;
    type(f.session, f.host, "j");
    const std::string third = f.host.page.at(2).value;
    f.session.selectCandidate(2, f.host);
    CHECK_EQ(f.host.committed, third);
    CHECK(!f.session.isComposing());
}

TEST(anEditedDictionaryIsAdoptedOnceNothingIsComposing) {
    Fixture f;
    // A phrase on a code built-in words have: the engine lists it first.
    f.dir.write(imejd::userdict_file::fileName, "键道\tz\n");
    f.store.reload();

    // Off: the phrase is loaded, but engines don't get it.
    type(f.session, f.host, "z");
    CHECK(f.host.page.at(0).value != "键道");
    f.session.handleKey(named(kEscape), f.host);

    // Switched on in the middle of a composition: that composition keeps the
    // engine it started with, whose candidates are on screen.
    type(f.session, f.host, "z");
    CHECK(f.store.setEnabled(true));
    type(f.session, f.host, "=-");
    CHECK(f.host.page.at(0).value != "键道");
    f.session.handleKey(named(kEscape), f.host);

    // The next composition gets the phrase.
    type(f.session, f.host, "z");
    CHECK_EQ(f.host.page.at(0).value, "键道");
    CHECK(contains(f.host.page, "键道"));
}
