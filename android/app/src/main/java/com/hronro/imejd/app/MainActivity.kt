// Container-app landing screen — port of ios/App/RootViewController.swift.
// Explains how to enable the keyboard and offers a field to try it.
package com.hronro.imejd.app

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.hronro.imejd.R

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
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
        val enableBtn = Button(this).apply {
            text = getString(R.string.enable_in_settings)
            setOnClickListener { startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) }
        }
        val switchBtn = Button(this).apply {
            text = getString(R.string.switch_ime)
            setOnClickListener {
                (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showInputMethodPicker()
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
        root.addView(tryField, lp)

        setContentView(root)
    }
}
