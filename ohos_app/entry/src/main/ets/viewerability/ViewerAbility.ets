import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import { parseSshTunnelConfigText, resolveConnectionAddress } from '../utils/ConnectionUtils';

interface WantLike {
  parameters?: Record<string, Object>;
}

interface UIAbilityContextWithWant {
  getWant?: () => WantLike;
  want?: WantLike;
}

interface WindowErrorLike {
  code?: number;
}

interface SystemBarPropertiesLike {
  statusBarColor?: string;
  navigationBarColor?: string;
  statusBarContentColor?: string;
  navigationBarContentColor?: string;
  isStatusBarLightIcon?: boolean;
  isNavigationBarLightIcon?: boolean;
}

interface WindowLike {
  setWindowTitle?: (t: string) => void;
  setWindowLayoutFullScreen?: (enable: boolean) => void;
  setFullScreen?: (enable: boolean) => void;
  setWindowDecorVisible?: (visible: boolean) => void;
  setSystemBarEnable?: (bars: string[]) => void;
  setWindowSystemBarEnable?: (bars: Array<'status' | 'navigation'>, callback?: (err: WindowErrorLike) => void) => void;
  setWindowSystemBarProperties?: (props: SystemBarPropertiesLike) => void;
}

export default class ViewerAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      windowStage.loadContent('pages/Viewer');
      const ctx = this.context as UIAbilityContextWithWant;
      const want = (typeof ctx?.getWant === 'function') ? ctx.getWant() : ctx?.want;
      const params = want?.parameters ?? {};
      const address = (params['address'] !== undefined && params['address'] !== null) ? String(params['address']) : '';
      const name = (params['name'] !== undefined && params['name'] !== null) ? String(params['name']) : '';
      const sshConfig = (params['sshConfig'] !== undefined && params['sshConfig'] !== null) ? String(params['sshConfig']) : '';
      const displayAddress = resolveConnectionAddress(address, parseSshTunnelConfigText(sshConfig, address) ?? undefined);
      const title = (name.trim() ? name.trim() : (displayAddress || 'Viewer')) + (displayAddress ? `  ${displayAddress}` : '');
      interface WindowStageLike {
        getMainWindowSync?: () => Object;
        getMainWindow?: () => Promise<Object>;
      }
      const ws = windowStage as WindowStageLike;
      const mainWin = ws.getMainWindowSync?.();
      const apply = (win: Object): void => {
        try {
          const w = win as WindowLike;
          w.setWindowTitle?.(title);
          w.setWindowLayoutFullScreen?.(true);
          w.setFullScreen?.(true);
          w.setWindowDecorVisible?.(false);
          w.setWindowSystemBarEnable?.([], (_err?: WindowErrorLike) => {});
          w.setSystemBarEnable?.([]);
          w.setWindowSystemBarProperties?.({
            statusBarColor: '#00000000',
            navigationBarColor: '#00000000',
            statusBarContentColor: '#00000000',
            navigationBarContentColor: '#00000000'
          });
          setTimeout(() => {
            try {
              w.setWindowLayoutFullScreen?.(true);
              w.setFullScreen?.(true);
              w.setWindowDecorVisible?.(false);
              w.setWindowSystemBarEnable?.([], (_err?: WindowErrorLike) => {});
              w.setSystemBarEnable?.([]);
              w.setWindowSystemBarProperties?.({
                statusBarColor: '#00000000',
                navigationBarColor: '#00000000',
                statusBarContentColor: '#00000000',
                navigationBarContentColor: '#00000000'
              });
            } catch (e) {
            }
          }, 200);
          setTimeout(() => {
            try {
              w.setWindowLayoutFullScreen?.(true);
              w.setFullScreen?.(true);
              w.setWindowDecorVisible?.(false);
              w.setWindowSystemBarEnable?.([], (_err?: WindowErrorLike) => {});
              w.setSystemBarEnable?.([]);
              w.setWindowSystemBarProperties?.({
                statusBarColor: '#00000000',
                navigationBarColor: '#00000000',
                statusBarContentColor: '#00000000',
                navigationBarContentColor: '#00000000'
              });
            } catch (e) {
            }
          }, 600);
        } catch (e) {
        }
      };
      if (mainWin) {
        apply(mainWin);
      } else {
        ws.getMainWindow?.()
          .then((win: Object): void => {
            apply(win);
          })
          .catch((): void => {});
      }
    } catch (e) {
    }
  }
}
