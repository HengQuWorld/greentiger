import image from '@ohos.multimedia.image';
import { router } from '@kit.ArkUI';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { SharedViewerSessionSnapshot, SharedViewerRect, viewerMultiWindowStore } from '../utils/ViewerMultiWindow';
import { keySymFromEvent } from '../utils/KeyMap';
import {
  releasePixelMap,
  createPixelMapFromBuffer,
  getMonitorImageMetrics,
  mapLocalToRemote,
  getVncMouseButton,
  getScrollClicksForServer,
  VNC_SCROLL_UP,
  VNC_SCROLL_DOWN,
  type ViewportTarget,
  type RemotePoint,
  InteractFrameThrottle
} from '../utils/ViewerCommonUtils';

export interface DisplayLaunchParams {
  sessionId: string;
  monitorIndex: number;
  title: string;
}

const DEFAULT_PARAMS: DisplayLaunchParams = {
  sessionId: '',
  monitorIndex: 0,
  title: '显示窗口'
};

@Entry
@Component
struct DisplayPage {
  @StorageLink('__display_launch_bridge__') private bridgeParams: DisplayLaunchParams = DEFAULT_PARAMS;
  @State private title: string = '显示窗口';
  @State private statusText: string = '正在初始化...';
  @State private pm: image.PixelMap | undefined = undefined;
  @State private pmVersion: number = 0;
  @State private windowW: number = 1;
  @State private windowH: number = 1;
  @State private fbW: number = 0;
  @State private fbH: number = 0;
  @State private monitorRect: SharedViewerRect = { x: 0, y: 0, w: 1, h: 1 };
  @State private connected: boolean = false;
  @State private cachedViewport: ViewportTarget = { source: { x: 0, y: 0, w: 1, h: 1 }, frame: { x: 0, y: 0, w: 1, h: 1 } };

  private sessionId: string = '';
  private monitorIndex: number = 0;
  private lastFrameVersion: number = -1;
  private timerId: number = -1;
  private loopStopped: boolean = false;
  private pmW: number = 0;
  private pmH: number = 0;

  private lastSentX: number = -1;
  private lastSentY: number = -1;
  private lastSentMask: number = 0;

  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private touchMoved: boolean = false;
  private touchDragging: boolean = false;

  private remoteShiftDown: boolean = false;
  private remoteCtrlDown: boolean = false;
  private remoteAltDown: boolean = false;
  private remoteMetaDown: boolean = false;
  private remoteChineseMode: boolean = false;

  private isInteracting: boolean = false;
  private frameThrottle: InteractFrameThrottle = new InteractFrameThrottle();
  private pendingFrame: ArrayBuffer | null = null;
  private pendingFbW: number = 0;
  private pendingFbH: number = 0;
  private pendingVersion: number = -1;

  aboutToAppear(): void {
    void this.initialize();
  }

  aboutToDisappear(): void {
    this.stopLoop();
    releasePixelMap(this.pm);
    this.pm = undefined;
    this.pmVersion = 0;
    AppStorage.setOrCreate<DisplayLaunchParams>('__display_launch_bridge__', DEFAULT_PARAMS);
  }

  private async initialize(): Promise<void> {
    const params = this.getLaunchParams();
    this.sessionId = params.sessionId;
    this.monitorIndex = Math.max(0, Math.floor(params.monitorIndex));
    this.title = params.title || `屏幕 ${this.monitorIndex + 1}`;
    if (!this.sessionId) {
      this.statusText = '缺少会话标识，请在主窗口重新打开';
      return;
    }
    console.info(`DisplayPage initialized: sessionId=${this.sessionId}, monitorIndex=${this.monitorIndex}, title=${this.title}`);
    this.startLoop();
    await this.syncOnce();
  }

  private getLaunchParams(): DisplayLaunchParams {
    if (this.bridgeParams && this.bridgeParams.sessionId) {
      console.info(`DisplayPage got params from AppStorage bridge: sessionId=${this.bridgeParams.sessionId}, monitorIndex=${this.bridgeParams.monitorIndex}, title=${this.bridgeParams.title}`);
      return {
        sessionId: this.bridgeParams.sessionId,
        monitorIndex: this.bridgeParams.monitorIndex,
        title: this.bridgeParams.title
      };
    }
    try {
      const routerParams = router.getParams() as Record<string, Object> | undefined;
      if (routerParams && routerParams['sessionId']) {
        const sid = String(routerParams['sessionId']);
        const mi = routerParams['monitorIndex'] !== undefined ? Number(routerParams['monitorIndex']) : 0;
        const t = routerParams['title'] !== undefined ? String(routerParams['title']) : '';
        console.info(`DisplayPage got params from router: sessionId=${sid}, monitorIndex=${mi}, title=${t}`);
        return { sessionId: sid, monitorIndex: mi, title: t };
      }
    } catch (e) {
    }
    const sessions = viewerMultiWindowStore.listAllSessions();
    for (let si = 0; si < sessions.length; si++) {
      const sid = sessions[si];
      const names = viewerMultiWindowStore.listWindowNames(sid);
      for (let ni = 0; ni < names.length; ni++) {
        const binding = viewerMultiWindowStore.getWindowBinding(names[ni]);
        if (binding && !viewerMultiWindowStore.isWindowClaimed(names[ni])) {
          viewerMultiWindowStore.claimWindow(names[ni]);
          console.info(`DisplayPage got params from unclaimed binding: sessionId=${binding.sessionId}, monitorIndex=${binding.monitorIndex}, title=${binding.title}`);
          return {
            sessionId: binding.sessionId,
            monitorIndex: binding.monitorIndex,
            title: binding.title
          };
        }
      }
    }
    console.warn('DisplayPage could not get any launch params, using defaults');
    return { sessionId: '', monitorIndex: 0, title: '显示窗口' };
  }

  private startLoop(): void {
    this.loopStopped = false;
    this.scheduleNextSync();
  }

  private stopLoop(): void {
    this.loopStopped = true;
    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  private scheduleNextSync(): void {
    if (this.loopStopped) return;
    const interval = this.isInteracting ? 50 : 33;
    this.timerId = setTimeout(() => {
      this.timerId = -1;
      if (this.loopStopped) return;
      void this.syncOnce().then(() => this.scheduleNextSync());
    }, interval) as number;
  }

  private async syncOnce(): Promise<void> {
    if (!this.sessionId) return;
    const snapshot = viewerMultiWindowStore.getSessionSnapshot(this.sessionId);
    await this.applySnapshot(snapshot);
  }

  private async applySnapshot(snapshot: SharedViewerSessionSnapshot | null): Promise<void> {
    if (!snapshot) {
      if (!this.isInteracting) {
        this.connected = false;
        this.statusText = '主会话不存在或已结束';
      }
      return;
    }
    if (this.isInteracting) {
      if (snapshot.frame && snapshot.fbW > 0 && snapshot.fbH > 0 &&
        snapshot.frameVersion !== this.lastFrameVersion) {
        this.fbW = snapshot.fbW;
        this.fbH = snapshot.fbH;
        const monitor = snapshot.monitors[this.monitorIndex];
        if (monitor && monitor.w > 0 && monitor.h > 0) {
          this.monitorRect = monitor;
        } else {
          this.monitorRect = {
            x: 0,
            y: 0,
            w: Math.max(1, snapshot.fbW),
            h: Math.max(1, snapshot.fbH)
          };
        }
        this.pendingFrame = snapshot.frame;
        this.pendingFbW = snapshot.fbW;
        this.pendingFbH = snapshot.fbH;
        this.pendingVersion = snapshot.frameVersion;
        if (this.frameThrottle.shouldRender()) {
          this.lastFrameVersion = snapshot.frameVersion;
          await this.replacePixelMap(snapshot.frame, snapshot.fbW, snapshot.fbH);
          this.pendingFrame = null;
        }
      }
      return;
    }
    this.connected = snapshot.connected;
    this.fbW = snapshot.fbW;
    this.fbH = snapshot.fbH;
    const monitor = snapshot.monitors[this.monitorIndex];
    if (monitor && monitor.w > 0 && monitor.h > 0) {
      this.monitorRect = monitor;
    } else {
      this.monitorRect = {
        x: 0,
        y: 0,
        w: Math.max(1, snapshot.fbW),
        h: Math.max(1, snapshot.fbH)
      };
    }
    if (!snapshot.connected) {
      this.statusText = '会话未连接';
      return;
    }
    if (!snapshot.frame || snapshot.fbW <= 0 || snapshot.fbH <= 0) {
      this.statusText = '正在等待画面...';
      return;
    }
    if (snapshot.frameVersion === this.lastFrameVersion && this.pm) {
      this.statusText = '';
      return;
    }
    this.lastFrameVersion = snapshot.frameVersion;
    this.statusText = '';
    await this.replacePixelMap(snapshot.frame, snapshot.fbW, snapshot.fbH);
  }

  private flushPendingFrame(): void {
    if (!this.pendingFrame || this.pendingFbW <= 0 || this.pendingFbH <= 0) return;
    const frame = this.pendingFrame;
    const fbW = this.pendingFbW;
    const fbH = this.pendingFbH;
    const version = this.pendingVersion;
    this.pendingFrame = null;
    this.pendingFbW = 0;
    this.pendingFbH = 0;
    this.pendingVersion = -1;
    void this.replacePixelMap(frame, fbW, fbH);
  }

  private async replacePixelMap(frame: ArrayBuffer, width: number, height: number): Promise<void> {
    const prevPm = this.pm;
    try {
      const nextPm = await createPixelMapFromBuffer(frame, width, height);
      this.pm = nextPm;
      this.pmW = width;
      this.pmH = height;
      this.pmVersion++;
      this.cachedViewport = getMonitorImageMetrics(this.monitorRect, this.windowW, this.windowH, width, height);
    } catch (e) {
      console.error('DisplayPage replacePixelMap failed', e);
    } finally {
      releasePixelMap(prevPm);
    }
  }

  private viewportMetrics(): ViewportTarget {
    return getMonitorImageMetrics(this.monitorRect, this.windowW, this.windowH, this.fbW, this.fbH);
  }

  private toRemote(localX: number, localY: number): RemotePoint {
    return mapLocalToRemote(localX, localY, this.monitorRect, this.windowW, this.windowH, this.fbW, this.fbH);
  }

  private safeSendPointer(x: number, y: number, mask: number, force: boolean = false): void {
    if (!this.connected || !this.sessionId) return;
    if (!force) {
      if (this.lastSentX === x && this.lastSentY === y && this.lastSentMask === mask) return;
      if (this.lastSentMask === mask && mask !== 0 &&
        Math.abs(x - this.lastSentX) <= 1 && Math.abs(y - this.lastSentY) <= 1) return;
    }
    const client = viewerMultiWindowStore.getVncClient(this.sessionId);
    if (!client) return;
    try {
      client.sendPointer(x, y, mask);
      this.lastSentX = x;
      this.lastSentY = y;
      this.lastSentMask = mask;
    } catch (e) {
    }
  }

  private safeSendKey(keysym: number, down: boolean): void {
    if (!this.connected || !this.sessionId) return;
    const client = viewerMultiWindowStore.getVncClient(this.sessionId);
    if (!client) return;
    try {
      client.sendKey(keysym, down);
    } catch (e) {
    }
  }

  private getModifierDown(ev: KeyEvent, key: string): boolean {
    if (typeof ev?.getModifierKeyState !== 'function') return false;
    try {
      return ev.getModifierKeyState([key]);
    } catch (e) {
      return false;
    }
  }

  private syncRemoteModifiers(ev: KeyEvent): void {
    const shiftDown = this.getModifierDown(ev, 'Shift');
    const ctrlDown = this.getModifierDown(ev, 'Ctrl');
    const altDown = this.getModifierDown(ev, 'Alt');
    const metaDown = this.getModifierDown(ev, 'Meta');

    if (shiftDown !== this.remoteShiftDown) {
      this.safeSendKey(0xffe1, shiftDown);
      this.remoteShiftDown = shiftDown;
    }
    if (ctrlDown !== this.remoteCtrlDown) {
      this.safeSendKey(0xffe3, ctrlDown);
      this.remoteCtrlDown = ctrlDown;
    }
    if (altDown !== this.remoteAltDown) {
      this.safeSendKey(0xffe9, altDown);
      this.remoteAltDown = altDown;
    }
    if (metaDown !== this.remoteMetaDown) {
      this.safeSendKey(0xffe7, metaDown);
      this.remoteMetaDown = metaDown;
    }
  }

  private sendRemoteCommittedText(text: string): void {
    if (!text) return;
    let asciiOnly = true;
    for (const ch of text) {
      if ((ch.codePointAt(0) ?? 0) > 0x7f) {
        asciiOnly = false;
        break;
      }
    }
    if (asciiOnly) {
      for (const ch of text) {
        let code = ch.codePointAt(0) ?? 0;
        if (code === 10) code = 0xff0d;
        this.safeSendKey(code, true);
        this.safeSendKey(code, false);
      }
      return;
    }
    for (const ch of text) {
      const cp = ch.codePointAt(0) ?? 0;
      if (cp >= 0x20) {
        const ks = 0x01000000 | cp;
        this.safeSendKey(ks, true);
        this.safeSendKey(ks, false);
      }
    }
  }

  private beginInteraction(): void {
    this.isInteracting = true;
    this.frameThrottle.begin();
  }

  private endInteraction(): void {
    this.isInteracting = false;
    this.frameThrottle.end();
    this.flushPendingFrame();
  }

  private handleTouch(ev: TouchEvent): void {
    if (!this.connected) return;
    const t = ev?.touches?.[0] ?? ev?.changedTouches?.[0];
    const type = ev?.type;
    const localX = t?.x ?? 0;
    const localY = t?.y ?? 0;
    const p = this.toRemote(localX, localY);

    if (type === TouchType.Down) {
      this.beginInteraction();
      this.touchStartX = localX;
      this.touchStartY = localY;
      this.touchMoved = false;
      this.touchDragging = false;
      this.safeSendPointer(p.x, p.y, 0);
      return;
    }

    if (type === TouchType.Move) {
      const dx = Math.abs(localX - this.touchStartX);
      const dy = Math.abs(localY - this.touchStartY);
      if (dx + dy >= 6) this.touchMoved = true;
      if (this.touchMoved && !this.touchDragging) {
        this.touchDragging = true;
        const startP = this.toRemote(this.touchStartX, this.touchStartY);
        this.safeSendPointer(startP.x, startP.y, 1);
      }
      this.safeSendPointer(p.x, p.y, this.touchDragging ? 1 : 0);
      return;
    }

    if (type === TouchType.Up) {
      if (this.touchDragging) {
        this.touchDragging = false;
        this.safeSendPointer(p.x, p.y, 0);
      } else if (!this.touchMoved) {
        this.safeSendPointer(p.x, p.y, 1);
        this.safeSendPointer(p.x, p.y, 0);
      } else {
        this.safeSendPointer(p.x, p.y, 0);
      }
      this.touchDragging = false;
      this.endInteraction();
      return;
    }

    if (type === TouchType.Cancel) {
      this.touchDragging = false;
      this.safeSendPointer(p.x, p.y, 0);
      this.endInteraction();
      return;
    }
  }

  private handleMouse(ev: MouseEvent): void {
    if (!this.connected) return;
    const localX = ev?.x ?? 0;
    const localY = ev?.y ?? 0;
    const action = ev?.action;
    const button = ev?.button;

    const bit = getVncMouseButton(button);

    if (action === MouseAction.Press) {
      this.beginInteraction();
      this.lastSentMask |= bit;
    }
    if (action === MouseAction.Release) {
      this.lastSentMask &= ~bit;
      if (this.lastSentMask === 0) this.endInteraction();
    }

    const p = this.toRemote(localX, localY);
    this.safeSendPointer(p.x, p.y, this.lastSentMask, true);
  }

  private handleAxis(ev: AxisEvent): void {
    if (!this.connected) return;
    const axisX = ev?.x ?? 0;
    const axisY = ev?.y ?? 0;
    let dy = 0;
    if (typeof ev?.getVerticalAxisValue === 'function') {
      dy = ev.getVerticalAxisValue();
    } else if (ev?.scrollStep !== undefined) {
      dy = ev.scrollStep;
    }
    if (dy === 0) return;

    const p = this.toRemote(axisX, axisY);
    const mask = dy < 0 ? VNC_SCROLL_UP : VNC_SCROLL_DOWN;
    const clicks = getScrollClicksForServer(this.title);
    for (let i = 0; i < clicks; i++) {
      this.safeSendPointer(p.x, p.y, this.lastSentMask | mask, true);
      this.safeSendPointer(p.x, p.y, this.lastSentMask, true);
    }
  }

  private handleKey(ev: KeyEvent): boolean {
    if (!this.connected || !this.sessionId) return false;
    const code = ev?.keyCode ?? 0;
    const isModKey =
      code === KeyCode.KEYCODE_SHIFT_LEFT || code === KeyCode.KEYCODE_SHIFT_RIGHT ||
      code === KeyCode.KEYCODE_CTRL_LEFT || code === KeyCode.KEYCODE_CTRL_RIGHT ||
      code === KeyCode.KEYCODE_ALT_LEFT || code === KeyCode.KEYCODE_ALT_RIGHT ||
      code === KeyCode.KEYCODE_META_LEFT || code === KeyCode.KEYCODE_META_RIGHT;
    if (!isModKey) this.syncRemoteModifiers(ev);
    const isDown = (ev?.type === KeyType.Down);
    const isUp = (ev?.type === KeyType.Up);
    const text = typeof ev?.keyText === 'string' ? ev.keyText : '';

    let isTextEvent = false;
    if (text && code === 0) isTextEvent = true;
    if (text) {
      for (const ch of text) {
        if ((ch.codePointAt(0) ?? 0) > 0x7f) {
          isTextEvent = true;
          break;
        }
      }
    }

    if (isTextEvent) {
      if (isDown) {
        this.sendRemoteCommittedText(text);
      }
      return true;
    }

    if (code === KeyCode.KEYCODE_DEL || code === 67) {
      if (isDown) this.safeSendKey(0xff08, true);
      if (isUp) this.safeSendKey(0xff08, false);
      return true;
    }

    if (code === KeyCode.KEYCODE_CAPS_LOCK && isDown) {
      this.remoteChineseMode = !this.remoteChineseMode;
    }

    const keysym = keySymFromEvent(ev, this.remoteChineseMode);
    if (!keysym) return false;

    if (keysym >= 0x01000000 && keysym <= 0x0100ffff) {
      if (isDown) {
        const ch = String.fromCodePoint(keysym & 0xffffff);
        const cp = ch.codePointAt(0) ?? 0;
        if (cp > 0x20) {
          this.safeSendKey(keysym, true);
          this.safeSendKey(keysym, false);
        }
      }
      return true;
    }

    if (isDown) this.safeSendKey(keysym, true);
    if (isUp) this.safeSendKey(keysym, false);

    if (keysym === 0xffe1 || keysym === 0xffe2) this.remoteShiftDown = isDown ? true : (isUp ? false : this.remoteShiftDown);
    if (keysym === 0xffe3 || keysym === 0xffe4) this.remoteCtrlDown = isDown ? true : (isUp ? false : this.remoteCtrlDown);
    if (keysym === 0xffe9 || keysym === 0xffea) this.remoteAltDown = isDown ? true : (isUp ? false : this.remoteAltDown);
    if (keysym === 0xffe7 || keysym === 0xffe8) this.remoteMetaDown = isDown ? true : (isUp ? false : this.remoteMetaDown);
    return true;
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000');

      if (this.pm) {
        Image(this.pm)
          .width(this.cachedViewport.frame.w)
          .height(this.cachedViewport.frame.h)
          .position({
            x: this.cachedViewport.frame.x,
            y: this.cachedViewport.frame.y
          })
          .interpolation(ImageInterpolation.High)
          .draggable(false);
      }

      Text(this.title)
        .fontSize(11)
        .fontColor('#ffffff99')
        .backgroundColor('#00000088')
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(6)
        .position({ x: 8, y: 8 });

      if (!this.pm || this.statusText) {
        Column({ space: 8 }) {
          Text(this.title)
            .fontSize(16)
            .fontColor('#ffffff')
            .fontWeight(FontWeight.Medium);
          Text(this.statusText || '正在等待画面...')
            .fontSize(12)
            .fontColor('#d6d3d1');
        }
        .padding(16)
        .backgroundColor('rgba(12,20,22,0.72)')
        .borderRadius(16);
      }
    }
    .width('100%')
    .height('100%')
    .draggable(false)
    .focusable(true)
    .focusOnTouch(true)
    .defaultFocus(true)
    .onTouch((ev: TouchEvent) => this.handleTouch(ev))
    .onMouse((ev: MouseEvent) => this.handleMouse(ev))
    .onHover((isHover: boolean) => {
      if (!isHover) {
        this.lastSentMask = 0;
        this.endInteraction();
      }
    })
    .onAxisEvent((ev: AxisEvent) => this.handleAxis(ev))
    .onKeyEvent((ev: KeyEvent) => this.handleKey(ev))
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.windowW = (newValue.width as number) ?? 1;
      this.windowH = (newValue.height as number) ?? 1;
    });
  }
}
