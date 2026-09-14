// The field policy (FieldPolicy): which plane a field opens on and when
// letters bypass the engine, both read off EditorInfo.inputType. Pins that
// numeric classes open on ?123 whatever flags ride along, that text classes —
// email / URI / ASCII included — stay on letters, and that every password
// variation, and only those, gets direct input.
package com.hronro.imejd

import android.text.InputType
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hronro.imejd.ui.FieldPolicy
import com.hronro.imejd.ui.KeyboardLayer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FieldPolicyTest {

    @Test
    fun numericClassesOpenOnNumbers() {
        for (type in listOf(
            InputType.TYPE_CLASS_NUMBER,
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or InputType.TYPE_NUMBER_FLAG_SIGNED,
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD,
            InputType.TYPE_CLASS_PHONE,
            InputType.TYPE_CLASS_DATETIME or InputType.TYPE_DATETIME_VARIATION_DATE,
        )) {
            assertEquals("inputType $type", KeyboardLayer.NUMBERS, FieldPolicy.openingLayer(type))
        }
    }

    @Test
    fun textClassesOpenOnLetters() {
        for (type in listOf(
            InputType.TYPE_NULL,
            InputType.TYPE_CLASS_TEXT,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
        )) {
            assertEquals("inputType $type", KeyboardLayer.LETTERS, FieldPolicy.openingLayer(type))
        }
    }

    @Test
    fun everyPasswordVariationGetsDirectInput() {
        for (type in listOf(
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS,
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD,
        )) {
            assertTrue("inputType $type", FieldPolicy.isPassword(type))
        }
    }

    @Test
    fun ordinaryFieldsKeepTheEngine() {
        for (type in listOf(
            InputType.TYPE_NULL,
            InputType.TYPE_CLASS_TEXT,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PERSON_NAME,
            InputType.TYPE_CLASS_NUMBER,
            InputType.TYPE_CLASS_PHONE,
        )) {
            assertFalse("inputType $type", FieldPolicy.isPassword(type))
        }
    }
}
