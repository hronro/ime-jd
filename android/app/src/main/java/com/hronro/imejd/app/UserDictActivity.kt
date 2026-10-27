// The phrase list — port of ios/App/UserDictListViewController.swift: the user
// dictionary's file as a list, saved as it is edited. Every row is written as
// typed — the screen validates nothing — and the engine's verdict on each row,
// from the build that follows every save, is its second line: a line the
// engine skips because it does not parse (red), a duplicate it drops (grey), a
// phrase on a code a built-in word or another row already uses (orange; it
// works, listed first). Order among phrases on one code is file order, which
// is what the drag handles are for. The file travels as it is: imported from
// any document provider and appended — the duplicates that may make are the
// engine's to flag and the user's to remove, with 移除重复词条 — and exported
// through the system's save dialog.
package com.hronro.imejd.app

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.os.Bundle
import android.text.InputType
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SearchView
import androidx.coordinatorlayout.widget.CoordinatorLayout
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.R as MaterialR
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.color.DynamicColors
import com.google.android.material.color.MaterialColors
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.floatingactionbutton.FloatingActionButton
import com.google.android.material.materialswitch.MaterialSwitch
import com.google.android.material.snackbar.Snackbar
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import com.hronro.imejd.R
import com.hronro.imejd.userdict.UserDictEntry
import com.hronro.imejd.userdict.UserDictFile
import com.hronro.imejd.userdict.UserDictProblem
import com.hronro.imejd.userdict.UserDictStore
import java.io.IOException

class UserDictActivity : AppCompatActivity() {

    companion object {
        /**
         * QA (the iOS `-userdict` launch arg's counterpart):
         * `--es jd.userdict "词<TAB>编码;词<TAB>编码"` on the launcher seeds the
         * user dictionary with these phrases, replacing the file, and switches
         * it on, so the preview (`jd.type`) or the real IME can type a known
         * phrase with no list editing.
         */
        const val EXTRA_SEED = "jd.userdict"

        /** QA: `--ez jd.userdict_list true` on the launcher opens this screen. */
        const val EXTRA_OPEN = "jd.userdict_list"

        fun seed(context: Context, seed: String) {
            val entries = seed.split(';').map { line ->
                val parts = line.split('\t', limit = 2)
                UserDictEntry(parts[0], parts.getOrElse(1) { "" })
            }
            val store = UserDictStore.get(context)
            try {
                store.save(entries)
                store.isEnabled = true
            } catch (e: IOException) {
                Log.w("JdIME", "user dict: cannot seed", e)
            }
        }
    }

    private enum class Action(val label: Int, val icon: Int) {
        IMPORT(R.string.user_dict_import, R.drawable.ic_file_import),
        EXPORT(R.string.user_dict_export, R.drawable.ic_file_export),
        REMOVE_DUPLICATES(R.string.user_dict_remove_duplicates, R.drawable.ic_delete_sweep),
    }

    private enum class TextStyle { STATUS, FOOTER, HEADER }

    /** What the list shows, top to bottom. */
    private sealed interface Item {
        data object Enable : Item
        data class Text(val text: String, val style: TextStyle) : Item
        data class Command(val action: Action, val enabled: Boolean) : Item
        /** A phrase, by its index into the store's rows. */
        data class Phrase(val row: Int) : Item
    }

    private val store by lazy { UserDictStore.get(this) }
    private val storeListener: () -> Unit = { refresh() }
    private val adapter = ListAdapter()
    private val touchHelper = ItemTouchHelper(TouchCallback())
    private lateinit var root: CoordinatorLayout
    private lateinit var recycler: RecyclerView
    private lateinit var fab: FloatingActionButton
    private var items: MutableList<Item> = ArrayList()
    /** While the search field is open the list is the phrases alone, and they cannot be dragged. */
    private var searching = false
    private var filter = ""

    private val importDocument = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) importFrom(uri)
    }
    private val exportDocument = registerForActivityResult(ActivityResultContracts.CreateDocument("text/plain")) { uri ->
        if (uri != null) exportTo(uri)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        DynamicColors.applyToActivityIfAvailable(this)
        super.onCreate(savedInstanceState)

        val toolbar = MaterialToolbar(this)
        toolbar.setBackgroundColor(MaterialColors.getColor(toolbar, MaterialR.attr.colorSurface))
        setSupportActionBar(toolbar)
        supportActionBar?.apply {
            title = getString(R.string.user_dict)
            setDisplayHomeAsUpEnabled(true)
        }

        recycler = RecyclerView(this).apply {
            layoutManager = LinearLayoutManager(this@UserDictActivity)
            adapter = this@UserDictActivity.adapter
            clipToPadding = false
        }
        touchHelper.attachToRecyclerView(recycler)

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(toolbar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(recycler, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        fab = FloatingActionButton(this).apply {
            setImageResource(R.drawable.ic_add)
            contentDescription = getString(R.string.user_dict_add)
            setOnClickListener { addPhrase() }
        }
        root = CoordinatorLayout(this).apply {
            addView(column, CoordinatorLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            addView(
                fab,
                CoordinatorLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                    .apply { gravity = Gravity.BOTTOM or Gravity.END },
            )
        }
        setContentView(root)

        // Edge-to-edge (enforced at targetSdk 35): the toolbar takes the status
        // bar, the list scrolls under the navigation bar — or the keyboard,
        // while the search field has it — and clear of the add button.
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val bottom = maxOf(bars.bottom, insets.getInsets(WindowInsetsCompat.Type.ime()).bottom)
            toolbar.updatePadding(left = bars.left, top = bars.top, right = bars.right)
            recycler.updatePadding(left = bars.left, right = bars.right, bottom = bottom + dp(88))
            (fab.layoutParams as ViewGroup.MarginLayoutParams).setMargins(0, 0, bars.right + dp(16), bottom + dp(16))
            fab.requestLayout()
            insets
        }

        store.addListener(storeListener)
        refresh()
    }

    override fun onDestroy() {
        store.removeListener(storeListener)
        super.onDestroy()
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        val search = SearchView(supportActionBar?.themedContext ?: this).apply {
            queryHint = getString(R.string.user_dict_search)
            maxWidth = Int.MAX_VALUE
            setOnQueryTextListener(object : SearchView.OnQueryTextListener {
                override fun onQueryTextSubmit(query: String?): Boolean {
                    clearFocus()
                    return true
                }

                override fun onQueryTextChange(newText: String?): Boolean {
                    filter = newText.orEmpty().trim()
                    refresh()
                    return true
                }
            })
        }
        menu.add(Menu.NONE, Menu.NONE, Menu.NONE, R.string.user_dict_search).apply {
            setIcon(R.drawable.ic_search)
            actionView = search
            setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS or MenuItem.SHOW_AS_ACTION_COLLAPSE_ACTION_VIEW)
            setOnActionExpandListener(object : MenuItem.OnActionExpandListener {
                override fun onMenuItemActionExpand(item: MenuItem): Boolean {
                    searching = true
                    fab.hide()
                    refresh()
                    return true
                }

                override fun onMenuItemActionCollapse(item: MenuItem): Boolean {
                    searching = false
                    filter = ""
                    fab.show()
                    refresh()
                    return true
                }
            })
        }
        return true
    }

    override fun onSupportNavigateUp(): Boolean {
        onBackPressedDispatcher.onBackPressed()
        return true
    }

    // ---- Model ----

    @SuppressLint("NotifyDataSetChanged") // every row's verdict may have changed
    private fun refresh() {
        val rows = store.rows
        val shown = if (filter.isEmpty()) {
            rows.indices.toList()
        } else {
            rows.indices.filter {
                rows[it].entry.value.contains(filter, ignoreCase = true) ||
                    rows[it].entry.keys.contains(filter, ignoreCase = true)
            }
        }
        items = ArrayList<Item>(shown.size + 9).apply {
            if (!searching) {
                add(Item.Enable)
                add(Item.Text(store.statusText, TextStyle.STATUS))
                add(Item.Command(Action.IMPORT, enabled = true))
                add(Item.Command(Action.EXPORT, enabled = rows.isNotEmpty()))
                // Greyed out while the engine flags none — or has no notes, the
                // file having failed to build at all.
                add(Item.Command(Action.REMOVE_DUPLICATES, enabled = store.duplicateRows.isNotEmpty()))
                add(Item.Text(getString(R.string.user_dict_actions_footer), TextStyle.FOOTER))
                add(Item.Text(getString(R.string.user_dict_phrases_header), TextStyle.HEADER))
            }
            shown.forEach { add(Item.Phrase(it)) }
            val footer = when {
                searching && shown.isEmpty() && filter.isNotEmpty() -> R.string.user_dict_no_match
                searching -> R.string.user_dict_search_footer
                rows.isEmpty() -> R.string.user_dict_empty_footer
                else -> R.string.user_dict_list_footer
            }
            add(Item.Text(getString(footer), TextStyle.FOOTER))
        }
        adapter.notifyDataSetChanged()
    }

    /** Save, or say why not; the list is redrawn either way (a failed swipe puts its row back). */
    private fun save(entries: List<UserDictEntry>): Boolean = try {
        store.save(entries)
        true
    } catch (e: IOException) {
        alert(R.string.user_dict_save_failed, e.message)
        refresh()
        false
    }

    private fun alert(title: Int, message: String?) {
        MaterialAlertDialogBuilder(this)
            .setTitle(title)
            .setMessage(message)
            .setPositiveButton(R.string.user_dict_ok, null)
            .show()
    }

    private fun snackbar(text: String, undo: (() -> Unit)? = null) {
        val bar = Snackbar.make(root, text, Snackbar.LENGTH_LONG)
        if (undo != null) {
            // LENGTH_LONG is under three seconds: short for noticing a slip.
            bar.duration = 5000
            bar.setAction(R.string.user_dict_undo) { undo() }
        }
        bar.show()
    }

    private fun scrollToRow(row: Int) {
        val position = items.indexOfFirst { it is Item.Phrase && it.row == row }
        if (position >= 0) recycler.scrollToPosition(position)
    }

    // ---- Add, edit, delete, reorder ----

    private fun addPhrase() {
        presentForm(R.string.user_dict_add, UserDictEntry("", "")) { entry ->
            if (save(store.entries + entry)) scrollToRow(store.rows.size - 1)
        }
    }

    private fun editPhrase(row: Int) {
        presentForm(R.string.user_dict_edit, store.entries[row]) { entry ->
            val entries = store.entries.toMutableList()
            if (row in entries.indices) {
                entries[row] = entry
                save(entries)
            }
        }
    }

    /** Two fields; whatever is typed is saved as it is — the engine judges it. */
    private fun presentForm(title: Int, entry: UserDictEntry, done: (UserDictEntry) -> Unit) {
        val valueLayout = TextInputLayout(this).apply { hint = getString(R.string.user_dict_value) }
        val valueField = TextInputEditText(valueLayout.context).apply {
            inputType = InputType.TYPE_CLASS_TEXT
            setText(entry.value)
        }
        valueLayout.addView(valueField)
        val keysLayout = TextInputLayout(this).apply {
            hint = getString(R.string.user_dict_keys)
            helperText = getString(R.string.user_dict_keys_helper)
        }
        val keysField = TextInputEditText(keysLayout.context).apply {
            // A code is letters, not words: the field asks for ASCII with no
            // suggestions or capitals, as iOS's field does, so 键道 types into
            // it directly instead of composing (FieldPolicy). Not a password
            // field: phones with a secure keyboard of their own would swap
            // it in.
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_FLAG_FORCE_ASCII
            setText(entry.keys)
        }
        keysLayout.addView(keysField)
        val form = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(8), dp(24), 0)
            addView(valueLayout)
            addView(
                keysLayout,
                LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                    .apply { topMargin = dp(12) },
            )
        }
        val dialog = MaterialAlertDialogBuilder(this)
            .setTitle(title)
            .setView(form)
            .setNegativeButton(R.string.user_dict_cancel, null)
            .setPositiveButton(R.string.user_dict_save) { _, _ ->
                done(UserDictEntry(valueField.text?.toString().orEmpty(), keysField.text?.toString().orEmpty()))
            }
            .create()
        dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE)
        dialog.show()
        valueField.requestFocus()
    }

    /** Swiped away: saved at once, with a moment to take it back. */
    private fun deletePhrase(row: Int) {
        val entries = store.entries.toMutableList()
        if (row !in entries.indices) return refresh()
        val removed = entries.removeAt(row)
        if (!save(entries)) return
        snackbar(getString(R.string.user_dict_deleted, removed.value.ifEmpty { removed.keys })) {
            val restored = store.entries.toMutableList()
            restored.add(minOf(row, restored.size), removed)
            save(restored)
        }
    }

    /** A drag ended: write the phrases in the order on screen. Dragging is off while searching, so that is all of them. */
    private fun commitOrder() {
        val order = items.filterIsInstance<Item.Phrase>().map { it.row }
        if (order == order.sorted()) return
        val entries = store.entries
        save(order.map { entries[it] })
    }

    // ---- Import, export, duplicates ----

    private fun perform(action: Action) {
        try {
            when (action) {
                // Any file: one that arrived without its extension is typed
                // as plain data, and what a pick holds is checked anyway.
                Action.IMPORT -> importDocument.launch(arrayOf("*/*"))
                Action.EXPORT -> exportDocument.launch(UserDictFile.FILE_NAME)
                Action.REMOVE_DUPLICATES -> confirmRemoveDuplicates()
            }
        } catch (e: ActivityNotFoundException) {
            alert(if (action == Action.IMPORT) R.string.user_dict_import_failed else R.string.user_dict_export_failed, e.message)
        }
    }

    /**
     * Append the picked file's rows as they are, the way a typed row is
     * taken: the screen compares nothing. What that makes of the list is the
     * engine's verdict, duplicates grey, for 移除重复词条 when the user wants.
     * The one check is the engine's build of the result: an import that
     * would push the file over its caps changes nothing.
     */
    private fun importFrom(uri: Uri) {
        val first = store.rows.size
        val count: Int
        try {
            val imported = contentResolver.openInputStream(uri)?.use { UserDictStore.entriesFrom(it) }
                ?: throw UserDictStore.LoadError.Unreadable(null)
            store.saveIfBuildable(store.entries + imported)
            count = imported.size
        } catch (e: UserDictStore.LoadError) {
            return alert(R.string.user_dict_import_failed, e.message)
        } catch (e: Exception) {
            return alert(R.string.user_dict_import_failed, UserDictStore.LoadError.Unreadable(e.message).message)
        } catch (_: OutOfMemoryError) {
            return alert(R.string.user_dict_import_failed, getString(R.string.user_dict_too_large))
        }
        scrollToRow(first)
        snackbar(getString(R.string.user_dict_imported, count))
    }

    /** The phrases file itself, into the document the system's save dialog created. */
    private fun exportTo(uri: Uri) {
        try {
            val out = contentResolver.openOutputStream(uri, "w") ?: throw IOException(uri.toString())
            out.use { store.export(it) }
        } catch (e: Exception) {
            return alert(R.string.user_dict_export_failed, e.message)
        }
        snackbar(getString(R.string.user_dict_exported))
    }

    /** Delete the rows the engine flags as duplicates, after a confirmation that counts them and says what they repeat. */
    private fun confirmRemoveDuplicates() {
        val rows = store.duplicateRows
        if (rows.isEmpty()) return
        val ofRows = rows.count { (store.problems[it] as? UserDictProblem.Duplicate)?.ofRow != null }
        MaterialAlertDialogBuilder(this)
            .setTitle(getString(R.string.user_dict_remove_title, rows.size))
            .setMessage(getString(R.string.user_dict_remove_message, ofRows, rows.size - ofRows))
            .setNegativeButton(R.string.user_dict_cancel, null)
            .setPositiveButton(R.string.user_dict_remove) { _, _ ->
                try {
                    store.removeDuplicates()
                } catch (e: IOException) {
                    alert(R.string.user_dict_save_failed, e.message)
                }
            }
            .show()
    }

    // ---- List ----

    private fun color(attr: Int): Int = MaterialColors.getColor(root, attr)

    private fun rippleBackground() = TypedValue().let {
        theme.resolveAttribute(android.R.attr.selectableItemBackground, it, true)
        ContextCompat.getDrawable(this, it.resourceId)
    }

    private fun fullWidth() = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)

    private inner class ListAdapter : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        override fun getItemCount(): Int = items.size

        override fun getItemViewType(position: Int): Int = when (items[position]) {
            Item.Enable -> 0
            is Item.Text -> 1
            is Item.Command -> 2
            is Item.Phrase -> 3
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder = when (viewType) {
            0 -> EnableHolder()
            1 -> TextHolder()
            2 -> CommandHolder()
            else -> PhraseHolder()
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            when (val item = items[position]) {
                Item.Enable -> (holder as EnableHolder).bind()
                is Item.Text -> (holder as TextHolder).bind(item)
                is Item.Command -> (holder as CommandHolder).bind(item)
                is Item.Phrase -> (holder as PhraseHolder).bind(item.row)
            }
        }
    }

    private inner class EnableHolder : RecyclerView.ViewHolder(MaterialSwitch(this@UserDictActivity)) {
        private val switch = itemView as MaterialSwitch

        init {
            switch.layoutParams = fullWidth()
            switch.text = getString(R.string.user_dict_enabled)
            switch.textSize = 16f
            switch.setPadding(dp(24), dp(8), dp(24), 0)
            switch.setOnCheckedChangeListener { _, on -> store.isEnabled = on }
        }

        fun bind() {
            if (switch.isChecked != store.isEnabled) switch.isChecked = store.isEnabled
        }
    }

    private inner class TextHolder : RecyclerView.ViewHolder(TextView(this@UserDictActivity)) {
        private val label = itemView as TextView

        init {
            label.layoutParams = fullWidth()
        }

        fun bind(item: Item.Text) {
            label.text = item.text
            when (item.style) {
                TextStyle.STATUS -> {
                    label.textSize = 14f
                    label.typeface = Typeface.DEFAULT
                    label.setTextColor(color(MaterialR.attr.colorOnSurfaceVariant))
                    label.setPadding(dp(24), 0, dp(24), dp(12))
                }
                TextStyle.FOOTER -> {
                    label.textSize = 13f
                    label.typeface = Typeface.DEFAULT
                    label.setTextColor(color(MaterialR.attr.colorOnSurfaceVariant))
                    label.setPadding(dp(24), dp(8), dp(24), dp(16))
                }
                TextStyle.HEADER -> {
                    label.textSize = 14f
                    label.typeface = Typeface.DEFAULT_BOLD
                    label.setTextColor(color(MaterialR.attr.colorPrimary))
                    label.setPadding(dp(24), dp(16), dp(24), dp(8))
                }
            }
        }
    }

    private inner class CommandHolder : RecyclerView.ViewHolder(LinearLayout(this@UserDictActivity)) {
        private val row = itemView as LinearLayout
        private val icon = ImageView(this@UserDictActivity)
        private val label = TextView(this@UserDictActivity)
        private var action: Action? = null

        init {
            row.layoutParams = fullWidth()
            row.orientation = LinearLayout.HORIZONTAL
            row.gravity = Gravity.CENTER_VERTICAL
            row.minimumHeight = dp(56)
            row.setPadding(dp(24), 0, dp(24), 0)
            row.background = rippleBackground()
            row.addView(icon, LinearLayout.LayoutParams(dp(24), dp(24)))
            row.addView(
                label,
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = dp(20) },
            )
            label.textSize = 16f
            row.setOnClickListener { action?.let { perform(it) } }
        }

        fun bind(item: Item.Command) {
            action = item.action
            label.setText(item.action.label)
            icon.setImageResource(item.action.icon)
            // Material's disabled content: on-surface at 38%.
            val tint = if (item.enabled) color(MaterialR.attr.colorPrimary) else (color(MaterialR.attr.colorOnSurface) and 0x00FFFFFF) or 0x61000000
            label.setTextColor(tint)
            icon.imageTintList = ColorStateList.valueOf(tint)
            row.isEnabled = item.enabled
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private inner class PhraseHolder : RecyclerView.ViewHolder(LinearLayout(this@UserDictActivity)) {
        private val value = TextView(this@UserDictActivity)
        private val detail = TextView(this@UserDictActivity)
        private val handle = ImageView(this@UserDictActivity)
        var row = -1
            private set

        init {
            val line = itemView as LinearLayout
            line.layoutParams = fullWidth()
            line.orientation = LinearLayout.HORIZONTAL
            line.gravity = Gravity.CENTER_VERTICAL
            line.minimumHeight = dp(64)
            line.setPadding(dp(24), dp(8), dp(8), dp(8))
            line.background = rippleBackground()
            val texts = LinearLayout(this@UserDictActivity).apply {
                orientation = LinearLayout.VERTICAL
                addView(value)
                addView(detail)
            }
            value.textSize = 17f
            detail.textSize = 14f
            line.addView(texts, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            handle.setImageResource(R.drawable.ic_drag_handle)
            handle.setPadding(dp(12), dp(12), dp(12), dp(12))
            handle.contentDescription = getString(R.string.user_dict_reorder)
            line.addView(handle, LinearLayout.LayoutParams(dp(48), dp(48)))
            handle.setOnTouchListener { _, event ->
                if (event.actionMasked == MotionEvent.ACTION_DOWN) touchHelper.startDrag(this)
                false
            }
            line.setOnClickListener { if (row >= 0) editPhrase(row) }
        }

        fun bind(index: Int) {
            row = index
            val entry = store.rows[index].entry
            val problem = store.problems.getOrNull(index)
            value.text = entry.value.ifEmpty { " " }
            detail.text = if (problem == null) entry.keys else "${entry.keys}  ·  ${problem.text}"
            value.setTextColor(
                color(if (problem is UserDictProblem.Invalid || problem is UserDictProblem.Duplicate) MaterialR.attr.colorOnSurfaceVariant else MaterialR.attr.colorOnSurface),
            )
            detail.setTextColor(
                when (problem) {
                    is UserDictProblem.Invalid -> color(MaterialR.attr.colorError)
                    is UserDictProblem.SharedCode -> ContextCompat.getColor(this@UserDictActivity, R.color.user_dict_shared)
                    else -> color(MaterialR.attr.colorOnSurfaceVariant)
                },
            )
            handle.visibility = if (searching) View.GONE else View.VISIBLE
        }

        /** Held by its handle: an opaque surface, so the rows it passes over don't show through. */
        fun lift(lifted: Boolean) {
            itemView.background = if (lifted) {
                ColorDrawable(color(MaterialR.attr.colorSurfaceContainerHigh))
            } else {
                rippleBackground()
            }
        }
    }

    /**
     * Swipe either way to delete; drag by the handle to reorder, only among
     * the phrases and not while searching. The drop is saved once, when the
     * drag ends.
     */
    private inner class TouchCallback : ItemTouchHelper.Callback() {
        private var dragged = false

        override fun isLongPressDragEnabled(): Boolean = false

        override fun getMovementFlags(recyclerView: RecyclerView, viewHolder: RecyclerView.ViewHolder): Int {
            if (viewHolder !is PhraseHolder) return 0
            val drag = if (searching) 0 else ItemTouchHelper.UP or ItemTouchHelper.DOWN
            return makeMovementFlags(drag, ItemTouchHelper.START or ItemTouchHelper.END)
        }

        override fun canDropOver(
            recyclerView: RecyclerView,
            current: RecyclerView.ViewHolder,
            target: RecyclerView.ViewHolder,
        ): Boolean = target is PhraseHolder

        override fun onMove(
            recyclerView: RecyclerView,
            viewHolder: RecyclerView.ViewHolder,
            target: RecyclerView.ViewHolder,
        ): Boolean {
            val from = viewHolder.adapterPosition
            val to = target.adapterPosition
            if (from < 0 || to < 0) return false
            items.add(to, items.removeAt(from))
            adapter.notifyItemMoved(from, to)
            dragged = true
            return true
        }

        override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) {
            deletePhrase((viewHolder as PhraseHolder).row)
        }

        override fun onSelectedChanged(viewHolder: RecyclerView.ViewHolder?, actionState: Int) {
            super.onSelectedChanged(viewHolder, actionState)
            if (actionState == ItemTouchHelper.ACTION_STATE_DRAG) (viewHolder as? PhraseHolder)?.lift(true)
        }

        override fun clearView(recyclerView: RecyclerView, viewHolder: RecyclerView.ViewHolder) {
            super.clearView(recyclerView, viewHolder)
            (viewHolder as? PhraseHolder)?.lift(false)
            if (dragged) {
                dragged = false
                commitOrder()
            }
        }
    }
}
