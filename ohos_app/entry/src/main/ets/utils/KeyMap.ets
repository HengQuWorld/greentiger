import { KeyCode } from '@ohos.multimodalInput.keyCode';

export function keySymFromEvent(ev: KeyEvent, isChineseMode: boolean = false): number {
  let isShiftDown = false;
  if (typeof ev.getModifierKeyState === 'function') {
    try {
      isShiftDown = ev.getModifierKeyState(['shift']);
    } catch (e) {
      // ignore
    }
  }

  const text = typeof ev?.keyText === 'string' ? ev.keyText : '';
  if (text.length === 1) {
    const charCode = text.charCodeAt(0);
    // If the text is an uppercase letter but Shift is not pressed, it implies CapsLock is on.
    // If it's a lowercase letter and Shift is pressed, it implies CapsLock is on.
    // However, if keyText provides the EXACT character, we can just use it directly!
    // But sometimes keyText is just the physical label (e.g. 'A' even if 'a' is typed).
    // Let's only use it if it's not an alphabet or if we trust it.
    // Wait, in Android/Harmony, keyText is often just the unshifted label for punctuation.
    // Let's rely on keyCode mapping for predictability.
  }

  const code = ev?.keyCode ?? 0;
  
  if (code >= KeyCode.KEYCODE_A && code <= KeyCode.KEYCODE_Z) {
    const isCapsOn = ev.isCapsLockOn === true;
    const uppercase = isCapsOn !== isShiftDown; // XOR
    const base = uppercase ? 'A'.charCodeAt(0) : 'a'.charCodeAt(0);
    return base + (code - KeyCode.KEYCODE_A);
  }
  
  const shiftNums = [')', '!', '@', '#', '$', '%', '^', '&', '*', '('];
  if (code >= KeyCode.KEYCODE_0 && code <= KeyCode.KEYCODE_9) {
    if (isShiftDown) {
      return shiftNums[code - KeyCode.KEYCODE_0].charCodeAt(0);
    }
    return '0'.charCodeAt(0) + (code - KeyCode.KEYCODE_0);
  }
  
  // Android keycodes fallback
  if (code >= 29 && code <= 54) {
    const isCapsOn = ev.isCapsLockOn === true;
    const uppercase = isCapsOn !== isShiftDown;
    const base = uppercase ? 'A'.charCodeAt(0) : 'a'.charCodeAt(0);
    return base + (code - 29);
  }
  if (code >= 7 && code <= 16) {
    if (isShiftDown) {
      return shiftNums[code - 7].charCodeAt(0);
    }
    return '0'.charCodeAt(0) + (code - 7);
  }

  const isCapsOn = ev.isCapsLockOn === true;
  
  const mapPunc = (base: string, shift: string, zhBase?: string, zhShift?: string) => {
    if (isChineseMode && zhBase && zhShift) {
      const punc = isShiftDown ? zhShift : zhBase;
      return 0x01000000 | punc.codePointAt(0)!;
    }
    return isShiftDown ? shift.charCodeAt(0) : base.charCodeAt(0);
  };

  switch (code) {
    case KeyCode.KEYCODE_ENTER:
    case 66:
      return 0xff0d; // XK_Return
    case KeyCode.KEYCODE_DEL:
    case 67:
      return 0xff08; // XK_BackSpace
    case KeyCode.KEYCODE_FORWARD_DEL:
    case 112:
      return 0xffff; // XK_Delete
    case KeyCode.KEYCODE_ESCAPE:
    case 111:
      return 0xff1b; // XK_Escape
    case KeyCode.KEYCODE_DPAD_LEFT:
    case 21:
      return 0xff51; // XK_Left
    case KeyCode.KEYCODE_DPAD_UP:
    case 19:
      return 0xff52; // XK_Up
    case KeyCode.KEYCODE_DPAD_RIGHT:
    case 22:
      return 0xff53; // XK_Right
    case KeyCode.KEYCODE_DPAD_DOWN:
    case 20:
      return 0xff54; // XK_Down
    case KeyCode.KEYCODE_TAB:
    case 61:
      return 0xff09; // XK_Tab
    case KeyCode.KEYCODE_SPACE:
    case 62:
      return 0x20;   // XK_space
    case KeyCode.KEYCODE_SHIFT_LEFT:
    case 59:
      return 0xffe1; // XK_Shift_L
    case KeyCode.KEYCODE_SHIFT_RIGHT:
    case 60:
      return 0xffe2; // XK_Shift_R
    case KeyCode.KEYCODE_CTRL_LEFT:
    case 113:
      return 0xffe3; // XK_Control_L
    case KeyCode.KEYCODE_CTRL_RIGHT:
    case 114:
      return 0xffe4; // XK_Control_R
    case KeyCode.KEYCODE_ALT_LEFT:
    case 57:
      return 0xffe9; // XK_Alt_L
    case KeyCode.KEYCODE_ALT_RIGHT:
    case 58:
      return 0xffea; // XK_Alt_R
    case KeyCode.KEYCODE_META_LEFT:
    case 117:
      return 0xffe7; // XK_Meta_L
    case KeyCode.KEYCODE_META_RIGHT:
    case 118:
      return 0xffe8; // XK_Meta_R

    // Punctuation mapping for both HarmonyOS KeyCode and Android fallbacks
    case KeyCode.KEYCODE_COMMA:
    case 55:
      return mapPunc(',', '<', '，', '《'); // comma
    case KeyCode.KEYCODE_PERIOD:
    case 56:
      return mapPunc('.', '>', '。', '》'); // period
    case KeyCode.KEYCODE_MINUS:
    case 69:
      return mapPunc('-', '_', '-', '——'); // minus
    case KeyCode.KEYCODE_EQUALS:
    case 70:
      return mapPunc('=', '+', '=', '+'); // equal
    case KeyCode.KEYCODE_LEFT_BRACKET:
    case 71:
      return mapPunc('[', '{', '【', '｛'); // left bracket
    case KeyCode.KEYCODE_RIGHT_BRACKET:
    case 72:
      return mapPunc(']', '}', '】', '｝'); // right bracket
    case KeyCode.KEYCODE_BACKSLASH:
    case 73:
      return mapPunc('\\', '|', '、', '|'); // backslash
    case KeyCode.KEYCODE_SEMICOLON:
    case 74:
      return mapPunc(';', ':', '；', '：'); // semicolon
    case KeyCode.KEYCODE_APOSTROPHE:
    case 75:
      return mapPunc('\'', '"', '’', '”'); // apostrophe
    case KeyCode.KEYCODE_SLASH:
    case 76:
      return mapPunc('/', '?', '/', '？'); // slash
    case KeyCode.KEYCODE_GRAVE:
    case 68:
      return mapPunc('`', '~', '·', '~'); // grave

    // Additional extended keys
    case KeyCode.KEYCODE_HOME:
    case KeyCode.KEYCODE_MOVE_HOME:
      return 0xff50; // XK_Home
    case KeyCode.KEYCODE_MOVE_END:
      return 0xff57; // XK_End
    case KeyCode.KEYCODE_PAGE_UP:
      return 0xff55; // XK_Page_Up
    case KeyCode.KEYCODE_PAGE_DOWN:
      return 0xff56; // XK_Page_Down
    case KeyCode.KEYCODE_INSERT:
      return 0xff63; // XK_Insert
    case KeyCode.KEYCODE_F1:
      return 0xffbe; // XK_F1
    case KeyCode.KEYCODE_F2:
      return 0xffbf; // XK_F2
    case KeyCode.KEYCODE_F3:
      return 0xffc0; // XK_F3
    case KeyCode.KEYCODE_F4:
      return 0xffc1; // XK_F4
    case KeyCode.KEYCODE_F5:
      return 0xffc2; // XK_F5
    case KeyCode.KEYCODE_F6:
      return 0xffc3; // XK_F6
    case KeyCode.KEYCODE_F7:
      return 0xffc4; // XK_F7
    case KeyCode.KEYCODE_F8:
      return 0xffc5; // XK_F8
    case KeyCode.KEYCODE_F9:
      return 0xffc6; // XK_F9
    case KeyCode.KEYCODE_F10:
      return 0xffc7; // XK_F10
    case KeyCode.KEYCODE_F11:
      return 0xffc8; // XK_F11
    case KeyCode.KEYCODE_F12:
      return 0xffc9; // XK_F12
    case KeyCode.KEYCODE_CAPS_LOCK:
      return 0xffe5; // XK_Caps_Lock
    case KeyCode.KEYCODE_SCROLL_LOCK:
      return 0xff14; // XK_Scroll_Lock
    case KeyCode.KEYCODE_NUM_LOCK:
      return 0xff7f; // XK_Num_Lock
    case KeyCode.KEYCODE_NUMPAD_0:
      return 0xffb0; // XK_KP_0
    case KeyCode.KEYCODE_NUMPAD_1:
      return 0xffb1; // XK_KP_1
    case KeyCode.KEYCODE_NUMPAD_2:
      return 0xffb2; // XK_KP_2
    case KeyCode.KEYCODE_NUMPAD_3:
      return 0xffb3; // XK_KP_3
    case KeyCode.KEYCODE_NUMPAD_4:
      return 0xffb4; // XK_KP_4
    case KeyCode.KEYCODE_NUMPAD_5:
      return 0xffb5; // XK_KP_5
    case KeyCode.KEYCODE_NUMPAD_6:
      return 0xffb6; // XK_KP_6
    case KeyCode.KEYCODE_NUMPAD_7:
      return 0xffb7; // XK_KP_7
    case KeyCode.KEYCODE_NUMPAD_8:
      return 0xffb8; // XK_KP_8
    case KeyCode.KEYCODE_NUMPAD_9:
      return 0xffb9; // XK_KP_9
    case KeyCode.KEYCODE_NUMPAD_DIVIDE:
      return 0xffaf; // XK_KP_Divide
    case KeyCode.KEYCODE_NUMPAD_MULTIPLY:
      return 0xffaa; // XK_KP_Multiply
    case KeyCode.KEYCODE_NUMPAD_SUBTRACT:
      return 0xffad; // XK_KP_Subtract
    case KeyCode.KEYCODE_NUMPAD_ADD:
      return 0xffab; // XK_KP_Add
    case KeyCode.KEYCODE_NUMPAD_DOT:
      return 0xffae; // XK_KP_Decimal
    case KeyCode.KEYCODE_NUMPAD_ENTER:
      return 0xff8d; // XK_KP_Enter
    case KeyCode.KEYCODE_SYSRQ:
      return 0xff15; // XK_Sys_Req
    case KeyCode.KEYCODE_BREAK:
      return 0xff6b; // XK_Break

    default:
      return 0;
  }
}
