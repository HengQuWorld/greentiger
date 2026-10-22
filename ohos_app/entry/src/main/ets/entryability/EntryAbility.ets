import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import { BusinessError } from '@ohos.base';
import { Configuration } from '@kit.AbilityKit';
import { DARK_MODE_STORAGE_KEY, DarkColors, LightColors, syncSystemColorMode } from '../utils/ThemeConstants';

interface WindowLike {
  setWindowBackgroundColor?: (color: string) => void;
}

export default class EntryAbility extends UIAbility {
  private mainWindow: Object | null = null;

  onCreate(): void {
    // The ability keeps the default COLOR_MODE_NOT_SET, so the system drives
    // the window decoration and the resources under resources/dark. Only the
    // rendered colors need to be told which way the system went.
    const isDark: boolean = syncSystemColorMode(this.context.config.colorMode);
    console.info(`EntryAbility system color mode: ${this.context.config.colorMode}, dark=${isDark}`);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.requestClipboardPermission();
    try {
      this.mainWindow = windowStage.getMainWindowSync();
      this.applyWindowBackground();
    } catch (e) {
    }
    try {
      windowStage.loadContent('pages/Index', () => {
        // Paint the window surface once the page is up so no white frame is
        // left behind the content while it renders.
        this.applyWindowBackground();
      });
    } catch (e) {
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    const isDark: boolean = syncSystemColorMode(newConfig.colorMode);
    console.info(`EntryAbility color mode changed: ${newConfig.colorMode}, dark=${isDark}`);
    this.applyWindowBackground();
  }

  /**
   * Paints the window surface in the current theme background. The window
   * decoration is drawn by the system and follows the system setting on its own.
   */
  private applyWindowBackground(): void {
    const dark: boolean = AppStorage.get<boolean>(DARK_MODE_STORAGE_KEY) === true;
    const background: string = (dark ? DarkColors : LightColors).surface;
    try {
      const win = this.mainWindow as WindowLike;
      win?.setWindowBackgroundColor?.(background);
    } catch (e) {
    }
  }

  private async requestClipboardPermission(): Promise<void> {
    const permissions: Array<Permissions> = ['ohos.permission.READ_PASTEBOARD'];
    const atManager = abilityAccessCtrl.createAtManager();
    try {
      await atManager.requestPermissionsFromUser(this.context, permissions);
    } catch (err) {
      const error = err as BusinessError;
      console.error(`requestPermissionsFromUser failed, code: ${error.code}, message: ${error.message}`);
    }
  }
}
