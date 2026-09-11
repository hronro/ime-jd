// Container-app landing screen — port of ios/App/RootViewController.swift.
// Explains how to enable the keyboard, offers a field to try it, holds the
// keyboard's few settings, and — in self-updating builds — is where an
// update is installed from.
package com.hronro.imejd.app

import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.R as MaterialR
import com.google.android.material.button.MaterialButton
import com.google.android.material.color.DynamicColors
import com.google.android.material.color.MaterialColors
import com.google.android.material.materialswitch.MaterialSwitch
import com.hronro.imejd.BuildConfig
import com.hronro.imejd.R
import com.hronro.imejd.ui.KeyFeedback
import com.hronro.imejd.update.AvailableUpdate
import com.hronro.imejd.update.UpdateChecker
import com.hronro.imejd.update.UpdateInstaller

class MainActivity : AppCompatActivity() {

    /** The update UI — only in builds that carry the updater (BuildConfig.AUTO_UPDATE). */
    private var updates: UpdateSection? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Material You: recolor from the wallpaper palette on Android 12+.
        DynamicColors.applyToActivityIfAvailable(this)
        super.onCreate(savedInstanceState)

        val density = resources.displayMetrics.density
        val pad = (24 * density).toInt()
        val gap = (16 * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }

        val title = TextView(this).apply {
            text = getString(R.string.app_name)
            textSize = 28f
        }
        val updates = if (BuildConfig.AUTO_UPDATE) UpdateSection(density) else null
        this.updates = updates
        val steps = TextView(this).apply {
            // The guide's closing note says what the build does with the
            // network: nothing at all, or the daily update check.
            val note = if (updates != null) R.string.enable_steps_note_updates else R.string.enable_steps_note_offline
            text = getString(R.string.enable_steps) + "\n\n" + getString(note)
            textSize = 16f
        }
        // M3 hierarchy: the one action a new user must take is filled; the
        // secondary actions are tonal.
        val enableBtn = MaterialButton(this).apply {
            text = getString(R.string.enable_in_settings)
            setOnClickListener { startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) }
        }
        val switchBtn = tonalButton().apply {
            text = getString(R.string.switch_ime)
            setOnClickListener {
                (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showInputMethodPicker()
            }
        }
        val previewBtn = tonalButton().apply {
            text = getString(R.string.preview_keyboard)
            setOnClickListener {
                startActivity(Intent(this@MainActivity, KeyboardPreviewActivity::class.java))
            }
        }
        // Key-press feedback toggles, the ones the built-in keyboards also
        // offer (Gboard/AOSP; the iOS keyboard always clicks — extensions
        // have no settings surface there). They write the prefs KeyFeedback
        // re-reads on every press, so a flip applies immediately to the
        // try-field below, the preview screen, and the real IME.
        val soundSwitch = MaterialSwitch(this).apply {
            text = getString(R.string.key_sound)
            textSize = 16f
            isChecked = KeyFeedback.isSoundEnabled(context)
            setOnCheckedChangeListener { _, on -> KeyFeedback.setSoundEnabled(context, on) }
        }
        val vibrationSwitch = MaterialSwitch(this).apply {
            text = getString(R.string.key_vibration)
            textSize = 16f
            isChecked = KeyFeedback.isVibrationEnabled(context)
            setOnCheckedChangeListener { _, on -> KeyFeedback.setVibrationEnabled(context, on) }
        }
        val tryField = EditText(this).apply {
            hint = getString(R.string.try_hint)
        }

        val lp = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = gap }

        root.addView(title)
        // The update card sits right under the title, GONE until the feed
        // has reported a release newer than this build.
        updates?.let { root.addView(it.card, lp) }
        root.addView(steps, lp)
        root.addView(enableBtn, lp)
        root.addView(switchBtn, lp)
        root.addView(previewBtn, lp)
        root.addView(soundSwitch, lp)
        root.addView(vibrationSwitch, lp)
        updates?.let {
            root.addView(it.autoCheckSwitch, lp)
            root.addView(it.versionStatus, lp)
            root.addView(it.checkButton, LinearLayout.LayoutParams(lp).apply { topMargin = gap / 2 })
        }
        root.addView(tryField, lp)

        // The switch rows tipped the column past short screens (landscape,
        // small phones) — let it scroll instead of clipping the try-field.
        setContentView(ScrollView(this).apply {
            isFillViewport = true
            addView(root)
        })

        // Edge-to-edge (enforced at targetSdk 35): keep the fixed padding and
        // add the system-bar/cutout insets on top of it.
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
            )
            v.setPadding(pad + bars.left, pad + bars.top, pad + bars.right, pad + bars.bottom)
            insets
        }

        updates?.start()

        // QA fast-path (the iOS -preview launch arg's counterpart): forward to
        // the embedded preview, so one adb command reaches that non-exported
        // screen through this exported launcher — see KeyboardPreviewActivity.
        if (intent.getBooleanExtra(KeyboardPreviewActivity.EXTRA_PREVIEW, false)) {
            startActivity(Intent(this, KeyboardPreviewActivity::class.java).putExtras(intent))
        }
    }

    override fun onResume() {
        super.onResume()
        // Back from Settings (install permission) or from the installer.
        updates?.render()
    }

    // Widget.Material3.Button.TonalButton is only a style resource in material
    // 1.12 (the materialButtonTonalStyle theme attr arrived in 1.13, which
    // costs ~1 MB more APK — see build.gradle.kts), and programmatic buttons
    // can't take a style resource. The tonal style is just the filled default
    // with container/content colors swapped, and these buttons are never
    // disabled, so two theme colors + the press ripple reproduce it exactly.
    private fun tonalButton(): MaterialButton = MaterialButton(this).apply {
        val container = MaterialColors.getColor(this, MaterialR.attr.colorSecondaryContainer)
        val content = MaterialColors.getColor(this, MaterialR.attr.colorOnSecondaryContainer)
        backgroundTintList = ColorStateList.valueOf(container)
        setTextColor(content)
        rippleColor = ColorStateList.valueOf(content).withAlpha(31) // 12% press overlay
    }

    /**
     * Everything the updater adds to this screen: the update card, the
     * auto-check switch, and the version line with its check button. Built
     * only for self-updating builds, so a store build never touches update/.
     */
    private inner class UpdateSection(density: Float) {
        val card: LinearLayout
        val autoCheckSwitch: MaterialSwitch
        val versionStatus: TextView
        val checkButton: MaterialButton
        private val cardTitle: TextView
        private val cardBody: TextView
        private val installButton: MaterialButton
        /** While a download/install runs the body shows its progress; don't overwrite it. */
        private var installing = false

        init {
            val activity = this@MainActivity
            val inner = (16 * density).toInt()
            card = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(inner, inner, inner, inner)
                visibility = View.GONE
            }
            card.background = GradientDrawable().apply {
                cornerRadius = 16 * density
                setColor(MaterialColors.getColor(card, MaterialR.attr.colorPrimaryContainer))
            }
            val onContainer = MaterialColors.getColor(card, MaterialR.attr.colorOnPrimaryContainer)
            cardTitle = TextView(activity).apply {
                textSize = 18f
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(onContainer)
            }
            cardBody = TextView(activity).apply {
                textSize = 14f
                setTextColor(onContainer)
            }
            installButton = MaterialButton(activity).apply {
                text = getString(R.string.update_install)
                setOnClickListener { UpdateChecker.availableUpdate(context)?.let { install(it) } }
            }
            val notesButton = tonalButton().apply {
                text = getString(R.string.update_release_notes)
                setOnClickListener { UpdateChecker.availableUpdate(context)?.let { openPage(it.pageUrl) } }
            }
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = (8 * density).toInt() }
            card.addView(cardTitle)
            card.addView(cardBody, lp)
            card.addView(installButton, lp)
            card.addView(notesButton, lp)

            // The daily release-feed check (UpdateChecker) — the app's only
            // use of the network, so it gets a switch next to the other settings.
            autoCheckSwitch = MaterialSwitch(activity).apply {
                text = getString(R.string.update_auto_check)
                textSize = 16f
                isChecked = UpdateChecker.isAutoCheckEnabled(context)
                setOnCheckedChangeListener { _, on -> UpdateChecker.setAutoCheckEnabled(context, on) }
            }
            versionStatus = TextView(activity).apply { textSize = 14f }
            checkButton = tonalButton().apply {
                text = getString(R.string.update_check)
                setOnClickListener { checkNow() }
            }
        }

        /** Opening the app is the other daily trigger besides the keyboard showing. */
        fun start() {
            UpdateChecker.checkIfDue(this@MainActivity) { render() }
            render()
        }

        /** Reflect UpdateChecker's recorded state: the version line and the card. */
        fun render() {
            val activity = this@MainActivity
            val current = UpdateChecker.currentVersion(activity)?.toString() ?: "0.0.0"
            if (checkButton.isEnabled) {
                versionStatus.text = getString(R.string.update_current_version, current)
            }
            val update = UpdateChecker.availableUpdate(activity)
            if (update == null) {
                card.visibility = View.GONE
                return
            }
            card.visibility = View.VISIBLE
            cardTitle.text = getString(R.string.update_available_title, update.tag)
            if (!installing) {
                cardBody.text = getString(
                    if (update.apk != null) R.string.update_available_body else R.string.update_available_no_apk,
                )
            }
            installButton.text = getString(if (update.apk != null) R.string.update_install else R.string.update_release_notes)
            // Seeing the card here is seeing the notice; the keyboard stops announcing it.
            UpdateChecker.markNoticeSeen(activity)
        }

        private fun checkNow() {
            val activity = this@MainActivity
            checkButton.isEnabled = false
            versionStatus.text = getString(R.string.update_checking)
            UpdateChecker.checkNow(activity) { result ->
                checkButton.isEnabled = true
                // Card first (it resets the version line), then the outcome.
                render()
                val current = UpdateChecker.currentVersion(activity)?.toString() ?: "0.0.0"
                val line = getString(R.string.update_current_version, current)
                versionStatus.text = when (result) {
                    is UpdateChecker.Result.UpToDate -> "$line · ${getString(R.string.update_up_to_date)}"
                    is UpdateChecker.Result.Available -> line
                    is UpdateChecker.Result.Failed -> "$line\n${getString(R.string.update_check_failed, result.reason)}"
                }
            }
        }

        private fun install(update: AvailableUpdate) {
            val activity = this@MainActivity
            val apk = update.apk
            if (apk == null) {
                openPage(update.pageUrl)
                return
            }
            if (!UpdateInstaller.canRequestInstalls(activity)) {
                // One-time system grant; onResume re-renders when the user is back.
                cardBody.text = getString(R.string.update_need_permission)
                startActivity(UpdateInstaller.unknownSourcesSettingsIntent(activity))
                return
            }
            installing = true
            installButton.isEnabled = false
            UpdateInstaller.downloadAndInstall(activity, apk) { progress ->
                when (progress) {
                    UpdateInstaller.Progress.Downloading -> cardBody.text = getString(R.string.update_downloading)
                    UpdateInstaller.Progress.Verifying -> cardBody.text = getString(R.string.update_verifying)
                    UpdateInstaller.Progress.Committed -> {
                        cardBody.text = getString(R.string.update_committed)
                        installing = false
                        installButton.isEnabled = true
                    }
                    is UpdateInstaller.Progress.Failed -> {
                        cardBody.text = getString(R.string.update_failed, progress.reason)
                        installing = false
                        installButton.isEnabled = true
                    }
                }
            }
        }

        private fun openPage(url: String) {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        }
    }
}
