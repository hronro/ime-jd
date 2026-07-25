// Pins the punctuation-plane arrangement and its press-and-hold groups
// (mirrors ios/KeyboardTests/KeyLayoutTests.swift): '；' stays a dedicated key,
// grouped marks never also have keys, and the engine's punctuation inventory
// stays reachable through any plane reshuffle.
package com.hronro.imejd

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hronro.imejd.ui.KeyCap
import com.hronro.imejd.ui.KeyLayout
import com.hronro.imejd.ui.KeySpec
import com.hronro.imejd.ui.KeyboardIdiom
import com.hronro.imejd.ui.KeyboardLayer
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeyLayoutTest {

    private val allSpecs: List<KeySpec> =
        listOf(KeyboardLayer.LETTERS, KeyboardLayer.NUMBERS, KeyboardLayer.SYMBOLS)
            .flatMap { layer -> KeyLayout.rows(layer, KeyboardIdiom.PHONE).flatten() }

    private val literalKeys: Set<String> =
        allSpecs.mapNotNull { (it.cap as? KeyCap.InsertLiteral)?.text }.toSet()

    /** '；' has no engine key (';' is the desktop 2nd-candidate shortcut), so
     *  it must stay reachable as a dedicated engine-bypass key. */
    @Test
    fun semicolonIsADedicatedKey() {
        assertTrue("； must be a key on some plane", literalKeys.contains("；"))
    }

    /** The ellipsis key inserts the single-glyph form; the variants live in
     *  its press-and-hold group. */
    @Test
    fun ellipsisKeyAndGroup() {
        assertTrue(literalKeys.contains("…"))
        assertFalse("…… was replaced by the … key", literalKeys.contains("……"))
        val group = allSpecs.first { it.cap == KeyCap.InsertLiteral("…") }.alternates
        assertTrue("⋯ must be in the … group", group.contains("⋯"))
    }

    /** Grouping exists to free plane slots, so a grouped mark must not ALSO
     *  have a dedicated key (e.g. '‘' lives under '“', not on the plane). */
    @Test
    fun alternatesAreNotAlsoKeys() {
        for (spec in allSpecs) {
            for (alt in spec.alternates) {
                assertFalse("$alt is both a key and an alternate", literalKeys.contains(alt))
            }
        }
    }

    /** Alternates only make sense on direct-insert keys, must not repeat the
     *  primary, and must be non-empty marks. */
    @Test
    fun alternateGroupsAreWellFormed() {
        for (spec in allSpecs) {
            if (spec.alternates.isEmpty()) continue
            val cap = spec.cap
            assertTrue("alternates on non-literal key $cap", cap is KeyCap.InsertLiteral)
            val primary = (cap as KeyCap.InsertLiteral).text
            assertFalse("$primary duplicates its own group", spec.alternates.contains(primary))
            assertFalse(spec.alternates.any { it.isEmpty() })
        }
    }

    /** Every mark in the engine's punctuation inventory
     *  (core/src/punctuation-marks/) stays reachable as a key or an alternate. */
    @Test
    fun engineInventoryStaysReachable() {
        val inventory = listOf(
            "｀", "～", "！", "＠", "＃", "＄", "％", "……", "＆", "＊", "（", "）",
            "－", "＝", "＿", "＋", "「", "【", "〔", "［", "『", "〖", "｛",
            "」", "】", "〕", "］", "』", "〗", "｝", "、", "·", "｜", "¦", "＼",
            "：", "，", "《", "。", "》", "／", "？", "‘", "’", "“", "”",
        )
        val reachable = literalKeys + allSpecs.flatMap { it.alternates }
        for (mark in inventory) {
            assertTrue("$mark is no longer reachable", reachable.contains(mark))
        }
    }

    /** Every configured group is actually mounted on some plane (no orphans
     *  left behind by a layout reshuffle). */
    @Test
    fun alternateGroupsAllMounted() {
        val mounted = allSpecs.mapNotNull { spec ->
            (spec.cap as? KeyCap.InsertLiteral)?.text?.takeIf { spec.alternates.isNotEmpty() }
        }.toSet()
        for (primary in listOf(
            "0", "“", "”", "「", "」", "【", "】", "｜", "《", "》",
            "。", "·", "…", "－", "＄", "℃", "√", "→", "★", "♡", "©",
        )) {
            assertTrue("group on $primary is not on any plane", mounted.contains(primary))
        }
    }
}
