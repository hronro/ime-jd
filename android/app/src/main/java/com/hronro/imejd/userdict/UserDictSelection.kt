// What the keyboard types from, by the user's two switches — 启用用户自造词
// and, while it is on, 只用用户自造词 — the counterpart of the Swift
// frontends' UserDictSelection.
package com.hronro.imejd.userdict

import com.hronro.jd.Dict
import com.hronro.jd.Engine
import com.hronro.jd.UserDict

sealed interface UserDictSelection {
    /** The built-in dictionary, merged with the user's phrases when they are on and load. */
    data class BuiltIn(val dict: UserDict?) : UserDictSelection

    /** The user's phrases alone, on the empty dictionary ([emptyDict]). */
    data class UserOnly(val dict: UserDict) : UserDictSelection

    /**
     * The user's phrases alone were asked for and cannot be had, for the
     * reason [why] gives: the keyboard says so and keys type themselves.
     * Never the built-in dictionary instead.
     */
    data class Unavailable(val why: String) : UserDictSelection

    /** An engine on this; null when it is [Unavailable], or a user-only dictionary is refused. */
    fun makeEngine(): Engine? = when (this) {
        is BuiltIn -> Engine(dict)
        is UserOnly -> try {
            Engine(emptyDict, dict)
        } catch (_: IllegalStateException) {
            null
        }
        is Unavailable -> null
    }

    companion object {
        /** The empty dictionary, built once per process: every empty dictionary is the same one. */
        val emptyDict: Dict by lazy { Dict.empty() }
    }
}
