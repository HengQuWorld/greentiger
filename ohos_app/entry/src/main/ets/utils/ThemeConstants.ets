import { ConfigurationConstant } from '@kit.AbilityKit';

/**
 * Semantic color tokens for 翠虎.
 *
 * Every screen reads colors from one of the two palettes below, so a new theme
 * (dark or light) never needs page-level edits. The names match the tokens the
 * pages used before dark mode existed; only their values differ per palette.
 */
export interface ThemeColors {
  textPrimary: string;
  textMuted: string;
  textSecondary: string;
  textTertiary: string;
  surface: string;
  surfaceAlt: string;
  surfacePressed: string;
  border: string;
  primary: string;
  primaryFg: string;
  primarySoft: string;
  primaryPressed: string;
  primaryOutline: string;
  ink: string;
  onInk: string;
  error: string;
  errorSoft: string;
  // 面板内"破坏性"次级按钮（白底红字 + 红描边），与 error（正文错误色）区分
  destructive: string;
  destructiveBorder: string;
  warning: string;
  warningStrong: string;
  success: string;
  focusOutline: string;
  overlayPanel: string;
  toggleTrackOn: string;
  toggleTrackOff: string;
  toggleKnob: string;
  statusBarContent: string;
}

export const LightColors: ThemeColors = {
  textPrimary: '#1c1917',
  textMuted: '#292524',
  textSecondary: '#57534e',
  textTertiary: '#78716c',
  surface: '#fdfbf7',
  surfaceAlt: '#ffffff',
  surfacePressed: 'rgba(12,20,22,0.06)',
  border: '#e7e5e4',
  primary: '#2c4f54',
  primaryFg: '#ffffff',
  primarySoft: 'rgba(44,79,84,0.12)',
  primaryPressed: 'rgba(44,79,84,0.88)',
  primaryOutline: 'rgba(44,79,84,0.22)',
  ink: '#0c1416',
  onInk: '#e7e5e4',
  error: '#b42318',
  errorSoft: 'rgba(180,35,24,0.12)',
  destructive: '#ef4444',
  destructiveBorder: 'rgba(239,68,68,0.55)',
  warning: '#d97706',
  warningStrong: '#d99a2b',
  success: '#15803d',
  focusOutline: '#3b82f6',
  overlayPanel: 'rgba(12,20,22,0.78)',
  toggleTrackOn: '#2c4f54',
  toggleTrackOff: '#e7e5e4',
  toggleKnob: '#ffffff',
  statusBarContent: '#000000'
};

/**
 * Dark palette. The hue family stays the same (warm neutral + deep teal), only
 * the lightness flips: surfaces go near-black, the primary becomes a light teal
 * so it keeps enough contrast on those surfaces, and every foreground token is
 * lightened instead of invented anew.
 */
export const DarkColors: ThemeColors = {
  textPrimary: '#eceae6',
  textMuted: '#d8d4cd',
  textSecondary: '#a8a29c',
  textTertiary: '#8b857e',
  surface: '#0d1416',
  surfaceAlt: '#141d20',
  surfacePressed: 'rgba(255,255,255,0.08)',
  border: '#263236',
  primary: '#6fb7b0',
  primaryFg: '#0b1315',
  primarySoft: 'rgba(111,183,176,0.16)',
  primaryPressed: 'rgba(147,206,200,0.92)',
  primaryOutline: 'rgba(111,183,176,0.34)',
  ink: '#080d0f',
  onInk: '#e7e5e4',
  error: '#f2756a',
  errorSoft: 'rgba(242,117,106,0.16)',
  destructive: '#f2756a',
  destructiveBorder: 'rgba(242,117,106,0.55)',
  warning: '#f2b544',
  warningStrong: '#eeb45c',
  success: '#4ade80',
  focusOutline: '#7aa7ff',
  overlayPanel: 'rgba(10,16,18,0.86)',
  toggleTrackOn: '#6fb7b0',
  toggleTrackOff: '#33403f',
  toggleKnob: '#f5f4f1',
  statusBarContent: '#eceae6'
};

export const DARK_MODE_STORAGE_KEY: string = '__app_is_dark_mode__';

export function isDarkColorMode(colorMode: ConfigurationConstant.ColorMode | undefined): boolean {
  return colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
}

/**
 * Mirrors the system dark/light setting into AppStorage so every page reacts
 * to it. The abilities keep the default COLOR_MODE_NOT_SET, which is what lets
 * the system drive both the window decoration and the resources under
 * resources/dark; only the rendered colors have to learn which way it went.
 */
export function syncSystemColorMode(colorMode: ConfigurationConstant.ColorMode | undefined): boolean {
  const isDark: boolean = isDarkColorMode(colorMode);
  AppStorage.setOrCreate<boolean>(DARK_MODE_STORAGE_KEY, isDark);
  return isDark;
}
