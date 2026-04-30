import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import { viewerMultiWindowStore } from '../utils/ViewerMultiWindow';
import { DisplayLaunchParams } from '../pages/DisplayPage';

interface WantLike {
  parameters?: Record<string, Object>;
}

interface ContextWithWant {
  getWant?: () => WantLike;
  want?: WantLike;
}

function paramStr(params: Record<string, Object>, key: string, fallback: string = ''): string {
  const v = params[key];
  return (v !== undefined && v !== null) ? String(v) : fallback;
}

function paramNum(params: Record<string, Object>, key: string, fallback: number = 0): number {
  const v = params[key];
  return (v !== undefined && v !== null) ? Number(v) : fallback;
}

export default class DisplayAbility extends UIAbility {

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      const ctx = this.context as ContextWithWant;
      const want = (typeof ctx?.getWant === 'function') ? ctx.getWant() : ctx?.want;
      const params = want?.parameters ?? {};
      const sessionId = paramStr(params, 'sessionId');
      const monitorIndex = paramNum(params, 'monitorIndex');
      const title = paramStr(params, 'title', '显示窗口');
      const launchParams: DisplayLaunchParams = { sessionId, monitorIndex, title };
      console.info(`DisplayAbility onWindowStageCreate: sessionId=${sessionId}, monitorIndex=${monitorIndex}, title=${title}`);
      if (sessionId) {
        viewerMultiWindowStore.registerWindow({
          windowName: `viewer-display:${sessionId}:${monitorIndex}`,
          sessionId,
          monitorIndex,
          title
        });
      }
      AppStorage.setOrCreate<DisplayLaunchParams>('__display_launch_bridge__', launchParams);
      const storage = new LocalStorage();
      storage.setOrCreate<DisplayLaunchParams>('__display_launch_params__', launchParams);
      windowStage.loadContent('pages/DisplayPage', storage);
      this.applyWindowTitle(windowStage, title);
    } catch (e) {
      console.error('DisplayAbility onWindowStageCreate error:', e);
    }
  }

  private applyWindowTitle(windowStage: window.WindowStage, _title: string): void {
    const showDecor = (win: window.Window): void => {
      try {
        win.setWindowDecorVisible(true);
        console.info('DisplayAbility setWindowDecorVisible true');
      } catch (e) {
        console.warn('DisplayAbility setWindowDecorVisible failed:', e);
      }
    };
    try {
      const mainWin = windowStage.getMainWindowSync();
      if (mainWin) {
        showDecor(mainWin);
        return;
      }
    } catch (e) {
    }
    windowStage.getMainWindow()
      .then((win: window.Window): void => {
        showDecor(win);
      })
      .catch((): void => {});
    setTimeout((): void => {
      try {
        const mainWin = windowStage.getMainWindowSync();
        if (mainWin) showDecor(mainWin);
      } catch (e) {
      }
    }, 200);
    setTimeout((): void => {
      try {
        const mainWin = windowStage.getMainWindowSync();
        if (mainWin) showDecor(mainWin);
      } catch (e) {
      }
    }, 600);
  }

  onDestroy(): void {
    try {
      const ctx = this.context as ContextWithWant;
      const want = (typeof ctx?.getWant === 'function') ? ctx.getWant() : ctx?.want;
      const params = want?.parameters ?? {};
      const sessionId = paramStr(params, 'sessionId');
      const monitorIndex = paramNum(params, 'monitorIndex');
      if (sessionId) {
        viewerMultiWindowStore.removeWindow(`viewer-display:${sessionId}:${monitorIndex}`);
      }
    } catch (e) {
    }
  }
}
