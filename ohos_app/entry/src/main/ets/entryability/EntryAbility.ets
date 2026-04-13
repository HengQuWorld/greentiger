import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import { BusinessError } from '@ohos.base';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.requestClipboardPermission();
    try {
      windowStage.loadContent('pages/Index');
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
