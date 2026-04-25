package com.hengqutiandi.vncviewer

import android.app.Activity
import android.app.ActivityManager
import android.view.KeyEvent

@Suppress("DEPRECATION")
fun applyTaskLabel(activity: Activity?, label: String) {
    if (activity == null || label.isBlank()) return
    activity.title = label
    try {
        activity.setTaskDescription(ActivityManager.TaskDescription(label))
    } catch (_: Throwable) {
    }
}

fun keySymFromAndroidKey(code: Int, shiftDown: Boolean, capsOn: Boolean): Int {
    if (code in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z) {
        val uppercase = capsOn.xor(shiftDown)
        val base = if (uppercase) 'A'.code else 'a'.code
        return base + (code - KeyEvent.KEYCODE_A)
    }
    if (code in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9) {
        val shifted = listOf(')', '!', '@', '#', '$', '%', '^', '&', '*', '(')
        return if (shiftDown) shifted[code - KeyEvent.KEYCODE_0].code else '0'.code + (code - KeyEvent.KEYCODE_0)
    }
    return when (code) {
        KeyEvent.KEYCODE_ENTER -> 0xff0d
        KeyEvent.KEYCODE_DEL -> 0xff08
        KeyEvent.KEYCODE_FORWARD_DEL -> 0xffff
        KeyEvent.KEYCODE_ESCAPE -> 0xff1b
        KeyEvent.KEYCODE_BACK -> 0xff1b
        KeyEvent.KEYCODE_DPAD_LEFT -> 0xff51
        KeyEvent.KEYCODE_DPAD_UP -> 0xff52
        KeyEvent.KEYCODE_DPAD_RIGHT -> 0xff53
        KeyEvent.KEYCODE_DPAD_DOWN -> 0xff54
        KeyEvent.KEYCODE_TAB -> 0xff09
        KeyEvent.KEYCODE_SPACE -> 0x20
        KeyEvent.KEYCODE_SHIFT_LEFT -> 0xffe1
        KeyEvent.KEYCODE_SHIFT_RIGHT -> 0xffe2
        KeyEvent.KEYCODE_CTRL_LEFT -> 0xffe3
        KeyEvent.KEYCODE_CTRL_RIGHT -> 0xffe4
        KeyEvent.KEYCODE_ALT_LEFT -> 0xffe9
        KeyEvent.KEYCODE_ALT_RIGHT -> 0xffea
        KeyEvent.KEYCODE_META_LEFT -> 0xffe7
        KeyEvent.KEYCODE_META_RIGHT -> 0xffe8
        KeyEvent.KEYCODE_COMMA -> if (shiftDown) '<'.code else ','.code
        KeyEvent.KEYCODE_PERIOD -> if (shiftDown) '>'.code else '.'.code
        KeyEvent.KEYCODE_MINUS -> if (shiftDown) '_'.code else '-'.code
        KeyEvent.KEYCODE_EQUALS -> if (shiftDown) '+'.code else '='.code
        KeyEvent.KEYCODE_LEFT_BRACKET -> if (shiftDown) '{'.code else '['.code
        KeyEvent.KEYCODE_RIGHT_BRACKET -> if (shiftDown) '}'.code else ']'.code
        KeyEvent.KEYCODE_BACKSLASH -> if (shiftDown) '|'.code else '\\'.code
        KeyEvent.KEYCODE_SEMICOLON -> if (shiftDown) ':'.code else ';'.code
        KeyEvent.KEYCODE_APOSTROPHE -> if (shiftDown) '"'.code else '\''.code
        KeyEvent.KEYCODE_SLASH -> if (shiftDown) '?'.code else '/'.code
        KeyEvent.KEYCODE_GRAVE -> if (shiftDown) '~'.code else '`'.code
        KeyEvent.KEYCODE_MOVE_HOME -> 0xff50
        KeyEvent.KEYCODE_MOVE_END -> 0xff57
        KeyEvent.KEYCODE_PAGE_UP -> 0xff55
        KeyEvent.KEYCODE_PAGE_DOWN -> 0xff56
        KeyEvent.KEYCODE_INSERT -> 0xff63
        KeyEvent.KEYCODE_CAPS_LOCK -> 0xffe5
        KeyEvent.KEYCODE_SCROLL_LOCK -> 0xff14
        KeyEvent.KEYCODE_NUM_LOCK -> 0xff7f
        KeyEvent.KEYCODE_DPAD_CENTER -> 0xff0d
        KeyEvent.KEYCODE_SYSRQ -> 0xff15
        KeyEvent.KEYCODE_BREAK -> 0xff6b
        KeyEvent.KEYCODE_NUMPAD_0 -> 0xffb0
        KeyEvent.KEYCODE_NUMPAD_1 -> 0xffb1
        KeyEvent.KEYCODE_NUMPAD_2 -> 0xffb2
        KeyEvent.KEYCODE_NUMPAD_3 -> 0xffb3
        KeyEvent.KEYCODE_NUMPAD_4 -> 0xffb4
        KeyEvent.KEYCODE_NUMPAD_5 -> 0xffb5
        KeyEvent.KEYCODE_NUMPAD_6 -> 0xffb6
        KeyEvent.KEYCODE_NUMPAD_7 -> 0xffb7
        KeyEvent.KEYCODE_NUMPAD_8 -> 0xffb8
        KeyEvent.KEYCODE_NUMPAD_9 -> 0xffb9
        KeyEvent.KEYCODE_NUMPAD_DIVIDE -> 0xffaf
        KeyEvent.KEYCODE_NUMPAD_MULTIPLY -> 0xffaa
        KeyEvent.KEYCODE_NUMPAD_SUBTRACT -> 0xffad
        KeyEvent.KEYCODE_NUMPAD_ADD -> 0xffab
        KeyEvent.KEYCODE_NUMPAD_DOT -> 0xffae
        KeyEvent.KEYCODE_NUMPAD_EQUALS -> 0xffbd
        KeyEvent.KEYCODE_NUMPAD_ENTER -> 0xff8d
        KeyEvent.KEYCODE_F1 -> 0xffbe
        KeyEvent.KEYCODE_F2 -> 0xffbf
        KeyEvent.KEYCODE_F3 -> 0xffc0
        KeyEvent.KEYCODE_F4 -> 0xffc1
        KeyEvent.KEYCODE_F5 -> 0xffc2
        KeyEvent.KEYCODE_F6 -> 0xffc3
        KeyEvent.KEYCODE_F7 -> 0xffc4
        KeyEvent.KEYCODE_F8 -> 0xffc5
        KeyEvent.KEYCODE_F9 -> 0xffc6
        KeyEvent.KEYCODE_F10 -> 0xffc7
        KeyEvent.KEYCODE_F11 -> 0xffc8
        KeyEvent.KEYCODE_F12 -> 0xffc9
        else -> 0
    }
}

data class TextDelta(val deletedCount: Int, val insertedText: String)

private fun String.toCodePointList(): List<Int> {
    val codePoints = ArrayList<Int>(length)
    var index = 0
    while (index < length) {
        val codePoint = codePointAt(index)
        codePoints.add(codePoint)
        index += Character.charCount(codePoint)
    }
    return codePoints
}

fun buildTextDelta(previous: String, next: String): TextDelta {
    val previousChars = previous.toCodePointList()
    val nextChars = next.toCodePointList()
    var prefix = 0
    while (prefix < previousChars.size && prefix < nextChars.size && previousChars[prefix] == nextChars[prefix]) {
        prefix++
    }
    var suffix = 0
    while (
        suffix < previousChars.size - prefix &&
        suffix < nextChars.size - prefix &&
        previousChars[previousChars.size - 1 - suffix] == nextChars[nextChars.size - 1 - suffix]
    ) {
        suffix++
    }
    val insertedText = nextChars
        .subList(prefix, nextChars.size - suffix)
        .joinToString(separator = "") { String(Character.toChars(it)) }
    return TextDelta(
        deletedCount = previousChars.size - prefix - suffix,
        insertedText = insertedText
    )
}

interface KeySender {
    fun sendKey(keysym: Int, down: Boolean)
}

fun sendRemoteBackspace(sender: KeySender, count: Int) {
    repeat(maxOf(0, count)) {
        sender.sendKey(0xff08, true)
        sender.sendKey(0xff08, false)
    }
}

fun sendCommittedText(sender: KeySender, text: String) {
    var index = 0
    while (index < text.length) {
        val codePoint = text.codePointAt(index)
        val keysym = when {
            codePoint == '\n'.code -> 0xff0d
            codePoint in 0x20..0x7E -> codePoint
            codePoint in 0xA0..0xFF -> codePoint
            else -> 0x01000000 or codePoint
        }
        sender.sendKey(keysym, true)
        sender.sendKey(keysym, false)
        index += Character.charCount(codePoint)
    }
}
