// In-app preview of the keyboard — port of ios/App/KeyboardPreviewViewController.swift.
// It drives the SAME KeyboardView + InputSession as the IME, with committed text
// routed into an in-app field, so the keyboard can be tried (and QA-driven)
// without enabling anything in Settings. The system IME is suppressed on the
// field; only the embedded keyboard edits it.
package com.hronro.imejd.app

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.AppCompatEditText
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.hronro.imejd.R
import com.hronro.imejd.engine.InputSession
import com.hronro.imejd.engine.KeyAction
import com.hronro.imejd.engine.KeyboardHost
import com.hronro.imejd.ui.KeyboardLayer
import com.hronro.imejd.ui.KeyboardTheme
import com.hronro.imejd.ui.KeyboardView

class KeyboardPreviewActivity : AppCompatActivity() {

    companion object {
        // QA intent extras, mirroring the iOS -preview/-numbers/-symbols/-type
        // launch args. MainActivity forwards them so one adb command reaches
        // this (non-exported) screen:
        //   adb shell am start -n com.hronro.imejd/.app.MainActivity \
        //     --ez jd.preview true --es jd.type a [--es jd.plane numbers]
        const val EXTRA_PREVIEW = "jd.preview"
        const val EXTRA_PLANE = "jd.plane"   // "numbers" | "symbols"
        const val EXTRA_TYPE = "jd.type"     // keys fed into the session at launch
    }

    private val session = InputSession(pageSize = 16) // mirrors JdInputMethodService
    private val host = FieldHost()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val theme = KeyboardTheme.resolve(this, 0)
        val density = resources.displayMetrics.density
        val pad = (12 * density).toInt()

        val field = PreviewEditText(this).apply {
            id = R.id.preview_field
            hint = getString(R.string.try_hint)
            textSize = 22f
            gravity = Gravity.TOP
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            // Only the embedded keyboard edits this field — never the system IME.
            showSoftInputOnFocus = false
            setPadding(pad, pad, pad, pad)
            setTextColor(theme.keyText)
            setHintTextColor(theme.candidateHint)
            background = GradientDrawable().apply {
                cornerRadius = 8 * density
                setColor(theme.keyboardBackground)
            }
        }
        host.input = field
        session.host = host
        // An external caret move mid-composition orphans the composition's
        // context — drop it, exactly like the service does in onUpdateSelection.
        field.onCaretMoved = { if (session.isComposing) session.cancelAndReset() }

        val keyboard = KeyboardView(this, session, theme)
        keyboard.onReturn = {
            if (session.isComposing) session.handle(KeyAction.CommitRaw) else host.insertText("\n")
        }

        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(
            field,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f).apply {
                setMargins(pad, pad, pad, pad)
            },
        )
        root.addView(
            keyboard,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT),
        )
        setContentView(root)

        // Edge-to-edge: keep the field clear of the status bar / cutout; the
        // keyboard consumes the bottom (nav) inset itself.
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
            )
            v.setPadding(bars.left, bars.top, bars.right, 0)
            insets
        }

        field.requestFocus()

        when (intent.getStringExtra(EXTRA_PLANE)) {
            "numbers" -> keyboard.showLayer(KeyboardLayer.NUMBERS)
            "symbols" -> keyboard.showLayer(KeyboardLayer.SYMBOLS)
        }
        intent.getStringExtra(EXTRA_TYPE)?.let { keys ->
            for (b in keys.toByteArray(Charsets.UTF_8)) session.handle(KeyAction.EngineKey(b))
        }
    }

    override fun onDestroy() {
        session.close()
        super.onDestroy()
    }
}

/** Routes committed text into the preview field — port of the iOS FieldHost. */
private class FieldHost : KeyboardHost {
    var input: PreviewEditText? = null
    override fun insertText(text: String) { input?.replaceSelection(text) }
    override fun deleteBackward() { input?.deleteBackward() }
}

/**
 * The preview field: edited only through the KeyboardHost calls below (the
 * system IME is suppressed), with external caret moves surfaced so the owner
 * can drop an in-flight composition.
 */
@SuppressLint("ViewConstructor")
private class PreviewEditText(context: Context) : AppCompatEditText(context) {

    /** Fired when the caret moves for any reason other than our own edits. */
    var onCaretMoved: (() -> Unit)? = null
    private var ownEdit = false

    fun replaceSelection(insert: String) = edit { t, s, e -> t.replace(s, e, insert) }

    /** ⌫ semantics matching the service: the selection first, else one code point. */
    fun deleteBackward() = edit { t, s, e ->
        when {
            s != e -> t.delete(s, e)
            s == 0 -> {}
            else -> {
                val n = if (s >= 2 && Character.isSurrogatePair(t[s - 2], t[s - 1])) 2 else 1
                t.delete(s - n, s)
            }
        }
    }

    private inline fun edit(body: (t: Editable, selMin: Int, selMax: Int) -> Unit) {
        val t = text ?: return
        val s = selectionStart
        val e = selectionEnd
        if (s < 0 || e < 0) return
        ownEdit = true
        try {
            body(t, minOf(s, e), maxOf(s, e))
        } finally {
            ownEdit = false
        }
    }

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        if (!ownEdit) onCaretMoved?.invoke()
    }
}
