import image from '@ohos.multimedia.image';
import dataPreferences from '@ohos.data.preferences';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { pasteboard } from '@kit.BasicServicesKit';
import { inputMethod } from '@kit.IMEKit';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import window from '@ohos.window';
import {
  ConnectionItem,
  SshTunnelConfig,
  generateId,
  normalizeConnName,
  normalizeSshTunnelConfigForAddress,
  parseAddress,
  parseConnectionsJson,
  parseSshTunnelConfigText,
  resolveConnectionAddress
} from '../utils/ConnectionUtils';
import { keySymFromEvent } from '../utils/KeyMap';
import { SharedViewerRect, VncClientLike, viewerMultiWindowStore } from '../utils/ViewerMultiWindow';
import { InteractFrameThrottle, saveCtrlPassthrough, saveAdaptiveResolution } from '../utils/ViewerCommonUtils';
import { recordRatingSession } from '../utils/AppRating';
import { VncClient } from 'libvncviewer.so';

interface ClickEvent {
  timestamp: number;
}

interface VncFramebufferInfo {
  width: number;
  height: number;
  stride: number;
  state: number;
  name?: string;
}

type WantParamValue = string | number | boolean | undefined;

interface VncClientData {
  connect(host: string, port: number, user?: string, pass?: string): Promise<number>;
  setSshTunnel?(config: SshTunnelConfig): number;
  clearSshTunnel?(): void;
  disconnect(): void;
  process(): number;
  refresh(): number;
  requestUpdate?(incremental?: boolean): number;
  setDesktopSize?(width: number, height: number): number;
  takeDesktopResizeFailure?(): boolean;
  computeDesktopSizeTarget?(viewportWidth: number, viewportHeight: number, pixelRatio: number): DesktopSizeTarget;
  consumeDamage(): VncRect | null;
  getFramebufferInfo(): VncFramebufferInfo;
  copyFrameRGBA(order: number): ArrayBuffer | null;
  
  copyRectRGBA(order: number, x: number, y: number, width: number, height: number): ArrayBuffer | null;
  sendPointer(x: number, y: number, mask: number): void;
  sendKey(keysym: number, down: boolean): void;
  setClipboardText(text: string): void;
  requestClipboard(): void;
  takeRemoteClipboardAnnounce(): number;
  takeRemoteClipboardText(): string;
  hasRemoteClipboardText(): boolean;
  getLastError(): string;
  isSecure?(): boolean;
  getSecurityLevel?(): number;
  hasReceivedFirstUpdate?(): boolean;
  detectMonitors?(fallbackRects?: VncRect[]): VncRect[];
  isServerLikelyMac?(): boolean;
  setDebugOptions(enabled: boolean, level: number, byteOrder: number, pmFormat: number): void;
  getDebugInfo(): VncDebugInfo;
  getDebugLog(clear: boolean): string;
}

export interface VncRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

interface ViewportTarget {
  source: VncRect;
  frame: VncRect;
}

interface SavedMonitorLayout {
  width: number;
  height: number;
  rects: VncRect[];
}

interface MonitorAspectOption {
  label: string;
  ratio: number;
}

interface DesktopSizeTarget {
  ok: boolean;
  width: number;
  height: number;
}

const MAX_MANUAL_MONITOR_COUNT = 8;
// 面板标题栏高度：上下内边距 16/12 + 关闭按钮 30
const PANEL_HEADER_HEIGHT = 58;
// 面板与其上下窗口边缘之间保留的最小空白
const PANEL_VERTICAL_GAP = 24;

interface WindowLike {
  setWindowTitle?: (t: string) => void;
  setFullScreen?: (enable: boolean) => void;
  setWindowLayoutFullScreen?: (enable: boolean) => void;
  setSystemBarEnable?: (bars: string[]) => void;
  setWindowSystemBarEnable?: (bars: Array<'status' | 'navigation'>, callback?: (err: WindowErrorLike) => void) => void;
  setWindowSystemBarProperties?: (props: SystemBarPropertiesLike) => void;
  setWindowDecorVisible?: (visible: boolean) => void;
  resize?: (width: number, height: number) => Promise<void>;
  showWindow?: () => Promise<void>;
  destroyWindow?: () => Promise<void>;
  setUIContent?: (path: string) => Promise<void>;
}

interface WindowCreateConfigLike {
  name: string;
  windowType: number;
  ctx?: common.UIAbilityContext;
  decorEnabled?: boolean;
  title?: string;
}

interface WindowSizeLike {
  width: number;
  height: number;
}

interface WindowTypeLike {
  TYPE_DIALOG?: number;
  TYPE_FLOAT?: number;
}

interface WindowModuleLike {
  WindowType?: WindowTypeLike;
  createWindow?: (config: WindowCreateConfigLike) => Promise<Object>;
  findWindow?: (name: string) => Object;
}

interface WindowErrorLike {
  code?: number;
}

interface ClipboardErrorLike {
  code?: number;
  message?: string;
}

interface PermissionRequestResultLike {
  authResults?: number[];
}

interface PermissionAwareContext {
  requestPermissionsFromUser?: (permissions: Array<string>, requestCode: number) => Promise<PermissionRequestResultLike>;
}

interface SystemBarPropertiesLike {
  statusBarColor?: string;
  navigationBarColor?: string;
  statusBarContentColor?: string;
  navigationBarContentColor?: string;
  isStatusBarLightIcon?: boolean;
  isNavigationBarLightIcon?: boolean;
}

interface TouchPointLike {
  x?: number;
  y?: number;
  displayX?: number;
  displayY?: number;
  globalX?: number;
  globalY?: number;
  screenX?: number;
  screenY?: number;
}
interface LocalPoint {
  x: number;
  y: number;
}
interface TextDelta {
  deletedCount: number;
  insertedText: string;
}
interface VncDebugInfo {
  width?: number;
  height?: number;
  stride?: number;
  state?: number;
  fbUpdateCount?: number;
  lastUpdateX?: number;
  lastUpdateY?: number;
  lastUpdateW?: number;
  lastUpdateH?: number;
  processCount?: number;
  lastProcessRc?: number;
  checksum?: number;
  p00?: number[];
  pCenter?: number[];
  pendingDamage?: VncRect;
}

class RemotePoint {
  x: number;
  y: number;
  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

class TopActionButtonParams {
  label: ResourceStr = '';
  active: boolean = false;
  onClick: () => void = () => {};
}

class DockButtonParams {
  label: ResourceStr = '';
  active: boolean = false;
  enabled: boolean = false;
  onClick: () => void = () => {};
}

class PanelActionParams {
  label: ResourceStr = '';
  primary: boolean = false;
  onClick: () => void = () => {};
}

@Entry
@Component
struct Viewer {
  private vncClient: VncClientData = new VncClient();

  @State address: string = '';
  @State user: string = '';
  @State password: string = '';
  @State private connName: string = '';
  @State private connections: ConnectionItem[] = [];
  @State private selectedConnId: string = '';
  private runtimeSshConfig: SshTunnelConfig | null = null;
  private runtimeTouchScrollStep: number = 0;
  private runtimeMacMode: boolean = false;
  @State private remoteCtrlPassthrough: boolean = false;
  private macAutoChecked: boolean = false;
  @State private showPassword: boolean = false;
  @State private editOpen: boolean = false;
  @State private editId: string = '';
  @State private editName: string = '';
  @State private editAddress: string = '';
  @State private editUser: string = '';
  @State private editPassword: string = '';
  @State private editStorePassword: boolean = true;
  @State private editTouchScrollStep: number = 0;
  @State private editMacMode: boolean = false;
  @State private editShowPassword: boolean = false;
  @State private connectPromptOpen: boolean = false;
  @State private connectPromptConnId: string = '';
  @State private connectPromptName: string = '';
  @State private connectPromptAddress: string = '';
  @State private connectPromptPassword: string = '';
  @State private connectPromptStorePassword: boolean = false;
  @State connected: boolean = false;
  @State securityLevel: number = 0;
  @State connecting: boolean = false;
  @State lastError: string = '';
  @State private showPanel: boolean = true;
  @State private authOpen: boolean = false;
  @State private devToolsEnabled: boolean = false;
  private didShowPanelGestureHint: boolean = false;
  private readonly cTextPrimary: string = '#1c1917';
  private readonly cTextMuted: string = '#292524';
  private readonly cTextSecondary: string = '#57534e';
  private readonly cTextTertiary: string = '#78716c';
  private readonly cSurface: string = '#fdfbf7';
  private readonly cSurfaceAlt: string = '#ffffff';
  private readonly cBorder: string = '#e7e5e4';
  private readonly cPrimary: string = '#2c4f54';
  private readonly cPrimaryFg: string = '#ffffff';
  private readonly cPrimarySoft: string = 'rgba(44,79,84,0.12)';
  private readonly cInk: string = '#0c1416';
  private readonly cOnInk: string = '#e7e5e4';
  private readonly cError: string = '#b42318';
  private readonly cWarning: string = '#d97706';
  private readonly cSuccess: string = '#15803d';
  private readonly cOverlayPanel: string = 'rgba(12,20,22,0.78)';

  @State viewerW: number = 1;
  @State viewerH: number = 1;
  @State private interactionMode: 'control' | 'inspect' = 'control';
  @State private zoomScale: number = 1;
  @State private zoomOffsetX: number = 0;
  @State private zoomOffsetY: number = 0;

  @State private windowW: number = 0;
  @State private windowH: number = 0;

 @State private fbW: number = 0;
  @State private fbH: number = 0;
  private fbStride: number = 0;
  @State private vncState: number = -1;
  // rfb::CConnection::RFBSTATE_NORMAL: the handshake is done and the server's
  // capabilities (screen layout, security type) are all known.
  private readonly vncStateNormal: number = 7;
  private lastMask: number = 0;
  private isInteracting: boolean = false;
  private frameThrottle: InteractFrameThrottle = new InteractFrameThrottle();
  private pendingFrameCache: ArrayBuffer | null = null;
  private timerId: number = -1;
  private ticking: boolean = false;
  private tickQueued: boolean = false;
  private tickScheduled: boolean = false;
  @State private pm: image.PixelMap | undefined = undefined;
  private pmBack: image.PixelMap | undefined = undefined;
  @State private pmVersion: number = 0;
  @State viewportMode: 'all' | 'single' | 'tile' = 'all';
  @State private currentMonitorIndex: number = 0;
  @State private monitors: VncRect[] = [];
  @State private detectedMonitorRects: VncRect[] = [];
  @State private manualMonitorRects: VncRect[] = [];
  @State private manualMonitorDrafts: string[] = [];
  @State private manualDragMonitorIndex: number = -1;
  @State private manualDragAction: 'none' | 'draw' | 'move' = 'none';
  private moveStartRect: VncRect | null = null;
  @State private monitorCount: number = 0;
  @State private detectingDisplayLayout: boolean = false;
  @State private monitorLayoutLocked: boolean = false;
  @State private monitorWindowsOpenCount: number = 0;
  @State private displayEditingScreens: boolean = false;
  private monitorSlots: VncRect[] = [];
  private readonly sharedSessionId: string = generateId();
  private manualDragActive: boolean = false;
  private manualDragStartX: number = 0;
  private manualDragStartY: number = 0;
  private manualDragNewScreen: boolean = false;
  private manualDragBackupRect: VncRect | null = null;
  private creatingPm: boolean = false;
  private pmW: number = 0;
  private pmH: number = 0;
  private frameCache: ArrayBuffer | null = null;
  private lastX: number = 0;
  private lastY: number = 0;
  private readonly inputLayerKey: string = 'vnc_input_layer';
  private readonly softInputKey: string = 'vnc_soft_input';
  @State private softInputDraft: string = '';
  private readonly inputMethodController = inputMethod.getController();
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private touchStartTs: number = 0;
  private touchMoved: boolean = false;
  private touchDragging: boolean = false;
  private touchStartedOutside: boolean = false;
  private edgeClampEnabled: boolean = true;
  // Adapting the remote desktop to the window is opt-out: the remote size is
  // otherwise fixed by the server and the picture gets letterboxed.
  @State private adaptiveResolutionEnabled: boolean = true;
  // Set when this session's server cannot honour a resize, so the panel can say
  // why the toggle did nothing instead of leaving the user guessing.
  @State private adaptiveResizeNotice: string = '';
  private adaptiveResizeTimer: number = -1;
  private adaptiveResizeBlocked: boolean = false;
  private adaptiveResizeTries: number = 0;
  private adaptiveResizeTryW: number = 0;
  private adaptiveResizeTryH: number = 0;
  private adaptiveResizeLastTs: number = 0;
  // A frame within this many pixels of the target already fills the window, so
  // another round trip would only renegotiate for nothing.
  private readonly adaptiveResizeTolerancePx: number = 32;
  private readonly adaptiveResizeMaxAttempts: number = 4;
  private readonly adaptiveResizeRetryDelayMs: number = 1500;
  private readonly adaptiveResizeMinIntervalMs: number = 1200;
  // The window keeps changing while it is being dragged, so the request waits
  // for the size to settle.
  private readonly adaptiveResizeSettleMs: number = 600;
  private readonly adaptiveResizeInitialDelayMs: number = 300;
  private readonly adaptiveResizeToggleDelayMs: number = 200;
  // Mirrors vncclient_desktop_resize_result in shared_native/vncclient.h; the
  // native tests keep those values from drifting.
  private readonly desktopResizeOk: number = 0;
  private readonly desktopResizeUnchanged: number = 1;
  private readonly desktopResizeUnsupported: number = -3;
  private readonly desktopResizeMultiScreen: number = -4;
  private touchScrollActive: boolean = false;
  private touchScrollLastX: number = 0;
  private touchScrollLastY: number = 0;
  private touchScrollResidualY: number = 0;
  private readonly touchScrollStepPx: number = 18;
  private readonly touchScrollStepPxMacNewer: number = 8;
  // The whole VNC pump (process/copyFrame/copyRect) runs on the UI thread, so the
  // tick rate is a direct tax on main-thread time. 30 fps keeps remote input
  // responsive without starving ArkUI; 62 fps (16 ms) was measured causing
  // main-thread freezes in the field.
  private readonly loopIntervalMs: number = 33;
  // Idle full-frame resync used to run every 250 ms. Each pass converts and copies
  // a whole framebuffer (~22 MB at 2880x1920), so an idle session burned ~88 MB/s on
  // the UI thread for no visual gain. Damage-driven updates cover normal use; this
  // fallback only needs to catch an occasional missed update.
  private readonly fallbackFullFrameSyncMs: number = 3000;
  private readonly monitorDetectionIntervalMs: number = 1500;
  private readonly emptyMonitorDetectionIntervalMs: number = 300;
  private readonly inputBurstRefreshWindowMs: number = 1200;
  private readonly inputBurstRefreshIntervalMs: number = 48;
  private readonly remoteClipboardSyncIntervalMs: number = 250;
  private readonly activeServerRefreshWindowMs: number = 15000;
  private readonly activeServerRefreshIntervalMs: number = 250;
  private readonly idleServerRefreshIntervalMs: number = 1000;
  private readonly partialDamageRefreshIntervalMs: number = 120;
  private readonly partialDamageRefreshAreaRatioThreshold: number = 0.9;
  // Damage above this fraction of the frame falls back to a full-frame convert.
  // The partial path uploads only the damage rect but also patches the local frame
  // cache in JS, so past roughly a third of the frame the full-frame path wins;
  // 8% was forcing full frames on ordinary scrolling.
  private readonly partialPixelMapAreaRatioThreshold: number = 0.35;
  private lastMonitorDetectionTs: number = 0;
  private lastMonitorDetectWidth: number = 0;
  private lastMonitorDetectHeight: number = 0;
  private lastLocalInputTs: number = 0;
  private lastRemoteClipboardSyncAttemptTs: number = 0;
  private edgeSwipeActive: boolean = false;
  private edgeSwipeStartX: number = 0;
  private edgeSwipeStartY: number = 0;
  private lastPointerSentX: number = -1;
  private lastPointerSentY: number = -1;
  private lastPointerSentMask: number = -1;
  private lastFullFrameSyncTs: number = 0;
  private connectedAtTs: number = 0;
  private lastFramebufferUpdateTs: number = 0;
  private lastServerRefreshRequestTs: number = 0;
  private lastRemoteClipboardText: string = '';
  private lastLocalClipboardText: string = '';
  private pendingLocalClipboardEchoText: string = '';
  private readonly systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();

  @State private debugEnabled: boolean = false;
  @State private debugLevel: number = 1;
  @State private debugPmFormat: number = 0;
  @State private debugByteOrder: number = 0;
  @State private debugInfoText: string = '';
  @State private debugLogText: string = '';
  @State private firstPixel: string = '';
  private lastDebugTs: number = 0;

  @State private showNavigationPad: boolean = true;

  @State serverName: string = '';
  private didAdoptServerName: boolean = false;
  @State private isFullscreen: boolean = false;
  @State private chromeVisible: boolean = true;
  @State private panelMode: 'none' | 'clipboard' | 'display' | 'more' | 'security' | 'connection' | 'developer' = 'none';
  @State private statusBannerText: string = '';
  @State private bootstrapping: boolean = false;
  @State private fsBtnX: number = 0;
  @State private fsBtnY: number = 0;
  private fsBtnInited: boolean = false;
  private fsBtnDragging: boolean = false;
  private fsBtnLastGX: number = 0;
  private fsBtnLastGY: number = 0;
  private fsBtnDownTs: number = 0;
  private fsBtnMoved: boolean = false;
  private inspectPanStartX: number = 0;
  private inspectPanStartY: number = 0;
  private inspectPanStartOffsetX: number = 0;
  private inspectPanStartOffsetY: number = 0;
  private inspectTouchStartTs: number = 0;
  private inspectTouchMoved: boolean = false;
  private pinchActive: boolean = false;
  private pinchStartDistance: number = 0;
  private pinchStartScale: number = 1;
  private pinchAnchorBaseX: number = 0;
  private pinchAnchorBaseY: number = 0;
  private lastInspectTapTs: number = 0;
  private lastInspectTapX: number = 0;
  private lastInspectTapY: number = 0;
  private readonly zoomMinScale: number = 1;
  private readonly zoomMaxScale: number = 4;
  private readonly zoomStepScale: number = 0.25;
  private readonly inspectMoveSlopPx: number = 8;
  private readonly inspectTapMaxMs: number = 260;
  private readonly inspectDoubleTapMs: number = 320;
  private readonly chromeAutoHideMs: number = 2200;
  private readonly chromeInteractionHideMs: number = 3200;
  private readonly chromeHandleWidth: number = 18;
  private readonly chromeHandleHeight: number = 72;
  private chromeHideTimer: number = -1;
  private statusBannerTimer: number = -1;
  private displayDetectRetryTimer: number = -1;
  private displayDetectRetryLeft: number = 0;
  private chromeHovering: boolean = false;
  private chromePressing: boolean = false;

  private getHostContext(): common.UIAbilityContext | undefined {
    try {
      return this.getUIContext()?.getHostContext?.() as common.UIAbilityContext;
    } catch (e) {
      return undefined;
    }
  }

  private s(res: Resource, ...args: (string | number)[]): string {
    try {
      return getContext(this).resourceManager.getStringSync(res, ...args);
    } catch (e) {
      return '';
    }
  }

  private toast(message: string): void {
    try {
      const pa = this.getUIContext()?.getPromptAction?.();
      pa?.showToast?.({ message });
    } catch (e) {
    }
  }

  private async loadEdgeClampSetting(): Promise<void> {
    try {
      const ctx = this.getHostContext();
      if (!ctx) return;
      const pref = await dataPreferences.getPreferences(ctx, { name: 'vnc_store' });
      this.edgeClampEnabled = !!(await pref.get('edge_clamp_enabled_v1', true)) as boolean;
    } catch (e) {
      console.error('Failed to load edge clamp setting', e);
    }
  }

  aboutToAppear() {
    viewerMultiWindowStore.ensureSession(this.sharedSessionId);
    this.refreshMonitorWindowsState();
    void this.loadEdgeClampSetting();
    void this.loadAdaptiveResolutionSetting();
    const booted = this.applyWantParams();
    if (booted) {
      this.updateWindowTitle();
      this.tryAutoConnect();
      setTimeout(() => this.tryAutoConnect(), 0);
      return;
    }
    void this.loadConnections().then(() => {
      this.updateWindowTitle();
      this.tryAutoConnect();
      setTimeout(() => this.tryAutoConnect(), 0);
    });
  }

  onPageShow(): void {
    this.updateWindowTitle();
    this.refreshMonitorWindowsState();
    this.applyFullscreenToWindow();
    void this.loadEdgeClampSetting();
    void this.loadAdaptiveResolutionSetting();
    this.tryAutoConnect();
  }

  aboutToDisappear(): void {
    try {
      this.disconnect(true);
    } catch (e) {
    }
    void this.closeMonitorWindows(false);
    viewerMultiWindowStore.disposeSession(this.sharedSessionId);
  }

  private applyWantParams(): boolean {
    try {
      interface WantLike {
        parameters?: Record<string, WantParamValue>;
      }
      interface UIAbilityContextWithWant {
        getWant?: () => WantLike;
        want?: WantLike;
      }
      const ctx = this.getUIContext()?.getHostContext?.() as UIAbilityContextWithWant | undefined;
      const want = (typeof ctx?.getWant === 'function') ? ctx.getWant() : ctx?.want;
      const params = want?.parameters;
      if (!params) return false;

      const address = (params['address'] !== undefined && params['address'] !== null) ? String(params['address']) : '';
      const user = (params['user'] !== undefined && params['user'] !== null) ? String(params['user']) : '';
      const password = (params['password'] !== undefined && params['password'] !== null) ? String(params['password']) : '';
      const name = (params['name'] !== undefined && params['name'] !== null) ? String(params['name']) : '';
      const sshConfigText = (params['sshConfig'] !== undefined && params['sshConfig'] !== null) ? String(params['sshConfig']) : '';
      const touchScrollStepValue = params['touchScrollStep'];
      const runtimeSshConfig = parseSshTunnelConfigText(sshConfigText, address);
      if (!parseAddress(resolveConnectionAddress(address, runtimeSshConfig ?? undefined))) return false;

      this.address = address;
      this.user = user;
      this.password = password;
      this.connName = name;
      this.runtimeSshConfig = runtimeSshConfig;
      this.runtimeTouchScrollStep = typeof touchScrollStepValue === 'number'
        ? this.normalizeTouchScrollStep(touchScrollStepValue)
        : this.normalizeTouchScrollStep(Number.parseInt(String(touchScrollStepValue ?? ''), 10));
      const macModeValue = params['macMode'];
      this.runtimeMacMode = typeof macModeValue === 'boolean' ? macModeValue : (String(macModeValue ?? '') === 'true');
      this.didAdoptServerName = false;
      this.showPassword = false;
      return true;
    } catch (e) {
      return false;
    }
  }

  private getEffectiveSshConfig(): SshTunnelConfig | null {
    if (this.runtimeSshConfig) {
      return normalizeSshTunnelConfigForAddress(this.runtimeSshConfig, this.address);
    }
    const selected = this.getSelectedConnection();
    if (!selected) return null;
    return normalizeSshTunnelConfigForAddress(selected.sshTunnel, selected.address);
  }

  private maybeAdoptServerNameAsConnName(): void {
    if (this.didAdoptServerName) return;
    if ((this.connName ?? '').trim()) return;
    const name = (this.serverName ?? '').trim();
    if (!name) return;
    this.connName = name;
    this.didAdoptServerName = true;
    void this.persistAdoptedServerNameToStore(name);
    this.updateWindowTitle();
  }

  private async persistAdoptedServerNameToStore(name: string): Promise<void> {
    const adopted = (name ?? '').trim();
    if (!adopted) return;

    const addr = (this.address ?? '').trim();
    const selectedId = (this.selectedConnId ?? '').trim();

    try {
      const ctx = this.getHostContext();
      if (!ctx) return;
      const pref = await dataPreferences.getPreferences(ctx, { name: 'vnc_store' });
      const raw = ((await pref.get('connections_v1', '')) as string) ?? '';
      const list = parseConnectionsJson(raw);
      if (list.length === 0) return;

      let changed = false;
      const next: ConnectionItem[] = [];
      for (let i = 0; i < list.length; i++) {
        const it = list[i];
        const match = selectedId ? (it.id === selectedId) : ((it.address ?? '').trim() === addr);
        if (match && !(it.name ?? '').trim()) {
          changed = true;
          next.push({
            id: it.id,
            name: adopted,
            address: it.address,
            user: it.user,
            password: it.password,
            storePassword: it.storePassword,
            touchScrollStep: it.touchScrollStep,
            macMode: it.macMode,
            sshTunnel: normalizeSshTunnelConfigForAddress(it.sshTunnel, it.address),
            lastUsedAt: it.lastUsedAt
          });
        } else {
          next.push(it);
        }
      }
      if (!changed) return;

      await pref.put('connections_v1', JSON.stringify(next));
      await pref.flush();

      if ((this.connections ?? []).length > 0) {
        this.connections = next;
      }
    } catch (e) {
    }
  }

  private updateWindowTitle(): void {
    try {
      const title = this.getWindowTitleText();
      const ctx = this.getHostContext();
      if (!ctx) return;
      window.getLastWindow(ctx)
        .then((win: Object) => {
          try {
            (win as WindowLike)?.setWindowTitle?.(title);
          } catch (e) {
          }
        })
        .catch(() => {
        });
    } catch (e) {
    }
    viewerMultiWindowStore.updateSessionTitle(this.sharedSessionId, this.getWindowTitleText());
  }

  private getWindowTitleText(): string {
    const addr = (this.address ?? '').trim();
    const name = (this.connName ?? '').trim();
    const user = (this.user ?? '').trim();
    let base = name ? name : (addr || 'Viewer');
    if (addr) base += `  ${addr}`;
    if (user) base += `  (${user})`;
    return base;
  }

  private getActiveMonitorRectsForWindows(): VncRect[] {
    if (this.monitors.length > 0) return this.monitors;
    const preview = this.getDisplayPreviewMonitorRects();
    if (preview.length > 0) return preview;
    if (this.fbW > 0 && this.fbH > 0) {
      return [{ x: 0, y: 0, w: this.fbW, h: this.fbH }];
    }
    return [];
  }

  private toSharedViewerRects(rects: VncRect[]): SharedViewerRect[] {
    return rects.map((rect: VncRect): SharedViewerRect => {
      return {
        x: Math.floor(rect.x),
        y: Math.floor(rect.y),
        w: Math.floor(rect.w),
        h: Math.floor(rect.h)
      };
    });
  }

  private syncSharedSessionSnapshot(): void {
    const title = this.getWindowTitleText();
    const rects = this.toSharedViewerRects(this.getActiveMonitorRectsForWindows());
    viewerMultiWindowStore.publishFrame(
      this.sharedSessionId,
      title,
      this.connected && this.fbW > 0 && this.fbH > 0,
      this.fbW,
      this.fbH,
      this.frameCache,
      rects
    );
  }

  private refreshMonitorWindowsState(): void {
    this.monitorWindowsOpenCount = viewerMultiWindowStore.listWindowNames(this.sharedSessionId).length;
  }

  private getMonitorWindowTitle(index: number): string {
    return this.getWindowTitleText() + ' - ' + this.s($r('app.string.viewer_screen_label'), index + 1);
  }

  private estimateMonitorWindowSize(rect: VncRect): WindowSizeLike {
    const aspect = rect.h > 0 ? (rect.w / rect.h) : 1.6;
    let width = Math.round(Math.max(480, Math.min(1280, rect.w)));
    let height = Math.round(width / Math.max(0.4, Math.min(3.2, aspect)));
    height = Math.max(320, Math.min(900, height));
    width = Math.max(420, Math.min(1400, width));
    const size: WindowSizeLike = { width, height };
    return size;
  }

  private async destroyNamedMonitorWindow(windowName: string): Promise<void> {
    try {
      const winObj = window.findWindow?.(windowName);
      if (!winObj) return;
      await (winObj as WindowLike).destroyWindow?.();
    } catch (e) {
    }
  }

  private async createMonitorWindow(index: number, rect: VncRect): Promise<boolean> {
    const ctx = this.getHostContext();
    if (!ctx) {
      console.error('createMonitorWindow: getHostContext returned undefined');
      return false;
    }
    const windowName = `viewer-display:${this.sharedSessionId}:${index}`;
    const title = this.getMonitorWindowTitle(index);
    viewerMultiWindowStore.registerWindow({
      windowName,
      sessionId: this.sharedSessionId,
      monitorIndex: index,
      title
    });
    try {
      console.info('createMonitorWindow: starting DisplayAbility for monitor', index);
      interface WantParameters {
        sessionId: string;
        monitorIndex: number;
        title: string;
        macMode: boolean;
      }
      interface StartWant {
        deviceId: string;
        bundleName: string;
        abilityName: string;
        moduleName: string;
        parameters?: WantParameters;
      }
      const wantParams: WantParameters = {
        sessionId: this.sharedSessionId,
        monitorIndex: index,
        title: title,
        macMode: this.runtimeMacMode
      };
      const want: StartWant = {
        deviceId: '',
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: 'DisplayAbility',
        moduleName: ctx.abilityInfo.moduleName,
        parameters: wantParams
      };
      await ctx.startAbility(want as object);
      console.info('createMonitorWindow: DisplayAbility started successfully for monitor', index);
      return true;
    } catch (e) {
      console.error('createMonitorWindow: error starting DisplayAbility:', e);
      viewerMultiWindowStore.removeWindow(windowName);
      return false;
    }
  }

  private async closeMonitorWindows(showStatus: boolean = true): Promise<void> {
    const names = viewerMultiWindowStore.listWindowNames(this.sharedSessionId);
    for (let i = 0; i < names.length; i++) {
      await this.destroyNamedMonitorWindow(names[i]);
      viewerMultiWindowStore.removeWindow(names[i]);
    }
    this.refreshMonitorWindowsState();
    if (showStatus && names.length > 0) {
      this.showStatusBanner(this.s($r('app.string.viewer_monitor_windows_closed')));
    }
  }

  private async openMonitorWindows(): Promise<void> {
    if (!this.connected) {
      this.toast(this.s($r('app.string.viewer_please_connect_first')));
      return;
    }
    const rects = this.getDisplayPreviewMonitorRects();
    if (rects.length <= 1) {
      this.toast(this.s($r('app.string.viewer_need_two_screens')));
      return;
    }
    this.syncSharedSessionSnapshot();
    await this.closeMonitorWindows(false);
    let opened = 0;
    for (let i = 0; i < rects.length; i++) {
      const ok = await this.createMonitorWindow(i, rects[i]);
      if (ok) opened++;
    }
    this.refreshMonitorWindowsState();
    if (opened > 0) {
      this.showStatusBanner(this.s($r('app.string.viewer_monitor_windows_opened'), opened));
    } else {
      this.toast(this.s($r('app.string.viewer_open_monitor_failed')));
    }
  }

  private cloneMonitorRects(rects: VncRect[]): VncRect[] {
    return rects.map((rect: VncRect): VncRect => {
      return {
        x: Math.floor(rect.x),
        y: Math.floor(rect.y),
        w: Math.floor(rect.w),
        h: Math.floor(rect.h)
      };
    });
  }

  private clearManualMonitorLayout(): void {
    this.manualMonitorRects = [];
    this.manualMonitorDrafts = [];
    this.manualDragMonitorIndex = -1;
    this.resetManualDragStrokeState();
  }

  private getCommonMonitorAspectOptions(): MonitorAspectOption[] {
    return [
      { label: '21:9', ratio: 21 / 9 },
      { label: '16:9', ratio: 16 / 9 },
      { label: '16:10', ratio: 16 / 10 },
      { label: '3:2', ratio: 3 / 2 },
      { label: '5:4', ratio: 5 / 4 },
      { label: '4:3', ratio: 4 / 3 },
      { label: '10:16', ratio: 10 / 16 },
      { label: '9:16', ratio: 9 / 16 }
    ];
  }

  private roundMonitorDimension(value: number): number {
    const rounded = Math.round(value);
    // 常见显示器分辨率的宽或高通常是这些精确值，直接做吸附
    const commonDimensions = [
      720, 768, 800, 900, 1024, 1050, 1080, 1152, 1200, 1280, 1366, 1440,
      1600, 1680, 1920, 2160, 2400, 2560, 2880, 3440, 3840, 4320, 5120
    ];
    for (let i = 0; i < commonDimensions.length; i++) {
      if (Math.abs(rounded - commonDimensions[i]) <= 32) {
        return commonDimensions[i];
      }
    }
    // 如果都不在常见列表里，至少保证是 8 或 16 的倍数
    const step = rounded >= 1200 ? 16 : 8;
    return Math.max(step, Math.round(rounded / step) * step);
  }

  private findNearestSnapValue(value: number, candidates: number[], threshold: number): number {
    let best = value;
    let bestDistance = threshold + 1;
    for (let i = 0; i < candidates.length; i++) {
      const distance = Math.abs(value - candidates[i]);
      if (distance <= threshold && distance < bestDistance) {
        best = candidates[i];
        bestDistance = distance;
      }
    }
    return best;
  }

  private snapMonitorRectEdges(rect: VncRect, index: number): VncRect {
    if (this.fbW <= 0 || this.fbH <= 0) {
      return rect;
    }
    const xCandidates: number[] = [0, this.fbW];
    const yCandidates: number[] = [0, this.fbH];
    for (let i = 0; i < this.manualMonitorRects.length; i++) {
      if (i === index) {
        continue;
      }
      const other = this.manualMonitorRects[i];
      xCandidates.push(other.x);
      xCandidates.push(other.x + other.w);
      yCandidates.push(other.y);
      yCandidates.push(other.y + other.h);
    }
    const thresholdX = Math.max(24, Math.floor(this.fbW * 0.012));
    const thresholdY = Math.max(24, Math.floor(this.fbH * 0.02));
    let left = this.findNearestSnapValue(rect.x, xCandidates, thresholdX);
    let right = this.findNearestSnapValue(rect.x + rect.w, xCandidates, thresholdX);
    let top = this.findNearestSnapValue(rect.y, yCandidates, thresholdY);
    let bottom = this.findNearestSnapValue(rect.y + rect.h, yCandidates, thresholdY);
    if (right <= left) {
      right = Math.min(this.fbW, left + Math.max(1, rect.w));
    }
    if (bottom <= top) {
      bottom = Math.min(this.fbH, top + Math.max(1, rect.h));
    }
    return {
      x: left,
      y: top,
      w: right - left,
      h: bottom - top
    };
  }

  private roundManualMonitorRectToCommonSize(rect: VncRect, index: number): VncRect {
    if (this.fbW <= 0 || this.fbH <= 0) {
      return rect;
    }
    let next = this.snapMonitorRectEdges(rect, index);
    const edgeThresholdY = Math.max(28, Math.floor(this.fbH * 0.02));
    const nearTop = next.y <= edgeThresholdY;
    const nearBottom = Math.abs((next.y + next.h) - this.fbH) <= edgeThresholdY;
    const nearlyFullHeight = next.h >= Math.floor(this.fbH * 0.78);
    if ((nearTop && nearBottom) || nearlyFullHeight) {
      next.y = 0;
      next.h = this.fbH;
    } else {
      next.h = this.roundMonitorDimension(next.h);
      if (nearTop) next.y = 0;
      else if (nearBottom) next.y = this.fbH - next.h;
    }
    let preferredWidth = this.roundMonitorDimension(next.w);
    let chosenRatioDelta = Number.POSITIVE_INFINITY;
    const currentRatio = next.w / Math.max(1, next.h);
    const ratioOptions = this.getCommonMonitorAspectOptions();
    for (let i = 0; i < ratioOptions.length; i++) {
      const width = this.roundMonitorDimension(ratioOptions[i].ratio * next.h);
      const delta = Math.abs(currentRatio - ratioOptions[i].ratio);
      if (width <= 0 || width > this.fbW) {
        continue;
      }
      if (delta < chosenRatioDelta) {
        chosenRatioDelta = delta;
        preferredWidth = width;
      }
    }
    const alignThresholdX = Math.max(24, Math.floor(this.fbW * 0.012));
    const currentLeft = next.x;
    const currentRight = next.x + next.w;
    const snappedLeft = this.findNearestSnapValue(currentLeft, [0, this.fbW], alignThresholdX);
    const snappedRight = this.findNearestSnapValue(currentRight, [0, this.fbW], alignThresholdX);
    if (chosenRatioDelta <= 0.42) {
      if (Math.abs(snappedLeft - currentLeft) <= alignThresholdX) {
        next.x = snappedLeft;
        next.w = preferredWidth;
      } else if (Math.abs(snappedRight - currentRight) <= alignThresholdX) {
        next.w = preferredWidth;
        next.x = snappedRight - next.w;
      } else {
        const center = next.x + (next.w / 2);
        next.w = preferredWidth;
        next.x = Math.round(center - (next.w / 2));
      }
    } else {
      next.w = preferredWidth;
      if (Math.abs(snappedLeft - currentLeft) <= alignThresholdX) {
        next.x = snappedLeft;
      } else if (Math.abs(snappedRight - currentRight) <= alignThresholdX) {
        next.x = snappedRight - next.w;
      }
    }
    next = this.snapMonitorRectEdges(next, index);
    return this.clampManualMonitorRect(next) ?? rect;
  }

  private formatManualMonitorDraft(rect: VncRect): string {
    return `${Math.floor(rect.x)},${Math.floor(rect.y)},${Math.floor(rect.w)},${Math.floor(rect.h)}`;
  }

  private syncManualMonitorDrafts(): void {
    this.manualMonitorDrafts = this.manualMonitorRects.map((rect: VncRect): string => this.formatManualMonitorDraft(rect));
  }

  private clampManualMonitorRect(rect: VncRect): VncRect | null {
    if (this.fbW <= 0 || this.fbH <= 0) {
      return null;
    }
    const x = Math.max(0, Math.min(this.fbW - 1, Math.floor(rect.x)));
    const y = Math.max(0, Math.min(this.fbH - 1, Math.floor(rect.y)));
    const maxWidth = Math.max(1, this.fbW - x);
    const maxHeight = Math.max(1, this.fbH - y);
    const w = Math.max(1, Math.min(maxWidth, Math.floor(rect.w)));
    const h = Math.max(1, Math.min(maxHeight, Math.floor(rect.h)));
    if (w <= 0 || h <= 0) {
      return null;
    }
    return { x, y, w, h };
  }

  private sanitizeManualMonitorRects(rects: VncRect[]): VncRect[] {
    const next: VncRect[] = [];
    for (let i = 0; i < rects.length; i++) {
      const normalized = this.clampManualMonitorRect(rects[i]);
      if (normalized) {
        next.push(normalized);
      }
    }
    return next;
  }

  private ensureManualMonitorBase(): void {
    if (this.manualMonitorRects.length > 0) {
      return;
    }
    const preview = this.sanitizeManualMonitorRects(this.getDisplayPreviewMonitorRects());
    this.manualMonitorRects = preview;
    this.monitorLayoutLocked = false;
  }

  private beginDisplayScreenEditing(): void {
    this.ensureManualMonitorBase();
    this.syncManualMonitorDrafts();
    this.displayEditingScreens = true;
  }

  private appendManualMonitorRect(compact: boolean): number {
    if (this.fbW <= 0 || this.fbH <= 0) {
      return -1;
    }
    this.ensureManualMonitorBase();
    const rects = this.manualMonitorRects.slice();
    if (rects.length >= MAX_MANUAL_MONITOR_COUNT) {
      this.showStatusBanner(this.s($r('app.string.monitor_max_screen_count'), MAX_MANUAL_MONITOR_COUNT));
      return -1;
    }
    if (compact) {
      // 拖拽加屏：先放入最小占位矩形，等待用户在主画面上拖出实际范围
      const seed = this.clampManualMonitorRect({ x: 0, y: 0, w: 1, h: 1 });
      if (!seed) {
        return -1;
      }
      rects.push(seed);
    } else {
      // 追加：优先放到已有屏幕右侧/下方的空位，尺寸参考现有屏幕并吸附常见规格
      let preferW = Math.max(1, Math.floor(this.fbW / 2));
      let preferH = Math.max(1, Math.floor(this.fbH / 2));
      let x = 0;
      let y = 0;
      if (rects.length > 0) {
        let sumW = 0;
        let sumH = 0;
        let maxRight = 0;
        let maxBottom = 0;
        for (let i = 0; i < rects.length; i++) {
          sumW += rects[i].w;
          sumH += rects[i].h;
          maxRight = Math.max(maxRight, rects[i].x + rects[i].w);
          maxBottom = Math.max(maxBottom, rects[i].y + rects[i].h);
        }
        const avgW = Math.floor(sumW / rects.length);
        const avgH = Math.floor(sumH / rects.length);
        if (avgW > 0) {
          preferW = avgW;
        }
        if (avgH > 0) {
          preferH = avgH;
        }
        if (maxRight < this.fbW) {
          x = maxRight;
          y = 0;
          preferW = Math.min(preferW, this.fbW - maxRight);
        } else if (maxBottom < this.fbH) {
          x = 0;
          y = maxBottom;
          preferH = Math.min(preferH, this.fbH - maxBottom);
        } else {
          x = Math.max(0, Math.floor((this.fbW - preferW) / 2));
          y = Math.max(0, Math.floor((this.fbH - preferH) / 2));
        }
      }
      const candidate = this.clampManualMonitorRect({ x: x, y: y, w: preferW, h: preferH });
      if (!candidate) {
        return -1;
      }
      const rounded = this.roundManualMonitorRectToCommonSize(candidate, rects.length);
      rects.push(rounded);
    }
    const sanitized = this.sanitizeManualMonitorRects(rects);
    if (sanitized.length !== rects.length) {
      return -1;
    }
    this.manualMonitorRects = sanitized;
    this.syncManualMonitorDrafts();
    return this.manualMonitorRects.length - 1;
  }

  private addManualMonitor(): void {
    const index = this.appendManualMonitorRect(false);
    if (index >= 0) {
      this.showStatusBanner(this.s($r('app.string.monitor_added_screen_n'), index + 1));
    }
  }

  private addManualMonitorByDraw(): void {
    const index = this.appendManualMonitorRect(true);
    if (index < 0) {
      return;
    }
    this.manualDragMonitorIndex = index;
    this.manualDragActive = false;
    this.manualDragNewScreen = true;
    this.setViewportMode('all');
    this.closePanel();
    this.showStatusBanner(this.s($r('app.string.monitor_draw_new_screen_hint'), index + 1));
  }

  private removeManualMonitorRect(index: number): void {
    if (index < 0 || index >= this.manualMonitorRects.length) {
      return;
    }
    if (this.manualMonitorRects.length <= 1) {
      this.showStatusBanner(this.s($r('app.string.monitor_keep_one_screen')));
      return;
    }
    const rects = this.manualMonitorRects.slice();
    rects.splice(index, 1);
    this.manualMonitorRects = this.sanitizeManualMonitorRects(rects);
    this.syncManualMonitorDrafts();
    if (this.manualDragMonitorIndex === index) {
      this.manualDragMonitorIndex = -1;
      this.manualDragActive = false;
    } else if (this.manualDragMonitorIndex > index) {
      this.manualDragMonitorIndex -= 1;
    }
    this.showStatusBanner(this.s($r('app.string.monitor_removed_screen_n'), index + 1));
  }

  private parseManualMonitorDraft(text: string): VncRect | null {
    const normalizedText = (text ?? '').trim();
    if (!normalizedText) {
      return null;
    }
    const parts = normalizedText.split(',').map((part: string): number => Number(part.trim()));
    if (parts.length !== 4) {
      return null;
    }
    for (let i = 0; i < parts.length; i++) {
      if (!Number.isFinite(parts[i])) {
        return null;
      }
    }
    return this.clampManualMonitorRect({
      x: parts[0],
      y: parts[1],
      w: parts[2],
      h: parts[3]
    });
  }

  private updateManualMonitorDraft(index: number, value: string): void {
    const drafts = this.manualMonitorDrafts.slice();
    drafts[index] = value;
    this.manualMonitorDrafts = drafts;
    const parsed = this.parseManualMonitorDraft(value);
    if (!parsed) {
      return;
    }
    const rects = this.manualMonitorRects.slice();
    rects[index] = parsed;
    this.manualMonitorRects = this.sanitizeManualMonitorRects(rects);
  }

  private getDisplayPreviewTouchPoint(ev: TouchEvent): LocalPoint | null {
    const point = ev?.touches?.[0] ?? ev?.changedTouches?.[0];
    if (!point) {
      return null;
    }
    return {
      x: point.x ?? 0,
      y: point.y ?? 0
    };
  }

  private mapPreviewPointToFramebuffer(point: LocalPoint): LocalPoint | null {
    if (this.fbW <= 0 || this.fbH <= 0) {
      return null;
    }
    const frame = this.getDisplayPreviewImageMetrics().frame;
    if (frame.w <= 0 || frame.h <= 0) {
      return null;
    }
    const localX = this.clamp(point.x - frame.x, 0, frame.w);
    const localY = this.clamp(point.y - frame.y, 0, frame.h);
    return {
      x: Math.floor((localX / Math.max(1, frame.w)) * this.fbW),
      y: Math.floor((localY / Math.max(1, frame.h)) * this.fbH)
    };
  }

  private updateManualMonitorRectFromDrag(index: number, start: LocalPoint, end: LocalPoint): void {
    if (index < 0 || index >= this.manualMonitorRects.length) {
      return;
    }
    const next = this.clampManualMonitorRect({
      x: Math.min(start.x, end.x),
      y: Math.min(start.y, end.y),
      w: Math.abs(end.x - start.x),
      h: Math.abs(end.y - start.y)
    });
    if (!next) {
      return;
    }
    const rects = this.manualMonitorRects.slice();
    rects[index] = next;
    this.manualMonitorRects = this.sanitizeManualMonitorRects(rects);
    this.syncManualMonitorDrafts();
  }

  private finalizeManualMonitorDrag(index: number): void {
    if (index < 0 || index >= this.manualMonitorRects.length) {
      return;
    }
    const rects = this.manualMonitorRects.slice();
    let current = rects[index];

    const snapThreshold = Math.max(20, Math.floor(this.fbW * 0.02));
    let snapX = current.x;
    let snapY = current.y;
    let snapRight = current.x + current.w;
    let snapBottom = current.y + current.h;

    if (Math.abs(snapX) < snapThreshold) snapX = 0;
    if (Math.abs(snapY) < snapThreshold) snapY = 0;
    if (Math.abs(this.fbW - snapRight) < snapThreshold) snapRight = this.fbW;
    if (Math.abs(this.fbH - snapBottom) < snapThreshold) snapBottom = this.fbH;

    for (let i = 0; i < rects.length; i++) {
      if (i === index) continue;
      const other = rects[i];
      const otherRight = other.x + other.w;
      const otherBottom = other.y + other.h;

      if (Math.abs(snapX - otherRight) < snapThreshold) snapX = otherRight;
      if (Math.abs(snapRight - other.x) < snapThreshold) snapRight = other.x;
      if (Math.abs(snapY - otherBottom) < snapThreshold) snapY = otherBottom;
      if (Math.abs(snapBottom - other.y) < snapThreshold) snapBottom = other.y;
    }

    const snappedRect = this.clampManualMonitorRect({
      x: snapX,
      y: snapY,
      w: Math.max(1, snapRight - snapX),
      h: Math.max(1, snapBottom - snapY)
    });

    if (snappedRect) {
      current = snappedRect;
    }

    const rounded = this.roundManualMonitorRectToCommonSize(current, index);
    rects[index] = rounded;
    this.manualMonitorRects = this.sanitizeManualMonitorRects(rects);
    this.syncManualMonitorDrafts();
  }

  private beginManualMonitorRectDrag(index: number): void {
    if (index < 0 || index >= this.manualMonitorRects.length) {
      return;
    }
    this.manualDragNewScreen = false;
    this.manualDragMonitorIndex = this.manualDragMonitorIndex === index ? -1 : index;
    this.resetManualDragStrokeState();
    if (this.manualDragMonitorIndex >= 0) {
      this.setViewportMode('all');
      this.closePanel();
      this.showStatusBanner(this.s($r('app.string.monitor_drag_define_screen'), index + 1));
    }
  }

  private resetManualDragStrokeState(): void {
    this.manualDragActive = false;
    this.manualDragAction = 'none';
    this.moveStartRect = null;
    this.manualDragBackupRect = null;
  }

  private finishManualMonitorDragSession(index: number): void {
    this.finalizeManualMonitorDrag(index);
    this.showStatusBanner(this.s($r('app.string.monitor_end_drag_screen'), index + 1));
    // 拖拽定义是"模式"而非"一笔"：松手仅结束本次笔画，保持定义模式、覆盖层与
    // 底部悬浮操作条，让用户继续拖拽或切换编号定义其他屏；退出经操作条"完成"
    this.resetManualDragStrokeState();
  }

  private cancelManualMonitorDragSession(): void {
    // 系统打断（Cancel）：还原本次按下前的屏幕矩形，仍停留在拖拽定义模式
    const index = this.manualDragMonitorIndex;
    if (index >= 0 && index < this.manualMonitorRects.length && this.manualDragBackupRect) {
      const rects = this.manualMonitorRects.slice();
      rects[index] = this.manualDragBackupRect;
      this.manualMonitorRects = this.sanitizeManualMonitorRects(rects);
      this.syncManualMonitorDrafts();
    }
    this.resetManualDragStrokeState();
  }

  private handleDisplayPreviewTouch(ev: TouchEvent): void {
    this.handleChromeTouchInteraction(ev);
    if (this.manualDragMonitorIndex < 0 || this.manualMonitorRects.length <= 0) {
      return;
    }
    const point = this.getDisplayPreviewTouchPoint(ev);
    const fbPoint = point ? this.mapPreviewPointToFramebuffer(point) : null;
    if (!fbPoint) {
      return;
    }
    const type = ev?.type;
    if (type === TouchType.Down) {
      this.manualDragActive = true;
      this.manualDragStartX = fbPoint.x;
      this.manualDragStartY = fbPoint.y;
      const backup = this.manualMonitorRects[this.manualDragMonitorIndex];
      this.manualDragBackupRect = backup ? { x: backup.x, y: backup.y, w: backup.w, h: backup.h } : null;
      this.updateManualMonitorRectFromDrag(this.manualDragMonitorIndex, fbPoint, fbPoint);
      return;
    }
    if (type === TouchType.Move && this.manualDragActive) {
      this.updateManualMonitorRectFromDrag(this.manualDragMonitorIndex, {
        x: this.manualDragStartX,
        y: this.manualDragStartY
      }, fbPoint);
      return;
    }
    if (type === TouchType.Up) {
      if (this.manualDragActive) {
        this.finishManualMonitorDragSession(this.manualDragMonitorIndex);
      }
      return;
    }
    if (type === TouchType.Cancel) {
      this.cancelManualMonitorDragSession();
    }
  }

  private handleViewerManualMonitorTouch(localX: number, localY: number, type: TouchType): boolean {
    if (this.manualDragMonitorIndex < 0 || this.manualMonitorRects.length <= 0) {
      return false;
    }
    const point = this.mapToRemotePoint(localX, localY);
    const fbPoint: LocalPoint = { x: point.x, y: point.y };
    if (type === TouchType.Down) {
      const rect = this.manualMonitorRects[this.manualDragMonitorIndex];
      const overlayRect = this.getViewerOverlayMonitorRect(rect);
      const cx = overlayRect.x + overlayRect.w / 2;
      const cy = overlayRect.y + overlayRect.h / 2;
      const dist = Math.hypot(localX - cx, localY - cy);

      if (this.manualDragNewScreen) {
        // 拖拽加屏：首次按下强制进入画框，避免命中占位矩形中心被判定为移动
        this.manualDragAction = 'draw';
        this.manualDragNewScreen = false;
      } else if (dist <= 44) {
        this.manualDragAction = 'move';
        this.moveStartRect = { x: rect.x, y: rect.y, w: rect.w, h: rect.h };
      } else {
        this.manualDragAction = 'draw';
      }

      this.manualDragActive = true;
      this.manualDragStartX = fbPoint.x;
      this.manualDragStartY = fbPoint.y;
      const backup = this.manualMonitorRects[this.manualDragMonitorIndex];
      this.manualDragBackupRect = backup ? { x: backup.x, y: backup.y, w: backup.w, h: backup.h } : null;

      if (this.manualDragAction === 'draw') {
        this.updateManualMonitorRectFromDrag(this.manualDragMonitorIndex, fbPoint, fbPoint);
      }
      return true;
    }
    if (type === TouchType.Move && this.manualDragActive) {
      if (this.manualDragAction === 'move' && this.moveStartRect) {
        const dx = fbPoint.x - this.manualDragStartX;
        const dy = fbPoint.y - this.manualDragStartY;
        const newRect = this.clampManualMonitorRect({
          x: this.moveStartRect.x + dx,
          y: this.moveStartRect.y + dy,
          w: this.moveStartRect.w,
          h: this.moveStartRect.h
        });
        if (newRect) {
          const rects = this.manualMonitorRects.slice();
          rects[this.manualDragMonitorIndex] = newRect;
          this.manualMonitorRects = rects;
          this.syncManualMonitorDrafts();
        }
      } else if (this.manualDragAction === 'draw') {
        this.updateManualMonitorRectFromDrag(this.manualDragMonitorIndex, {
          x: this.manualDragStartX,
          y: this.manualDragStartY
        }, fbPoint);
      }
      return true;
    }
    if (type === TouchType.Up) {
      if (this.manualDragActive) {
        if (this.manualDragAction === 'move' && this.moveStartRect) {
          const dx = fbPoint.x - this.manualDragStartX;
          const dy = fbPoint.y - this.manualDragStartY;
          const newRect = this.clampManualMonitorRect({
            x: this.moveStartRect.x + dx,
            y: this.moveStartRect.y + dy,
            w: this.moveStartRect.w,
            h: this.moveStartRect.h
          });
          if (newRect) {
            const rects = this.manualMonitorRects.slice();
            rects[this.manualDragMonitorIndex] = newRect;
            this.manualMonitorRects = rects;
          }
        } else if (this.manualDragAction === 'draw') {
          this.updateManualMonitorRectFromDrag(this.manualDragMonitorIndex, {
            x: this.manualDragStartX,
            y: this.manualDragStartY
          }, fbPoint);
        }
        this.finishManualMonitorDragSession(this.manualDragMonitorIndex);
      }
      return true;
    }
    if (type === TouchType.Cancel) {
      this.cancelManualMonitorDragSession();
      return true;
    }
    return false;
  }

  private isUsingManualMonitorLayout(): boolean {
    return this.manualMonitorRects.length > 0;
  }

  private normalizeSavedMonitorLayout(raw: SavedMonitorLayout | null | undefined): SavedMonitorLayout | null {
    if (!raw || !Array.isArray(raw.rects)) {
      return null;
    }
    const width = Math.max(0, Math.floor(raw.width ?? 0));
    const height = Math.max(0, Math.floor(raw.height ?? 0));
    if (width <= 0 || height <= 0) {
      return null;
    }
    const rects: VncRect[] = [];
    for (let i = 0; i < raw.rects.length; i++) {
      const rect = raw.rects[i];
      const x = Math.max(0, Math.floor(rect?.x ?? 0));
      const y = Math.max(0, Math.floor(rect?.y ?? 0));
      const w = Math.max(0, Math.floor(rect?.w ?? 0));
      const h = Math.max(0, Math.floor(rect?.h ?? 0));
      if (w <= 0 || h <= 0) {
        continue;
      }
      rects.push({ x, y, w, h });
    }
    if (rects.length <= 0) {
      return null;
    }
    return { width, height, rects };
  }

  private getMonitorLayoutStorageKey(): string {
    const selectedId = (this.selectedConnId ?? '').trim();
    if (selectedId) {
      return `monitor_layout_v1:${selectedId}`;
    }
    const addr = (this.address ?? '').trim();
    return addr ? `monitor_layout_v1:${addr}` : '';
  }

  private async restoreSavedMonitorLayoutIfAvailable(): Promise<void> {
    const key = this.getMonitorLayoutStorageKey();
    if (!key || this.fbW <= 0 || this.fbH <= 0) {
      return;
    }
    try {
      const ctx = this.getHostContext();
      if (!ctx) return;
      const pref = await dataPreferences.getPreferences(ctx, { name: 'vnc_store' });
      const raw = ((await pref.get(key, '')) as string) ?? '';
      if (!raw) return;
      const saved = this.normalizeSavedMonitorLayout(JSON.parse(raw) as SavedMonitorLayout);
      if (!saved || saved.rects.length <= 1) {
        return;
      }
      if (saved.width !== this.fbW || saved.height !== this.fbH) {
        return;
      }
      this.clearManualMonitorLayout();
      this.monitorLayoutLocked = true;
      this.setDetectedMonitorRects(saved.rects);
      this.setActiveMonitorRects(saved.rects);
    } catch (e) {
    }
  }

  private async persistConfirmedMonitorLayout(): Promise<void> {
    const key = this.getMonitorLayoutStorageKey();
    if (!key || this.fbW <= 0 || this.fbH <= 0 || this.monitors.length <= 1) {
      return;
    }
    try {
      const ctx = this.getHostContext();
      if (!ctx) return;
      const pref = await dataPreferences.getPreferences(ctx, { name: 'vnc_store' });
      const payload: SavedMonitorLayout = {
        width: this.fbW,
        height: this.fbH,
        rects: this.cloneMonitorRects(this.monitors)
      };
      await pref.put(key, JSON.stringify(payload));
      await pref.flush();
    } catch (e) {
    }
  }

  private getDisplayPreviewMonitorRects(): VncRect[] {
    if (this.manualMonitorRects.length > 0) {
      return this.manualMonitorRects;
    }
    if (this.monitorLayoutLocked && this.monitors.length > 1) {
      return this.monitors;
    }
    if (this.detectedMonitorRects.length > 0) {
      return this.detectedMonitorRects;
    }
    return this.monitors;
  }

  private confirmMonitorLayout(): void {
    const rects = this.sanitizeManualMonitorRects(this.getDisplayPreviewMonitorRects());
    if (rects.length <= 0) {
      this.showStatusBanner(this.s($r('app.string.monitor_no_monitors_detected')));
      return;
    }
    this.clearManualMonitorLayout();
    this.setActiveMonitorRects(rects);
    this.monitorLayoutLocked = rects.length > 1;
    if (rects.length > 1) {
      void this.persistConfirmedMonitorLayout();
      this.showStatusBanner(this.s($r('app.string.monitor_reset_layout')));
      return;
    }
    // 单一屏不支持手动布局（面板"记住布局"在预览屏数 <= 1 时禁用，因此这里通常不可达）；
    // 保留作为兜底：清洗后仅剩一屏时只应用不落盘，也不锁定布局
    this.showStatusBanner(this.s($r('app.string.monitor_only_one_detected')));
  }

  private redetectMonitorLayout(): void {
    if (!this.connected) return;
    this.clearManualMonitorLayout();
    this.monitorLayoutLocked = false;
    this.beginDisplayDetectionRetry();
    this.requestDisplayFullRefresh();
    this.prepareDisplayPanel();
    this.showStatusBanner(this.s($r('app.string.monitor_detecting')));
  }

  private applyFullscreenToWindow(): void {
    try {
      const ctx = this.getHostContext();
      if (!ctx) return;
      const enable = this.isFullscreen;
      window.getLastWindow(ctx)
        .then((win: Object) => {
          try {
            const w = win as WindowLike;
            w.setWindowDecorVisible?.(!enable);
            w.setWindowLayoutFullScreen?.(enable);
            w.setFullScreen?.(enable);
            const bars: Array<'status' | 'navigation'> = enable ? [] : ['status', 'navigation'];
            try {
              w.setWindowSystemBarEnable?.(bars, (_err?: WindowErrorLike) => {
              });
            } catch (e) {
            }
            try {
              w.setSystemBarEnable?.(bars);
            } catch (e) {
            }
            try {
              const props: SystemBarPropertiesLike = enable
                ? {
                  statusBarColor: '#00000000',
                  navigationBarColor: '#00000000',
                  statusBarContentColor: '#00000000',
                  navigationBarContentColor: '#00000000'
                }
                : {
                  statusBarColor: this.cSurface,
                  navigationBarColor: this.cSurface,
                  statusBarContentColor: '#000000',
                  navigationBarContentColor: '#000000'
                };
              w.setWindowSystemBarProperties?.(props);
            } catch (e) {
            }
          } catch (e) {
          }
        })
        .catch(() => {
        });
    } catch (e) {
    }
  }

  private toggleFullscreen(): void {
    this.isFullscreen = !this.isFullscreen;
    this.applyFullscreenToWindow();
    setTimeout(() => this.applyFullscreenToWindow(), 80);
    setTimeout(() => this.applyFullscreenToWindow(), 240);
    setTimeout(() => this.applyFullscreenToWindow(), 600);
    this.revealChrome();
    this.showStatusBanner(this.s($r(this.isFullscreen ? 'app.string.viewer_enter_fullscreen' : 'app.string.viewer_exit_fullscreen')));
  }

  private ensureFsBtnPosition(): void {
    const size = 28;
    const pad = 10;
    if (!this.fsBtnInited && this.viewerW > 1 && this.viewerH > 1) {
      this.fsBtnX = Math.max(pad, Math.floor((this.viewerW - size) / 2));
      this.fsBtnY = pad;
      this.fsBtnInited = true;
      return;
    }
    this.fsBtnX = this.clamp(this.fsBtnX, pad, Math.max(pad, this.viewerW - size - pad));
    this.fsBtnY = this.clamp(this.fsBtnY, pad, Math.max(pad, this.viewerH - size - pad));
  }

  private clamp(v: number, min: number, max: number): number {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  private getSessionTitle(): string {
    const name = (this.connName ?? '').trim();
    if (name) return name;
    const server = (this.serverName ?? '').trim();
    if (server) return server;
    const addr = (this.address ?? '').trim();
    if (addr) return addr;
    return this.s($r('app.string.viewer_session_title'));
  }

  private getSessionSubtitle(): string {
    const addr = (this.address ?? '').trim();
    if (!addr) return this.s($r('app.string.viewer_enter_address_hint'));
    if (this.connected && this.fbW > 0 && this.fbH > 0) return `${addr}  ·  ${this.fbW}x${this.fbH}`;
    return addr;
  }

  private getConnectionStateText(): string {
    if (this.connecting) return this.s($r('app.string.conn_connecting'));
    if (this.lastError) return this.s($r('app.string.conn_failed'));
    if (this.connected && !this.pm) return this.s($r('app.string.conn_waiting_first_frame'));
    if (this.connected) return this.s($r('app.string.conn_connected'));
    return this.s($r('app.string.conn_not_connected'));
  }

  private getConnectionStateColor(): string {
    if (this.lastError) return this.cError;
    if (this.connected) return this.cSuccess;
    if (this.connecting) return this.cWarning;
    return this.cTextSecondary;
  }

  private getSecurityLabel(): string {
    if (!this.connected) return this.s($r('app.string.security_not_connected'));
    if (this.securityLevel === 0) return this.s($r('app.string.security_insecure'));
    if (this.securityLevel === 1) return this.s($r('app.string.security_auth_safe'));
    return this.s($r('app.string.security_safe'));
  }

  private getSecurityDescription(): string {
    if (!this.connected) return this.s($r('app.string.security_desc_not_connected'));
    if (this.securityLevel === 0) return this.s($r('app.string.security_desc_insecure'));
    if (this.securityLevel === 1) return this.s($r('app.string.security_desc_auth_safe'));
    return this.s($r('app.string.security_desc_safe'));
  }

  private getSecurityBadgeColor(): string {
    if (!this.connected || this.securityLevel === 0) return this.cError;
    if (this.securityLevel === 1) return this.cWarning;
    return this.cSuccess;
  }

  private shouldAutoHideChrome(): boolean {
    return this.connected &&
      this.panelMode === 'none' &&
      !this.editOpen &&
      !this.connecting &&
      !this.lastError &&
      !!this.pm &&
      !this.chromeHovering &&
      !this.chromePressing;
  }

  private shouldRenderChrome(): boolean {
    // 拖拽定义屏幕进行中：不显示导航工具栏（缩放/导航），页面出口由
    // 底部悬浮操作条（屏幕编号 + 完成）提供
    if (this.manualDragMonitorIndex >= 0) {
      return false;
    }
    return !this.connected ||
      this.panelMode !== 'none' ||
      this.editOpen ||
      this.connecting ||
      !!this.lastError ||
      !this.pm ||
      this.chromeVisible;
  }

  private clearChromeAutoHide(): void {
    if (this.chromeHideTimer !== -1) {
      clearTimeout(this.chromeHideTimer);
      this.chromeHideTimer = -1;
    }
  }

  private scheduleChromeAutoHide(delayMs: number = this.chromeAutoHideMs): void {
    this.clearChromeAutoHide();
    if (!this.shouldAutoHideChrome()) {
      this.chromeVisible = true;
      return;
    }
    this.chromeHideTimer = setTimeout(() => {
      if (this.shouldAutoHideChrome()) {
        this.chromeVisible = false;
      }
      this.chromeHideTimer = -1;
    }, delayMs);
  }

  private revealChrome(pin: boolean = false): void {
    this.chromeVisible = true;
    if (pin) {
      this.clearChromeAutoHide();
      return;
    }
    this.scheduleChromeAutoHide();
  }

  private handleViewerFrameReady(): void {
    if (!this.connected) return;
    if (this.panelMode !== 'none' || this.editOpen || this.connecting || !!this.lastError) return;
    this.revealChrome();
  }

  private closePanel(): void {
    this.stopDisplayDetectionRetry();
    this.displayEditingScreens = false;
    this.panelMode = 'none';
    this.scheduleChromeAutoHide();
  }

  private togglePanel(mode: 'clipboard' | 'display' | 'more' | 'security' | 'connection' | 'developer'): void {
    if (this.panelMode === mode) {
      this.closePanel();
      return;
    }
    this.displayEditingScreens = false;
    this.panelMode = mode;
    if (mode === 'display') {
      this.beginDisplayDetectionRetry();
      this.prepareDisplayPanel();
      // 拖拽定义进行中时直接回到编辑视图，方便点“结束拖拽”
      if (this.manualDragMonitorIndex >= 0) {
        this.displayEditingScreens = true;
      }
    }
    this.revealChrome(true);
  }

  private canOpenDisplayPanel(): boolean {
    return this.connected || this.frameCache !== null || (this.fbW > 0 && this.fbH > 0);
  }

  private stopDisplayDetectionRetry(): void {
    if (this.displayDetectRetryTimer !== -1) {
      clearTimeout(this.displayDetectRetryTimer);
      this.displayDetectRetryTimer = -1;
    }
    this.displayDetectRetryLeft = 0;
    this.detectingDisplayLayout = false;
  }

  private beginDisplayDetectionRetry(): void {
    this.displayDetectRetryLeft = Math.max(this.displayDetectRetryLeft, 8);
    this.detectingDisplayLayout = true;
  }

  private queueDisplayDetectionRetry(): void {
    if (this.panelMode !== 'display' || this.displayDetectRetryLeft <= 0 || this.displayDetectRetryTimer !== -1) {
      if (this.panelMode === 'display' && this.displayDetectRetryLeft > 0) {
        this.detectingDisplayLayout = true;
      }
      return;
    }
    this.detectingDisplayLayout = true;
    this.displayDetectRetryTimer = setTimeout(() => {
      this.displayDetectRetryTimer = -1;
      if (this.panelMode !== 'display') {
        this.stopDisplayDetectionRetry();
        return;
      }
      this.displayDetectRetryLeft = Math.max(0, this.displayDetectRetryLeft - 1);
      if (this.displayDetectRetryLeft <= 0) {
        this.detectingDisplayLayout = false;
      }
      this.requestDisplayFullRefresh();
      this.prepareDisplayPanel();
    }, 180);
  }

  private requestDisplayFullRefresh(): void {
    if (!this.connected) return;
    this.lastFullFrameSyncTs = 0;
    this.lastServerRefreshRequestTs = Date.now();
    try {
      this.vncClient.refresh();
    } catch (e) {
    }
    this.requestTick();
  }

  private prepareDisplayPanel(): void {
    if (!this.connected) {
      this.stopDisplayDetectionRetry();
      this.setDetectedMonitorRects([]);
      this.setActiveMonitorRects([]);
      return;
    }
    this.refreshFramebufferInfo();
    if (this.fbW <= 0 || this.fbH <= 0) {
      this.requestDisplayFullRefresh();
      this.queueDisplayDetectionRetry();
      void this.ensurePixelMap();
      return;
    }
    if (this.frameCache) {
      this.refineMonitorsFromFrame(true);
    } else {
      this.requestDisplayFullRefresh();
      this.recalculateMonitors();
      void this.ensurePixelMap();
    }
    if (this.getDisplayPreviewMonitorRects().length > 1) {
      this.stopDisplayDetectionRetry();
      return;
    }
    this.requestDisplayFullRefresh();
    this.queueDisplayDetectionRetry();
  }

  private showStatusBanner(message: string): void {
    this.statusBannerText = message;
    if (this.statusBannerTimer !== -1) {
      clearTimeout(this.statusBannerTimer);
      this.statusBannerTimer = -1;
    }
    this.statusBannerTimer = setTimeout(() => {
      this.statusBannerText = '';
      this.statusBannerTimer = -1;
    }, 1800);
  }

  private shouldInterceptCanvasTouch(ev: TouchEvent): boolean {
    const type = ev?.type;
    if (type !== TouchType.Down) return false;
    if (this.panelMode !== 'none') {
      this.closePanel();
      return true;
    }
    return false;
  }

  private handleMouseChromeBehavior(): void {
    if (!this.shouldAutoHideChrome()) {
      this.revealChrome();
      return;
    }
    if (this.chromeVisible) {
      this.scheduleChromeAutoHide();
    }
  }

  private beginChromeInteraction(): void {
    this.chromeVisible = true;
    this.clearChromeAutoHide();
  }

  private pulseChromeInteraction(): void {
    this.chromeVisible = true;
    if (this.panelMode !== 'none') {
      this.clearChromeAutoHide();
      return;
    }
    if (this.chromeHovering || this.chromePressing) {
      this.clearChromeAutoHide();
      return;
    }
    this.scheduleChromeAutoHide(this.chromeInteractionHideMs);
  }

  private setChromeHovering(isHovering: boolean): void {
    this.chromeHovering = isHovering;
    if (isHovering) {
      this.beginChromeInteraction();
      return;
    }
    this.pulseChromeInteraction();
  }

  private handleChromeTouchInteraction(ev: TouchEvent): void {
    const type = ev?.type;
    if (type === TouchType.Down) {
      this.chromePressing = true;
      this.beginChromeInteraction();
      return;
    }
    if (type === TouchType.Up || type === TouchType.Cancel) {
      this.chromePressing = false;
      this.pulseChromeInteraction();
    }
  }

  private shouldShowChromeHandle(): boolean {
    return this.connected &&
      this.panelMode === 'none' &&
      this.manualDragMonitorIndex < 0 &&
      !this.editOpen &&
      !!this.pm &&
      !this.chromeVisible;
  }

  private canUseZoomViewer(): boolean {
    return this.viewerW > 0 && this.viewerH > 0 && this.viewportMode !== 'tile';
  }

  private getViewportPixelRatio(): number {
    try {
      const ratio = this.getUIContext()?.vp2px?.(1);
      if (typeof ratio === 'number' && ratio > 0) return ratio;
    } catch (e) {
    }
    return 1;
  }

  // Target remote resolution: the window measured in physical pixels, so the
  // picture lands on the screen 1:1 instead of being scaled down into a band.
  // The conversion and its limits live in shared_native/desktop_resize.cpp so
  // the clamping rules are covered by the host tests.
  private getAdaptiveDesktopTarget(): VncRect | null {
    if (this.viewerW <= 1 || this.viewerH <= 1 || this.bootstrapping) return null;
    const target = this.vncClient.computeDesktopSizeTarget?.(
      this.viewerW, this.viewerH, this.getViewportPixelRatio());
    if (!target || target.ok !== true) return null;
    if (target.width < 1 || target.height < 1) return null;
    return { x: 0, y: 0, w: target.width, h: target.height };
  }

  private isAppleServer(): boolean {
    try {
      return this.vncClient.isServerLikelyMac?.() === true;
    } catch (e) {
      return false;
    }
  }

  private cancelAdaptiveDesktopResize(): void {
    if (this.adaptiveResizeTimer !== -1) {
      clearTimeout(this.adaptiveResizeTimer);
      this.adaptiveResizeTimer = -1;
    }
  }

  private scheduleAdaptiveDesktopResize(delayMs: number): void {
    this.cancelAdaptiveDesktopResize();
    if (!this.adaptiveResolutionEnabled || !this.connected || this.adaptiveResizeBlocked) return;
    this.adaptiveResizeTimer = setTimeout(() => {
      this.adaptiveResizeTimer = -1;
      this.applyAdaptiveDesktopResize();
    }, delayMs);
  }

  private applyAdaptiveDesktopResize(): void {
    if (!this.adaptiveResolutionEnabled || !this.connected || this.adaptiveResizeBlocked) return;
    if (this.bootstrapping || this.viewportMode === 'tile') return;
    if (this.fbW <= 0 || this.fbH <= 0) return;

    const target = this.getAdaptiveDesktopTarget();
    if (!target) return;

    // Close enough: the frame already maps onto the window without another
    // round trip (servers and rounding rarely land on the exact request).
    if (Math.abs(this.fbW - target.w) <= this.adaptiveResizeTolerancePx &&
      Math.abs(this.fbH - target.h) <= this.adaptiveResizeTolerancePx) {
      this.adaptiveResizeTries = 0;
      this.adaptiveResizeNotice = '';
      return;
    }

    const sameTarget =
      Math.abs(target.w - this.adaptiveResizeTryW) <= this.adaptiveResizeTolerancePx &&
      Math.abs(target.h - this.adaptiveResizeTryH) <= this.adaptiveResizeTolerancePx;
    if (sameTarget && this.adaptiveResizeTries >= this.adaptiveResizeMaxAttempts) {
      // The server accepted but kept a different size (it clamped the request to
      // a supported mode). Retrying would only repeat the same answer.
      console.info('[adaptive] giving up: server settled on a different size');
      return;
    }
    if (sameTarget && (Date.now() - this.adaptiveResizeLastTs) < this.adaptiveResizeMinIntervalMs) return;

    let rc = -1;
    try {
      rc = (this.vncClient.setDesktopSize?.(target.w, target.h) as number) ?? -1;
    } catch (e) {
      console.error(`[adaptive] setDesktopSize threw: ${(e as Error)?.message}`);
      return;
    }
    this.adaptiveResizeTryW = target.w;
    this.adaptiveResizeTryH = target.h;
    this.adaptiveResizeTries = sameTarget ? this.adaptiveResizeTries + 1 : 1;
    this.adaptiveResizeLastTs = Date.now();
    console.info(`[adaptive] target=${target.w}x${target.h} current=${this.fbW}x${this.fbH} rc=${rc} tries=${this.adaptiveResizeTries}`);

    if (rc === this.desktopResizeOk || rc === this.desktopResizeUnchanged) return;
    if (rc === this.desktopResizeUnsupported) {
      // The server never announced ExtendedDesktopSize. Give it a few seconds
      // of updates to do so (some servers send the layout late), then say so.
      if (this.adaptiveResizeTries < this.adaptiveResizeMaxAttempts) {
        this.scheduleAdaptiveDesktopResize(this.adaptiveResizeRetryDelayMs);
        return;
      }
      this.adaptiveResizeBlocked = true;
      this.adaptiveResizeNotice = this.s($r('app.string.adaptive_resolution_unsupported_short'));
      this.showStatusBanner(this.s(this.isAppleServer()
        ? $r('app.string.adaptive_resolution_unsupported_apple')
        : $r('app.string.adaptive_resolution_unsupported')));
      return;
    }
    if (rc === this.desktopResizeMultiScreen) {
      this.adaptiveResizeBlocked = true;
      this.adaptiveResizeNotice = this.s($r('app.string.adaptive_resolution_multi_screen'));
      return;
    }
    // Not connected yet or a hard error: stop asking for this session.
    this.adaptiveResizeBlocked = true;
  }

  private checkAdaptiveResizeFailure(): void {
    let failed = false;
    try {
      failed = this.vncClient.takeDesktopResizeFailure?.() === true;
    } catch (e) {
      failed = false;
    }
    if (!failed) return;
    console.info('[adaptive] server rejected the resize request');
    this.adaptiveResizeBlocked = true;
    this.adaptiveResizeNotice = this.s($r('app.string.adaptive_resolution_unsupported_short'));
    this.showStatusBanner(this.s($r('app.string.adaptive_resolution_refused')));
  }

  private setAdaptiveResolutionEnabled(enabled: boolean): void {
    this.adaptiveResolutionEnabled = enabled;
    console.info(`[adaptive] toggle enabled=${enabled}`);
    this.adaptiveResizeBlocked = false;
    this.adaptiveResizeNotice = '';
    this.adaptiveResizeTries = 0;
    this.adaptiveResizeTryW = 0;
    this.adaptiveResizeTryH = 0;
    this.adaptiveResizeLastTs = 0;
    const ctx = this.getHostContext();
    if (ctx) saveAdaptiveResolution(enabled, ctx);
    if (enabled) this.scheduleAdaptiveDesktopResize(this.adaptiveResizeToggleDelayMs);
    else this.cancelAdaptiveDesktopResize();
  }

  private async loadAdaptiveResolutionSetting(): Promise<void> {
    try {
      const ctx = this.getHostContext();
      if (!ctx) return;
      const pref = await dataPreferences.getPreferences(ctx, { name: 'vnc_store' });
      this.adaptiveResolutionEnabled = !!(await pref.get('adaptive_resolution_v1', true)) as boolean;
    } catch (e) {
      console.error('Failed to load adaptive resolution setting', e);
    }
  }

  private getAllMonitorMetrics(): ViewportTarget {
    return this.getMonitorImageMetrics(
      { x: 0, y: 0, w: Math.max(1, this.fbW), h: Math.max(1, this.fbH) },
      this.getFullViewerFrame()
    );
  }

  private getPrimaryImageMetrics(): ViewportTarget {
    if (this.viewportMode === 'single' && this.hasCurrentMonitor()) {
      return this.getSingleMonitorMetrics();
    }
    return this.getAllMonitorMetrics();
  }

  private getBaseViewportTarget(): ViewportTarget {
    if (this.viewportMode === 'single' && this.hasCurrentMonitor()) {
      return {
        source: this.getCurrentMonitor(),
        frame: this.getFullViewerFrame()
      };
    }
    return {
      source: { x: 0, y: 0, w: Math.max(1, this.fbW), h: Math.max(1, this.fbH) },
      frame: this.getFullViewerFrame()
    };
  }

  private getViewportContentRect(target: ViewportTarget): VncRect {
    const scale = this.getViewportScale(target.source, target.frame);
    const contentW = target.source.w * scale;
    const contentH = target.source.h * scale;
    return {
      x: target.frame.x + (target.frame.w - contentW) / 2,
      y: target.frame.y + (target.frame.h - contentH) / 2,
      w: contentW,
      h: contentH
    };
  }

  private getViewerCenter(): LocalPoint {
    return {
      x: this.viewerW / 2,
      y: this.viewerH / 2
    };
  }

  private getTransformedRect(rect: VncRect): VncRect {
    if (!this.canUseZoomViewer()) {
      return rect;
    }
    if (this.zoomScale <= this.zoomMinScale) {
      return {
        x: rect.x + this.zoomOffsetX,
        y: rect.y + this.zoomOffsetY,
        w: rect.w,
        h: rect.h
      };
    }
    const center = this.getViewerCenter();
    return {
      x: center.x + (rect.x - center.x) * this.zoomScale + this.zoomOffsetX,
      y: center.y + (rect.y - center.y) * this.zoomScale + this.zoomOffsetY,
      w: rect.w * this.zoomScale,
      h: rect.h * this.zoomScale
    };
  }

  private clampZoomOffset(): void {
    if (!this.canUseZoomViewer() || this.zoomScale <= this.zoomMinScale) {
      this.zoomOffsetX = 0;
      this.zoomOffsetY = 0;
      return;
    }

    const target = this.getBaseViewportTarget();
    const content = this.getViewportContentRect(target);
    const center = this.getViewerCenter();
    const scaledLeft = center.x + (content.x - center.x) * this.zoomScale;
    const scaledTop = center.y + (content.y - center.y) * this.zoomScale;
    const scaledW = content.w * this.zoomScale;
    const scaledH = content.h * this.zoomScale;

    let minOffsetX = this.viewerW - (scaledLeft + scaledW);
    let maxOffsetX = -scaledLeft;
    if (minOffsetX > maxOffsetX) {
      const centerOffset = (minOffsetX + maxOffsetX) / 2;
      minOffsetX = centerOffset;
      maxOffsetX = centerOffset;
    }
    const expandX = this.viewerW / 2;
    minOffsetX -= expandX;
    maxOffsetX += expandX;
    this.zoomOffsetX = this.clamp(this.zoomOffsetX, minOffsetX, maxOffsetX);

    let minOffsetY = this.viewerH - (scaledTop + scaledH);
    let maxOffsetY = -scaledTop;
    if (minOffsetY > maxOffsetY) {
      const centerOffset = (minOffsetY + maxOffsetY) / 2;
      minOffsetY = centerOffset;
      maxOffsetY = centerOffset;
    }
    const expandY = this.viewerH / 2;
    minOffsetY -= expandY;
    maxOffsetY += expandY;
    this.zoomOffsetY = this.clamp(this.zoomOffsetY, minOffsetY, maxOffsetY);
  }

  private toBaseViewerPoint(x: number, y: number): LocalPoint {
    if (!this.canUseZoomViewer()) {
      return { x, y };
    }
    if (this.zoomScale <= this.zoomMinScale) {
      return {
        x: x - this.zoomOffsetX,
        y: y - this.zoomOffsetY
      };
    }
    const center = this.getViewerCenter();
    return {
      x: center.x + (x - center.x - this.zoomOffsetX) / this.zoomScale,
      y: center.y + (y - center.y - this.zoomOffsetY) / this.zoomScale
    };
  }

  private setViewerZoom(nextScale: number, anchorX: number, anchorY: number): void {
    if (!this.canUseZoomViewer()) return;
    const scale = this.clamp(nextScale, this.zoomMinScale, this.zoomMaxScale);
    if (scale <= this.zoomMinScale) {
      this.resetViewerZoom();
      return;
    }

    const base = this.toBaseViewerPoint(anchorX, anchorY);
    const center = this.getViewerCenter();
    this.zoomScale = scale;
    this.zoomOffsetX = anchorX - center.x - (base.x - center.x) * scale;
    this.zoomOffsetY = anchorY - center.y - (base.y - center.y) * scale;
    this.clampZoomOffset();
  }

  private resetViewerZoom(): void {
    this.zoomScale = 1;
    this.zoomOffsetX = 0;
    this.zoomOffsetY = 0;
    this.pinchActive = false;
    this.inspectTouchMoved = false;
  }

  private setViewportMode(mode: 'all' | 'single' | 'tile', monitorIndex: number = this.currentMonitorIndex): void {
    this.viewportMode = mode;
    this.currentMonitorIndex = monitorIndex;
    if (mode === 'tile') {
      this.interactionMode = 'control';
      this.resetViewerZoom();
      this.showStatusBanner(this.s($r('app.string.monitor_split_overview')));
      return;
    }
    this.clampZoomOffset();
    if (mode === 'all') {
      this.showStatusBanner(this.s($r('app.string.monitor_all_screens')));
    } else {
      this.showStatusBanner(this.s($r('app.string.monitor_switch_to'), monitorIndex + 1));
    }
  }

  private setInteractionMode(mode: 'control' | 'inspect'): void {
    if (this.interactionMode === mode) return;
    if (mode === 'inspect' && this.viewportMode === 'tile') {
      this.setViewportMode('all', this.currentMonitorIndex);
      this.showStatusBanner(this.s($r('app.string.monitor_all_screens')));
    }
    this.interactionMode = mode;
    if (mode === 'inspect') {
      this.requestInputFocus();
      this.revealChrome();
      this.showStatusBanner(this.s($r('app.string.viewer_inspect_mode')));
      return;
    }
    this.pinchActive = false;
    this.inspectTouchMoved = false;
    this.revealChrome();
    this.showStatusBanner(this.s($r('app.string.viewer_control_mode')));
  }

  private getZoomButtonLabel(): string {
    if (this.zoomScale > 1.05) {
      return `${Math.round(this.zoomScale * 10) / 10}x`;
    }
    return '1x';
  }

  private stepViewerZoom(delta: number): void {
    if (!this.canUseZoomViewer()) return;
    const center = this.getViewerCenter();
    this.setViewerZoom(this.zoomScale + delta, center.x, center.y);
  }

  private quickToggleViewerZoom(): void {
    if (!this.canUseZoomViewer()) return;
    const center = this.getViewerCenter();
    if (this.zoomScale > 1.05) {
      this.resetViewerZoom();
      this.showStatusBanner(this.s($r('app.string.zoom_toggle_fit')));
      return;
    }
    if (this.interactionMode !== 'inspect') {
      this.setInteractionMode('inspect');
    }
    this.setViewerZoom(2, center.x, center.y);
    this.showStatusBanner(this.s($r('app.string.zoom_toggle_fit')));
  }

  private getTouchDistance(ev: TouchEvent): number {
    const touches = ev?.touches;
    if (!touches || touches.length < 2) return 0;
    const t0 = touches[0] as TouchPointLike;
    const t1 = touches[1] as TouchPointLike;
    const dx = (t0?.x ?? 0) - (t1?.x ?? 0);
    const dy = (t0?.y ?? 0) - (t1?.y ?? 0);
    return Math.sqrt(dx * dx + dy * dy);
  }

  private handleInspectTap(localX: number, localY: number): void {
    const now = Date.now();
    const withinWindow = now - this.lastInspectTapTs <= this.inspectDoubleTapMs;
    const nearPrev = Math.abs(localX - this.lastInspectTapX) + Math.abs(localY - this.lastInspectTapY) <= 28;
    if (withinWindow && nearPrev) {
      if (this.zoomScale > 1.05) {
        this.resetViewerZoom();
      } else {
        this.setViewerZoom(2, localX, localY);
      }
      this.lastInspectTapTs = 0;
      return;
    }
    this.lastInspectTapTs = now;
    this.lastInspectTapX = localX;
    this.lastInspectTapY = localY;
  }

  private handleInspectTouch(ev: TouchEvent): boolean {
    if (this.interactionMode !== 'inspect' || !this.connected || !this.canUseZoomViewer()) {
      return false;
    }

    const type = ev?.type;
    const touches = ev?.touches;
    const touchCount = touches?.length ?? 0;
    const point = ev?.touches?.[0] ?? ev?.changedTouches?.[0];
    const localX = point?.x ?? this.lastX;
    const localY = point?.y ?? this.lastY;

    if (touchCount >= 2) {
      const center = this.getTouchCenter(ev);
      const distance = this.getTouchDistance(ev);
      if (center && distance > 0) {
        if (!this.pinchActive) {
          this.pinchActive = true;
          this.pinchStartDistance = distance;
          this.pinchStartScale = this.zoomScale;
          const base = this.toBaseViewerPoint(center.x, center.y);
          this.pinchAnchorBaseX = base.x;
          this.pinchAnchorBaseY = base.y;
        } else if (type === TouchType.Move) {
          const scale = this.clamp(
            this.pinchStartScale * (distance / Math.max(1, this.pinchStartDistance)),
            this.zoomMinScale,
            this.zoomMaxScale
          );
          const viewerCenter = this.getViewerCenter();
          this.zoomScale = scale;
          this.zoomOffsetX = center.x - viewerCenter.x - (this.pinchAnchorBaseX - viewerCenter.x) * scale;
          this.zoomOffsetY = center.y - viewerCenter.y - (this.pinchAnchorBaseY - viewerCenter.y) * scale;
          this.clampZoomOffset();
        }
      }
      this.inspectTouchMoved = true;
      return true;
    }

    if (this.pinchActive) {
      this.pinchActive = false;
      this.inspectPanStartX = localX;
      this.inspectPanStartY = localY;
      this.inspectPanStartOffsetX = this.zoomOffsetX;
      this.inspectPanStartOffsetY = this.zoomOffsetY;
    }

    if (type === TouchType.Down) {
      this.inspectPanStartX = localX;
      this.inspectPanStartY = localY;
      this.inspectPanStartOffsetX = this.zoomOffsetX;
      this.inspectPanStartOffsetY = this.zoomOffsetY;
      this.inspectTouchStartTs = Date.now();
      this.inspectTouchMoved = false;
      return true;
    }

    if (type === TouchType.Move) {
      const dx = localX - this.inspectPanStartX;
      const dy = localY - this.inspectPanStartY;
      if (Math.abs(dx) + Math.abs(dy) >= this.inspectMoveSlopPx) {
        this.inspectTouchMoved = true;
      }
      if (this.zoomScale > 1.05) {
        this.zoomOffsetX = this.inspectPanStartOffsetX + dx;
        this.zoomOffsetY = this.inspectPanStartOffsetY + dy;
        this.clampZoomOffset();
      }
      return true;
    }

    if (type === TouchType.Up) {
      const dt = Date.now() - this.inspectTouchStartTs;
      if (!this.inspectTouchMoved && dt <= this.inspectTapMaxMs) {
        this.handleInspectTap(localX, localY);
      }
      this.inspectTouchMoved = false;
      return true;
    }

    if (type === TouchType.Cancel) {
      this.inspectTouchMoved = false;
      this.pinchActive = false;
      return true;
    }

    return true;
  }

  private tryAutoConnect(): void {
    if (this.connected || this.connecting) return;
    const addr = (this.address ?? '').trim();
    if (!addr) return;
    this.prepareConnect();
  }

  private async loadConnections() {
    try {
      const ctx = this.getHostContext();
      if (!ctx) return;
      const pref = await dataPreferences.getPreferences(ctx, { name: 'vnc_store' });
      const raw = (await pref.get('connections_v1', '')) as string;
      let list: ConnectionItem[] = parseConnectionsJson(raw);

      if (list.length === 0) {
        const oldAddress = (await pref.get('address', '')) as string;
        const oldUser = (await pref.get('user', '')) as string;
        const oldPassword = (await pref.get('password', '')) as string;
        const addr = (oldAddress ?? '').trim();
        if (addr) {
          const migrated: ConnectionItem = {
            id: generateId(),
            name: '',
            address: addr,
            user: (oldUser ?? '').trim(),
            password: (oldPassword ?? ''),
            storePassword: (oldPassword ?? '').length > 0,
            touchScrollStep: 0,
            macMode: false,
            sshTunnel: normalizeSshTunnelConfigForAddress(undefined, addr),
            lastUsedAt: Date.now()
          };
          list = [migrated];
        }
      }

      list.sort((a, b) => (b.lastUsedAt ?? 0) - (a.lastUsedAt ?? 0));
      this.connections = list;

      const savedSelected = ((await pref.get('selected_conn_id', '')) as string) ?? '';
      const initialId = list.find(c => c.id === savedSelected)?.id ?? list[0]?.id ?? '';
      this.selectedConnId = initialId;
      this.applySelectedConnectionToFields();
    } catch (e) {
      console.error('Failed to load connections', e);
    }
  }

  private async saveConnections() {
    try {
      const ctx = this.getHostContext();
      if (!ctx) return;
      const pref = await dataPreferences.getPreferences(ctx, { name: 'vnc_store' });
      await pref.put('connections_v1', JSON.stringify(this.connections ?? []));
      await pref.put('selected_conn_id', this.selectedConnId ?? '');
      await pref.put('address', this.address ?? '');
      await pref.put('user', this.user ?? '');
      await pref.put('password', this.isSelectedStorePasswordEnabled() ? (this.password ?? '') : '');
      await pref.flush();
    } catch (e) {
      console.error('Failed to save connections', e);
    }
  }

  private applySelectedConnectionToFields(): void {
    const c = (this.connections ?? []).find(it => it.id === this.selectedConnId);
    if (!c) return;
    this.connName = (c.name ?? '').trim();
    this.address = c.address ?? '';
    this.user = c.user ?? '';
    this.password = c.password ?? '';
    this.runtimeSshConfig = normalizeSshTunnelConfigForAddress(c.sshTunnel, c.address);
    this.runtimeTouchScrollStep = this.normalizeTouchScrollStep(c.touchScrollStep);
    this.runtimeMacMode = !!c.macMode;
    this.showPassword = false;
  }

  private saveSelectedName(): void {
    if (this.connected || !this.selectedConnId) return;
    const name = (this.connName ?? '').trim();
    const curr = this.connections ?? [];
    const next: ConnectionItem[] = [];
    let changed = false;
    for (let i = 0; i < curr.length; i++) {
      const it = curr[i];
      if (it.id === this.selectedConnId) {
        if ((it.name ?? '') !== name) changed = true;
        next.push({
          id: it.id,
          name,
          address: it.address,
          user: it.user,
          password: it.password,
          storePassword: it.storePassword,
          touchScrollStep: it.touchScrollStep,
          macMode: it.macMode,
          sshTunnel: normalizeSshTunnelConfigForAddress(it.sshTunnel, it.address),
          lastUsedAt: it.lastUsedAt
        });
      } else {
        next.push(it);
      }
    }
    if (!changed) return;
    this.connections = next;
    void this.saveConnections();
    this.toast(this.s($r('app.string.conn_saved')));
  }

  private selectConnection(id: string): void {
    if (!id) return;
    this.selectedConnId = id;
    this.closeConnectPasswordPrompt();
    this.applySelectedConnectionToFields();
    void this.saveConnections();
  }

  private shouldPromptForSelectedConnectionPassword(): boolean {
    const c = this.getSelectedConnection();
    if (!c) return false;
    return !c.storePassword || (c.password ?? '').length === 0;
  }

  private openConnectPasswordPrompt(connection: ConnectionItem): void {
    if (this.connected) return;
    this.connectPromptConnId = connection.id;
    this.connectPromptName = normalizeConnName(connection.name ?? '', connection.address ?? '', connection.sshTunnel);
    this.connectPromptAddress = resolveConnectionAddress(connection.address ?? '', connection.sshTunnel);
    this.connectPromptPassword = '';
    this.connectPromptStorePassword = !!connection.storePassword;
    this.connectPromptOpen = true;
  }

  private closeConnectPasswordPrompt(): void {
    this.connectPromptOpen = false;
    this.connectPromptConnId = '';
    this.connectPromptName = '';
    this.connectPromptAddress = '';
    this.connectPromptPassword = '';
    this.connectPromptStorePassword = false;
  }

  private prepareConnect(): void {
    if (this.connected || this.connecting) return;
    if (this.shouldPromptForSelectedConnectionPassword()) {
      const selected = this.getSelectedConnection();
      if (selected) {
        this.openConnectPasswordPrompt(selected);
        return;
      }
    }
    void this.connect();
  }

  private async confirmConnectPasswordPrompt(): Promise<void> {
    const connId = (this.connectPromptConnId ?? '').trim();
    const runtimePassword = this.connectPromptPassword ?? '';
    if (!connId) {
      this.closeConnectPasswordPrompt();
      return;
    }
    if (!runtimePassword.length) {
      this.toast(this.s($r('app.string.viewer_please_connect_first')));
      return;
    }
    const curr = this.connections ?? [];
    const next: ConnectionItem[] = [];
    let target: ConnectionItem | null = null;
    const now = Date.now();
    for (let i = 0; i < curr.length; i++) {
      const it = curr[i];
      if (it.id === connId) {
        const updated: ConnectionItem = {
          id: it.id,
          name: it.name,
          address: it.address,
          user: it.user,
          password: this.connectPromptStorePassword ? runtimePassword : '',
          storePassword: this.connectPromptStorePassword,
          touchScrollStep: it.touchScrollStep,
          macMode: it.macMode,
          sshTunnel: normalizeSshTunnelConfigForAddress(it.sshTunnel, it.address),
          lastUsedAt: now
        };
        target = updated;
        next.push(updated);
      } else {
        next.push(it);
      }
    }
    if (!target) {
      this.closeConnectPasswordPrompt();
      return;
    }
    next.sort((a, b) => (b.lastUsedAt ?? 0) - (a.lastUsedAt ?? 0));
    this.connections = next;
    this.selectedConnId = target.id;
    this.connName = target.name ?? '';
    this.address = target.address ?? '';
    this.user = target.user ?? '';
    this.password = runtimePassword;
    this.runtimeSshConfig = normalizeSshTunnelConfigForAddress(target.sshTunnel, target.address);
    this.runtimeTouchScrollStep = this.normalizeTouchScrollStep(target.touchScrollStep);
    this.runtimeMacMode = !!target.macMode;
    this.showPassword = false;
    await this.saveConnections();
    this.closeConnectPasswordPrompt();
    await this.connect();
  }

  private getSelectedConnection(): ConnectionItem | null {
    const id = this.selectedConnId ?? '';
    if (!id) return null;
    const c = (this.connections ?? []).find(it => it.id === id);
    return c ?? null;
  }

  private isSelectedStorePasswordEnabled(): boolean {
    const c = this.getSelectedConnection();
    return !!c?.storePassword;
  }

  private toggleSelectedStorePassword(): void {
    if (!this.selectedConnId || this.connected) return;
    const enable = !this.isSelectedStorePasswordEnabled();
    const nowPass = this.password ?? '';
    const curr = this.connections ?? [];
    const next: ConnectionItem[] = [];
    for (let i = 0; i < curr.length; i++) {
      const it = curr[i];
      if (it.id === this.selectedConnId) {
        const updated: ConnectionItem = {
          id: it.id,
          name: it.name,
          address: it.address,
          user: it.user,
          password: enable ? nowPass : '',
          storePassword: enable,
          touchScrollStep: it.touchScrollStep,
          macMode: it.macMode,
          sshTunnel: normalizeSshTunnelConfigForAddress(it.sshTunnel, it.address),
          lastUsedAt: it.lastUsedAt
        };
        next.push(updated);
      } else {
        next.push(it);
      }
    }
    this.connections = next;
    void this.saveConnections();
    this.toast(this.s($r(enable ? 'app.string.clipboard_sent_success' : 'app.string.action_close')));
  }

  private saveCurrentFieldsToSelected(): void {
    if (this.connected || !this.selectedConnId) return;
    const addr = (this.address ?? '').trim();
    if (addr && !parseAddress(addr)) {
      this.toast(this.s($r('app.string.viewer_only_address_or_ssh_hint')));
      return;
    }

    const curr = this.connections ?? [];
    const selected = curr.find(it => it.id === this.selectedConnId);
    const sshTunnel = normalizeSshTunnelConfigForAddress(selected?.sshTunnel, addr);
    if (!parseAddress(resolveConnectionAddress(addr, sshTunnel))) {
      this.toast(this.s($r('app.string.viewer_only_address_or_ssh_hint')));
      return;
    }
    const next: ConnectionItem[] = [];
    const user = (this.user ?? '').trim();
    const pass = this.password ?? '';
    for (let i = 0; i < curr.length; i++) {
      const it = curr[i];
      if (it.id === this.selectedConnId) {
        const updated: ConnectionItem = {
          id: it.id,
          name: (it.name ?? '').trim(),
          address: addr,
          user,
          password: it.storePassword ? pass : '',
          storePassword: it.storePassword,
          touchScrollStep: it.touchScrollStep,
          macMode: it.macMode,
          sshTunnel,
          lastUsedAt: it.lastUsedAt
        };
        next.push(updated);
      } else {
        next.push(it);
      }
    }
    this.connections = next;
    void this.saveConnections();
    this.toast(this.s($r('app.string.conn_saved')));
  }

  private openCreateDialog(): void {
    this.editId = '';
    this.editName = '';
    this.editAddress = '';
    this.editUser = '';
    this.editPassword = '';
    this.editStorePassword = true;
    this.editTouchScrollStep = 0;
    this.editMacMode = false;
    this.editShowPassword = false;
    this.editOpen = true;
  }

  private openEditDialog(id: string): void {
    const c = (this.connections ?? []).find(it => it.id === id);
    if (!c) return;
    this.editId = c.id;
    this.editName = c.name ?? '';
    this.editAddress = c.address ?? '';
    this.editUser = c.user ?? '';
    this.editPassword = c.password ?? '';
    this.editStorePassword = !!c.storePassword;
    this.editTouchScrollStep = this.normalizeTouchScrollStep(c.touchScrollStep);
    this.editMacMode = !!c.macMode;
    this.editShowPassword = false;
    this.editOpen = true;
  }

  private async openConnectionActions(id: string): Promise<void> {
    if (this.connected) return;
    const c = (this.connections ?? []).find(it => it.id === id);
    if (!c) return;
    try {
      const pa = this.getUIContext()?.getPromptAction?.();
      if (!pa?.showDialog) return;
      const res = await pa.showDialog({
        title: normalizeConnName(c.name, c.address, c.sshTunnel),
        message: resolveConnectionAddress(c.address, c.sshTunnel),
        buttons: [
          { text: this.s($r('app.string.action_cancel')), color: this.cTextSecondary },
          { text: this.s($r('app.string.action_edit')), color: this.cPrimary },
          { text: this.s($r('app.string.action_delete')), color: this.cError }
        ]
      });
      if (res.index === 1) {
        this.openEditDialog(c.id);
        return;
      }
      if (res.index === 2) {
        void this.deleteConnection(c.id);
      }
    } catch (e) {
      return;
    }
  }

  @Builder
  private buildBrandSwitch(isOn: boolean, enabled: boolean, onChange: (next: boolean) => void): void {
    Row() {
      Blank()
        .width(18)
        .height(18)
        .backgroundColor(this.cSurfaceAlt)
        .borderRadius(9)
        .margin({ left: isOn ? 18 : 0 });
    }
    .width(42)
    .height(24)
    .padding(3)
    .backgroundColor(isOn ? this.cPrimary : this.cBorder)
    .borderRadius(12)
    .opacity(enabled ? 1 : 0.6)
    .onClick(() => {
      if (!enabled) return;
      onChange(!isOn);
    });
  }

  private closeEditDialog(): void {
    this.editOpen = false;
    this.editId = '';
    this.editName = '';
    this.editAddress = '';
    this.editUser = '';
    this.editPassword = '';
    this.editStorePassword = true;
    this.editTouchScrollStep = 0;
    this.editShowPassword = false;
  }

  @Builder
  private buildConnectPasswordPromptOverlay(): void {
    if (this.connectPromptOpen) {
      Stack() {
        Column() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(12,20,22,0.55)')
        .onClick(() => this.closeConnectPasswordPrompt());

        Column() {
          Row() {
            Text($r('app.string.conn_enter_password'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1);
            Button($r('app.string.action_close'))
              .height(28)
              .fontSize(12)
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => this.closeConnectPasswordPrompt());
          }
          .padding({ left: 14, right: 14, top: 14, bottom: 10 });

          Column() {
            Text(`"${this.connectPromptName || this.s($r('app.string.conn_unnamed'))}" ${this.s($r('app.string.viewer_password_not_saved'))}`)
              .fontSize(14)
              .fontColor(this.cTextPrimary)
              .width('100%');
            if (this.connectPromptAddress) {
              Text(this.connectPromptAddress)
                .fontSize(12)
                .fontColor(this.cTextSecondary)
                .width('100%')
                .padding({ top: 4, bottom: 10 });
            } else {
              Blank().height(10);
            }
            Text($r('app.string.conn_password_label'))
              .fontSize(12)
              .fontColor(this.cTextSecondary)
              .width('100%')
              .padding({ bottom: 4 });
            TextInput({ text: this.connectPromptPassword, placeholder: $r('app.string.enter_password_placeholder') })
              .type(InputType.Password)
              .onChange((v: string) => this.connectPromptPassword = v)
              .padding({ bottom: 8 });
            Row() {
              Text($r('app.string.conn_save_password'))
                .fontSize(12)
                .fontColor(this.cTextSecondary)
                .layoutWeight(1);
              this.buildBrandSwitch(this.connectPromptStorePassword, true, (next: boolean) => {
                this.connectPromptStorePassword = next;
              });
            }
            .padding({ bottom: 8 });
          }
          .padding({ left: 14, right: 14, bottom: 14 });

          Row() {
            Button($r('app.string.action_cancel'))
              .layoutWeight(1)
              .height(36)
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(14)
              .onClick(() => this.closeConnectPasswordPrompt());
            Button($r('app.string.conn_connect'))
              .layoutWeight(1)
              .height(36)
              .margin({ left: 10 })
              .fontColor(this.cPrimaryFg)
              .backgroundColor(this.cPrimary)
              .borderRadius(14)
              .onClick(() => { void this.confirmConnectPasswordPrompt(); });
          }
          .padding({ left: 14, right: 14, bottom: 14 });
        }
        .width(420)
        .backgroundColor(this.cSurfaceAlt)
        .border({ width: 1, color: this.cBorder })
        .borderRadius(12)
        .shadow({ radius: 16, color: 'rgba(12,20,22,0.16)', offsetX: 0, offsetY: 4 });
      }
      .alignContent(Alignment.Center)
      .width('100%')
      .height('100%');
    }
  }

  private normalizeTouchScrollStep(step: number): number {
    if (!Number.isFinite(step)) return 0;
    const v = Math.floor(step);
    if (v <= 0) return 0;
    return this.clamp(v, 4, 48);
  }

  private updateEditTouchScrollStep(step: number): void {
    this.editTouchScrollStep = this.normalizeTouchScrollStep(step);
  }

  private async saveEditDialog(): Promise<void> {
    const addr = (this.editAddress ?? '').trim();
    if (addr && !parseAddress(addr)) {
      this.toast(this.s($r('app.string.viewer_only_address_or_ssh_hint')));
      return;
    }
    const previousSshTunnel = (this.connections ?? []).find(it => it.id === this.editId)?.sshTunnel;
    const sshTunnel = normalizeSshTunnelConfigForAddress(previousSshTunnel, addr);
    if (!parseAddress(resolveConnectionAddress(addr, sshTunnel))) {
      this.toast(this.s($r('app.string.viewer_only_address_or_ssh_hint')));
      return;
    }

    const id = this.editId || generateId();
    const now = Date.now();
    const next: ConnectionItem = {
      id,
      name: (this.editName ?? '').trim(),
      address: addr,
      user: (this.editUser ?? '').trim(),
      password: this.editStorePassword ? (this.editPassword ?? '') : '',
      storePassword: this.editStorePassword,
      touchScrollStep: this.normalizeTouchScrollStep(this.editTouchScrollStep),
      macMode: this.editMacMode,
      sshTunnel,
      lastUsedAt: this.editId ? ((this.connections ?? []).find(it => it.id === id)?.lastUsedAt ?? 0) : now
    };

    const existing = (this.connections ?? []).filter(it => it.id !== id);
    const merged: ConnectionItem[] = [next];
    for (let i = 0; i < existing.length; i++) {
      merged.push(existing[i]);
    }
    merged.sort((a, b) => (b.lastUsedAt ?? 0) - (a.lastUsedAt ?? 0));
    this.connections = merged;
    this.selectedConnId = id;
    this.connName = next.name ?? '';
    this.address = next.address ?? '';
    this.user = next.user ?? '';
    this.password = this.editStorePassword ? (next.password ?? '') : (this.editPassword ?? '');
    this.runtimeSshConfig = normalizeSshTunnelConfigForAddress(next.sshTunnel, next.address);
    this.runtimeTouchScrollStep = this.normalizeTouchScrollStep(next.touchScrollStep);
    this.runtimeMacMode = !!next.macMode;
    this.showPassword = false;
    await this.saveConnections();
    this.closeEditDialog();
  }

  private async deleteConnection(id: string): Promise<void> {
    const c = (this.connections ?? []).find(it => it.id === id);
    if (!c) return;
    if (this.connected) {
      this.toast(this.s($r('app.string.viewer_session_not_connected')));
      return;
    }
    try {
      const pa = this.getUIContext()?.getPromptAction?.();
      if (!pa?.showDialog) return;
      const res = await pa.showDialog({
        title: this.s($r('app.string.action_delete')),
        message: this.s($r('app.string.action_confirm')) + ` "${normalizeConnName(c.name, c.address, c.sshTunnel)}"？`,
        buttons: [{ text: this.s($r('app.string.action_cancel')), color: this.cTextSecondary }, { text: this.s($r('app.string.action_delete')), color: this.cError }]
      });
      if (res.index !== 1) return;
    } catch (e) {
      return;
    }

    const next = (this.connections ?? []).filter(it => it.id !== id);
    this.connections = next;
    if (this.selectedConnId === id) {
      this.selectedConnId = next[0]?.id ?? '';
      this.applySelectedConnectionToFields();
    }
    await this.saveConnections();
  }

  private touchConnectionUsed(): void {
    if (!this.selectedConnId) return;
    const now = Date.now();
    const curr = this.connections ?? [];
    const next: ConnectionItem[] = [];
    for (let i = 0; i < curr.length; i++) {
      const it = curr[i];
      if (it.id === this.selectedConnId) {
        const updated: ConnectionItem = {
          id: it.id,
          name: it.name,
          address: this.address ?? '',
          user: this.user ?? '',
          password: it.storePassword ? (this.password ?? '') : '',
          storePassword: it.storePassword,
          touchScrollStep: it.touchScrollStep,
          macMode: it.macMode,
          sshTunnel: normalizeSshTunnelConfigForAddress(it.sshTunnel, this.address ?? ''),
          lastUsedAt: now
        };
        next.push(updated);
      } else {
        next.push(it);
      }
    }
    next.sort((a, b) => (b.lastUsedAt ?? 0) - (a.lastUsedAt ?? 0));
    this.connections = next;
    void this.saveConnections();
  }

  private refreshFramebufferInfo(): void {
    try {
      const info = this.vncClient.getFramebufferInfo();
      const oldW = this.fbW;
      const oldH = this.fbH;
      this.fbW = info.width;
      this.fbH = info.height;
      this.fbStride = info.stride;
      this.vncState = info.state;
      if (info?.name) {
        this.serverName = info.name;
      }
      // Detect once the handshake is complete, where both the RFB banner and the
      // negotiated security type are known. Waiting for a desktop name here used
      // to skip detection entirely on servers that send an unrelated name.
      if (!this.macAutoChecked && this.connected && this.vncState === this.vncStateNormal) {
        this.macAutoChecked = true;
        if (this.vncClient.isServerLikelyMac?.()) {
          this.runtimeMacMode = true;
          console.info(`Viewer auto-detected macOS server: ${this.serverName}`);
        }
      }
      if (this.connected) {
        this.securityLevel = this.vncClient.getSecurityLevel?.() ?? 0;
      }

      if (this.fbW > 0 && (oldW !== this.fbW || oldH !== this.fbH || this.monitors.length === 0)) {
        if (oldW > 0 && oldH > 0 && (oldW !== this.fbW || oldH !== this.fbH)) {
          this.resetViewerZoom();
          this.detectedMonitorRects = [];
          this.clearManualMonitorLayout();
          this.monitorLayoutLocked = false;
        }
        this.recalculateMonitors();
        if (oldW !== this.fbW || oldH !== this.fbH) {
          void this.restoreSavedMonitorLayoutIfAvailable();
        }
      }
    } catch (e) {
    }
  }

  private recalculateMonitors(): void {
    if (this.fbW <= 0 || this.fbH <= 0) {
      this.clearManualMonitorLayout();
      this.setDetectedMonitorRects([]);
      this.setActiveMonitorRects([]);
      return;
    }
    this.updateMonitorDetection(this.getHeuristicMonitorRects());
  }

  private getHeuristicMonitorRects(): VncRect[] {
    const next: VncRect[] = [];
    if (this.fbW <= 0 || this.fbH <= 0) return next;
    const ratio = this.fbW / this.fbH;
    if (ratio >= 2.1) {
      if (ratio >= 4.0) {
        const w = Math.floor(this.fbW / 3);
        next.push({ x: 0, y: 0, w: w, h: this.fbH });
        next.push({ x: w, y: 0, w: w, h: this.fbH });
        next.push({ x: w * 2, y: 0, w: this.fbW - (w * 2), h: this.fbH });
      } else {
        const w = Math.floor(this.fbW / 2);
        next.push({ x: 0, y: 0, w: w, h: this.fbH });
        next.push({ x: w, y: 0, w: this.fbW - w, h: this.fbH });
      }
    } else {
      next.push({ x: 0, y: 0, w: this.fbW, h: this.fbH });
    }
    return next;
  }

  private getMonitorDetectionFallbackRects(): VncRect[] {
    if (this.monitorSlots.length > 1) {
      return this.monitorSlots.slice();
    }
    const heuristic = this.getHeuristicMonitorRects();
    return heuristic.length > 1 ? heuristic : [];
  }

  private refineMonitorsFromFrame(force: boolean = false): void {
    if (this.fbW <= 0 || this.fbH <= 0) return;

    const now = Date.now();
    const framebufferChanged = this.fbW !== this.lastMonitorDetectWidth || this.fbH !== this.lastMonitorDetectHeight;
    const shouldDetect = framebufferChanged ||
      this.monitors.length === 0 ||
      (force && now - this.lastMonitorDetectionTs >= this.monitorDetectionIntervalMs) ||
      (this.monitors.length === 0 && now - this.lastMonitorDetectionTs >= this.emptyMonitorDetectionIntervalMs);

    if (!shouldDetect) return;

    const detected = this.detectMonitorsFromFrame();
    this.lastMonitorDetectionTs = now;
    this.lastMonitorDetectWidth = this.fbW;
    this.lastMonitorDetectHeight = this.fbH;
    if (detected.length <= 0) return;
    this.updateMonitorDetection(this.sortMonitorRects(detected));
  }

  private detectMonitorsFromFrame(): VncRect[] {
    const fallback = this.getMonitorDetectionFallbackRects();
    return this.vncClient.detectMonitors?.(fallback) ?? fallback;
  }

  private sortMonitorRects(rects: VncRect[]): VncRect[] {
    const next = rects.slice();
    if (next.length <= 1) return next;
    let minCenterX = Number.POSITIVE_INFINITY;
    let maxCenterX = Number.NEGATIVE_INFINITY;
    let minCenterY = Number.POSITIVE_INFINITY;
    let maxCenterY = Number.NEGATIVE_INFINITY;
    for (let i = 0; i < next.length; i++) {
      const rect = next[i];
      const centerX = rect.x + (rect.w / 2);
      const centerY = rect.y + (rect.h / 2);
      minCenterX = Math.min(minCenterX, centerX);
      maxCenterX = Math.max(maxCenterX, centerX);
      minCenterY = Math.min(minCenterY, centerY);
      maxCenterY = Math.max(maxCenterY, centerY);
    }
    const horizontalSpread = maxCenterX - minCenterX;
    const verticalSpread = maxCenterY - minCenterY;
    next.sort((a, b) => {
      if (horizontalSpread >= verticalSpread * 1.25) {
        if (Math.abs(a.x - b.x) > 40) return a.x - b.x;
        return a.y - b.y;
      }
      if (verticalSpread >= horizontalSpread * 1.25) {
        if (Math.abs(a.y - b.y) > 40) return a.y - b.y;
        return a.x - b.x;
      }
      const ay = a.y + (a.h / 2);
      const by = b.y + (b.h / 2);
      if (Math.abs(ay - by) > 40) return ay - by;
      return a.x - b.x;
    });
    return next;
  }

  private getMonitorRectMatchScore(prev: VncRect, next: VncRect): number {
    const overlapLeft = Math.max(prev.x, next.x);
    const overlapTop = Math.max(prev.y, next.y);
    const overlapRight = Math.min(prev.x + prev.w, next.x + next.w);
    const overlapBottom = Math.min(prev.y + prev.h, next.y + next.h);
    const overlapW = Math.max(0, overlapRight - overlapLeft);
    const overlapH = Math.max(0, overlapBottom - overlapTop);
    const overlapArea = overlapW * overlapH;
    const minArea = Math.max(1, Math.min(prev.w * prev.h, next.w * next.h));
    const overlapRatio = overlapArea / minArea;
    const prevCenterX = prev.x + (prev.w / 2);
    const prevCenterY = prev.y + (prev.h / 2);
    const nextCenterX = next.x + (next.w / 2);
    const nextCenterY = next.y + (next.h / 2);
    const distanceX = prevCenterX - nextCenterX;
    const distanceY = prevCenterY - nextCenterY;
    const distanceSq = (distanceX * distanceX) + (distanceY * distanceY);
    return (overlapRatio * 1000000) - distanceSq;
  }

  private stabilizeMonitorOrder(rects: VncRect[]): VncRect[] {
    const sorted = this.sortMonitorRects(rects);
    if (this.monitorSlots.length <= 1 || this.monitorSlots.length !== sorted.length) {
      return sorted;
    }
    const remaining: VncRect[] = sorted.slice();
    const stable: VncRect[] = [];
    for (let i = 0; i < this.monitorSlots.length; i++) {
      const prev = this.monitorSlots[i];
      let bestIndex = -1;
      let bestScore = Number.NEGATIVE_INFINITY;
      for (let j = 0; j < remaining.length; j++) {
        const score = this.getMonitorRectMatchScore(prev, remaining[j]);
        if (score > bestScore) {
          bestScore = score;
          bestIndex = j;
        }
      }
      if (bestIndex >= 0) {
        stable.push(remaining[bestIndex]);
        remaining.splice(bestIndex, 1);
      }
    }
    return stable.concat(remaining);
  }

  private setDetectedMonitorRects(rects: VncRect[]): void {
    const next: VncRect[] = this.cloneMonitorRects(this.stabilizeMonitorOrder(rects));
    this.detectedMonitorRects = next;
    this.monitorCount = next.length;
    if (next.length > 1) {
      this.detectingDisplayLayout = false;
      if (this.panelMode === 'display') {
        this.stopDisplayDetectionRetry();
      }
    }
  }

  private updateMonitorDetection(rects: VncRect[]): void {
    this.setDetectedMonitorRects(rects);
    if (!this.monitorLayoutLocked || this.monitors.length <= 0) {
      this.setActiveMonitorRects(rects);
    }
  }

  private setActiveMonitorRects(rects: VncRect[]): void {
    const next: VncRect[] = this.stabilizeMonitorOrder(rects).map((rect: VncRect): VncRect => {
      return {
        x: rect.x,
        y: rect.y,
        w: rect.w,
        h: rect.h
      };
    });
    this.monitorSlots = next;
    this.monitors = next.slice();
    if (next.length <= 0) {
      this.currentMonitorIndex = 0;
      if (this.viewportMode !== 'all') {
        this.viewportMode = 'all';
      }
      this.clampZoomOffset();
      return;
    }
    if (this.currentMonitorIndex >= next.length) {
      this.currentMonitorIndex = 0;
    }
    if (this.viewportMode !== 'all' && next.length <= 1) {
      this.viewportMode = 'all';
    }
    this.clampZoomOffset();
    this.syncSharedSessionSnapshot();
  }

  private getDisplayPreviewContainer(): VncRect {
    return {
      x: 0,
      y: 0,
      w: Math.max(220, Math.min(320, this.windowW > 0 ? this.windowW - 88 : 320)),
      h: 180
    };
  }

  private getDisplayPreviewImageMetrics(): ViewportTarget {
    return this.getMonitorImageMetrics(
      { x: 0, y: 0, w: Math.max(1, this.fbW), h: Math.max(1, this.fbH) },
      this.getDisplayPreviewContainer()
    );
  }

  private getDisplayPreviewRect(rect: VncRect): VncRect {
    const imageFrame = this.getDisplayPreviewImageMetrics().frame;
    const scale = imageFrame.w / Math.max(1, this.fbW);
    return {
      x: imageFrame.x + (rect.x * scale),
      y: imageFrame.y + (rect.y * scale),
      w: rect.w * scale,
      h: rect.h * scale
    };
  }

  private formatMonitorRectLabel(rect: VncRect): string {
    return `${rect.x},${rect.y} ${rect.w}×${rect.h}`;
  }

  private shouldShowMonitorLayoutOverlay(): boolean {
    return (this.panelMode === 'display' || this.manualDragMonitorIndex >= 0) &&
      this.pm !== undefined &&
      this.viewportMode !== 'tile' &&
      this.getDisplayPreviewMonitorRects().length > 0;
  }

  private getViewerOverlayImageRect(): VncRect {
    return this.getTransformedRect(this.getPrimaryImageMetrics().frame);
  }

  private getViewerOverlayMonitorRect(rect: VncRect): VncRect {
    const imageRect = this.getViewerOverlayImageRect();
    const scale = imageRect.w / Math.max(1, this.fbW);
    return {
      x: imageRect.x + (rect.x * scale),
      y: imageRect.y + (rect.y * scale),
      w: rect.w * scale,
      h: rect.h * scale
    };
  }

  private getFocusedMonitorVisibleRect(): VncRect | null {
    if (this.viewportMode !== 'single' || !this.hasCurrentMonitor()) {
      return null;
    }
    const rect = this.getViewerOverlayMonitorRect(this.getCurrentMonitor());
    const viewer = this.getFullViewerFrame();
    const left = this.clamp(rect.x, 0, viewer.w);
    const top = this.clamp(rect.y, 0, viewer.h);
    const right = this.clamp(rect.x + rect.w, 0, viewer.w);
    const bottom = this.clamp(rect.y + rect.h, 0, viewer.h);
    if (right <= left || bottom <= top) {
      return null;
    }
    return {
      x: left,
      y: top,
      w: right - left,
      h: bottom - top
    };
  }

  private shouldShowSingleMonitorOcclusion(): boolean {
    return this.getSingleMonitorOverlayRect() !== null;
  }

  private getFocusedMonitorVisibleRectOrEmpty(): VncRect {
    return this.getFocusedMonitorVisibleRect() ?? { x: 0, y: 0, w: 0, h: 0 };
  }

  private getSingleMonitorOverlayRect(): VncRect | null {
    const rect = this.getFocusedMonitorVisibleRect();
    if (rect === null) {
      return null;
    }
    const viewer = this.getFullViewerFrame();
    const left = this.clamp(Math.floor(rect.x), 0, viewer.w);
    const top = this.clamp(Math.floor(rect.y), 0, viewer.h);
    const right = this.clamp(Math.ceil(rect.x + rect.w), 0, viewer.w);
    const bottom = this.clamp(Math.ceil(rect.y + rect.h), 0, viewer.h);
    if (right <= left || bottom <= top) {
      return null;
    }
    return {
      x: left,
      y: top,
      w: right - left,
      h: bottom - top
    };
  }

  private getSingleMonitorMaskRects(): VncRect[] {
    const rect = this.getSingleMonitorOverlayRect();
    if (rect === null) {
      return [];
    }
    const viewer = this.getFullViewerFrame();
    const overlap = 2;
    const leftWidth = this.clamp(rect.x + overlap, 0, viewer.w);
    const rightStart = this.clamp(rect.x + rect.w - overlap, 0, viewer.w);
    const topHeight = this.clamp(rect.y + overlap, 0, viewer.h);
    const bottomStart = this.clamp(rect.y + rect.h - overlap, 0, viewer.h);
    const horizontalStart = this.clamp(rect.x - overlap, 0, viewer.w);
    const horizontalEnd = this.clamp(rect.x + rect.w + overlap, 0, viewer.w);
    const rects: VncRect[] = [];
    if (leftWidth > 0) {
      rects.push({ x: 0, y: 0, w: leftWidth, h: viewer.h });
    }
    if (rightStart < viewer.w) {
      rects.push({ x: rightStart, y: 0, w: viewer.w - rightStart, h: viewer.h });
    }
    if (topHeight > 0 && horizontalEnd > horizontalStart) {
      rects.push({ x: horizontalStart, y: 0, w: horizontalEnd - horizontalStart, h: topHeight });
    }
    if (bottomStart < viewer.h && horizontalEnd > horizontalStart) {
      rects.push({ x: horizontalStart, y: bottomStart, w: horizontalEnd - horizontalStart, h: viewer.h - bottomStart });
    }
    return rects;
  }

  private isPointWithinFocusedMonitor(x: number, y: number): boolean {
    const rect = this.getFocusedMonitorVisibleRect();
    if (rect === null) {
      return true;
    }
    return x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h;
  }

  private getFullViewerFrame(): VncRect {
    return {
      x: 0,
      y: 0,
      w: Math.max(1, this.viewerW),
      h: Math.max(1, this.viewerH)
    };
  }

  private getTileFrames(): VncRect[] {
    const count = this.monitors.length;
    if (count <= 0) return [];
    if (count === 1) return [this.getFullViewerFrame()];

    const gap = 12;
    const cols = count === 2 ? (this.viewerW >= this.viewerH ? 2 : 1) : 2;
    const rows = Math.ceil(count / cols);
    const totalGapX = gap * Math.max(0, cols - 1);
    const totalGapY = gap * Math.max(0, rows - 1);
    const cellW = Math.max(1, Math.floor((Math.max(1, this.viewerW) - totalGapX) / cols));
    const cellH = Math.max(1, Math.floor((Math.max(1, this.viewerH) - totalGapY) / rows));
    const frames: VncRect[] = [];

    for (let index = 0; index < count; index++) {
      const col = index % cols;
      const row = Math.floor(index / cols);
      const isLastInRow = col === cols - 1 || index === count - 1;
      const isLastRow = row === rows - 1;
      const x = col * (cellW + gap);
      const y = row * (cellH + gap);
      const w = isLastInRow ? Math.max(1, Math.max(1, this.viewerW) - x) : cellW;
      const h = isLastRow ? Math.max(1, Math.max(1, this.viewerH) - y) : cellH;
      frames.push({ x, y, w, h });
    }

    return frames;
  }

  private getViewportTargetAt(x: number, y: number): ViewportTarget {
    if (this.viewportMode === 'single' && this.monitors.length > this.currentMonitorIndex) {
      return {
        source: this.monitors[this.currentMonitorIndex],
        frame: this.getFullViewerFrame()
      };
    }

    if (this.viewportMode === 'tile' && this.monitors.length > 1) {
      const frames = this.getTileFrames();
      let targetIndex = Math.max(0, Math.min(this.currentMonitorIndex, this.monitors.length - 1));
      for (let i = 0; i < frames.length; i++) {
        const frame = frames[i];
        if (x >= frame.x && x <= frame.x + frame.w && y >= frame.y && y <= frame.y + frame.h) {
          targetIndex = i;
          break;
        }
      }
      return {
        source: this.monitors[targetIndex],
        frame: frames[targetIndex] ?? this.getFullViewerFrame()
      };
    }

    return {
      source: { x: 0, y: 0, w: this.fbW, h: this.fbH },
      frame: this.getFullViewerFrame()
    };
  }

  private getViewportScale(source: VncRect, frame: VncRect): number {
    const widthScale = frame.w / source.w;
    const heightScale = frame.h / source.h;
    return Math.min(widthScale, heightScale);
  }

  private getMonitorImageMetrics(source: VncRect, frame: VncRect): ViewportTarget {
    const scale = this.getViewportScale(source, frame);
    const contentW = source.w * scale;
    const contentH = source.h * scale;
    return {
      source,
      frame: {
        x: (frame.w - contentW) / 2 - source.x * scale,
        y: (frame.h - contentH) / 2 - source.y * scale,
        w: this.fbW * scale,
        h: this.fbH * scale
      }
    };
  }

  private hasCurrentMonitor(): boolean {
    return this.currentMonitorIndex >= 0 && this.currentMonitorIndex < this.monitors.length;
  }

  private getCurrentMonitor(): VncRect {
    return this.monitors[this.currentMonitorIndex] ?? { x: 0, y: 0, w: Math.max(1, this.fbW), h: Math.max(1, this.fbH) };
  }

  private getTileFrame(index: number): VncRect {
    return this.getTileFrames()[index] ?? { x: 0, y: 0, w: 1, h: 1 };
  }

  private getSingleMonitorMetrics(): ViewportTarget {
    return this.getMonitorImageMetrics(this.getCurrentMonitor(), this.getFullViewerFrame());
  }

  private getTileMonitorMetrics(index: number): ViewportTarget {
    return this.getMonitorImageMetrics(this.monitors[index], this.getTileFrame(index));
  }

  private safeSendPointer(x: number, y: number, mask: number, force: boolean = false): void {
    if (!this.connected) return;
    if (!force &&
      this.lastPointerSentX === x &&
      this.lastPointerSentY === y &&
      this.lastPointerSentMask === mask) {
      return;
    }
    try {
      this.vncClient.sendPointer(x, y, mask);
      this.lastPointerSentX = x;
      this.lastPointerSentY = y;
      this.lastPointerSentMask = mask;
    } catch (e) {
    }
  }

  private beginInteraction(): void {
    if (!this.isInteracting) {
      this.isInteracting = true;
      this.frameThrottle.begin();
    }
  }

  private endInteraction(): void {
    if (this.isInteracting) {
      this.isInteracting = false;
      this.frameThrottle.end();
      void this.flushPendingFrameCache();
    }
  }

  private async flushPendingFrameCache(): Promise<void> {
    if (!this.pendingFrameCache) return;
    const buf = this.pendingFrameCache;
    this.pendingFrameCache = null;
    this.frameCache = buf;
    await this.presentFrameCacheDirect();
  }

  private async presentFrameCacheDirect(): Promise<boolean> {
    if (!this.connected || !this.pm || !this.frameCache) return false;
    if (!this.pmBack || this.pmW !== this.fbW || this.pmH !== this.fbH) {
      this.releasePixelMap(this.pmBack);
      this.pmBack = undefined;
      try {
        this.pmBack = await this.createPixelMapFromBuffer(this.frameCache);
      } catch (e) {
        this.pmBack = undefined;
        console.error('Failed to create back PixelMap', e);
        return false;
      }
    }
    if (!this.writeBufferToPixelMap(this.pmBack, this.frameCache, null)) {
      return false;
    }
    const currentPm = this.pm;
    this.pm = this.pmBack;
    this.pmBack = currentPm;
    this.pmW = this.fbW;
    this.pmH = this.fbH;
    this.pmVersion++;
    this.lastFullFrameSyncTs = Date.now();
    return true;
  }

  private safeSendKey(keysym: number, down: boolean): void {
    if (!this.connected) return;
    try {
      this.vncClient.sendKey(keysym, down);
    } catch (e) {
    }
  }

  private remoteShiftDown: boolean = false;
  private remoteCtrlDown: boolean = false;
  private remoteAltDown: boolean = false;
  private remoteMetaDown: boolean = false;
  private remoteChineseMode: boolean = false;

  private macClipboardKeys = new Set<string>(['a', 'c', 'v', 'x', 'z']);

  private trySwapCtrlForCmd(ev: KeyEvent, keysym: number, isDown: boolean, ctrlDown: boolean, metaDown: boolean): boolean {
    if (!this.runtimeMacMode || !ctrlDown || metaDown || this.remoteCtrlPassthrough) return false;
    const lower = String.fromCharCode(keysym & 0xff);
    if (!this.macClipboardKeys.has(lower)) return false;
    if (isDown) {
      this.remoteCtrlDown = false;
      this.safeSendKey(0xffe3, false);
      this.safeSendKey(0xffeb, true);
      this.safeSendKey(keysym, true);
      this.safeSendKey(keysym, false);
      this.safeSendKey(0xffeb, false);
      this.safeSendKey(0xffe3, true);
      this.remoteCtrlDown = true;
    }
    return true;
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

    let changed = false;
    if (shiftDown !== this.remoteShiftDown) {
      this.safeSendKey(0xffe1, shiftDown);
      this.remoteShiftDown = shiftDown;
      changed = true;
    }
    if (ctrlDown !== this.remoteCtrlDown) {
      this.safeSendKey(0xffe3, ctrlDown);
      this.remoteCtrlDown = ctrlDown;
      changed = true;
    }
    if (altDown !== this.remoteAltDown) {
      this.safeSendKey(0xffe9, altDown);
      this.remoteAltDown = altDown;
      changed = true;
    }
    if (metaDown !== this.remoteMetaDown) {
      this.safeSendKey(0xffe7, metaDown);
      this.remoteMetaDown = metaDown;
      changed = true;
    }
    if (changed) {
      this.requestTick();
    }
  }

  private async sendTextToRemoteAsync(text: string): Promise<void> {
    if (!text) return;

    let toSend = text;
    let hasTrailingNewline = false;
    if (toSend.endsWith('\n')) {
      toSend = toSend.slice(0, -1);
      hasTrailingNewline = true;
    }

    if (toSend.length > 0) {
      try {
        this.vncClient.setClipboardText(toSend);
      } catch (e) {}
      
      await new Promise<void>(resolve => setTimeout(resolve, 50));
      
      const modKey = this.runtimeMacMode ? 0xffeb : 0xffe3; // Cmd(Super) for Mac, Ctrl for others
      const vKey = 0x76; // 'v'
      
      this.safeSendKey(modKey, true);
      await new Promise<void>(resolve => setTimeout(resolve, 20));
      this.safeSendKey(vKey, true);
      await new Promise<void>(resolve => setTimeout(resolve, 20));
      this.safeSendKey(vKey, false);
      await new Promise<void>(resolve => setTimeout(resolve, 20));
      this.safeSendKey(modKey, false);
      this.requestTick();
      await new Promise<void>(resolve => setTimeout(resolve, 200));
    }

    if (hasTrailingNewline) {
      this.safeSendKey(0xff0d, true);
      this.requestTick();
      await new Promise<void>(resolve => setTimeout(resolve, 20));
      this.safeSendKey(0xff0d, false);
      this.requestTick();
      await new Promise<void>(resolve => setTimeout(resolve, 20));
    }
  }

  private async ensurePixelMap(): Promise<void> {
    if (!this.connected) return;
    if (this.pm || this.creatingPm) return;
    this.refreshFramebufferInfo();
    if (this.fbW <= 0 || this.fbH <= 0) return;
    let buf: ArrayBuffer | null = null;
    try {
      buf = this.vncClient.copyFrameRGBA(this.debugByteOrder) ?? null;
    } catch (e) {
      buf = null;
    }
    if (!buf) return;
    this.refineMonitorsFromFrame(true);

    if (this.debugEnabled) {
      try {
        const view = new Uint8Array(buf);
        if (view.length >= 4) {
          this.firstPixel = `Pixel: ${view[0]},${view[1]},${view[2]},${view[3]}`;
        }
      } catch (e) {
      }
    }

    this.creatingPm = true;
    try {
      // copyFrameRGBA hands back a freshly allocated buffer, so adopt it directly.
      // Cloning it again only burnt a second full-frame memcpy on the UI thread.
      this.frameCache = buf;
      this.syncSharedSessionSnapshot();
      await this.replacePixelMapFromBuffer(buf);
    } catch (e) {
      console.error('Failed to create PixelMap', e);
    } finally {
      this.creatingPm = false;
    }
  }

  private normalizeDamageRect(dmg: VncRect | null): VncRect | null {
    if (!dmg) return null;
    const x = Math.max(0, Math.min(this.fbW, Math.floor(dmg.x ?? 0)));
    const y = Math.max(0, Math.min(this.fbH, Math.floor(dmg.y ?? 0)));
    const right = Math.max(x, Math.min(this.fbW, Math.floor((dmg.x ?? 0) + (dmg.w ?? 0))));
    const bottom = Math.max(y, Math.min(this.fbH, Math.floor((dmg.y ?? 0) + (dmg.h ?? 0))));
    const w = right - x;
    const h = bottom - y;
    if (w <= 0 || h <= 0) return null;
    return { x, y, w, h };
  }

  private getFrameByteSize(): number {
    return Math.max(0, this.fbW) * Math.max(0, this.fbH) * 4;
  }

  private hasUsableFrameCache(): boolean {
    return this.frameCache !== null && this.frameCache.byteLength === this.getFrameByteSize();
  }

  private patchFrameCache(rect: VncRect, rectBuf: ArrayBuffer): boolean {
    if (!this.frameCache) return false;
    if (rect.w <= 0 || rect.h <= 0) return false;
    if (rectBuf.byteLength < rect.w * rect.h * 4) return false;
    if (this.frameCache.byteLength !== this.getFrameByteSize()) return false;

    const src = new Uint8Array(rectBuf);
    const dst = new Uint8Array(this.frameCache);
    const srcStride = rect.w * 4;
    const dstStride = this.fbW * 4;
    if (srcStride === dstStride && rect.x === 0) {
      // Full-width damage is contiguous in both buffers, so one copy covers it.
      // Scroll and window-drag updates take this path on every frame.
      dst.set(src.subarray(0, rect.h * srcStride), rect.y * dstStride);
      return true;
    }
    for (let row = 0; row < rect.h; row++) {
      const srcOffset = row * srcStride;
      const dstOffset = ((rect.y + row) * dstStride) + (rect.x * 4);
      dst.set(src.subarray(srcOffset, srcOffset + srcStride), dstOffset);
    }
    return true;
  }

  private releasePixelMap(pm: image.PixelMap | undefined): void {
    if (!pm) return;
    try {
      pm.release();
    } catch (e) {
    }
  }

  private releaseViewerPixelMaps(): void {
    this.releasePixelMap(this.pm);
    this.releasePixelMap(this.pmBack);
    this.pm = undefined;
    this.pmBack = undefined;
    this.pmW = 0;
    this.pmH = 0;
    this.pmVersion = 0;
  }

  private async createPixelMapFromBuffer(buf: ArrayBuffer): Promise<image.PixelMap> {
    const opts: image.InitializationOptions = {
      size: { width: this.fbW, height: this.fbH },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.UNPREMUL,
      editable: true
    };
    return await image.createPixelMap(buf, opts) as image.PixelMap;
  }

  private async replacePixelMapFromBuffer(buf: ArrayBuffer): Promise<void> {
    const frontPm = await this.createPixelMapFromBuffer(buf);
    let backPm: image.PixelMap | undefined = undefined;
    try {
      backPm = await this.createPixelMapFromBuffer(buf);
    } catch (e) {
      this.releasePixelMap(frontPm);
      throw new Error('Failed to create back PixelMap');
    }
    if (!this.connected || this.pm) {
      this.releasePixelMap(frontPm);
      this.releasePixelMap(backPm);
      return;
    }
    this.pm = frontPm;
    this.pmBack = backPm;
    this.pmW = this.fbW;
    this.pmH = this.fbH;
    this.pmVersion++;
    this.lastFullFrameSyncTs = Date.now();
    this.handleViewerFrameReady();
  }

  private writeBufferToPixelMap(targetPm: image.PixelMap | undefined, buf: ArrayBuffer, rect: VncRect | null): boolean {
    if (!targetPm) return false;
    const targetRect = rect ?? { x: 0, y: 0, w: this.fbW, h: this.fbH };
    if (targetRect.w <= 0 || targetRect.h <= 0) return false;

    const area: image.PositionArea = {
      pixels: buf,
      offset: 0,
      stride: targetRect.w * 4,
      region: {
        x: targetRect.x,
        y: targetRect.y,
        size: {
          width: targetRect.w,
          height: targetRect.h
        }
      }
    };
    try {
      targetPm.writePixelsSync(area);
      return true;
    } catch (e) {
      console.error('Failed to write pixels to PixelMap', e);
      return false;
    }
  }

  private async presentFrameCache(): Promise<boolean> {
    if (!this.connected || !this.pm || !this.frameCache) return false;
    if (this.isInteracting) {
      this.pendingFrameCache = this.frameCache;
      if (!this.frameThrottle.shouldRender()) {
        return true;
      }
    }
    if (!this.pmBack || this.pmW !== this.fbW || this.pmH !== this.fbH) {
      this.releasePixelMap(this.pmBack);
      this.pmBack = undefined;
      try {
        this.pmBack = await this.createPixelMapFromBuffer(this.frameCache);
      } catch (e) {
        this.pmBack = undefined;
        console.error('Failed to create back PixelMap', e);
        return false;
      }
    }
    if (!this.writeBufferToPixelMap(this.pmBack, this.frameCache, null)) {
      return false;
    }
    const currentPm = this.pm;
    this.pm = this.pmBack;
    this.pmBack = currentPm;
    this.pmW = this.fbW;
    this.pmH = this.fbH;
    this.pmVersion++;
    this.lastFullFrameSyncTs = Date.now();
    return true;
  }

  private shouldUsePartialPixelMapUpdate(rect: VncRect | null): boolean {
    if (!rect) return false;
    if (rect.w <= 0 || rect.h <= 0) return false;
    const frameArea = this.fbW * this.fbH;
    if (frameArea <= 0) return false;
    const rectArea = rect.w * rect.h;
    return (rectArea / frameArea) <= this.partialPixelMapAreaRatioThreshold;
  }

  private presentDamageRect(rect: VncRect, rectBuf: ArrayBuffer): boolean {
    if (!this.pm) return false;
    if (!this.patchFrameCache(rect, rectBuf)) return false;

    try {
      if (!this.writeBufferToPixelMap(this.pm, rectBuf, rect)) return false;
      this.pmVersion++;
      this.syncSharedSessionSnapshot();
      return true;
    } catch (e) {
      console.error('Failed to present damage rect', e);
      return false;
    }
  }

  private async updatePixelMap(dmg: VncRect | null): Promise<void> {
    if (!this.pm) return;
    if (!this.connected) return;
    if (this.pmW !== this.fbW || this.pmH !== this.fbH) {
      this.releaseViewerPixelMaps();
      this.frameCache = null;
      this.lastFullFrameSyncTs = 0;
      await this.ensurePixelMap();
      return;
    }

    try {
      const rect = this.normalizeDamageRect(dmg);
      const usePartial = this.shouldUsePartialPixelMapUpdate(rect);
      if (usePartial && rect) {
        let rectBuf: ArrayBuffer | null = null;
        try {
          rectBuf = this.vncClient.copyRectRGBA(this.debugByteOrder, rect.x, rect.y, rect.w, rect.h) ?? null;
        } catch (e) {
          rectBuf = null;
        }
        if (rectBuf && this.presentDamageRect(rect, rectBuf)) {
          return;
        }
      }

      let buf: ArrayBuffer | null = null;
      try {
        buf = this.vncClient.copyFrameRGBA(this.debugByteOrder) ?? null;
      } catch (e) {
        buf = null;
      }
      if (!buf) return;
      // Adopt the buffer copyFrameRGBA just allocated for us (see replaceFrameCache removal).
      this.frameCache = buf;
      this.refineMonitorsFromFrame(dmg === null || !usePartial);
      this.syncSharedSessionSnapshot();

      if (this.debugEnabled) {
        try {
          const view = new Uint8Array(buf);
          if (view.length >= 4) {
            this.firstPixel = `Pixel: ${view[0]},${view[1]},${view[2]},${view[3]}`;
          }
        } catch (e) {
        }
      }

      await this.presentFrameCache();
    } catch (e) {
      console.error('Failed to update pixelmap', e);
    }
  }

  private async bootstrapFirstFrame(): Promise<void> {
    this.debugByteOrder = 0;
    this.debugPmFormat = 1; // 1 = swap R/B (BGRA) for correct colors on RGBA_8888
    this.vncClient.setDebugOptions(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
    this.lastServerRefreshRequestTs = Date.now();
    this.bootstrapping = true;
    this.vncClient.requestUpdate?.(false);
    const fbInfo = this.vncClient.getFramebufferInfo();
    let accLeft = Number.MAX_SAFE_INTEGER;
    let accTop = Number.MAX_SAFE_INTEGER;
    let accRight = 0;
    let accBottom = 0;
    let receivedFirstUpdate = false;
    let damageCoversFullFramebuffer = false;
    for (let attempt = 0; attempt < 256; attempt++) {
      try {
        const prc = this.vncClient.process();
        if (prc !== 0) {
          this.lastError = (this.vncClient.getLastError() as string) ?? '';
          this.disconnect(true);
          this.toast(this.lastError || this.s($r('app.string.conn_failed')));
          return;
        }
        const dmg = this.vncClient.consumeDamage?.();
        if (dmg) {
          await this.ensurePixelMap();
          if (this.pm) {
            await this.updatePixelMap(dmg);
          }
          accLeft = Math.min(accLeft, dmg.x);
          accTop = Math.min(accTop, dmg.y);
          accRight = Math.max(accRight, dmg.x + dmg.w);
          accBottom = Math.max(accBottom, dmg.y + dmg.h);
        }
        receivedFirstUpdate = this.vncClient.hasReceivedFirstUpdate?.() ?? false;
        damageCoversFullFramebuffer =
          fbInfo.width > 0 && fbInfo.height > 0 &&
          accLeft <= 0 && accTop <= 0 &&
          accRight >= fbInfo.width && accBottom >= fbInfo.height;
        if (receivedFirstUpdate && damageCoversFullFramebuffer) {
          break;
        }
        await new Promise<void>(resolve => setTimeout(resolve, 5));
      } catch (e) {
        this.lastError = (this.vncClient.getLastError() as string) ?? '';
        this.disconnect(true);
        this.toast(this.lastError || this.s($r('app.string.conn_failed')));
        return;
      }
    }
    this.refreshFramebufferInfo();
    await this.ensurePixelMap();
    this.bootstrapping = false;
  }

  private requestTick(): void {
    if (!this.connected) return;
    if (this.ticking) {
      this.tickQueued = true;
      return;
    }
    if (this.tickScheduled) return;
    this.tickScheduled = true;
    setTimeout(() => {
      this.tickScheduled = false;
      if (!this.connected) return;
      void this.tick();
    }, 0);
  }

  private noteLocalInputActivity(): void {
    if (!this.connected) return;
    const now = Date.now();
    this.lastLocalInputTs = now;
    if ((now - this.lastServerRefreshRequestTs) < this.inputBurstRefreshIntervalMs) {
      this.requestTick();
      return;
    }
    this.lastServerRefreshRequestTs = now;
    try {
      this.vncClient.requestUpdate?.(true);
    } catch (e) {
    }
    this.requestTick();
  }

  private isInLocalInputBurstWindow(now: number): boolean {
    return this.lastLocalInputTs > 0 && (now - this.lastLocalInputTs) <= this.inputBurstRefreshWindowMs;
  }

  private shouldSyncRemoteClipboard(now: number): boolean {
    if (!this.connected) return false;
    if (this.isInLocalInputBurstWindow(now)) return false;
    if ((now - this.lastRemoteClipboardSyncAttemptTs) < this.remoteClipboardSyncIntervalMs) return false;
    this.lastRemoteClipboardSyncAttemptTs = now;
    return true;
  }

  private shouldRequestServerRefresh(now: number): boolean {
    if (!this.connected) return false;
    const refreshInterval = this.isInLocalInputBurstWindow(now)
      ? this.inputBurstRefreshIntervalMs
      : ((this.connectedAtTs > 0 && (now - this.connectedAtTs) <= this.activeServerRefreshWindowMs)
        ? this.activeServerRefreshIntervalMs
        : this.idleServerRefreshIntervalMs);
    const sinceLastUpdate = now - this.lastFramebufferUpdateTs;
    const sinceLastRequest = now - this.lastServerRefreshRequestTs;
    return sinceLastUpdate >= refreshInterval && sinceLastRequest >= refreshInterval;
  }

  private shouldRequestRefreshForDamage(dmg: VncRect | null, now: number): boolean {
    if (!this.connected || !dmg) return false;
    const rect = this.normalizeDamageRect(dmg);
    if (!rect) return false;
    const frameArea = this.fbW * this.fbH;
    if (frameArea <= 0) return false;
    const rectArea = rect.w * rect.h;
    if (rectArea <= 0) return false;
    if ((rectArea / frameArea) >= this.partialDamageRefreshAreaRatioThreshold) return false;
    return (now - this.lastServerRefreshRequestTs) >= this.partialDamageRefreshIntervalMs;
  }

  private async tick(): Promise<void> {
    if (!this.connected) return;
    if (this.ticking) {
      this.tickQueued = true;
      return;
    }
    this.ticking = true;
    let shouldContinueTickSoon = false;
    try {
      this.refreshFramebufferInfo();
      this.checkAdaptiveResizeFailure();
      this.maybeAdoptServerNameAsConnName();
      
      let prc = 0;
      try {
        prc = this.vncClient.process();
      } catch (e) {
        prc = -1;
      }
      if (prc !== 0) {
        this.lastError = (this.vncClient.getLastError() as string) ?? '';
        this.disconnect(true);
        this.toast(this.lastError || this.s($r('app.string.conn_disconnected')));
        return;
      }

      this.consumeRemoteClipboardAnnounce();

      let dmg: VncRect | null = null;
      try {
        dmg = this.vncClient.consumeDamage();
      } catch (e) {
        dmg = null;
      }
      const now = Date.now();
      if (dmg) {
        this.lastFramebufferUpdateTs = now;
        shouldContinueTickSoon = true;
        if (this.shouldRequestRefreshForDamage(dmg, now)) {
          this.lastServerRefreshRequestTs = now;
          try {
            this.vncClient.requestUpdate?.(true);
            shouldContinueTickSoon = true;
          } catch (e) {
          }
        }
      } else if (this.shouldRequestServerRefresh(now)) {
        this.lastServerRefreshRequestTs = now;
        try {
          this.vncClient.requestUpdate?.(true);
          shouldContinueTickSoon = true;
        } catch (e) {
        }
      }

      if (!this.pm) {
        await this.ensurePixelMap();
        if (!this.connected) return;
      } else if (dmg) {
        await this.updatePixelMap(dmg);
        if (!this.connected) return;
      } else if (now - this.lastFullFrameSyncTs >= this.fallbackFullFrameSyncMs) {
        await this.updatePixelMap(null);
        if (!this.connected) return;
      }

      this.lastError = (this.vncClient.getLastError() as string) ?? '';
      if (this.shouldSyncRemoteClipboard(now)) {
        await this.syncRemoteClipboardToSystemAsync();
      }

      if (this.debugEnabled) {
        const now = Date.now();
        if (now - this.lastDebugTs > 500) {
          this.lastDebugTs = now;
          const info = this.vncClient.getDebugInfo?.() as VncDebugInfo;
          const log = (this.vncClient.getDebugLog?.(false) as string) ?? '';
          const p00 = info.p00 ?? [];
          const pc = info.pCenter ?? [];
          const pd = info?.pendingDamage ?? null;
          const pdText = pd ? `${pd.x},${pd.y} ${pd.w}x${pd.h}` : '-';
          this.debugInfoText =
            `proc#${info.processCount ?? 0} rc=${info.lastProcessRc ?? 0} upd#${info.fbUpdateCount ?? 0} ` +
            `lastUpd=${info.lastUpdateX ?? 0},${info.lastUpdateY ?? 0} ${info.lastUpdateW ?? 0}x${info.lastUpdateH ?? 0} ` +
            `pending=${pdText} checksum=${info.checksum ?? 0} ` +
            `p00=[${p00.join(',')}] pc=[${pc.join(',')}]`;
          this.debugLogText = log.length > 6000 ? log.slice(log.length - 6000) : log;
        }
      }
    } finally {
      this.ticking = false;
      if (this.connected && (this.tickQueued || shouldContinueTickSoon)) {
        this.tickQueued = false;
        this.requestTick();
      }
    }
  }

  private startLoop(): void {
    if (this.timerId !== -1) return;
    this.timerId = setInterval(() => { this.requestTick(); }, this.loopIntervalMs);
  }

  private stopLoop(): void {
    if (this.timerId === -1) return;
    clearInterval(this.timerId);
    this.timerId = -1;
  }

  private requestInputFocus(): void {
    try {
      const fc = this.getUIContext()?.getFocusController?.();
      fc?.requestFocus?.('vnc_root_stack');
      fc?.requestFocus?.(this.inputLayerKey);
    } catch (e) {
      console.error('requestInputFocus error=' + e);
    }
  }

  private focusSoftInputLater(): void {
    setTimeout(() => {
      try {
        const fc = this.getUIContext()?.getFocusController?.();
        fc?.requestFocus?.(this.softInputKey);
      } catch (e) {
      }
    }, 0);
  }

  private showSoftKeyboard(): void {
    if (!this.connected) {
      this.toast(this.s($r('app.string.viewer_please_connect_first')));
      return;
    }
    this.revealChrome();
    this.focusSoftInputLater();
    setTimeout(() => {
      void this.inputMethodController.showTextInput().catch(() => {
      });
    }, 0);
  }

  private buildTextDelta(previous: string, next: string): TextDelta {
    const prevChars = Array.from(previous ?? '');
    const nextChars = Array.from(next ?? '');

    let prefix = 0;
    while (prefix < prevChars.length && prefix < nextChars.length && prevChars[prefix] === nextChars[prefix]) {
      prefix++;
    }

    let suffix = 0;
    while (
      suffix < prevChars.length - prefix &&
      suffix < nextChars.length - prefix &&
      prevChars[prevChars.length - 1 - suffix] === nextChars[nextChars.length - 1 - suffix]
    ) {
      suffix++;
    }

    return {
      deletedCount: prevChars.length - prefix - suffix,
      insertedText: nextChars.slice(prefix, nextChars.length - suffix).join('')
    };
  }

  private sendRemoteBackspace(count: number): void {
    const total = Math.max(0, Math.floor(count));
    if (total <= 0) return;
    this.noteLocalInputActivity();
    for (let i = 0; i < total; i++) {
      this.safeSendKey(0xff08, true);
      this.safeSendKey(0xff08, false);
    }
    this.requestTick();
  }

  private sendRemoteCommittedText(text: string): void {
    if (!text) return;
    this.noteLocalInputActivity();
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
      this.requestTick();
      return;
    }

    void this.sendTextToRemoteAsync(text);
    this.requestTick();
  }

  private handleSoftInputChange(next: string): void {
    const previous = this.softInputDraft ?? '';
    this.softInputDraft = next;
    if (!this.connected) return;

    const delta = this.buildTextDelta(previous, next);
    if (delta.deletedCount > 0) {
      this.sendRemoteBackspace(delta.deletedCount);
    }
    if (delta.insertedText.length > 0) {
      this.sendRemoteCommittedText(delta.insertedText);
    }
  }

  private async connect(): Promise<void> {
    if (this.connecting) return;
    viewerMultiWindowStore.ensureSession(this.sharedSessionId);
    this.connecting = true;
    this.lastError = '';
    this.panelMode = 'none';
    this.didAdoptServerName = false;
    this.interactionMode = 'control';
    this.resetViewerZoom();
    this.revealChrome(true);

    await new Promise<void>((resolve) => setTimeout(resolve, 0));

    try {
      this.saveSelectedName();
      this.updateWindowTitle();
      const sshConfig = this.getEffectiveSshConfig();
      const parsed = parseAddress(resolveConnectionAddress(this.address, sshConfig ?? undefined));
      if (!parsed) {
        this.lastError = this.s($r('app.string.conn_fill_address_or_ssh'));
        this.toast(this.lastError);
        return;
      }
      if (sshConfig?.enabled) {
        const sshRc = (this.vncClient.setSshTunnel?.(sshConfig) as number) ?? 0;
        if (sshRc !== 0) {
          this.lastError = (this.vncClient.getLastError() as string) ?? this.s($r('app.string.ssh_tunnel_config_failed'));
          this.toast(this.lastError);
          return;
        }
      } else {
        this.vncClient.clearSshTunnel?.();
      }
      this.vncClient.setDebugOptions(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
      const rc = (await this.vncClient.connect?.(parsed.host, parsed.port, this.user, this.password)) ?? -1;
      this.connected = (rc === 0);
      viewerMultiWindowStore.updateSessionConnectionState(this.sharedSessionId, this.connected);
      if (this.connected) {
        viewerMultiWindowStore.setVncClient(this.sharedSessionId, this.vncClient as VncClientLike);
      }
      this.securityLevel = this.connected ? (this.vncClient.getSecurityLevel?.() ?? 0) : 0;
      this.releaseViewerPixelMaps();
      this.frameCache = null;
      this.lastFullFrameSyncTs = 0;
      this.connectedAtTs = 0;
      this.lastFramebufferUpdateTs = 0;
      this.lastServerRefreshRequestTs = 0;
      this.lastMask = 0;
      this.adaptiveResizeBlocked = false;
      this.adaptiveResizeNotice = '';
      this.adaptiveResizeTries = 0;
      this.adaptiveResizeTryW = 0;
      this.adaptiveResizeTryH = 0;
      this.adaptiveResizeLastTs = 0;
      this.refreshFramebufferInfo();
      this.maybeAdoptServerNameAsConnName();
      this.lastError = (this.vncClient.getLastError() as string) ?? '';
      if (!this.connected) {
        this.toast(this.lastError || this.s($r('app.string.conn_failed')));
        return;
      }
      this.lastRemoteClipboardText = '';
      this.lastLocalClipboardText = '';
      this.pendingLocalClipboardEchoText = '';
      const now = Date.now();
      this.connectedAtTs = now;
      this.lastFramebufferUpdateTs = now;
      this.lastServerRefreshRequestTs = 0;
      this.touchConnectionUsed();
      void recordRatingSession(this.getHostContext());
      await this.bootstrapFirstFrame();
      if (!this.connected) return;
      this.maybeAdoptServerNameAsConnName();
      this.requestRemoteClipboard();
      this.startLoop();
      // The first frame has landed, so the server's screen layout is known and
      // the remote desktop can be matched to the window.
      this.scheduleAdaptiveDesktopResize(this.adaptiveResizeInitialDelayMs);
      setTimeout(() => this.requestInputFocus(), 0);
      this.showStatusBanner(this.s($r('app.string.conn_connected')));
    } catch (e) {
      this.connected = false;
      viewerMultiWindowStore.updateSessionConnectionState(this.sharedSessionId, false);
      this.releaseViewerPixelMaps();
      this.frameCache = null;
      this.lastFullFrameSyncTs = 0;
      this.connectedAtTs = 0;
      this.lastFramebufferUpdateTs = 0;
      this.lastServerRefreshRequestTs = 0;
      const msg = (e as Error)?.message;
      this.lastError = msg ?? this.s($r('app.string.conn_failed'));
      this.toast(this.lastError);
    } finally {
      this.connecting = false;
      this.handleViewerFrameReady();
    }
  }

  private setDevToolsEnabled(enable: boolean): void {
    this.devToolsEnabled = enable;
    if (!enable) {
      this.debugEnabled = false;
      this.debugInfoText = '';
      this.debugLogText = '';
      this.firstPixel = '';
      this.vncClient.setDebugOptions(false, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
    } else {
      this.vncClient.setDebugOptions(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
    }
    this.revealChrome(true);
  }

  private getPanelBarTitle(): string {
    if (this.connected) return this.s($r('app.string.conn_connected'));
    const c = this.getSelectedConnection();
    if (!c) return this.s($r('app.string.viewer_free_connect_hint_short'));
    return normalizeConnName(c.name, c.address, c.sshTunnel);
  }

  private getPanelBarSubtitle(): string {
    const addr = resolveConnectionAddress(this.address, this.getEffectiveSshConfig() ?? undefined);
    if (addr) return addr;
    const c = this.getSelectedConnection();
    return resolveConnectionAddress(c?.address ?? '', c?.sshTunnel) || this.s($r('app.string.viewer_enter_address_hint'));
  }

  private disconnect(preserveError: boolean = false): void {
    this.stopLoop();
    this.cancelAdaptiveDesktopResize();
    this.adaptiveResizeBlocked = false;
    this.adaptiveResizeNotice = '';
    this.adaptiveResizeTries = 0;
    this.adaptiveResizeTryW = 0;
    this.adaptiveResizeTryH = 0;
    this.adaptiveResizeLastTs = 0;
    void this.closeMonitorWindows(false);
    viewerMultiWindowStore.setVncClient(this.sharedSessionId, null);
    try { this.vncClient.disconnect(); } catch (e) {}
    try { this.vncClient.clearSshTunnel?.(); } catch (e) {}
    this.connected = false;
    this.connecting = false;
    this.bootstrapping = false;
    this.panelMode = 'none';
    this.chromeVisible = true;
    this.clearChromeAutoHide();
    this.interactionMode = 'control';
    this.resetViewerZoom();
    void this.inputMethodController.hideTextInput().catch(() => {
    });
    this.softInputDraft = '';
    this.ticking = false;
    this.didAdoptServerName = false;
    this.macAutoChecked = false;
    this.remoteCtrlPassthrough = false;
    const ctx = this.getHostContext();
    if (ctx) saveCtrlPassthrough(false, ctx);
    this.releaseViewerPixelMaps();
    this.frameCache = null;
    this.lastMask = 0;
    this.lastFullFrameSyncTs = 0;
    this.connectedAtTs = 0;
    this.lastFramebufferUpdateTs = 0;
    this.lastServerRefreshRequestTs = 0;
    this.tickQueued = false;
    this.tickScheduled = false;
    this.lastPointerSentX = -1;
    this.lastPointerSentY = -1;
    this.lastPointerSentMask = -1;
    this.lastRemoteClipboardText = '';
    this.lastLocalClipboardText = '';
    this.pendingLocalClipboardEchoText = '';
    this.fbW = 0;
    this.fbH = 0;
    this.fbStride = 0;
    this.monitors = [];
    this.detectedMonitorRects = [];
    this.clearManualMonitorLayout();
    this.monitorCount = 0;
    this.monitorLayoutLocked = false;
    this.monitorSlots = [];
    viewerMultiWindowStore.clearSessionFrame(this.sharedSessionId, this.getWindowTitleText());
    this.refreshMonitorWindowsState();
    if (!preserveError) this.lastError = '';
  }

  private consumeRemoteClipboardAnnounce(): void {
    let announce = -1;
    try {
      announce = this.vncClient.takeRemoteClipboardAnnounce();
    } catch (e) {
      return;
    }
    if (announce > 0) {
      console.info(`remote clipboard announced available=${announce}`);
      this.requestRemoteClipboard();
    }
  }

  private requestRemoteClipboard(): void {
    if (!this.connected) return;
    try {
      this.vncClient.requestClipboard();
      console.info('remote clipboard request sent');
    } catch (e) {
      const err = e as ClipboardErrorLike;
      console.error(`remote clipboard request failed code=${err?.code ?? -1} message=${err?.message ?? ''}`);
    }
  }

  private async readSystemClipboardTextAsync(): Promise<string | null> {
    try {
      const data = await this.systemPasteboard.getData();
      if (data.hasType(pasteboard.MIMETYPE_TEXT_PLAIN)) {
        return data.getPrimaryText();
      }
      const text = data.getPrimaryText();
      return text.length > 0 ? text : null;
    } catch (e) {
      const err = e as ClipboardErrorLike;
      console.error(`local clipboard read failed code=${err?.code ?? -1} message=${err?.message ?? ''}`);
      return null;
    }
  }

  private async syncLocalClipboardToRemoteAsync(): Promise<void> {
    if (!this.connected) return;
    const text = await this.readSystemClipboardTextAsync();
    if (text === null) return;
    if (text === this.pendingLocalClipboardEchoText) {
      this.pendingLocalClipboardEchoText = '';
      this.lastLocalClipboardText = text;
      return;
    }
    if (text === this.lastLocalClipboardText || text === this.lastRemoteClipboardText) {
      this.lastLocalClipboardText = text;
      return;
    }
    try {
      this.vncClient.setClipboardText(text);
      this.lastLocalClipboardText = text;
      console.info(`local clipboard synced len=${text.length}`);
    } catch (e) {
      const err = e as ClipboardErrorLike;
      console.error(`local clipboard sync failed code=${err?.code ?? -1} message=${err?.message ?? ''}`);
    }
  }

  private async onPasteButtonClickedAsync(): Promise<void> {
    this.requestInputFocus();
    if (!this.connected) {
      this.toast(this.s($r('app.string.viewer_please_connect_first')));
      return;
    }

    const text = await this.readSystemClipboardTextAsync();
    if (!text) {
      this.toast(this.s($r('app.string.clipboard_no_content')));
      return;
    }

    if (text === this.lastLocalClipboardText) {
      this.toast(this.s($r('app.string.clipboard_no_content')));
      return;
    }

    try {
      this.vncClient.setClipboardText(text);
      this.lastLocalClipboardText = text;
      this.toast(this.s($r('app.string.clipboard_sent_success_count'), text.length));
    } catch (e) {
      const err = e as ClipboardErrorLike;
      console.error(`clipboard sync failed code=${err?.code ?? -1} message=${err?.message ?? ''}`);
      this.toast(this.s($r('app.string.clipboard_fetch_success')));
    }
  }

  private async syncRemoteClipboardToSystemAsync(): Promise<void> {
    if (!this.connected) return;

    let hasRemoteClipboardText = false;
    try {
      hasRemoteClipboardText = this.vncClient.hasRemoteClipboardText();
    } catch (e) {
      const err = e as ClipboardErrorLike;
      console.error(`remote clipboard state read failed code=${err?.code ?? -1} message=${err?.message ?? ''}`);
      return;
    }
    if (!hasRemoteClipboardText) return;

    let text = '';
    try {
      text = this.vncClient.takeRemoteClipboardText();
    } catch (e) {
      const err = e as ClipboardErrorLike;
      console.error(`remote clipboard text read failed code=${err?.code ?? -1} message=${err?.message ?? ''}`);
      return;
    }

    if (text === this.lastRemoteClipboardText) return;

    try {
      const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      this.pendingLocalClipboardEchoText = text;
      await pasteboard.getSystemPasteboard().setData(pasteData);
      this.lastRemoteClipboardText = text;
      this.lastLocalClipboardText = text;
      console.info(`remote clipboard synced len=${text.length}`);
    } catch (e) {
      const err = e as ClipboardErrorLike;
      console.error(`remote clipboard sync failed code=${err?.code ?? -1} message=${err?.message ?? ''}`);
    }
  }

  private mapToRemoteX(x: number): number {
    return this.mapToRemotePoint(x, this.lastY).x;
  }

  private mapToRemoteY(y: number): number {
    return this.mapToRemotePoint(this.lastX, y).y;
  }

  private mapToRemotePoint(x: number, y: number): RemotePoint {
    if (this.fbW <= 0 || this.fbH <= 0) return new RemotePoint(0, 0);
    if (this.viewerW <= 0 || this.viewerH <= 0) return new RemotePoint(0, 0);

    const basePoint = this.toBaseViewerPoint(x, y);
    x = basePoint.x;
    y = basePoint.y;

    const target = this.getViewportTargetAt(x, y);
    const source = target.source;
    const frame = target.frame;
    const scale = this.getViewportScale(source, frame);
    const contentW = source.w * scale;
    const contentH = source.h * scale;
    const offsetX = frame.x + (frame.w - contentW) / 2;
    const offsetY = frame.y + (frame.h - contentH) / 2;

    this.lastX = x;
    this.lastY = y;

    const localX = (x - offsetX) / scale;
    const localY = (y - offsetY) / scale;

    const rx = Math.max(0, Math.min(source.w - 1, Math.floor(localX)));
    const ry = Math.max(0, Math.min(source.h - 1, Math.floor(localY)));
    return new RemotePoint(source.x + rx, source.y + ry);
  }

  private isLocalWithinContent(localX: number, localY: number): boolean {
    if (this.fbW <= 0 || this.fbH <= 0) return true;
    if (this.viewerW <= 0 || this.viewerH <= 0) return true;
    const basePoint = this.toBaseViewerPoint(localX, localY);
    const x = basePoint.x;
    const y = basePoint.y;
    const target = this.getViewportTargetAt(x, y);
    const source = target.source;
    const frame = target.frame;
    const scale = this.getViewportScale(source, frame);
    const contentW = source.w * scale;
    const contentH = source.h * scale;
    const offsetX = frame.x + (frame.w - contentW) / 2;
    const offsetY = frame.y + (frame.h - contentH) / 2;
    const rawLocalX = (x - offsetX) / scale;
    const rawLocalY = (y - offsetY) / scale;
    return rawLocalX >= 0 && rawLocalX < source.w && rawLocalY >= 0 && rawLocalY < source.h;
  }

  private getTouchCenter(ev: TouchEvent): LocalPoint | null {
    const touches = ev?.touches;
    if (!touches || touches.length < 2) return null;
    const t0 = touches[0] as TouchPointLike;
    const t1 = touches[1] as TouchPointLike;
    const x0 = t0?.x ?? 0;
    const y0 = t0?.y ?? 0;
    const x1 = t1?.x ?? 0;
    const y1 = t1?.y ?? 0;
    return {
      x: (x0 + x1) / 2,
      y: (y0 + y1) / 2
    };
  }

  private beginTouchScroll(localX: number, localY: number): void {
    if (this.touchDragging) {
      const p = this.mapToRemotePoint(localX, localY);
      this.touchDragging = false;
      this.safeSendPointer(p.x, p.y, 0);
    }
    this.touchMoved = true;
    this.touchScrollActive = true;
    this.touchScrollLastX = localX;
    this.touchScrollLastY = localY;
    this.touchScrollResidualY = 0;
    this.requestInputFocus();
  }

  private endTouchScroll(): void {
    this.touchScrollActive = false;
    this.touchScrollResidualY = 0;
  }

  private isMacRemote(): boolean {
    const lower = (this.serverName ?? '').toLowerCase();
    return lower.indexOf('mac') >= 0 || lower.indexOf('os x') >= 0 || lower.indexOf('apple') >= 0;
  }

  private getRemoteMacMajorVersion(): number {
    const lower = (this.serverName ?? '').toLowerCase();
    const m = lower.match(/(?:macos|mac os x|mac os|os x|mac)[^0-9]*([0-9]{1,2})/);
    if (!m || m.length < 2) return 0;
    const v = Number.parseInt(m[1], 10);
    return Number.isFinite(v) ? v : 0;
  }

  private getTouchScrollStepPx(): number {
    const selected = this.getSelectedConnection();
    const configured = this.normalizeTouchScrollStep(selected?.touchScrollStep ?? this.runtimeTouchScrollStep);
    let base = 0;
    if (configured > 0) {
      base = configured;
    } else {
      const isMac = this.isMacRemote();
      if (!isMac) {
        base = this.touchScrollStepPx;
      } else {
        const major = this.getRemoteMacMajorVersion();
        base = (major >= 20) ? this.touchScrollStepPxMacNewer : this.touchScrollStepPx;
      }
    }
    if (this.isMacRemote()) base = base / 10;
    return base;
  }

  private emitTouchScroll(localX: number, localY: number, deltaY: number): void {
    if (deltaY === 0) return;
    const stepPx = this.getTouchScrollStepPx();
    this.touchScrollResidualY += deltaY;
    let clicks = 0;
    let mask = 0;
    while (Math.abs(this.touchScrollResidualY) >= stepPx && clicks < 20) {
      if (this.touchScrollResidualY > 0) {
        mask = 16;
        this.touchScrollResidualY -= stepPx;
      } else {
        mask = 8;
        this.touchScrollResidualY += stepPx;
      }
      clicks++;
    }
    if (clicks <= 0) return;
    const p = this.mapToRemotePoint(localX, localY);
    for (let i = 0; i < clicks; i++) {
      this.safeSendPointer(p.x, p.y, this.lastMask | mask, true);
      this.safeSendPointer(p.x, p.y, this.lastMask, true);
    }
    this.requestTick();
  }

  private async saveImage(): Promise<void> {
    if (!this.pm) {
      this.toast(this.s($r('app.string.viewer_save_image_no_data')));
      return;
    }
    try {
      const context = this.getHostContext();
      if (!context) return;
      const buf: ArrayBuffer | null = this.vncClient.copyFrameRGBA(this.debugByteOrder) ?? null;
      if (buf) {
        const rawPath = context.cacheDir + '/frame.raw';
        const rawFile = fs.openSync(rawPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(rawFile.fd, buf);
        fs.closeSync(rawFile);
      }

      const imagePacker = image.createImagePacker();
      const packOpts: image.PackingOption = { format: 'image/jpeg', quality: 90 };
      const data = await imagePacker.packToData(this.pm, packOpts);
      
      const path = context.cacheDir + '/frame.jpg';
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, data);
      fs.closeSync(file);
      this.toast(this.s($r('app.string.viewer_save_image_saved')));
    } catch (e) {
      console.error('Failed to save image', e);
      this.toast(this.s($r('app.string.viewer_save_image_failed')));
    }
  }

  @Builder
  private buildControls(): void {
    Column() {
      Row() {
        Text(this.connected ? $r('app.string.viewer_session_title') : $r('app.string.conn_connect'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1);
        Button($r('app.string.conn_new'))
          .height(32)
          .fontSize(12)
          .fontColor(this.cPrimary)
          .backgroundColor(this.cSurfaceAlt)
          .border({ width: 1, color: this.cBorder })
          .borderRadius(12)
          .enabled(!this.connected)
          .onClick(() => this.openCreateDialog());
        if (this.connected) {
          Text($r('app.string.conn_collapse'))
            .fontSize(12)
            .fontColor(this.cTextSecondary)
            .margin({ left: 12 })
            .onClick(() => this.closePanel());
        }
      }
      .padding({ left: 12, right: 12, top: 12, bottom: 8 });

      if (this.connections.length === 0) {
        Text($r('app.string.conn_no_saved'))
          .fontSize(13)
          .fontColor(this.cTextSecondary)
          .padding({ left: 12, right: 12, bottom: 10 });
      } else {
        List() {
          ForEach(this.connections, (c: ConnectionItem) => {
            ListItem() {
              Column() {
                Row() {
                  Column() {
                    Text(normalizeConnName(c.name ?? '', c.address ?? '', c.sshTunnel))
                      .fontSize(14)
                      .fontWeight(c.id === this.selectedConnId ? FontWeight.Medium : FontWeight.Regular);
                    Row() {
                      if (((c.name ?? '').trim())) {
                        Text(resolveConnectionAddress(c.address ?? '', c.sshTunnel))
                          .fontSize(12)
                          .fontColor(this.cTextSecondary)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(1);
                      }
                      if ((c.user ?? '').trim()) {
                        Text($r('app.string.conn_user_prefix', (c.user ?? '').trim())).fontSize(12).fontColor(this.cTextSecondary).margin({ left: ((c.name ?? '').trim()) ? 8 : 0 });
                      }
                      if (c.storePassword && (c.password ?? '').length > 0) {
                        Text($r('app.string.conn_password_saved')).fontSize(12).fontColor(this.cTextSecondary).margin({ left: 8 });
                      }
                    }.margin({ top: 2 });
                  }.layoutWeight(1);
                  if (!this.connected && c.id === this.selectedConnId) {
                    Text($r('app.string.conn_edit_delete'))
                      .fontSize(12)
                      .fontColor(this.cTextSecondary)
                      .margin({ left: 12 })
                      .onClick(() => { void this.openConnectionActions(c.id); });
                  }
                }
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .onClick(() => this.selectConnection(c.id));
                Blank().height(1).backgroundColor(this.cBorder).margin({ left: 12, right: 12 });
              }
            }
          }, (c: ConnectionItem) => c.id);
        }
        .height(180);
      }

      Row() {
        Text($r('app.string.conn_quick_connect'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1);
        Button(this.authOpen ? $r('app.string.conn_collapse_auth') : $r('app.string.conn_open_auth'))
          .height(32)
          .fontSize(12)
          .fontColor(this.cPrimary)
          .backgroundColor(this.cSurfaceAlt)
          .border({ width: 1, color: this.cBorder })
          .borderRadius(12)
          .enabled(!this.connected)
          .onClick(() => this.authOpen = !this.authOpen);
      }
      .padding({ left: 12, right: 12, top: 8, bottom: 6 });

      Column() {
        Text($r('app.string.conn_address_label'))
          .fontSize(12)
          .fontColor(this.cTextSecondary)
          .width('100%')
          .padding({ bottom: 4 });
        TextInput({ text: this.address, placeholder: $r('app.string.conn_address_placeholder') })
          .onChange((v: string) => this.address = v)
          .enabled(!this.connected)
          .padding({ bottom: 8 });

        if (this.authOpen) {
          Text($r('app.string.conn_user_optional'))
            .fontSize(12)
            .fontColor(this.cTextSecondary)
            .width('100%')
            .padding({ bottom: 4 });
          TextInput({ text: this.user, placeholder: $r('app.string.conn_user_placeholder') })
            .onChange((v: string) => this.user = v)
            .enabled(!this.connected)
            .padding({ bottom: 8 });

          Text($r('app.string.conn_password_optional'))
            .fontSize(12)
            .fontColor(this.cTextSecondary)
            .width('100%')
            .padding({ bottom: 4 });
          TextInput({ text: this.password, placeholder: $r('app.string.conn_password_placeholder') })
            .type(InputType.Password)
            .onChange((v: string) => this.password = v)
            .enabled(!this.connected)
            .padding({ bottom: 8 });
          if (this.selectedConnId) {
            Row() {
              Text($r('app.string.conn_remember_password'))
                .fontSize(12)
                .fontColor(this.cTextSecondary)
                .layoutWeight(1);
              this.buildBrandSwitch(this.isSelectedStorePasswordEnabled(), !this.connected, (next: boolean) => {
                if (next !== this.isSelectedStorePasswordEnabled()) this.toggleSelectedStorePassword();
              });
            }
            .padding({ bottom: 8 });
          }
        }
      }
      .padding({ left: 12, right: 12, bottom: 10 });

      if (this.lastError) {
        Text(this.lastError)
          .fontSize(12)
          .fontColor(this.cError)
          .padding({ left: 12, right: 12, bottom: 8 });
      }

      Row() {
        Button(this.connected ? $r('app.string.conn_disconnect') : (this.connecting ? $r('app.string.conn_connecting') : $r('app.string.conn_connect')))
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(this.connected ? this.cPrimary : this.cPrimaryFg)
          .backgroundColor(this.connected ? this.cSurfaceAlt : this.cPrimary)
          .border(this.connected ? { width: 1, color: this.cBorder } : { width: 0, color: this.cBorder })
          .borderRadius(14)
          .enabled(!this.connecting)
          .onClick(() => {
            if (this.connected) this.disconnect();
            else this.prepareConnect();
          });
      }
      .padding({ left: 12, right: 12, bottom: 12 });

      if (this.connected) {
        Row() {
          Text(this.s($r('app.string.viewer_connected_size'), this.fbW, this.fbH))
            .fontSize(12)
            .fontColor(this.cTextSecondary)
            .layoutWeight(1);
          Button(this.devToolsEnabled ? $r('app.string.viewer_devtools_on') : $r('app.string.viewer_devtools_off'))
            .fontSize(12)
            .height(28)
            .fontColor(this.cPrimary)
            .backgroundColor(this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(12)
            .onClick(() => this.setDevToolsEnabled(!this.devToolsEnabled));
        }.padding({ left: 12, right: 12, bottom: 8 });

        if (this.devToolsEnabled) {
          Row() {
            Button(this.debugEnabled ? $r('app.string.viewer_debug_on') : $r('app.string.viewer_debug_off'))
              .fontSize(12)
              .height(28)
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => {
                this.debugEnabled = !this.debugEnabled;
                this.vncClient.setDebugOptions(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
                if (!this.debugEnabled) {
                  this.debugInfoText = '';
                  this.debugLogText = '';
                  this.firstPixel = '';
                }
              });
            Button(this.s($r('app.string.devtools_pixel_format'), this.debugPmFormat === 0 ? 'RGBA' : 'ARGB'))
              .fontSize(12)
              .height(28)
              .margin({ left: 6 })
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => {
                this.debugPmFormat = (this.debugPmFormat + 1) % 2;
                this.vncClient.setDebugOptions(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
                this.pm = undefined;
                void this.ensurePixelMap();
              });
            Button(this.s($r('app.string.devtools_byte_order'), this.debugByteOrder))
              .fontSize(12)
              .height(28)
              .margin({ left: 6 })
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => {
                this.debugByteOrder = (this.debugByteOrder + 1) % 4;
                this.vncClient.setDebugOptions(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
                this.pm = undefined;
                void this.ensurePixelMap();
              });
          }.padding({ left: 12, right: 12, bottom: 8 });

          Row() {
            Button($r('app.string.viewer_refresh_frame'))
              .fontSize(12)
              .height(28)
              .layoutWeight(1)
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => this.vncClient.refresh());
            Button($r('app.string.viewer_save_frame'))
              .fontSize(12)
              .height(28)
              .layoutWeight(1)
              .margin({ left: 8 })
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => { void this.saveImage(); });
          }.padding({ left: 12, right: 12, bottom: 8 });
        }
      }

      if (this.connected && this.debugEnabled && (this.debugInfoText || this.debugLogText || this.firstPixel)) {
        Column() {
          if (this.firstPixel) {
            Text(this.firstPixel)
              .fontSize(14)
              .lineHeight(18)
              .fontColor(this.cError)
              .fontWeight(FontWeight.Bold)
              .fontFamily('monospace');
          }
          if (this.debugInfoText) {
            Text(this.debugInfoText)
              .fontSize(13)
              .lineHeight(18)
              .fontColor(this.cTextPrimary)
              .fontFamily('monospace')
              .maxLines(4)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
          if (this.debugLogText) {
            Text(this.debugLogText)
              .fontSize(12)
              .lineHeight(16)
              .fontColor(this.cTextMuted)
              .fontFamily('monospace')
              .maxLines(8)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
        }
        .padding(10)
        .margin({ left: 12, right: 12, bottom: 12 })
        .backgroundColor(this.cSurfaceAlt)
        .border({ width: 1, color: this.cBorder })
        .borderRadius(8);
      }
    }
    .backgroundColor(this.cSurface)
    .margin({ left: 0, right: 0, top: 0, bottom: 0 });
  }

  @Builder
  private buildEditOverlay(): void {
    if (this.editOpen) {
      Stack() {
        Column() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(12,20,22,0.55)')
        .onClick(() => this.closeEditDialog());

        Column() {
          Row() {
            Text(this.editId ? this.s($r('app.string.conn_edit_connection')) : this.s($r('app.string.conn_new_connection')))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1);
            Button($r('app.string.action_close'))
              .height(28)
              .fontSize(12)
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => this.closeEditDialog());
          }
          .padding({ left: 14, right: 14, top: 14, bottom: 10 });

          Column() {
            Text($r('app.string.conn_name_optional'))
              .fontSize(12)
              .fontColor(this.cTextSecondary)
              .width('100%')
              .padding({ bottom: 4 });
            TextInput({ text: this.editName, placeholder: $r('app.string.conn_name_placeholder') })
              .onChange((v: string) => this.editName = v)
              .padding({ bottom: 10 });

            Text($r('app.string.conn_address_label'))
              .fontSize(12)
              .fontColor(this.cTextSecondary)
              .width('100%')
              .padding({ bottom: 4 });
            TextInput({ text: this.editAddress, placeholder: $r('app.string.conn_address_placeholder') })
              .onChange((v: string) => this.editAddress = v)
              .padding({ bottom: 10 });

            Text($r('app.string.conn_user_optional'))
              .fontSize(12)
              .fontColor(this.cTextSecondary)
              .width('100%')
              .padding({ bottom: 4 });
            TextInput({ text: this.editUser, placeholder: $r('app.string.conn_user_placeholder') })
              .onChange((v: string) => this.editUser = v)
              .padding({ bottom: 10 });

            Text($r('app.string.conn_password_optional'))
              .fontSize(12)
              .fontColor(this.cTextSecondary)
              .width('100%')
              .padding({ bottom: 4 });
            TextInput({ text: this.editPassword, placeholder: $r('app.string.password_optional_short') })
              .type(InputType.Password)
              .onChange((v: string) => this.editPassword = v)
              .padding({ bottom: 8 });
            Row() {
              Text($r('app.string.conn_remember_password'))
                .fontSize(12)
                .fontColor(this.cTextSecondary)
                .layoutWeight(1);
              this.buildBrandSwitch(this.editStorePassword, true, (next: boolean) => this.editStorePassword = next);
            }
            .padding({ bottom: 8 });
            Column() {
              Text($r('app.string.conn_touch_scroll_step'))
                .fontSize(12)
                .fontColor(this.cTextSecondary)
                .width('100%')
                .padding({ bottom: 6 });
              Row() {
                Button($r('app.string.button_auto'))
                  .height(28)
                  .fontSize(12)
                  .fontColor(this.editTouchScrollStep <= 0 ? this.cPrimaryFg : this.cPrimary)
                  .backgroundColor(this.editTouchScrollStep <= 0 ? this.cPrimary : this.cSurfaceAlt)
                  .border({ width: 1, color: this.cBorder })
                  .borderRadius(12)
                  .onClick(() => this.updateEditTouchScrollStep(0));
                Button($r('app.string.tool_scroll_slow'))
                  .height(28)
                  .fontSize(12)
                  .margin({ left: 6 })
                  .fontColor(this.editTouchScrollStep === 18 ? this.cPrimaryFg : this.cPrimary)
                  .backgroundColor(this.editTouchScrollStep === 18 ? this.cPrimary : this.cSurfaceAlt)
                  .border({ width: 1, color: this.cBorder })
                  .borderRadius(12)
                  .onClick(() => this.updateEditTouchScrollStep(18));
                Button($r('app.string.tool_scroll_medium'))
                  .height(28)
                  .fontSize(12)
                  .margin({ left: 6 })
                  .fontColor(this.editTouchScrollStep === 12 ? this.cPrimaryFg : this.cPrimary)
                  .backgroundColor(this.editTouchScrollStep === 12 ? this.cPrimary : this.cSurfaceAlt)
                  .border({ width: 1, color: this.cBorder })
                  .borderRadius(12)
                  .onClick(() => this.updateEditTouchScrollStep(12));
                Button($r('app.string.tool_scroll_fast'))
                  .height(28)
                  .fontSize(12)
                  .margin({ left: 6 })
                  .fontColor(this.editTouchScrollStep === 8 ? this.cPrimaryFg : this.cPrimary)
                  .backgroundColor(this.editTouchScrollStep === 8 ? this.cPrimary : this.cSurfaceAlt)
                  .border({ width: 1, color: this.cBorder })
                  .borderRadius(12)
                  .onClick(() => this.updateEditTouchScrollStep(8));
              }
              .width('100%');
              Text(this.editTouchScrollStep <= 0
                ? this.s($r('app.string.conn_touch_scroll_auto_current'))
                : this.s($r('app.string.conn_touch_scroll_value_current'), this.editTouchScrollStep))
                .fontSize(11)
                .fontColor(this.cTextTertiary)
                .width('100%')
                .padding({ top: 6 });
            }
          }
          .padding({ left: 14, right: 14, bottom: 14 });

          Row() {
            Button($r('app.string.action_cancel'))
              .layoutWeight(1)
              .height(36)
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(14)
              .onClick(() => this.closeEditDialog());
            Button($r('app.string.action_save'))
              .layoutWeight(1)
              .height(36)
              .margin({ left: 10 })
              .fontColor(this.cPrimaryFg)
              .backgroundColor(this.cPrimary)
              .borderRadius(14)
              .onClick(() => { void this.saveEditDialog(); });
          }
          .padding({ left: 14, right: 14, bottom: 14 });
        }
        .width(420)
        .backgroundColor(this.cSurfaceAlt)
        .border({ width: 1, color: this.cBorder })
        .borderRadius(12)
        .shadow({ radius: 16, color: 'rgba(12,20,22,0.16)', offsetX: 0, offsetY: 4 });
      }
      .alignContent(Alignment.Center)
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  private buildViewer(): void {
    Stack() {
      if (this.pm) {
        if (this.viewportMode === 'tile' && this.monitors.length > 1) {
          this.buildTiledMonitorView()
        } else {
          this.buildSingleMonitorView()
          this.buildSingleMonitorOcclusion()
        }
      } else {
        Column() {
          Text(this.connecting ? this.s($r('app.string.conn_connecting')) : (this.lastError ? this.lastError : (this.connected ? this.s($r('app.string.viewer_waiting_first_frame_state')) : this.s($r('app.string.conn_disconnected_state')))))
            .fontSize(14)
            .fontColor(this.lastError ? this.cError : this.cOnInk);
        }
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height('100%');
      }
      if (this.shouldShowMonitorLayoutOverlay()) {
        ForEach(this.getDisplayPreviewMonitorRects(), (m: VncRect, index: number) => {
          Stack() {
            Text(this.s($r('app.string.viewer_screen_label'), index + 1))
              .fontSize(11)
              .fontColor('#ffffff')
              .padding({ left: 6, right: 6, top: 3, bottom: 3 })
              .backgroundColor(this.manualDragMonitorIndex === index
                ? 'rgba(239,68,68,0.92)'
                : index === this.currentMonitorIndex
                  ? 'rgba(20,184,166,0.92)'
                  : 'rgba(245,158,11,0.92)')
              .borderRadius(10)
              .position({ x: 8, y: 8 })
          }
          .width(this.getViewerOverlayMonitorRect(m).w)
          .height(this.getViewerOverlayMonitorRect(m).h)
          .position({
            x: this.getViewerOverlayMonitorRect(m).x,
            y: this.getViewerOverlayMonitorRect(m).y
          })
          .border({
            width: this.manualDragMonitorIndex === index ? 3 : 2,
            color: this.manualDragMonitorIndex === index
              ? '#ef4444'
              : index === this.currentMonitorIndex
                ? '#14b8a6'
                : '#f59e0b'
          })
          .borderRadius(12)

          if (this.manualDragMonitorIndex === index) {
            Stack() {
              Text('✥')
                .fontSize(24)
                .fontColor('#ffffff')
            }
            .width(48)
            .height(48)
            .backgroundColor('rgba(16,185,129,0.9)')
            .borderRadius(24)
            .shadow({ radius: 8, color: 'rgba(0,0,0,0.5)', offsetX: 0, offsetY: 2 })
            .position({
              x: this.getViewerOverlayMonitorRect(m).x + this.getViewerOverlayMonitorRect(m).w / 2 - 24,
              y: this.getViewerOverlayMonitorRect(m).y + this.getViewerOverlayMonitorRect(m).h / 2 - 24
            })
          }
        }, (m: VncRect, index: number) => `${index}:${m.x},${m.y},${m.w},${m.h}:overlay`);
      }
      Column() {
      }
        .id(this.inputLayerKey)
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.001)')
        .focusable(true)
        .focusOnTouch(true)
        .defaultFocus(true)
        .onAppear(() => {
          if (!this.connected) return;
          this.requestInputFocus();
        })
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.viewerW = (newValue.width as number) ?? 1;
          this.viewerH = (newValue.height as number) ?? 1;
          this.ensureFsBtnPosition();
          this.clampZoomOffset();
          this.scheduleAdaptiveDesktopResize(this.adaptiveResizeSettleMs);
        })
        .onTouch((ev: TouchEvent) => {
          const t = ev?.touches?.[0] ?? ev?.changedTouches?.[0];
          const type = ev?.type;
          const localX = t?.x ?? 0;
          const localY = t?.y ?? 0;
          this.lastX = localX;
          this.lastY = localY;

          if (!this.connected) return;
          if (this.manualDragMonitorIndex >= 0 && this.manualMonitorRects.length > 0) {
            if (this.handleViewerManualMonitorTouch(localX, localY, type)) {
              this.requestInputFocus();
              return;
            }
            return;
          }
          if (this.shouldInterceptCanvasTouch(ev)) return;
          if (this.chromeVisible && this.shouldAutoHideChrome()) {
            this.scheduleChromeAutoHide();
          }
          const withinContent = this.isLocalWithinContent(localX, localY);
          if (!withinContent && !this.edgeClampEnabled) {
            if (this.touchDragging && this.lastPointerSentX >= 0 && this.lastPointerSentY >= 0) {
              this.safeSendPointer(this.lastPointerSentX, this.lastPointerSentY, 0, true);
              this.requestTick();
            }
            this.touchDragging = false;
            this.touchMoved = false;
            this.touchStartedOutside = false;
            this.endTouchScroll();
            return;
          }
          if (type === TouchType.Down) this.requestInputFocus();
          if (this.handleInspectTouch(ev)) return;

          const center = this.getTouchCenter(ev);
          if (center) {
            if (!this.touchScrollActive || type === TouchType.Down) {
              this.beginTouchScroll(center.x, center.y);
            }
            if (type === TouchType.Move) {
              const dy = center.y - this.touchScrollLastY;
              this.emitTouchScroll(center.x, center.y, dy);
              this.touchScrollLastX = center.x;
              this.touchScrollLastY = center.y;
            }
            return;
          }

          if (this.touchScrollActive) {
            if (type === TouchType.Move || type === TouchType.Up || type === TouchType.Cancel) {
              this.endTouchScroll();
            }
            if (type !== TouchType.Down) return;
          }

          const p = this.mapToRemotePoint(localX, localY);
          if (this.debugEnabled) {
            console.info(`onTouch type=${type} local=${t?.x ?? 0},${t?.y ?? 0} remote=${p.x},${p.y}`);
          }
          const now = Date.now();
          if (type === TouchType.Down) {
            this.touchStartX = localX;
            this.touchStartY = localY;
            this.touchStartTs = now;
            this.touchMoved = false;
            this.touchDragging = false;
            this.touchStartedOutside = !withinContent;
            this.beginInteraction();
            this.safeSendPointer(p.x, p.y, 0);
            return;
          }

          if (type === TouchType.Move) {
            if (this.touchStartedOutside) {
              this.safeSendPointer(p.x, p.y, 0);
              return;
            }
            const dx = Math.abs(localX - this.touchStartX);
            const dy = Math.abs(localY - this.touchStartY);
            if (dx + dy >= 6) this.touchMoved = true;
            if (this.touchMoved && !this.touchDragging) {
              this.touchDragging = true;
              const startP = this.mapToRemotePoint(this.touchStartX, this.touchStartY);
              this.safeSendPointer(startP.x, startP.y, 1);
            }
            this.safeSendPointer(p.x, p.y, this.touchDragging ? 1 : 0);
            return;
          }

          if (type === TouchType.Up) {
            const dt = now - this.touchStartTs;
            if (this.touchStartedOutside) {
              this.safeSendPointer(p.x, p.y, 0);
            } else if (this.touchDragging) {
              this.touchDragging = false;
              this.safeSendPointer(p.x, p.y, 0);
              this.requestTick();
            } else if (!this.touchMoved && dt <= 350) {
              this.safeSendPointer(p.x, p.y, 1);
              this.safeSendPointer(p.x, p.y, 0);
              this.requestTick();
            } else if (!this.touchMoved && dt > 500) {
              this.safeSendPointer(p.x, p.y, 4);
              this.safeSendPointer(p.x, p.y, 0);
              this.requestTick();
            } else {
              this.safeSendPointer(p.x, p.y, 0);
            }
            this.touchDragging = false;
            this.touchStartedOutside = false;
            this.endInteraction();
            return;
          }

          if (type === TouchType.Cancel) {
            this.touchDragging = false;
            this.touchStartedOutside = false;
            this.endTouchScroll();
            this.safeSendPointer(p.x, p.y, 0);
            this.requestTick();
            this.endInteraction();
          }
        })
        .onMouse((ev: MouseEvent) => {
          if (!this.connected) return;
          const localX = ev?.x ?? this.lastX;
          const localY = ev?.y ?? this.lastY;
          this.lastX = localX;
          this.lastY = localY;

          const action = ev?.action;
          const button = ev?.button;
          this.handleMouseChromeBehavior();

          const left = 1;
          const middle = 2;
          const right = 4;
          let bit = 0;
          if (button === MouseButton.Left) bit = left;
          else if (button === MouseButton.Middle) bit = middle;
          else if (button === MouseButton.Right) bit = right;

          if (!this.isLocalWithinContent(localX, localY) && !this.edgeClampEnabled) {
            if (this.lastMask !== 0 && this.lastPointerSentX >= 0 && this.lastPointerSentY >= 0) {
              this.lastMask = 0;
              this.safeSendPointer(this.lastPointerSentX, this.lastPointerSentY, 0, true);
              this.requestTick();
            }
            return;
          }

          const mouseOutside = this.edgeClampEnabled && !this.isLocalWithinContent(localX, localY);

          if (!mouseOutside) {
            if (action === MouseAction.Press) {
              this.lastMask |= bit;
              this.beginInteraction();
            }
            if (action === MouseAction.Release) {
              this.lastMask &= ~bit;
              if (this.lastMask === 0) this.endInteraction();
            }
          }
          if (action === MouseAction.Press) this.requestInputFocus();

          const p = this.mapToRemotePoint(localX, localY);

          if (this.debugEnabled) {
            console.info(`onMouse action=${action} btn=${button} local=${ev?.x ?? 0},${ev?.y ?? 0} remote=${p.x},${p.y} mask=${mouseOutside ? 0 : this.lastMask}`);
          }
          this.safeSendPointer(p.x, p.y, mouseOutside ? 0 : this.lastMask);
          if (action === MouseAction.Release) {
            this.requestTick();
          }
        })
        .onHover((isHover: boolean) => {
          if (!this.connected) return;
          if (!isHover) {
            this.lastMask = 0;
            this.endInteraction();
          }
          if (!isHover) this.scheduleChromeAutoHide();
        })
        .onAxisEvent((ev: AxisEvent) => {
          if (!this.connected) return;
          this.handleMouseChromeBehavior();
          const axisX = ev?.x ?? this.lastX;
          const axisY = ev?.y ?? this.lastY;
          if (!this.isLocalWithinContent(axisX, axisY) && !this.edgeClampEnabled) {
            return;
          }
          const p = this.mapToRemotePoint(axisX, axisY);

          let dy = 0;
          if (typeof ev?.getVerticalAxisValue === 'function') {
            dy = ev.getVerticalAxisValue();
          } else if (ev?.scrollStep !== undefined) {
            dy = ev.scrollStep;
          }

          if (dy === 0) return;

          let clicks = 1;
          if (this.runtimeMacMode) {
            clicks = 10;
          }

          const up = 8;
          const down = 16;
          const mask = dy < 0 ? up : down;
          if (this.debugEnabled) {
            console.info(`onAxis dy=${dy} remote=${p.x},${p.y} mask=${mask} clicks=${clicks} server=${this.serverName}`);
          }

          for (let i = 0; i < clicks; i++) {
            this.safeSendPointer(p.x, p.y, this.lastMask | mask, true);
            this.safeSendPointer(p.x, p.y, this.lastMask, true);
          }
          this.requestTick();
        });

      if (this.connected) {
        TextInput({ text: this.softInputDraft, placeholder: '' })
          .id(this.softInputKey)
          .width(1)
          .height(1)
          .opacity(0.01)
          .caretColor(Color.Transparent)
          .fontSize(1)
          .fontColor(Color.Transparent)
          .backgroundColor(Color.Transparent)
          .position({ x: -100, y: -100 })
          .onChange((value: string) => this.handleSoftInputChange(value));
      }

      if (this.manualDragMonitorIndex >= 0 && this.manualMonitorRects.length > 0) {
        Row({ space: 8 }) {
          Text($r('app.string.viewer_fullscreen_frame_select'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#ffffff');

          ForEach(this.manualMonitorRects, (m: VncRect, index: number) => {
            Button(`${index + 1}`)
              .fontSize(12)
              .height(28)
              .fontColor(this.manualDragMonitorIndex === index ? this.cPrimaryFg : this.cTextPrimary)
              .backgroundColor(this.manualDragMonitorIndex === index ? this.cPrimary : this.cSurfaceAlt)
              .border({ width: 1, color: this.manualDragMonitorIndex === index ? this.cPrimary : this.cBorder })
              .borderRadius(14)
              .onClick(() => {
                this.manualDragMonitorIndex = index;
                this.showStatusBanner(this.s($r('app.string.monitor_drag_select_screen'), index + 1));
              });
          }, (m: VncRect, index: number) => `drag-btn-${index}`);

          Blank().layoutWeight(1);

          Button($r('app.string.action_cancel'))
            .fontSize(12)
            .height(28)
            .fontColor('#ef4444')
            .backgroundColor(this.cSurfaceAlt)
            .border({ width: 1, color: 'rgba(239,68,68,0.55)' })
            .borderRadius(14)
            .onClick(() => {
              // 放弃本次手动布局修改：清除手动矩形并退出定义模式，回到面板主视图查看还原后的布局
              this.clearManualMonitorLayout();
              if (this.panelMode !== 'display') {
                this.togglePanel('display');
              }
              this.displayEditingScreens = false;
              this.showStatusBanner(this.s($r('app.string.monitor_exit_manual')));
            });

          Button($r('app.string.button_done'))
            .fontSize(12)
            .height(28)
            .fontColor(this.cTextPrimary)
            .backgroundColor(this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(14)
            .onClick(() => {
              // 退出定义模式并回到编辑屏幕视图；布局保存统一由面板主视图"记住布局"完成
              this.manualDragMonitorIndex = -1;
              this.resetManualDragStrokeState();
              if (this.panelMode !== 'display') {
                this.togglePanel('display');
              }
              this.displayEditingScreens = true;
            });
        }
        .width('92%')
        .padding(10)
        .backgroundColor('rgba(24,24,27,0.85)')
        .borderRadius(16)
        .position({ x: '4%', y: this.viewerH > 60 ? this.viewerH - 60 : '85%' })
        .onTouch((ev: TouchEvent) => {
          if (ev && typeof ev.stopPropagation === 'function') {
            ev.stopPropagation();
          }
        });
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.cInk)
    .margin(this.isFullscreen ? { left: 0, right: 0, bottom: 0 } : { left: 12, right: 12, bottom: 12 })
    .borderRadius(this.isFullscreen ? 0 : 8)
    .clip(true);
  }

  @Builder
  private buildSingleMonitorView(): void {
    if (this.pm && (this.viewportMode !== 'single' || this.hasCurrentMonitor())) {
      Image(this.pm)
        .width(this.getTransformedRect(this.getPrimaryImageMetrics().frame).w)
        .height(this.getTransformedRect(this.getPrimaryImageMetrics().frame).h)
        .position({
          x: this.getTransformedRect(this.getPrimaryImageMetrics().frame).x,
          y: this.getTransformedRect(this.getPrimaryImageMetrics().frame).y
        })
        .interpolation(ImageInterpolation.High)
        .opacity(this.pmVersion % 2 === 0 ? 1 : 0.999)
    }
  }

  @Builder
  private buildSingleMonitorOcclusion(): void {
    if (this.shouldShowSingleMonitorOcclusion()) {
      ForEach(this.getSingleMonitorMaskRects(), (mask: VncRect, index: number) => {
        Blank()
          .width(mask.w)
          .height(mask.h)
          .backgroundColor('#000000')
          .position({ x: mask.x, y: mask.y });
      }, (mask: VncRect, index: number) => `${index}:${mask.x},${mask.y},${mask.w},${mask.h}:single-mask`);
      if (this.getSingleMonitorOverlayRect() !== null) {
        Blank()
          .width(this.getSingleMonitorOverlayRect()!.w)
          .height(this.getSingleMonitorOverlayRect()!.h)
          .backgroundColor('#00000000')
          .border({ width: 1, color: 'rgba(255,255,255,0.18)' })
          .shadow({ radius: 8, color: 'rgba(0,0,0,0.28)', offsetX: 0, offsetY: 0 })
          .position({
            x: this.getSingleMonitorOverlayRect()!.x,
            y: this.getSingleMonitorOverlayRect()!.y
          });
      }
    }
  }

  @Builder
  private buildTiledMonitorView(): void {
    if (this.pm) {
      ForEach(this.monitors, (m: VncRect, index: number) => {
        Stack() {
          this.buildMonitorTileImage(index)
          Text(`${index + 1}`)
            .fontSize(11)
            .fontColor('#ffffff')
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            .backgroundColor('rgba(0,0,0,0.44)')
            .borderRadius(10)
            .position({ x: 8, y: 8 })
        }
        .width(this.getTileFrame(index).w)
        .height(this.getTileFrame(index).h)
        .clip(true)
        .backgroundColor('#000000')
        .borderRadius(12)
        .position({ x: this.getTileFrame(index).x, y: this.getTileFrame(index).y })
      }, (m: VncRect, index: number) => `${index}:${m.x},${m.y},${m.w},${m.h}`)
    }
  }

  @Builder
  private buildMonitorTileImage(index: number): void {
    if (this.pm && index >= 0 && index < this.monitors.length) {
      Image(this.pm)
        .width(this.getTileMonitorMetrics(index).frame.w)
        .height(this.getTileMonitorMetrics(index).frame.h)
        .position({ x: this.getTileMonitorMetrics(index).frame.x, y: this.getTileMonitorMetrics(index).frame.y })
        .interpolation(ImageInterpolation.High)
        .opacity(this.pmVersion % 2 === 0 ? 1 : 0.999)
    }
  }

  @Builder
  private buildTopActionButton($$: TopActionButtonParams): void {
    Button($$.label)
      .height(32)
      .fontSize(12)
      .fontColor($$.active ? this.cPrimaryFg : this.cOnInk)
      .backgroundColor($$.active ? this.cPrimary : 'rgba(255,255,255,0.08)')
      .border($$.active ? { width: 0, color: this.cPrimary } : { width: 1, color: 'rgba(255,255,255,0.12)' })
      .borderRadius(16)
      .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
      .onClick(() => {
        this.pulseChromeInteraction();
        $$.onClick();
      });
  }

  @Builder
  private buildDockButton($$: DockButtonParams): void {
    Button($$.label)
      .constraintSize({ minWidth: 68 })
      .flexShrink(1)
      .height(40)
      .fontSize(12)
      .fontColor($$.active ? this.cPrimaryFg : '#f5f5f4')
      .backgroundColor($$.active ? this.cPrimary : 'rgba(255,255,255,0.08)')
      .border($$.active ? { width: 0, color: this.cPrimary } : { width: 1, color: 'rgba(255,255,255,0.12)' })
      .borderRadius(16)
      .enabled($$.enabled)
      .opacity($$.enabled ? 1 : 0.5)
      .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
      .onClick(() => {
        this.pulseChromeInteraction();
        $$.onClick();
      });
  }

  @Builder
  private buildPanelAction($$: PanelActionParams): void {
    Button($$.label)
      .width('100%')
      .height(36)
      .fontSize(12)
      .fontColor($$.primary ? this.cPrimaryFg : this.cPrimary)
      .backgroundColor($$.primary ? this.cPrimary : this.cSurfaceAlt)
      .border($$.primary ? { width: 0, color: this.cPrimary } : { width: 1, color: this.cBorder })
      .borderRadius(14)
      .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
      .onClick(() => {
        this.pulseChromeInteraction();
        $$.onClick();
      });
  }

  // Reads this.adaptiveResolutionEnabled directly instead of taking it as a
  // parameter: @Builder parameters are passed by value, so a state variable
  // handed in that way never re-renders the toggle when it changes, which made
  // the switch look dead after a tap.
  @Builder
  private buildAdaptiveResolutionToggle(): void {
    Row() {
      Column() {
        Text($r('app.string.more_adaptive_resolution'))
          .fontSize(13)
          .fontColor(this.cTextPrimary)
          .maxLines(1);
        Text($r('app.string.more_adaptive_resolution_desc'))
          .fontSize(11)
          .fontColor(this.cTextSecondary)
          .maxLines(2);
      }
      .layoutWeight(1);
      Row() {
        Blank()
          .width(18)
          .height(18)
          .backgroundColor(this.cSurfaceAlt)
          .borderRadius(9)
          .margin({ left: this.adaptiveResolutionEnabled ? 18 : 0 });
      }
      .width(42)
      .height(24)
      .padding(3)
      .backgroundColor(this.adaptiveResolutionEnabled ? this.cPrimary : this.cBorder)
      .borderRadius(12);
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 8, bottom: 8 })
    .backgroundColor(this.cSurfaceAlt)
    .borderRadius(14)
    .border({ width: 1, color: this.cBorder })
    .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
    // The whole row is the hit area, not just the 42x24 switch.
    .onClick(() => {
      this.pulseChromeInteraction();
      this.setAdaptiveResolutionEnabled(!this.adaptiveResolutionEnabled);
    });
  }

  @Builder
  private buildTopBar(): void {
    Row() {
      Column() {
        Text(this.getSessionTitle())
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#ffffff')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(this.getSessionSubtitle())
          .fontSize(12)
          .fontColor('rgba(231,229,228,0.82)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 });
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start);

      Row() {
        Text(this.getConnectionStateText())
          .fontSize(11)
          .fontColor('#ffffff')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(this.getConnectionStateColor())
          .borderRadius(14);
        if (this.connected) {
          this.buildTopActionButton({ label: this.getSecurityLabel(), active: this.panelMode === 'security', onClick: () => {
            this.togglePanel('security');
          }});
          this.buildTopActionButton({ label: this.isFullscreen ? $r('app.string.viewer_exit_fullscreen') : $r('app.string.viewer_enter_fullscreen'), active: false, onClick: () => {
            this.toggleFullscreen();
          }});
        }
      }
      .margin({ left: 12 })
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Center);
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: this.isFullscreen ? 12 : 14, bottom: 12 })
    .backgroundColor('rgba(12,20,22,0.76)')
    .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
    .borderRadius(this.isFullscreen ? 20 : 18)
    .margin(this.isFullscreen ? { left: 12, right: 12, top: 12 } : { left: 12, right: 12, top: 12 })
    .onHover((isHover: boolean) => this.setChromeHovering(isHover))
    .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
    .shadow({ radius: 18, color: 'rgba(0,0,0,0.16)', offsetX: 0, offsetY: 6 });
  }

  @Builder
  private buildBottomDock(): void {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        this.buildDockButton({ label: this.s($r('app.string.dock_control_mode')), active: this.interactionMode === 'control', enabled: true, onClick: () => this.setInteractionMode('control') });
        this.buildDockButton({ label: this.s($r('app.string.dock_inspect_mode')), active: this.interactionMode === 'inspect', enabled: this.viewportMode !== 'tile', onClick: () => this.setInteractionMode('inspect') });
        this.buildDockButton({ label: this.s($r('app.string.dock_keyboard')), active: false, enabled: true, onClick: () => this.showSoftKeyboard() });
        this.buildDockButton({ label: this.s($r('app.string.dock_nav')), active: this.showNavigationPad, enabled: true, onClick: () => {
          this.showNavigationPad = !this.showNavigationPad;
          this.pulseChromeInteraction();
        }});
        this.buildDockButton({ label: this.s($r('app.string.dock_more')), active: this.panelMode === 'more' || this.panelMode === 'connection' || this.panelMode === 'developer' || this.panelMode === 'clipboard', enabled: true, onClick: () => this.togglePanel('more') });
      }
      .padding({ left: 10, right: 10, top: 10, bottom: 10 })
      .backgroundColor('rgba(12,20,22,0.82)')
      .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
      .borderRadius(22)
      .shadow({ radius: 20, color: 'rgba(0,0,0,0.18)', offsetX: 0, offsetY: 6 })
      .constraintSize({ maxWidth: '100%' })

      if (this.canUseZoomViewer() || this.canOpenDisplayPanel()) {
        Row({ space: 8 }) {
          // tile（分屏概览）模式下缩放无意义，仅保留 Display 按钮用于切换/退出多屏模式
          if (this.canUseZoomViewer()) {
            this.buildDockButton({ label: this.s($r('app.string.dock_zoom_out')), active: false, enabled: this.viewportMode !== 'tile', onClick: () => this.stepViewerZoom(-this.zoomStepScale) });
            this.buildDockButton({ label: this.s($r('app.string.dock_magnification')) + ' ' + this.getZoomButtonLabel(), active: this.zoomScale > 1.05, enabled: this.viewportMode !== 'tile', onClick: () => this.quickToggleViewerZoom() });
            this.buildDockButton({ label: this.s($r('app.string.dock_zoom_in')), active: false, enabled: this.viewportMode !== 'tile', onClick: () => this.stepViewerZoom(this.zoomStepScale) });
          }
          if (this.canOpenDisplayPanel()) {
            this.buildDockButton({ label: this.s($r('app.string.dock_screen')), active: this.panelMode === 'display', enabled: true, onClick: () => this.togglePanel('display') });
          }
        }
        .padding({ left: 10, right: 10, top: 10, bottom: 10 })
        .backgroundColor('rgba(12,20,22,0.82)')
        .border({ width: 1, color: 'rgba(255,255,255,0.08)' })
        .borderRadius(22)
        .shadow({ radius: 20, color: 'rgba(0,0,0,0.18)', offsetX: 0, offsetY: 6 })
        .constraintSize({ maxWidth: '100%' })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 12, right: 12 })
    .margin({ bottom: this.isFullscreen ? 12 : 24 })
    .onHover((isHover: boolean) => this.setChromeHovering(isHover))
    .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
  }

  @Builder
  private buildConnectionPrepLayer(): void {
    if (!this.connected) {
      Column() {
        Blank().layoutWeight(1);
        Column() {
          Text($r('app.string.panel_session_setup'))
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.cTextPrimary)
            .width('100%')
            .padding({ left: 12, right: 12, top: 12 });
          Text($r('app.string.panel_session_setup_desc'))
            .fontSize(12)
            .fontColor(this.cTextSecondary)
            .width('100%')
            .padding({ left: 12, right: 12, top: 4, bottom: 8 });
          this.buildControls();
        }
        .width(Math.max(320, Math.min(560, this.windowW > 0 ? this.windowW - 24 : 560)))
        .backgroundColor(this.cSurfaceAlt)
        .border({ width: 1, color: this.cBorder })
        .borderRadius(20)
        .shadow({ radius: 24, color: 'rgba(12,20,22,0.14)', offsetX: 0, offsetY: 10 });
        Blank().height(24);
      }
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  private buildClipboardPanelBody(): void {
    Column({ space: 10 }) {
      Text($r('app.string.clipboard_panel_action_desc'))
        .fontSize(12)
        .fontColor(this.cTextSecondary)
        .width('100%');
      Text(this.s(
        $r('app.string.clipboard_local_cache_label'),
        this.lastLocalClipboardText
          ? this.s($r('app.string.clipboard_chars_count'), this.lastLocalClipboardText.length)
          : this.s($r('app.string.clipboard_none'))
      ))
        .fontSize(12)
        .fontColor(this.cTextPrimary)
        .width('100%');
      Text(this.s(
        $r('app.string.clipboard_remote_cache_label'),
        this.lastRemoteClipboardText
          ? this.s($r('app.string.clipboard_chars_count'), this.lastRemoteClipboardText.length)
          : this.s($r('app.string.clipboard_none'))
      ))
        .fontSize(12)
        .fontColor(this.cTextPrimary)
        .width('100%');
      PasteButton()
        .width('100%')
        .height(40)
        .borderRadius(14)
        .padding({ left: 10, right: 10, top: 10, bottom: 10 })
        .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
          if (result === PasteButtonOnClickResult.SUCCESS) {
            void this.onPasteButtonClickedAsync();
            this.showStatusBanner(this.s($r('app.string.clipboard_send_attempted')));
            this.closePanel();
          } else {
            this.toast(this.s($r('app.string.clipboard_auth_failed')));
          }
        });
      this.buildPanelAction({ label: this.s($r('app.string.clipboard_fetch_label')), primary: false, onClick: () => {
        this.requestRemoteClipboard();
        this.showStatusBanner(this.s($r('app.string.clipboard_fetch_attempted')));
        this.closePanel();
      }});
    }
    .width('100%');
  }

  @Builder
  private buildDisplayPanelBody(): void {
    Column({ space: 10 }) {
      if (this.displayEditingScreens) {
        this.buildDisplayScreenEditor();
      } else {
        this.buildDisplayPanelMainBody();
      }
    }
    .width('100%');
  }

  @Builder
  private buildDisplayPreviewImage(): void {
    if (this.pm && this.getDisplayPreviewMonitorRects().length > 0 && this.fbW > 0 && this.fbH > 0) {
      Stack() {
        Image(this.pm)
          .width(this.getDisplayPreviewImageMetrics().frame.w)
          .height(this.getDisplayPreviewImageMetrics().frame.h)
          .position({
            x: this.getDisplayPreviewImageMetrics().frame.x,
            y: this.getDisplayPreviewImageMetrics().frame.y
          })
          .interpolation(ImageInterpolation.High)
        ForEach(this.getDisplayPreviewMonitorRects(), (m: VncRect, index: number) => {
          Stack() {
            Text(this.s($r('app.string.viewer_screen_label'), index + 1))
              .fontSize(10)
              .fontColor('#ffffff')
              .padding({ left: 6, right: 6, top: 3, bottom: 3 })
              .backgroundColor(this.manualDragMonitorIndex === index
                ? 'rgba(239,68,68,0.92)'
                : index === this.currentMonitorIndex
                  ? 'rgba(20,184,166,0.92)'
                  : 'rgba(245,158,11,0.92)')
              .borderRadius(10)
              .position({ x: 8, y: 8 })
          }
          .width(this.getDisplayPreviewRect(m).w)
          .height(this.getDisplayPreviewRect(m).h)
          .position({ x: this.getDisplayPreviewRect(m).x, y: this.getDisplayPreviewRect(m).y })
          .border({
            width: this.manualDragMonitorIndex === index ? 3 : 2,
            color: this.manualDragMonitorIndex === index
              ? '#ef4444'
              : index === this.currentMonitorIndex
                ? '#14b8a6'
                : '#f59e0b'
          })
          .borderRadius(10)
        }, (m: VncRect, index: number) => `${index}:${m.x},${m.y},${m.w},${m.h}:preview`);
        if (this.manualDragMonitorIndex >= 0) {
          Text(this.s($r('app.string.display_dragging_screen_n'), this.manualDragMonitorIndex + 1))
            .fontSize(11)
            .fontColor('#ffffff')
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor('rgba(239,68,68,0.92)')
            .borderRadius(12)
            .position({ x: 10, y: 10 });
        }
      }
      .width(this.getDisplayPreviewContainer().w)
      .height(this.getDisplayPreviewContainer().h)
      .clip(true)
      .backgroundColor('#000000')
      .border({ width: 1, color: this.cBorder })
      .borderRadius(14)
      .onTouch((ev: TouchEvent) => this.handleDisplayPreviewTouch(ev))
      .alignSelf(ItemAlign.Center);
    }
  }

  @Builder
  private buildDisplayScreenEditor(): void {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text($r('app.string.monitor_edit_screens'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.cTextPrimary)
          .layoutWeight(1);
        Button($r('app.string.monitor_edit_done'))
          .height(32)
          .fontSize(12)
          .fontColor(this.cPrimary)
          .backgroundColor(this.cSurfaceAlt)
          .border({ width: 1, color: this.cBorder })
          .borderRadius(14)
          .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
          .onClick(() => {
            this.pulseChromeInteraction();
            this.displayEditingScreens = false;
          });
      }
      .width('100%');
      this.buildDisplayPreviewImage();
      Text(this.manualDragMonitorIndex >= 0
        ? this.s($r('app.string.monitor_drag_mode_on'))
        : this.s($r('app.string.monitor_manual_input_hint')))
        .fontSize(11)
        .lineHeight(16)
        .fontColor(this.cTextSecondary)
        .width('100%');
      ForEach(this.manualMonitorDrafts, (draft: string, index: number) => {
        Column({ space: 6 }) {
          Text($r('app.string.viewer_screen_label', index + 1))
            .fontSize(11)
            .fontColor(this.cTextSecondary)
            .width('100%');
          TextInput({ text: draft, placeholder: $r('app.string.monitor_coords_placeholder') })
            .onChange((value: string) => this.updateManualMonitorDraft(index, value))
            .width('100%');
          Text($r('app.string.monitor_current_rect', this.formatMonitorRectLabel(this.manualMonitorRects[index])))
            .fontSize(10)
            .fontColor(this.cTextMuted)
            .width('100%');
          Row({ space: 8 }) {
            Button(this.manualDragMonitorIndex === index ? this.s($r('app.string.monitor_end_drag')) : this.s($r('app.string.monitor_drag_define')))
              .layoutWeight(1)
              .height(32)
              .fontSize(11)
              .fontColor(this.manualDragMonitorIndex === index ? '#ffffff' : this.cPrimary)
              .backgroundColor(this.manualDragMonitorIndex === index ? '#ef4444' : this.cSurfaceAlt)
              .border({ width: this.manualDragMonitorIndex === index ? 0 : 1, color: this.cBorder })
              .borderRadius(10)
              .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
              .onClick(() => {
                this.pulseChromeInteraction();
                this.beginManualMonitorRectDrag(index);
              });
            Button($r('app.string.monitor_remove_screen'))
              .layoutWeight(1)
              .height(32)
              .fontSize(11)
              .fontColor('#ef4444')
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: 'rgba(239,68,68,0.55)' })
              .borderRadius(10)
              .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
              .onClick(() => {
                this.pulseChromeInteraction();
                this.removeManualMonitorRect(index);
              });
          }
          .width('100%');
        }
        .width('100%')
        .padding(10)
        .backgroundColor(this.cSurfaceAlt)
        .border({ width: 1, color: this.cBorder })
        .borderRadius(12);
      }, (draft: string, index: number) => `manual:${index}:${draft}`);
      Row({ space: 8 }) {
        Button($r('app.string.monitor_add_screen'))
          .layoutWeight(1)
          .height(34)
          .fontSize(12)
          .fontColor(this.cPrimary)
          .backgroundColor(this.cSurfaceAlt)
          .border({ width: 1, color: this.cBorder })
          .borderRadius(12)
          .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
          .onClick(() => {
            this.pulseChromeInteraction();
            this.addManualMonitor();
          });
        Button($r('app.string.monitor_clear_manual'))
          .layoutWeight(1)
          .height(34)
          .fontSize(12)
          .fontColor('#ef4444')
          .backgroundColor(this.cSurfaceAlt)
          .border({ width: 1, color: 'rgba(239,68,68,0.55)' })
          .borderRadius(12)
          .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
          .onClick(() => {
            this.pulseChromeInteraction();
            this.clearManualMonitorLayout();
            this.displayEditingScreens = false;
            this.showStatusBanner(this.s($r('app.string.monitor_exit_manual')));
          });
      }
      .width('100%');
    }
    .width('100%');
  }

  @Builder
  private buildDisplayPanelMainBody(): void {
    Column({ space: 10 }) {
      Text($r('app.string.display_panel_switch_desc'))
        .fontSize(12)
        .fontColor(this.cTextSecondary)
        .width('100%');
      this.buildDisplayPreviewImage();
      if (this.getDisplayPreviewMonitorRects().length > 0) {
        Text(
          this.isUsingManualMonitorLayout()
            ? this.s($r('app.string.display_manual_tuning_count'), this.getDisplayPreviewMonitorRects().length)
            : this.monitorLayoutLocked && this.monitors.length > 1
            ? this.s($r('app.string.display_saved_layout_count'), this.monitors.length)
            : this.s($r('app.string.display_detected_screens_count'), this.getDisplayPreviewMonitorRects().length)
        )
          .fontSize(12)
          .fontColor(this.cTextSecondary)
          .width('100%');
        ForEach(this.getDisplayPreviewMonitorRects(), (m: VncRect, index: number) => {
          Text(this.s($r('app.string.display_screen_n_with_rect'), index + 1, this.formatMonitorRectLabel(m)))
            .fontSize(11)
            .fontColor(this.cTextMuted)
            .width('100%');
        }, (m: VncRect, index: number) => `${index}:${m.x},${m.y},${m.w},${m.h}:label`);
        Row({ space: 8 }) {
          Button($r('app.string.display_redetect'))
            .layoutWeight(1)
            .height(36)
            .fontSize(12)
            .fontColor(this.cPrimary)
            .backgroundColor(this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(14)
            .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
            .onClick(() => {
              this.pulseChromeInteraction();
              this.redetectMonitorLayout();
            });
          Button($r('app.string.display_remember_layout'))
            .layoutWeight(1)
            .height(36)
            .fontSize(12)
            .fontColor(this.cPrimary)
            .backgroundColor(this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(14)
            .enabled(this.getDisplayPreviewMonitorRects().length > 1)
            .opacity(this.getDisplayPreviewMonitorRects().length > 1 ? 1 : 0.5)
            .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
            .onClick(() => {
              this.pulseChromeInteraction();
              this.confirmMonitorLayout();
            });
        }
        .width('100%');
        Text(this.monitorWindowsOpenCount > 0
          ? this.s($r('app.string.display_monitor_windows_opened_count'), this.monitorWindowsOpenCount)
          : this.s($r('app.string.display_monitor_window_desc')))
          .fontSize(11)
          .lineHeight(16)
          .fontColor(this.cTextSecondary)
          .width('100%');
        Row({ space: 8 }) {
          Button($r('app.string.display_split_to_windows'))
            .layoutWeight(1)
            .height(36)
            .fontSize(12)
            .fontColor(this.cPrimary)
            .backgroundColor(this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(14)
            .enabled(this.getDisplayPreviewMonitorRects().length > 1 && this.connected)
            .opacity(this.getDisplayPreviewMonitorRects().length > 1 && this.connected ? 1 : 0.5)
            .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
            .onClick(() => {
              this.pulseChromeInteraction();
              void this.openMonitorWindows();
            });
          Button($r('app.string.display_close_windows_button'))
            .layoutWeight(1)
            .height(36)
            .fontSize(12)
            .fontColor(this.cPrimary)
            .backgroundColor(this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(14)
            .enabled(this.monitorWindowsOpenCount > 0)
            .opacity(this.monitorWindowsOpenCount > 0 ? 1 : 0.5)
            .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
            .onClick(() => {
              this.pulseChromeInteraction();
              void this.closeMonitorWindows();
            });
        }
        .width('100%');
      }
      if (this.fbW > 0 && this.fbH > 0) {
        Text($r('app.string.display_total_canvas_desc', this.fbW, this.fbH))
          .fontSize(11)
          .lineHeight(16)
          .fontColor(this.cTextMuted)
          .width('100%');
        if (this.monitorLayoutLocked && this.monitors.length > 1) {
          Text($r('app.string.display_layout_locked_hint'))
            .fontSize(11)
            .lineHeight(16)
            .fontColor(this.cTextSecondary)
            .width('100%');
        }
        Row({ space: 8 }) {
          Button($r('app.string.monitor_add_screen'))
            .layoutWeight(1)
            .height(34)
            .fontSize(12)
            .fontColor(this.cPrimary)
            .backgroundColor(this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(12)
            .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
            .onClick(() => {
              this.pulseChromeInteraction();
              this.addManualMonitor();
            });
          Button($r('app.string.monitor_draw_add_screen'))
            .layoutWeight(1)
            .height(34)
            .fontSize(12)
            .fontColor(this.cPrimary)
            .backgroundColor(this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(12)
            .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
            .onClick(() => {
              this.pulseChromeInteraction();
              this.addManualMonitorByDraw();
            });
          Button($r('app.string.monitor_edit_screens'))
            .layoutWeight(1)
            .height(34)
            .fontSize(12)
            .fontColor(this.cPrimary)
            .backgroundColor(this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(12)
            .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev))
            .onClick(() => {
              this.pulseChromeInteraction();
              this.beginDisplayScreenEditing();
            });
        }
        .width('100%');
      }
      this.buildPanelAction({ label: this.s($r('app.string.monitor_all_screens')), primary: this.viewportMode === 'all', onClick: () => {
        this.setViewportMode('all');
        this.closePanel();
      }});
      if (this.monitors.length > 1) {
        ForEach(this.monitors, (m: VncRect, index: number) => {
          this.buildPanelAction({ label: this.s($r('app.string.viewer_screen_label'), index + 1), primary: this.viewportMode === 'single' && this.currentMonitorIndex === index, onClick: () => {
            this.setViewportMode('single', index);
            this.closePanel();
          }});
        }, (m: VncRect, index: number) => `${index}:${m.x},${m.y},${m.w},${m.h}`);
        this.buildPanelAction({ label: this.s($r('app.string.monitor_split_overview')), primary: this.viewportMode === 'tile', onClick: () => {
          this.setViewportMode('tile');
          this.closePanel();
        }});
      } else if (this.detectingDisplayLayout) {
        Text($r('app.string.monitor_detecting'))
          .fontSize(12)
          .fontColor(this.cTextSecondary)
          .width('100%');
      } else {
        Text($r('app.string.monitor_only_one_detected'))
          .fontSize(12)
          .fontColor(this.cTextSecondary)
          .width('100%');
      }
    }
    .width('100%');
  }

  @Builder
  private buildMorePanelBody(): void {
    Column({ space: 10 }) {
      Text($r('app.string.more_panel_desc'))
        .fontSize(12)
        .fontColor(this.cTextSecondary)
        .width('100%');
      this.buildPanelAction({ label: this.s($r('app.string.more_clipboard_label')), primary: false, onClick: () => this.togglePanel('clipboard') });
      this.buildAdaptiveResolutionToggle();
      if (this.adaptiveResizeNotice) {
        Text(this.adaptiveResizeNotice)
          .fontSize(11)
          .fontColor(this.cWarning)
          .width('100%');
      }
      if (this.runtimeMacMode) {
        Row() {
          Column() {
            Text($r('app.string.keyboard_ctrl_passthrough'))
              .fontSize(13)
              .fontColor(this.cTextPrimary)
              .maxLines(1);
            Text($r('app.string.keyboard_ctrl_passthrough_desc'))
              .fontSize(11)
              .fontColor(this.cTextSecondary)
              .maxLines(2);
          }
          .layoutWeight(1);
          Row() {
            Blank()
              .width(18)
              .height(18)
              .backgroundColor(this.cSurfaceAlt)
              .borderRadius(9)
              .margin({ left: this.remoteCtrlPassthrough ? 18 : 0 });
          }
          .width(42)
          .height(24)
          .padding(3)
          .backgroundColor(this.remoteCtrlPassthrough ? this.cPrimary : this.cBorder)
          .borderRadius(12)
          .onClick(() => {
            const next = !this.remoteCtrlPassthrough;
            this.remoteCtrlPassthrough = next;
            const ctx = this.getHostContext();
            if (ctx) saveCtrlPassthrough(next, ctx);
          });
        }
        .width('100%')
        .padding({ left: 12, right: 8, top: 8, bottom: 8 })
        .backgroundColor(this.cSurfaceAlt)
        .borderRadius(14)
        .border({ width: 1, color: this.cBorder })
        .onTouch((ev: TouchEvent) => this.handleChromeTouchInteraction(ev));
      }
      this.buildPanelAction({ label: this.s($r('app.string.more_open_session_panel')), primary: false, onClick: () => this.togglePanel('connection') });
      this.buildPanelAction({ label: this.isFullscreen ? this.s($r('app.string.viewer_exit_fullscreen')) : this.s($r('app.string.viewer_enter_fullscreen')), primary: false, onClick: () => {
        this.toggleFullscreen();
        this.closePanel();
      }});
      this.buildPanelAction({ label: this.s($r('app.string.viewer_save_current_frame')), primary: false, onClick: () => {
        void this.saveImage();
        this.closePanel();
      }});
      this.buildPanelAction({ label: this.devToolsEnabled ? this.s($r('app.string.more_developer_tools')) : this.s($r('app.string.more_open_developer_tools')), primary: false, onClick: () => this.togglePanel('developer') });
      this.buildPanelAction({ label: this.connected ? this.s($r('app.string.conn_disconnect')) : this.s($r('app.string.viewer_reconnect')), primary: true, onClick: () => {
        if (this.connected) this.disconnect();
        else this.prepareConnect();
        this.closePanel();
      }});
    }
    .width('100%');
  }

  @Builder
  private buildSecurityPanelBody(): void {
    Column({ space: 10 }) {
      Text(this.getSecurityLabel())
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.getSecurityBadgeColor())
        .width('100%');
      Text(this.getSecurityDescription())
        .fontSize(13)
        .lineHeight(20)
        .fontColor(this.cTextPrimary)
        .width('100%');
      Text($r('app.string.security_panel_desc'))
        .fontSize(12)
        .fontColor(this.cTextSecondary)
        .width('100%');
    }
    .width('100%');
  }

  @Builder
  private buildDeveloperPanelBody(): void {
    Column({ space: 10 }) {
      Text($r('app.string.devtools_desc'))
        .fontSize(12)
        .fontColor(this.cTextSecondary)
        .width('100%');
      this.buildPanelAction({ label: this.debugEnabled ? this.s($r('app.string.debug_turn_off')) : this.s($r('app.string.debug_turn_on')), primary: false, onClick: () => {
        this.debugEnabled = !this.debugEnabled;
        this.vncClient.setDebugOptions(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
      }});
      this.buildPanelAction({ label: this.s($r('app.string.devtools_pixel_format'), this.debugPmFormat === 0 ? 'RGBA' : 'ARGB'), primary: false, onClick: () => {
        this.debugPmFormat = (this.debugPmFormat + 1) % 2;
        this.vncClient.setDebugOptions(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
        this.pm = undefined;
        void this.ensurePixelMap();
      }});
      this.buildPanelAction({ label: this.s($r('app.string.devtools_byte_order'), this.debugByteOrder), primary: false, onClick: () => {
        this.debugByteOrder = (this.debugByteOrder + 1) % 4;
        this.vncClient.setDebugOptions(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
        this.pm = undefined;
        void this.ensurePixelMap();
      }});
      this.buildPanelAction({ label: this.s($r('app.string.viewer_refresh_frame')), primary: false, onClick: () => {
        this.vncClient.refresh();
        this.showStatusBanner(this.s($r('app.string.devtools_refresh_attempted')));
      }});
      this.buildPanelAction({ label: this.devToolsEnabled ? this.s($r('app.string.devtools_hide_entry')) : this.s($r('app.string.devtools_keep_entry')), primary: false, onClick: () => {
        this.setDevToolsEnabled(!this.devToolsEnabled);
      }});
      if (this.firstPixel) {
        Text(this.firstPixel)
          .fontSize(12)
          .fontColor(this.cError)
          .fontWeight(FontWeight.Medium)
          .fontFamily('monospace')
          .width('100%');
      }
      if (this.debugInfoText) {
        Text(this.debugInfoText)
          .fontSize(12)
          .fontColor(this.cTextPrimary)
          .fontFamily('monospace')
          .maxLines(5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      if (this.debugLogText) {
        Text(this.debugLogText)
          .fontSize(11)
          .fontColor(this.cTextMuted)
          .fontFamily('monospace')
          .maxLines(8)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
    }
    .width('100%');
  }

  private getPanelBodyMaxHeight(): number {
    const viewer = this.viewerH > 1 ? this.viewerH : 640;
    const bottomMargin = this.isFullscreen ? 12 : 24;
    const available = Math.floor(viewer - PANEL_HEADER_HEIGHT - PANEL_VERTICAL_GAP - bottomMargin);
    // 窗口极矮时仍保留一段可用高度，但不允许整个面板超出窗口
    const floor = Math.max(0, Math.min(160, Math.floor(viewer - PANEL_HEADER_HEIGHT - 8)));
    return Math.max(available, floor);
  }

  // 面板贴合内容：内容短时不再被拉满整窗，内容长时才撑到上限并在内部滚动
  private getPanelMaxHeight(): number {
    return this.getPanelBodyMaxHeight() + PANEL_HEADER_HEIGHT;
  }

  @Builder
  private buildPanelLayer(): void {
    if (this.connected && this.panelMode !== 'none') {
      Stack() {
        Column() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(12,20,22,0.32)')
        .onClick(() => this.closePanel());

        Column() {
          Blank().layoutWeight(1);
          Column() {
            Row() {
              Text(
                this.panelMode === 'clipboard' ? this.s($r('app.string.panel_clipboard_title')) :
                this.panelMode === 'display' ? this.s($r('app.string.panel_display_screen_layout')) :
                this.panelMode === 'security' ? this.s($r('app.string.security_title')) :
                this.panelMode === 'developer' ? this.s($r('app.string.devtools_title')) :
                this.panelMode === 'connection' ? this.s($r('app.string.panel_connection_session')) : this.s($r('app.string.panel_more_operations'))
              )
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.cTextPrimary)
                .layoutWeight(1);
              Button($r('app.string.action_close'))
                .height(30)
                .fontSize(12)
                .fontColor(this.cPrimary)
                .backgroundColor(this.cSurfaceAlt)
                .border({ width: 1, color: this.cBorder })
                .borderRadius(14)
                .onClick(() => this.closePanel());
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 12 });

            Scroll() {
              Column() {
                if (this.panelMode === 'clipboard') {
                  this.buildClipboardPanelBody();
                } else if (this.panelMode === 'display') {
                  this.buildDisplayPanelBody();
                } else if (this.panelMode === 'security') {
                  this.buildSecurityPanelBody();
                } else if (this.panelMode === 'developer') {
                  this.buildDeveloperPanelBody();
                } else if (this.panelMode === 'connection') {
                  this.buildControls();
                } else {
                  this.buildMorePanelBody();
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 16 });
            }
            .width('100%')
            .constraintSize({ maxHeight: this.getPanelBodyMaxHeight() })
            .scrollable(this.manualDragMonitorIndex >= 0 ? ScrollDirection.None : ScrollDirection.Vertical)
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring);
          }
          .width(Math.max(320, Math.min(560, this.windowW > 0 ? this.windowW - 24 : 560)))
          .constraintSize({ maxHeight: this.getPanelMaxHeight() })
          .backgroundColor(this.panelMode === 'connection' ? this.cSurface : this.cSurfaceAlt)
          .border({ width: 1, color: this.cBorder })
          .borderRadius(22)
          .shadow({ radius: 24, color: 'rgba(12,20,22,0.18)', offsetX: 0, offsetY: 10 })
          .margin({ bottom: this.isFullscreen ? 12 : 24 });
        }
        .width('100%')
        .height('100%');
      }
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  private buildChromeHandle(): void {
    if (this.shouldShowChromeHandle()) {
      Row() {
        Column({ space: 5 }) {
          Blank()
            .width(4)
            .height(4)
            .borderRadius(2)
            .backgroundColor('rgba(255,255,255,0.9)');
          Blank()
            .width(4)
            .height(4)
            .borderRadius(2)
            .backgroundColor('rgba(255,255,255,0.72)');
          Blank()
            .width(4)
            .height(4)
            .borderRadius(2)
            .backgroundColor('rgba(255,255,255,0.56)');
        }
      }
      .width(this.chromeHandleWidth)
      .height(this.chromeHandleHeight)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('rgba(12,20,22,0.38)')
      .border({ width: 1, color: 'rgba(255,255,255,0.12)' })
      .borderRadius({ topLeft: 12, bottomLeft: 12, topRight: 0, bottomRight: 0 })
      .position({
        x: Math.max(0, this.viewerW - this.chromeHandleWidth),
        y: Math.max(24, Math.floor((this.viewerH - this.chromeHandleHeight) / 2))
      })
      .opacity(0.82)
      .onClick(() => this.revealChrome())
      .onTouch((ev: TouchEvent) => {
        if (ev?.type === TouchType.Down) {
          this.revealChrome();
        }
      });
    }
  }

  @Builder
  private buildStatusBanner(): void {
    if (this.statusBannerText) {
      Column() {
        Text(this.statusBannerText)
          .fontSize(12)
          .fontColor('#ffffff')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor(this.cOverlayPanel)
          .borderRadius(16);
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: this.isFullscreen ? 84 : 96 });
    }
    if (this.bootstrapping && this.pm) {
      Column() {
        Text($r('app.string.display_bootstrapping'))
          .fontSize(12)
          .fontColor('#ffffff')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor('rgba(0,0,0,0.65)')
          .borderRadius(12);
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ bottom: 40 });
    }
  }

  private extendChromeInteractionIfVisible(): void {
    if (this.chromeVisible) {
      this.chromeHideTimer = this.chromeInteractionHideMs;
      this.requestTick();
    }
  }

  private handleNavAction(action: 'up' | 'down' | 'left' | 'right' | 'zoomIn' | 'zoomOut'): void {
    if (!this.connected) return;
    this.extendChromeInteractionIfVisible();
    
    if (action === 'zoomIn') {
      this.stepViewerZoom(this.zoomStepScale);
    } else if (action === 'zoomOut') {
      this.stepViewerZoom(-this.zoomStepScale);
    } else {
      const panStep = 100;
      let dx = 0;
      let dy = 0;
      if (action === 'up') dy = panStep;
      if (action === 'down') dy = -panStep;
      if (action === 'left') dx = panStep;
      if (action === 'right') dx = -panStep;
      
      this.zoomOffsetX += dx;
      this.zoomOffsetY += dy;
      this.clampZoomOffset();
    }
  }

  private navTimers: Record<string, number> = {};

  private getNavSymbol(action: 'up' | 'down' | 'left' | 'right' | 'zoomIn' | 'zoomOut'): Resource {
    switch (action) {
      case 'up': return $r('sys.symbol.arrow_up');
      case 'down': return $r('sys.symbol.arrow_down');
      case 'left': return $r('sys.symbol.arrow_left');
      case 'right': return $r('sys.symbol.arrow_right');
      case 'zoomIn': return $r('sys.symbol.plus');
      case 'zoomOut': return $r('sys.symbol.minus');
    }
  }

  @Builder
  private buildNavButton(action: 'up' | 'down' | 'left' | 'right' | 'zoomIn' | 'zoomOut') {
    Button() {
      SymbolGlyph(this.getNavSymbol(action))
        .fontSize(24)
        .fontColor([Color.White])
    }
      .width(44)
      .height(44)
      .backgroundColor('rgba(255,255,255,0.15)')
      .borderRadius(12)
      .type(ButtonType.Normal)
      .onTouch((ev: TouchEvent) => {
        if (ev.type === TouchType.Down) {
          this.handleNavAction(action);
          this.navTimers[action] = setInterval(() => {
            this.handleNavAction(action);
          }, 100);
        } else if (ev.type === TouchType.Up || ev.type === TouchType.Cancel) {
          if (this.navTimers[action]) {
            clearInterval(this.navTimers[action]);
            this.navTimers[action] = 0;
          }
        }
      })
  }

  @Builder
  private buildNavigationPad(): void {
    if (this.connected && this.interactionMode === 'control' && this.showNavigationPad &&
      this.panelMode === 'none' && !this.isUsingManualMonitorLayout()) {
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          this.buildNavButton('zoomOut')
          this.buildNavButton('zoomIn')
        }
        Blank().height(8)
        this.buildNavButton('up')
        Row({ space: 52 }) {
          this.buildNavButton('left')
          this.buildNavButton('right')
        }
        this.buildNavButton('down')
      }
      .alignItems(HorizontalAlign.Center)
      .padding(12)
      .backgroundColor('rgba(12,20,22,0.5)')
      .borderRadius(20)
      .position({
        x: Math.max(0, this.viewerW - 176),
        y: Math.max(0, this.viewerH - 280)
      });
    }
  }

  build() {
    Stack() {
      this.buildViewer();
      this.buildConnectionPrepLayer();
      if (this.shouldRenderChrome()) {
        Column() {
          this.buildTopBar();
          Blank().layoutWeight(1);
          if (this.connected) {
            this.buildBottomDock();
          }
        }
        .width('100%')
        .height('100%');
      }
      this.buildChromeHandle();
      this.buildPanelLayer();
      this.buildStatusBanner();
      this.buildConnectPasswordPromptOverlay();
      this.buildEditOverlay();
      this.buildNavigationPad();
    }
    .id('vnc_root_stack')
    .width("100%")
    .height("100%")
    .backgroundColor(this.cSurface)
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((ev: KeyEvent) => {
      if (ev?.keyCode === KeyCode.KEYCODE_F11) {
        if (ev?.type === KeyType.Down) this.toggleFullscreen();
        return true;
      }
      if (!this.connected) return false;
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
      let isAsciiOnly = true;
      if (text) {
        if (code === 0) {
          isTextEvent = true;
        }
        for (const ch of text) {
          if ((ch.codePointAt(0) ?? 0) > 0x7f) {
            isTextEvent = true;
            isAsciiOnly = false;
            break;
          }
        }
      }

      if (isTextEvent) {
        if (isDown) {
          if (this.debugEnabled) {
            console.info(`onKey text->remote type=${ev?.type} code=${code} text=${text} ascii=${isAsciiOnly}`);
          }
          this.sendRemoteCommittedText(text);
        }
        return true;
      }

      if (code === KeyCode.KEYCODE_DEL || code === 67) {
        if (isDown) {
          this.noteLocalInputActivity();
          this.safeSendKey(0xff08, true);
        }
        if (isUp) {
          this.safeSendKey(0xff08, false);
          this.noteLocalInputActivity();
          this.requestTick();
        }
        return true;
      }
      
      if (code === KeyCode.KEYCODE_CAPS_LOCK && isDown) {
        if (this.runtimeMacMode) {
          this.remoteChineseMode = !this.remoteChineseMode;
        }
      }

      const keysym = keySymFromEvent(ev, this.remoteChineseMode);
      if (!keysym) return false;

      if (this.trySwapCtrlForCmd(ev, keysym, isDown, this.getModifierDown(ev, 'Ctrl'), this.getModifierDown(ev, 'Meta'))) {
        return true;
      }

      if (keysym >= 0x01000000 && keysym <= 0x0100ffff) {
        if (isDown) {
          const ch = String.fromCodePoint(keysym & 0xffffff);
          void this.sendTextToRemoteAsync(ch);
          this.requestTick();
        }
        return true;
      }

      if (this.debugEnabled) {
        console.info(`onKey type=${ev?.type} code=${ev?.keyCode ?? 0} text=${ev?.keyText ?? ''} keysym=0x${keysym.toString(16)}`);
      }
      if (isDown) {
        this.noteLocalInputActivity();
        this.safeSendKey(keysym, true);
      }
      if (isUp) {
        this.safeSendKey(keysym, false);
        this.noteLocalInputActivity();
        this.requestTick();
      }
      if (code === KeyCode.KEYCODE_SHIFT_LEFT || code === KeyCode.KEYCODE_SHIFT_RIGHT) this.remoteShiftDown = isDown ? true : (isUp ? false : this.remoteShiftDown);
      if (code === KeyCode.KEYCODE_CTRL_LEFT || code === KeyCode.KEYCODE_CTRL_RIGHT) this.remoteCtrlDown = isDown ? true : (isUp ? false : this.remoteCtrlDown);
      if (code === KeyCode.KEYCODE_ALT_LEFT || code === KeyCode.KEYCODE_ALT_RIGHT) this.remoteAltDown = isDown ? true : (isUp ? false : this.remoteAltDown);
      if (code === KeyCode.KEYCODE_META_LEFT || code === KeyCode.KEYCODE_META_RIGHT) this.remoteMetaDown = isDown ? true : (isUp ? false : this.remoteMetaDown);
      return true;
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.windowW = (newValue.width as number) ?? 0;
      this.windowH = (newValue.height as number) ?? 0;
    })
    .onDisAppear(() => this.disconnect());
  }
}
