// 编码反查 — port of ios/App/CodeLookupViewController.swift: which codes type a
// word. The word goes into the field at the top — typed, with 键道 or any
// keyboard, or pasted — and 查询, or the keyboard's search action, lists its
// codes below, shortest first: libjd's jd_lookup_codes over the built-in
// tables and, while the switch is on, the user dictionary, the dictionaries
// the keyboard types with. A code on which the word is not the first
// candidate says which one it is; a code from the user dictionary says so.
// The wording is CodeLookupReport's, the same as the macOS and iOS clients'.
package com.hronro.imejd.app

import android.annotation.SuppressLint
import android.graphics.Typeface
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.KeyEvent
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.R as MaterialR
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.button.MaterialButton
import com.google.android.material.color.DynamicColors
import com.google.android.material.color.MaterialColors
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import com.hronro.imejd.R
import com.hronro.imejd.lookup.CodeLookupReport
import com.hronro.imejd.userdict.UserDictSelection
import com.hronro.imejd.userdict.UserDictStore
import com.hronro.jd.Engine

class CodeLookupActivity : AppCompatActivity() {

    companion object {
        /**
         * QA (the iOS `-lookup` launch arg's counterpart): `--es jd.lookup 着`
         * on the launcher opens this screen with the word already looked up,
         * for screenshots with no taps.
         */
        const val EXTRA_QUERY = "jd.lookup"

        /** The field's text and the query on screen, across a rotation. */
        private const val STATE_FIELD = "field"
        private const val STATE_SHOWN = "shown"
    }

    private val store by lazy { UserDictStore.get(this) }
    private val adapter = ResultAdapter()
    private lateinit var input: TextInputEditText
    private lateinit var lookUpButton: MaterialButton
    /** The report on screen, and the query it answers; null before the first. */
    private var report: CodeLookupReport? = null
    private var shownQuery: String? = null

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        DynamicColors.applyToActivityIfAvailable(this)
        super.onCreate(savedInstanceState)

        val toolbar = MaterialToolbar(this)
        toolbar.setBackgroundColor(MaterialColors.getColor(toolbar, MaterialR.attr.colorSurface))
        setSupportActionBar(toolbar)
        supportActionBar?.apply {
            title = getString(R.string.code_lookup)
            setDisplayHomeAsUpEnabled(true)
        }

        val fieldLayout = TextInputLayout(this).apply { hint = getString(R.string.code_lookup_hint) }
        input = TextInputEditText(fieldLayout.context).apply {
            // A word, typed with any keyboard — 键道 composing into it like
            // anywhere else — or pasted: plain text, one line, no suggestions.
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            maxLines = 1
            setOnEditorActionListener { _, actionId, event ->
                val enter = event?.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN
                if (actionId == EditorInfo.IME_ACTION_SEARCH || enter) {
                    lookUp()
                    true
                } else {
                    false
                }
            }
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                override fun afterTextChanged(s: Editable?) = updateButton()
            })
        }
        fieldLayout.addView(input)
        lookUpButton = MaterialButton(this).apply {
            text = getString(R.string.code_lookup_submit)
            setOnClickListener { lookUp() }
        }
        val inputRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(8), dp(16), dp(8))
            addView(fieldLayout, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(
                lookUpButton,
                LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                    .apply { marginStart = dp(8) },
            )
        }

        val recycler = RecyclerView(this).apply {
            layoutManager = LinearLayoutManager(this@CodeLookupActivity)
            adapter = this@CodeLookupActivity.adapter
            clipToPadding = false
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val full = ViewGroup.LayoutParams.MATCH_PARENT
            addView(toolbar, LinearLayout.LayoutParams(full, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(inputRow, LinearLayout.LayoutParams(full, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(recycler, LinearLayout.LayoutParams(full, 0, 1f))
        }
        setContentView(root)

        // Edge-to-edge (enforced at targetSdk 35): the toolbar takes the
        // status bar, and the list scrolls under the navigation bar — or the
        // keyboard, while the field has it.
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val bottom = maxOf(bars.bottom, insets.getInsets(WindowInsetsCompat.Type.ime()).bottom)
            toolbar.updatePadding(left = bars.left, top = bars.top, right = bars.right)
            inputRow.updatePadding(left = bars.left + dp(16), right = bars.right + dp(16))
            recycler.updatePadding(left = bars.left, right = bars.right, bottom = bottom + dp(16))
            insets
        }

        if (savedInstanceState != null) {
            input.setText(savedInstanceState.getString(STATE_FIELD).orEmpty())
            savedInstanceState.getString(STATE_SHOWN)?.let { show(it) }
        } else {
            intent.getStringExtra(EXTRA_QUERY)?.let {
                input.setText(it)
                lookUp()
            }
        }
        updateButton()
        // Ready to type or paste into, unless the screen opened on a result.
        if (report == null) {
            input.requestFocus()
            window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(STATE_FIELD, input.text?.toString().orEmpty())
        shownQuery?.let { outState.putString(STATE_SHOWN, it) }
    }

    override fun onSupportNavigateUp(): Boolean {
        onBackPressedDispatcher.onBackPressed()
        return true
    }

    // ---- Looking up ----

    private val query: String get() = CodeLookupReport.query(input.text?.toString().orEmpty())

    private fun updateButton() {
        lookUpButton.isEnabled = query.isNotEmpty()
    }

    private fun lookUp() {
        val query = query
        if (query.isEmpty()) return
        // The keyboard would cover the codes.
        input.clearFocus()
        input.windowToken?.let {
            (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(it, 0)
        }
        show(query)
    }

    /**
     * A fresh engine over what the keyboard types with right now: the user
     * dictionary only while it is switched on, and alone when the built-in
     * one is off. Cheap — one allocation and a copy of the user's blob — and
     * closed before this returns; the codes are plain values.
     */
    @SuppressLint("NotifyDataSetChanged") // a new report replaces every row
    private fun show(query: String) {
        val selection = store.selection
        val engine = selection.makeEngine()
        report = if (engine != null) {
            val scope = when {
                !store.isEnabled -> CodeLookupReport.Scope.BUILT_IN
                store.isUserOnly -> CodeLookupReport.Scope.USER_ONLY
                else -> CodeLookupReport.Scope.BUILT_IN_AND_USER
            }
            CodeLookupReport(query, engine.use { it.lookupCodes(query) }, scope)
        } else {
            CodeLookupReport(query, (selection as? UserDictSelection.Unavailable)?.why ?: "用户自造词未能加载")
        }
        shownQuery = query
        adapter.notifyDataSetChanged()
    }

    // ---- The list ----

    private fun color(attr: Int): Int = MaterialColors.getColor(input, attr)

    private fun fullWidth() = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)

    /**
     * Found: a header (「着」的编码) and a row per code. Not found: the title
     * and the reason, centred. Before the first query: nothing.
     */
    private inner class ResultAdapter : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        override fun getItemCount(): Int {
            val report = report ?: return 0
            return if (report.found) 1 + report.lines.size else 1
        }

        override fun getItemViewType(position: Int): Int = when {
            report?.found != true -> 2
            position == 0 -> 0
            else -> 1
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder = when (viewType) {
            0 -> HeaderHolder()
            1 -> CodeHolder()
            else -> NotFoundHolder()
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            val report = report ?: return
            when (holder) {
                is HeaderHolder -> holder.label.text = report.title
                is CodeHolder -> holder.bind(report.lines[position - 1])
                is NotFoundHolder -> holder.bind(report)
            }
        }
    }

    private inner class HeaderHolder : RecyclerView.ViewHolder(TextView(this@CodeLookupActivity)) {
        val label = itemView as TextView

        init {
            label.layoutParams = fullWidth()
            label.textSize = 14f
            label.typeface = Typeface.DEFAULT_BOLD
            label.setTextColor(color(MaterialR.attr.colorPrimary))
            label.setPadding(dp(24), dp(16), dp(24), dp(8))
        }
    }

    private inner class CodeHolder : RecyclerView.ViewHolder(LinearLayout(this@CodeLookupActivity)) {
        private val keys = TextView(this@CodeLookupActivity)
        private val note = TextView(this@CodeLookupActivity)

        init {
            val line = itemView as LinearLayout
            line.layoutParams = fullWidth()
            line.orientation = LinearLayout.HORIZONTAL
            line.gravity = Gravity.CENTER_VERTICAL
            line.minimumHeight = dp(52)
            line.setPadding(dp(24), dp(8), dp(24), dp(8))
            keys.textSize = 17f
            keys.typeface = Typeface.MONOSPACE
            keys.setTextColor(color(MaterialR.attr.colorOnSurface))
            note.textSize = 14f
            note.setTextColor(color(MaterialR.attr.colorOnSurfaceVariant))
            line.addView(keys, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            line.addView(note)
        }

        fun bind(item: CodeLookupReport.Line) {
            keys.text = item.keys
            note.text = item.note.orEmpty()
        }
    }

    private inner class NotFoundHolder : RecyclerView.ViewHolder(LinearLayout(this@CodeLookupActivity)) {
        private val title = TextView(this@CodeLookupActivity)
        private val message = TextView(this@CodeLookupActivity)

        init {
            val column = itemView as LinearLayout
            column.layoutParams = fullWidth()
            column.orientation = LinearLayout.VERTICAL
            column.setPadding(dp(32), dp(32), dp(32), dp(16))
            title.textSize = 16f
            title.typeface = Typeface.DEFAULT_BOLD
            title.gravity = Gravity.CENTER_HORIZONTAL
            title.setTextColor(color(MaterialR.attr.colorOnSurface))
            message.textSize = 14f
            message.gravity = Gravity.CENTER_HORIZONTAL
            message.setTextColor(color(MaterialR.attr.colorOnSurfaceVariant))
            val full = ViewGroup.LayoutParams.MATCH_PARENT
            column.addView(title, LinearLayout.LayoutParams(full, ViewGroup.LayoutParams.WRAP_CONTENT))
            column.addView(
                message,
                LinearLayout.LayoutParams(full, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) },
            )
        }

        fun bind(report: CodeLookupReport) {
            title.text = report.title
            message.text = report.message.orEmpty()
        }
    }
}
