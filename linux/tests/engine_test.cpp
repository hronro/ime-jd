// The engine wrapper over the real libjd, as the macOS client smoke-tests
// its binding (macos/JdIMETests/EngineSmokeTests.swift).
#include <string>

#include "check.h"
#include "engine.h"

using imejd::Engine;

TEST(abiMatches) { CHECK(Engine::abiMatches()); }

TEST(pressKeyProducesCandidates) {
    Engine engine;
    const auto result = engine.pressKey('b');
    CHECK(!result.committed);
    CHECK(result.optionsCount > 0);
    CHECK(!engine.readRange(0, 9).empty());
}

TEST(punctuationCommitsAndAppends) {
    Engine engine;
    CHECK(engine.pressKey('n').optionsCount > 0);
    const auto result = engine.pressKey('.');
    CHECK(result.committed);
    const std::string stop = "。";
    CHECK(result.commit.size() > stop.size());
    CHECK_EQ(result.commit.substr(result.commit.size() - stop.size()), stop);
}

TEST(punctuationCommitsFromRoot) {
    Engine engine;
    const auto result = engine.pressKey('.');
    CHECK(result.committed);
    CHECK_EQ(result.commit, "。");
    CHECK_EQ(result.optionsCount, 0u);
}

TEST(resetClearsState) {
    Engine engine;
    engine.pressKey('b');
    engine.reset();
    CHECK_EQ(engine.optionsCount(), 0u);
    CHECK(engine.pressKey('b').optionsCount > 0);
}

TEST(readRangeClips) {
    Engine engine;
    const unsigned total = engine.pressKey('j').optionsCount;
    CHECK(total > 100);
    CHECK_EQ(engine.readRange(0, total + 50).size(), static_cast<size_t>(total));
    CHECK(engine.readRange(total, 5).empty());
    CHECK(engine.readRange(0, 0).empty());
}

TEST(setAnchorMovesWhatSpaceCommits) {
    Engine engine;
    engine.pressKey('j');
    const auto target = engine.readRange(9, 1);
    CHECK_EQ(target.size(), static_cast<size_t>(1));
    engine.setAnchor(9);
    const auto result = engine.pressKey(' ');
    CHECK(result.committed);
    CHECK_EQ(result.commit, target.at(0).value);
}
