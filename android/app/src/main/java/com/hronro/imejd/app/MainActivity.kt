// Container-app landing screen — port of ios/App/RootViewController.swift.
// Explains how to enable the keyboard and offers a field to try it.
package com.hronro.imejd.app

import android.content.Intent
import android.content.res.ColorStateList
import android.os.Bundle
import android.provider.Settings
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.R as MaterialR
import com.google.android.material.button.MaterialButton
import com.google.android.material.color.DynamicColors
import com.google.android.material.color.MaterialColors
import com.hronro.imejd.R

class MainActivity : AppCompatActivity() {
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
        val steps = TextView(this).apply {
            text = getString(R.string.enable_steps)
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
        val tryField = EditText(this).apply {
            hint = getString(R.string.try_hint)
        }

        val lp = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = gap }

        root.addView(title)
        root.addView(steps, lp)
        root.addView(enableBtn, lp)
        root.addView(switchBtn, lp)
        root.addView(previewBtn, lp)
        root.addView(tryField, lp)

        setContentView(root)

        // Edge-to-edge (enforced at targetSdk 35): keep the fixed padding and
        // add the system-bar/cutout insets on top of it.
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
            )
            v.setPadding(pad + bars.left, pad + bars.top, pad + bars.right, pad + bars.bottom)
            insets
        }

        // QA fast-path (the iOS -preview launch arg's counterpart): forward to
        // the embedded preview, so one adb command reaches that non-exported
        // screen through this exported launcher — see KeyboardPreviewActivity.
        if (intent.getBooleanExtra(KeyboardPreviewActivity.EXTRA_PREVIEW, false)) {
            startActivity(Intent(this, KeyboardPreviewActivity::class.java).putExtras(intent))
        }
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
}
