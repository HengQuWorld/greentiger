import image from '@ohos.multimedia.image';
import dataPreferences from '@ohos.data.preferences';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { pasteboard } from '@kit.BasicServicesKit';
import util from '@ohos.util';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { BUILD_VERSION } from '../utils/BuildInfo';
import {
  ConnectionItem,
  DEFAULT_SSH_PORT,
  DEFAULT_VNC_PORT,
  SSH_AUTH_PASSWORD,
  SSH_AUTH_PUBLIC_KEY,
  SshTunnelConfig,
  WantParamValue,
  generateId,
  isValidPort,
  normalizeConnName,
  normalizePortText,
  normalizeSshTunnelConfig,
  normalizeSshTunnelConfigForAddress,
  parseAddress,
  parseConnectionsJson,
  resolveEffectiveSshTunnelConfig,
  resolveConnectionAddress
} from '../utils/ConnectionUtils';

import vnc from 'libvncviewer.so';

interface VncFramebufferInfo {
  width: number;
  height: number;
  stride: number;
  state: number;
  name?: string;
}

interface ViewerAbilityParams extends Record<string, WantParamValue> {
  address: string;
  user: string;
  password: string;
  name: string;
  sshConfig?: string;
  touchScrollStep?: number;
}

interface StartWant {
  bundleName: string;
  moduleName: string;
  abilityName: string;
  parameters: Record<string, WantParamValue>;
}

interface BrowserWant {
  action: string;
  uri: string;
  entities?: string[];
  parameters?: Record<string, boolean>;
}

interface ErrorLike {
  code?: number;
  message?: string;
  name?: string;
  stack?: string;
}

interface VncClient {
  connect(host: string, port: number, user?: string, pass?: string): Promise<number>;
  setSshTunnel?(config: SshTunnelConfig): number;
  clearSshTunnel?(): void;
  disconnect(): void;
  process(): number;
  refresh(): number;
  consumeDamage(): VncRect | null;
  getFramebufferInfo(): VncFramebufferInfo;
  copyFrameRGBA(order: number): ArrayBuffer | null;
  sendPointer(x: number, y: number, mask: number): void;
  sendKey(keysym: number, down: boolean): void;
  setClipboardText(text: string): void;
  takeRemoteClipboardText(): string;
  getLastError(): string;
  setDebugOptions(enabled: boolean, level: number, byteOrder: number, pmFormat: number): void;
  getDebugInfo(): VncDebugInfo;
  getDebugLog(clear: boolean): string;
}

interface BorderSpec {
  width: number;
  color: string;
}

interface ConnectionDetailLine {
  label: string;
  value: string;
}

interface MarkdownBlock {
  key: string;
  type: number;
  level: number;
  text: string;
}

const EDIT_TAB_BASIC = 0;
const EDIT_TAB_ADVANCED = 1;
const MARKDOWN_BLOCK_PARAGRAPH = 0;
const MARKDOWN_BLOCK_HEADING = 1;
const MARKDOWN_BLOCK_BULLET = 2;
const AGREEMENT_DIALOG_NONE = 0;
const AGREEMENT_DIALOG_PRIVACY = 1;
const AGREEMENT_DIALOG_USER = 2;
const AGREEMENT_DIALOG_LAUNCH = 3;
const LAUNCH_AGREEMENTS_ACCEPTED_KEY = 'launch_agreements_accepted_v1';
const PRIVACY_POLICY_RAWFILE = 'privacy-policy.md';
const USER_AGREEMENT_RAWFILE = 'user-agreement.md';
const PRIVACY_POLICY_URL = 'https://www.hengqu.world/agreements/privacy-policy';
const USER_AGREEMENT_URL = 'https://www.hengqu.world/agreements/user-agreement';
const PROJECT_CONTACT_EMAIL = 'contact@hengqu.world';
const PROJECT_HOMEPAGE_URL = 'https://www.hengqu.world';
const PROJECT_SOURCE_URL = 'https://github.com/hengquworld/greentiger';
interface VncRect {
  x: number;
  y: number;
  w: number;
  h: number;
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

@Component
struct BrandSwitch {
  @Prop isOn: boolean = false;
  @Prop isEnabled: boolean = true;
  onChange: (next: boolean) => void = () => {};

  build() {
    Row() {
      Blank()
        .width(18)
        .height(18)
        .backgroundColor('#ffffff')
        .borderRadius(9)
        .margin({ left: this.isOn ? 18 : 0 });
    }
    .width(42)
    .height(24)
    .padding(3)
    .backgroundColor(this.isOn ? '#2c4f54' : '#e7e5e4')
    .borderRadius(12)
    .opacity(this.isEnabled ? 1 : 0.6)
    .onClick(() => {
      if (!this.isEnabled) return;
      this.onChange(!this.isOn);
    });
  }
}

@Entry
@Component
struct Index {
  @State address: string = '127.0.0.1:5900';
  @State user: string = '';
  @State password: string = '';
  @State private connName: string = '';
  @State private connections: ConnectionItem[] = [];
  @State private selectedConnId: string = '';
  @State private keyword: string = '';
  @State private showPassword: boolean = false;
  @State private mainStorePassword: boolean = false;
  @State private editOpen: boolean = false;
  @State private aboutOpen: boolean = false;
  @State private agreementDialogMode: number = AGREEMENT_DIALOG_NONE;
  @State private launchAgreementsAccepted: boolean = false;
  @State private privacyPolicyText: string = '';
  @State private userAgreementText: string = '';
  @State private privacyPolicyBlocks: MarkdownBlock[] = [];
  @State private userAgreementBlocks: MarkdownBlock[] = [];
  @State private editId: string = '';
  @State private editName: string = '';
  @State private editAddress: string = '';
  @State private editUser: string = '';
  @State private editPassword: string = '';
  @State private editStorePassword: boolean = true;
  @State private editShowPassword: boolean = false;
  @State private editTabIndex: number = EDIT_TAB_BASIC;
  @State private editMoreOptionsOpen: boolean = false;
  @State private editSshEnabled: boolean = false;
  @State private editSshAdvancedOpen: boolean = false;
  @State private editSshHost: string = '';
  @State private editSshPortText: string = `${DEFAULT_SSH_PORT}`;
  @State private editSshUser: string = '';
  @State private editSshReuseDesktopUser: boolean = false;
  @State private editSshAuthType: number = SSH_AUTH_PASSWORD;
  @State private editSshPassword: string = '';
  @State private editSshReuseDesktopPassword: boolean = false;
  @State private editSshPrivateKeyPath: string = '';
  @State private editSshPublicKeyPath: string = '';
  @State private editSshPrivateKeyPassphrase: string = '';
  @State private editSshKnownHostsPath: string = '';
  @State private editSshStrictHostKeyCheck: boolean = false;
  @State private editSshRemoteHost: string = '';
  @State private editSshRemotePortText: string = `${DEFAULT_VNC_PORT}`;
  @State connected: boolean = false;
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
  private readonly borderNone: BorderSpec = { width: 0, color: this.cBorder };
  private readonly borderThin: BorderSpec = { width: 1, color: this.cBorder };

  private getHostContext(): common.UIAbilityContext | undefined {
    try {
      return this.getUIContext()?.getHostContext?.() as common.UIAbilityContext;
    } catch (e) {
      return undefined;
    }
  }

  private toast(message: string): void {
    try {
      const pa = this.getUIContext()?.getPromptAction?.();
      pa?.showToast?.({ message });
    } catch (e) {
    }
  }

  private openExternalUrl(url: string): void {
    const context = this.getHostContext();
    if (!context) {
      this.toast('无法打开链接');
      return;
    }
    const want: BrowserWant = {
      action: 'ohos.want.action.viewData',
      uri: url,
      parameters: {
        'ohos.ability.params.showDefaultPicker': true
      }
    };
    if (url.startsWith('http://') || url.startsWith('https://')) {
      want.entities = ['entity.system.browsable'];
    }
    context.startAbility(want)
      .catch((e: ErrorLike) => {
        console.error('Failed to open external url', e);
        this.toast('无法打开链接');
      });
  }

  private copyText(text: string, successMessage: string): void {
    const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(pasteData)
      .then(() => {
        this.toast(successMessage);
      })
      .catch((e: ErrorLike) => {
        console.error('Failed to copy text', e);
        this.toast('复制失败');
      });
  }

  @State viewerW: number = 1;
  @State viewerH: number = 1;

  @State private windowW: number = 0;
  @State private windowH: number = 0;

 @State private fbW: number = 0;
  @State private fbH: number = 0;
  private fbStride: number = 0;
  @State private vncState: number = -1;
  private lastMask: number = 0;
  private timerId: number = -1;
  private ticking: boolean = false;
  @State private pm: image.PixelMap | undefined = undefined;
  @State private pmVersion: number = 0;
  private creatingPm: boolean = false;
  private lastX: number = 0;
  private lastY: number = 0;
  private readonly inputLayerKey: string = 'vnc_input_layer';
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private touchStartTs: number = 0;
  private touchMoved: boolean = false;
  private touchDragging: boolean = false;
  private edgeSwipeActive: boolean = false;
  private edgeSwipeStartX: number = 0;
  private edgeSwipeStartY: number = 0;

  @State private debugEnabled: boolean = false;
  @State private debugLevel: number = 1;
  @State private debugPmFormat: number = 0;
  @State private debugByteOrder: number = 0;
  @State private debugInfoText: string = '';
  @State private debugLogText: string = '';
  @State private firstPixel: string = '';
  private lastDebugTs: number = 0;

  @State serverName: string = '';
  @State private didAdoptServerName: boolean = false;

  @State private pressedBtnKey: string = '';
  private readonly iconBtnSize: number = 42;
  private readonly iconBtnRadius: number = 14;
  private readonly iconSize: number = 20;
  private readonly cSurfacePressed: string = 'rgba(12,20,22,0.06)';
  private readonly cPrimaryPressed: string = 'rgba(44,79,84,0.88)';
  private readonly cErrorSoft: string = 'rgba(180,35,24,0.12)';
  private readonly cPrimaryOutline: string = 'rgba(44,79,84,0.22)';
  private readonly cFocusOutline: string = '#3b82f6';
  private readonly connectionListScroller: Scroller = new Scroller();

  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm';

  aboutToAppear() {
    this.loadConnections();
    void this.loadAgreementsState();
    
    // 监听断点变化，用于响应式布局判断
    const mediaQuery = this.getUIContext()?.getMediaQuery();
    if (mediaQuery) {
      mediaQuery.matchMediaSync('(width >= 840vp)').on('change', (result) => {
        AppStorage.setOrCreate('currentBreakpoint', result.matches ? 'lg' : 'md');
      });
      mediaQuery.matchMediaSync('(width >= 600vp)').on('change', (result) => {
        if (!result.matches) {
          AppStorage.setOrCreate('currentBreakpoint', 'sm');
        }
      });
    }
  }

  onPageShow(): void {
    if (this.connected || this.connecting || this.editOpen) return;
    void this.loadConnections();
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
      this.scheduleScrollToConnection(initialId);
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
    this.toast('名称已保存');
  }

  private selectConnection(id: string): void {
    if (!id) return;
    this.selectedConnId = id;
    this.applySelectedConnectionToFields();
    this.scheduleScrollToConnection(id);
    void this.saveConnections();
  }

  private getSelectedConnection(): ConnectionItem | null {
    const id = this.selectedConnId ?? '';
    if (!id) return null;
    const c = (this.connections ?? []).find(it => it.id === id);
    return c ?? null;
  }

  private isSelectedStorePasswordEnabled(): boolean {
    if (!this.selectedConnId) return this.mainStorePassword;
    const c = this.getSelectedConnection();
    return !!c?.storePassword;
  }

  private toggleSelectedStorePassword(): void {
    if (this.connected) return;
    if (!this.selectedConnId) {
      this.mainStorePassword = !this.mainStorePassword;
      return;
    }
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
    this.toast(enable ? '已开启保存密码' : '已关闭保存密码');
  }

  private saveCurrentFieldsToSelected(): void {
    if (this.connected || !this.selectedConnId) return;
    const addr = (this.address ?? '').trim();
    if (addr && !parseAddress(addr)) {
      this.toast('地址格式不正确，例如 192.168.1.2:5900 或 [::1]:5900');
      return;
    }

    const curr = this.connections ?? [];
    const selected = curr.find(it => it.id === this.selectedConnId);
    const sshTunnel = normalizeSshTunnelConfigForAddress(selected?.sshTunnel, addr);
    if (!parseAddress(resolveConnectionAddress(addr, sshTunnel))) {
      this.toast('请填写地址，或在开启 SSH 隧道时提供有效的转发目标');
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
    this.toast('已保存');
  }

  private openCreateDialog(): void {
    this.editId = '';
    this.editName = '';
    this.editAddress = '';
    this.editUser = '';
    this.editPassword = '';
    this.editStorePassword = true;
    this.editTouchScrollStep = 0;
    this.loadEditSshConfig(undefined, '');
    this.editTabIndex = EDIT_TAB_BASIC;
    this.editMoreOptionsOpen = this.shouldOpenEditMoreOptions();
    this.editSshAdvancedOpen = this.hasEditAdvancedSshOptions();
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
    this.loadEditSshConfig(c.sshTunnel, c.address);
    this.editTabIndex = EDIT_TAB_BASIC;
    this.editMoreOptionsOpen = this.shouldOpenEditMoreOptions();
    this.editSshAdvancedOpen = this.hasEditAdvancedSshOptions();
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
        message: this.isConnectionUsingSsh(c)
          ? `路径：${this.getConnectionPathSummary(c)}\nVNC：${this.getConnectionVncTarget(c)}\nSSH：${this.getConnectionSshServer(c)}`
          : `路径：${this.getConnectionPathSummary(c)}\nVNC：${this.getConnectionVncTarget(c)}\n方式：直连`,
        buttons: [
          { text: '取消', color: this.cTextSecondary },
          { text: '编辑', color: this.cPrimary },
          { text: '删除', color: this.cError }
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



  private closeEditDialog(): void {
    this.editOpen = false;
    this.editId = '';
    this.editName = '';
    this.editAddress = '';
    this.editUser = '';
    this.editPassword = '';
    this.editStorePassword = true;
    this.editTouchScrollStep = 0;
    this.editTabIndex = EDIT_TAB_BASIC;
    this.loadEditSshConfig(undefined, '');
    this.editMoreOptionsOpen = false;
    this.editSshAdvancedOpen = false;
    this.editShowPassword = false;
  }

  private closeAboutDialog(): void {
    this.aboutOpen = false;
  }

  private openAgreementDialog(mode: number): void {
    this.agreementDialogMode = mode;
  }

  private closeAgreementDialog(): void {
    if (this.agreementDialogMode === AGREEMENT_DIALOG_LAUNCH) {
      return;
    }
    this.agreementDialogMode = AGREEMENT_DIALOG_NONE;
  }

  private async acceptLaunchAgreements(): Promise<void> {
    try {
      const ctx = this.getHostContext();
      if (!ctx) return;
      const pref = await dataPreferences.getPreferences(ctx, { name: 'vnc_store' });
      await pref.put(LAUNCH_AGREEMENTS_ACCEPTED_KEY, true);
      await pref.flush();
      this.launchAgreementsAccepted = true;
      this.agreementDialogMode = AGREEMENT_DIALOG_NONE;
    } catch (e) {
      console.error('Failed to persist launch agreements consent', e);
      this.toast('保存协议确认状态失败');
    }
  }

  private async exitApplication(): Promise<void> {
    try {
      const ctx = this.getHostContext();
      if (!ctx) return;
      await ctx.terminateSelf();
    } catch (e) {
      console.error('Failed to terminate app', e);
      this.toast('无法退出应用');
    }
  }

  private createFallbackAgreementText(title: string): string {
    return `# ${title}\n\n协议内容加载失败，请稍后重试。`;
  }

  private stripInlineMarkdown(value: string): string {
    return value
      .replace(/\[(.*?)\]\((.*?)\)/g, '$1')
      .replace(/`([^`]+)`/g, '$1')
      .replace(/\*\*(.*?)\*\*/g, '$1')
      .replace(/__(.*?)__/g, '$1')
      .replace(/\*(.*?)\*/g, '$1');
  }

  private parseMarkdownBlocks(markdown: string): MarkdownBlock[] {
    const blocks: MarkdownBlock[] = [];
    const paragraphBuffer: string[] = [];

    const pushBlock = (type: number, level: number, text: string): void => {
      blocks.push({
        key: `${type}-${blocks.length}`,
        type,
        level,
        text
      });
    };

    const flushParagraph = (): void => {
      if (paragraphBuffer.length === 0) return;
      pushBlock(
        MARKDOWN_BLOCK_PARAGRAPH,
        0,
        paragraphBuffer.map(line => this.stripInlineMarkdown(line.trim())).join('\n')
      );
      paragraphBuffer.length = 0;
    };

    markdown.split('\n').forEach((rawLine: string) => {
      const line = rawLine.trim();
      if (!line) {
        flushParagraph();
        return;
      }
      if (line.startsWith('### ')) {
        flushParagraph();
        pushBlock(MARKDOWN_BLOCK_HEADING, 3, this.stripInlineMarkdown(line.substring(4).trim()));
        return;
      }
      if (line.startsWith('## ')) {
        flushParagraph();
        pushBlock(MARKDOWN_BLOCK_HEADING, 2, this.stripInlineMarkdown(line.substring(3).trim()));
        return;
      }
      if (line.startsWith('# ')) {
        flushParagraph();
        pushBlock(MARKDOWN_BLOCK_HEADING, 1, this.stripInlineMarkdown(line.substring(2).trim()));
        return;
      }
      if (line.startsWith('- ')) {
        flushParagraph();
        pushBlock(MARKDOWN_BLOCK_BULLET, 0, this.stripInlineMarkdown(line.substring(2).trim()));
        return;
      }
      paragraphBuffer.push(line);
    });

    flushParagraph();
    return blocks;
  }

  private loadAgreementText(rawfileName: string, fallbackTitle: string): string {
    try {
      const ctx = this.getHostContext();
      if (!ctx) {
        return this.createFallbackAgreementText(fallbackTitle);
      }
      const rawFile = ctx.resourceManager.getRawFileContentSync(rawfileName);
      return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(rawFile);
    } catch (e) {
      console.error(`Failed to load agreement rawfile: ${rawfileName}`, e);
      return this.createFallbackAgreementText(fallbackTitle);
    }
  }

  private async loadAgreementsState(): Promise<void> {
    const privacyText = this.loadAgreementText(PRIVACY_POLICY_RAWFILE, '翠虎远程桌面隐私协议');
    const userText = this.loadAgreementText(USER_AGREEMENT_RAWFILE, '翠虎远程桌面用户协议');
    this.privacyPolicyText = privacyText;
    this.userAgreementText = userText;
    this.privacyPolicyBlocks = this.parseMarkdownBlocks(privacyText);
    this.userAgreementBlocks = this.parseMarkdownBlocks(userText);

    try {
      const ctx = this.getHostContext();
      if (!ctx) return;
      const pref = await dataPreferences.getPreferences(ctx, { name: 'vnc_store' });
      const accepted = !!((await pref.get(LAUNCH_AGREEMENTS_ACCEPTED_KEY, false)) as boolean);
      this.launchAgreementsAccepted = accepted;
      if (!accepted) {
        this.agreementDialogMode = AGREEMENT_DIALOG_LAUNCH;
      }
    } catch (e) {
      console.error('Failed to load launch agreements state', e);
      this.launchAgreementsAccepted = false;
      this.agreementDialogMode = AGREEMENT_DIALOG_LAUNCH;
    }
  }

  private getAgreementDialogTitle(): string {
    if (this.agreementDialogMode === AGREEMENT_DIALOG_PRIVACY) {
      return '隐私协议';
    }
    if (this.agreementDialogMode === AGREEMENT_DIALOG_USER) {
      return '用户协议';
    }
    return '协议阅读与确认';
  }

  private isLaunchAgreementDialog(): boolean {
    return this.agreementDialogMode === AGREEMENT_DIALOG_LAUNCH;
  }

  private getMarkdownHeadingFontSize(level: number): number {
    if (level <= 1) return 18;
    if (level === 2) return 16;
    return 15;
  }

  @Builder
  private buildAboutAgreementRow(label: string, title: string, mode: number): void {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(this.cTextSecondary)
        .width(80);
      Column() {
        Text(title)
          .fontSize(15)
          .lineHeight(22)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.cPrimary);
        Text('应用内完整查看')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(this.cTextSecondary)
          .margin({ top: 2 });
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start);
    }
    .alignItems(VerticalAlign.Top)
    .onClick(() => this.openAgreementDialog(mode));
  }

  @Builder
  private buildAboutActionRow(label: string, value: string, actionLabel: string, uri: string, copyMessage: string): void {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(this.cTextSecondary)
        .width(80);
      Column() {
        Text(value)
          .fontSize(15)
          .lineHeight(22)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.cPrimary)
          .onClick(() => this.openExternalUrl(uri));
        Row() {
          Text(actionLabel)
            .fontSize(12)
            .lineHeight(18)
            .fontColor(this.cPrimary)
            .onClick(() => this.openExternalUrl(uri));
          Text('复制')
            .fontSize(12)
            .lineHeight(18)
            .fontColor(this.cTextSecondary)
            .margin({ left: 16 })
            .onClick(() => this.copyText(value, copyMessage));
        }
        .margin({ top: 4 });
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start);
    }
    .alignItems(VerticalAlign.Top);
  }

  @Builder
  private buildAgreementMarkdownBlock(block: MarkdownBlock): void {
    if (block.type === MARKDOWN_BLOCK_HEADING) {
      Text(block.text)
        .width('100%')
        .fontSize(this.getMarkdownHeadingFontSize(block.level))
        .lineHeight(block.level <= 1 ? 28 : 24)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.cTextPrimary);
    } else if (block.type === MARKDOWN_BLOCK_BULLET) {
      Row() {
        Text('•')
          .width(18)
          .fontSize(14)
          .lineHeight(22)
          .fontColor(this.cTextPrimary);
        Text(block.text)
          .layoutWeight(1)
          .fontSize(14)
          .lineHeight(22)
          .fontColor(this.cTextMuted);
      }
      .width('100%')
      .alignItems(VerticalAlign.Top);
    } else {
      Text(block.text)
        .width('100%')
        .fontSize(14)
        .lineHeight(22)
        .fontColor(this.cTextMuted);
    }
  }

  @Builder
  private buildAgreementMarkdown(blocks: MarkdownBlock[]): void {
    Column({ space: 12 }) {
      if (blocks.length === 0) {
        Text('协议内容加载中...')
          .width('100%')
          .fontSize(14)
          .lineHeight(22)
          .fontColor(this.cTextSecondary);
      } else {
        ForEach(blocks, (block: MarkdownBlock) => {
          this.buildAgreementMarkdownBlock(block);
        }, (block: MarkdownBlock) => block.key);
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  private buildAgreementSection(title: string, blocks: MarkdownBlock[]): void {
    Column({ space: 12 }) {
      Text(title)
        .width('100%')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.cTextPrimary);
      this.buildAgreementMarkdown(blocks);
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  private normalizeEditSshConfig(config: SshTunnelConfig | undefined, address: string): SshTunnelConfig {
    const normalized = normalizeSshTunnelConfigForAddress(config, address);
    const reuseDesktopCredentials = !!normalized.reuseDesktopUser || !!normalized.reuseDesktopPassword;
    return {
      enabled: normalized.enabled,
      sshHost: normalized.sshHost,
      sshPort: normalized.sshPort,
      sshUser: normalized.sshUser,
      reuseDesktopUser: reuseDesktopCredentials,
      authType: normalized.authType,
      sshPassword: normalized.sshPassword,
      reuseDesktopPassword: reuseDesktopCredentials && normalized.authType === SSH_AUTH_PASSWORD,
      privateKeyPath: normalized.privateKeyPath,
      publicKeyPath: normalized.publicKeyPath,
      privateKeyPassphrase: normalized.privateKeyPassphrase,
      knownHostsPath: normalized.knownHostsPath,
      strictHostKeyCheck: normalized.strictHostKeyCheck,
      remoteHost: normalized.remoteHost,
      remotePort: normalized.remotePort
    };
  }

  private loadEditSshConfig(config: SshTunnelConfig | undefined, address: string): void {
    const normalized = this.normalizeEditSshConfig(config, address);
    this.editSshEnabled = normalized.enabled;
    this.editSshHost = normalized.sshHost;
    this.editSshPortText = `${normalized.sshPort}`;
    this.editSshUser = normalized.sshUser;
    this.editSshReuseDesktopUser = !!normalized.reuseDesktopUser;
    this.editSshAuthType = normalized.authType;
    this.editSshPassword = normalized.sshPassword;
    this.editSshReuseDesktopPassword = !!normalized.reuseDesktopPassword;
    this.editSshPrivateKeyPath = normalized.privateKeyPath;
    this.editSshPublicKeyPath = normalized.publicKeyPath;
    this.editSshPrivateKeyPassphrase = normalized.privateKeyPassphrase;
    this.editSshKnownHostsPath = normalized.knownHostsPath;
    this.editSshStrictHostKeyCheck = normalized.strictHostKeyCheck;
    this.editSshRemoteHost = normalized.remoteHost;
    this.editSshRemotePortText = `${normalized.remotePort}`;
  }

  private isReusingEditDesktopCredentials(): boolean {
    return this.editSshReuseDesktopUser || this.editSshReuseDesktopPassword;
  }

  private hasConfiguredEditSshDetails(): boolean {
    // 只要没有配置过 SSH 服务器地址，就认为是未配置状态，可以直接补全默认值模板
    return !!(this.editSshHost ?? '').trim();
  }

  private updateEditUser(value: string): void {
    this.editUser = value;
    if (this.isReusingEditDesktopCredentials()) {
      this.editSshUser = (value ?? '').trim();
    }
  }

  private updateEditPassword(value: string): void {
    this.editPassword = value;
    if (this.editSshAuthType === SSH_AUTH_PASSWORD && this.isReusingEditDesktopCredentials()) {
      this.editSshPassword = value ?? '';
    }
  }

  private setEditSshReuseDesktopCredentials(next: boolean): void {
    this.editSshReuseDesktopUser = next;
    this.editSshReuseDesktopPassword = next && this.editSshAuthType === SSH_AUTH_PASSWORD;
    if (next) {
      this.editSshUser = (this.editUser ?? '').trim();
      if (this.editSshAuthType === SSH_AUTH_PASSWORD) {
        this.editSshPassword = this.editPassword ?? '';
      }
    }
  }

  private setEditSshAuthType(next: number): void {
    this.editSshAuthType = next;
    if (next === SSH_AUTH_PUBLIC_KEY) {
      this.editSshReuseDesktopPassword = false;
      this.editSshPassword = '';
      return;
    }
    if (this.editSshReuseDesktopUser) {
      this.editSshReuseDesktopPassword = true;
      this.editSshPassword = this.editPassword ?? '';
    }
  }

  private createAutoFilledEditSshConfig(): SshTunnelConfig {
    const parsed = parseAddress(this.editAddress ?? '');
    const targetHost = parsed?.host ?? '';
    const targetPort = parsed?.port ?? DEFAULT_VNC_PORT;
    return this.normalizeEditSshConfig({
      enabled: true,
      sshHost: targetHost || (this.editSshHost ?? '').trim(),
      sshPort: DEFAULT_SSH_PORT,
      sshUser: (this.editUser ?? '').trim(),
      reuseDesktopUser: true,
      authType: SSH_AUTH_PASSWORD,
      sshPassword: this.editPassword ?? '',
      reuseDesktopPassword: true,
      privateKeyPath: '',
      publicKeyPath: '',
      privateKeyPassphrase: '',
      knownHostsPath: '',
      strictHostKeyCheck: false,
      remoteHost: '127.0.0.1',
      remotePort: targetPort
    }, this.editAddress);
  }

  private toggleEditSshEnabled(next: boolean): void {
    if (!next) {
      this.editSshEnabled = false;
      return;
    }
    if (!this.editSshEnabled && !this.hasConfiguredEditSshDetails()) {
      this.loadEditSshConfig(this.createAutoFilledEditSshConfig(), this.editAddress);
      return;
    }
    this.editSshEnabled = true;
  }

  private shouldOpenEditMoreOptions(): boolean {
    return this.normalizeTouchScrollStep(this.editTouchScrollStep) > 0;
  }

  private hasEditAdvancedSshOptions(): boolean {
    return (this.editSshPortText ?? '').trim() !== `${DEFAULT_SSH_PORT}` ||
      !!(this.editSshPublicKeyPath ?? '').trim() ||
      !!(this.editSshKnownHostsPath ?? '').trim() ||
      this.editSshStrictHostKeyCheck ||
      !!(this.editSshRemoteHost ?? '').trim() ||
      (this.editSshRemotePortText ?? '').trim() !== `${DEFAULT_VNC_PORT}`;
  }

  private hasAnyEditAdvancedOptions(): boolean {
    return this.shouldOpenEditMoreOptions() || (this.editSshEnabled && this.hasEditAdvancedSshOptions());
  }

  private validateEditSshConfig(config: SshTunnelConfig): string {
    if (!config.enabled) return '';
    if (!config.sshHost) return 'SSH 服务器不能为空';
    if (!config.sshUser) return 'SSH 用户名不能为空';
    if (!isValidPort(config.sshPort)) return 'SSH 端口必须在 1 到 65535 之间';
    if (!config.remoteHost) return 'SSH 转发目标不能为空';
    if (!isValidPort(config.remotePort)) return 'SSH 转发目标端口必须在 1 到 65535 之间';
    if (config.authType === SSH_AUTH_PUBLIC_KEY) {
      if (!config.privateKeyPath) return 'SSH 私钥路径不能为空';
    } else if (config.authType === SSH_AUTH_PASSWORD) {
      if (!config.sshPassword) return 'SSH 密码不能为空';
    }
    if (config.strictHostKeyCheck && !config.knownHostsPath) {
      return '开启严格主机校验时必须提供 known_hosts 路径';
    }
    return '';
  }

  private buildEditSshConfig(address: string): SshTunnelConfig | null {
    const parsed = parseAddress(address);
    const normalized = normalizeSshTunnelConfig({
      enabled: this.editSshEnabled,
      sshHost: this.editSshHost,
      sshPort: normalizePortText(this.editSshPortText, DEFAULT_SSH_PORT),
      sshUser: this.editSshUser,
      reuseDesktopUser: this.editSshReuseDesktopUser,
      authType: this.editSshAuthType,
      sshPassword: this.editSshPassword,
      reuseDesktopPassword: this.editSshReuseDesktopPassword,
      privateKeyPath: this.editSshPrivateKeyPath,
      publicKeyPath: this.editSshPublicKeyPath,
      privateKeyPassphrase: this.editSshPrivateKeyPassphrase,
      knownHostsPath: this.editSshKnownHostsPath,
      strictHostKeyCheck: this.editSshStrictHostKeyCheck,
      remoteHost: this.editSshRemoteHost,
      remotePort: normalizePortText(this.editSshRemotePortText, DEFAULT_VNC_PORT)
    }, parsed?.host ?? '', parsed?.port ?? DEFAULT_VNC_PORT);
    const persisted: SshTunnelConfig = {
      enabled: normalized.enabled,
      sshHost: normalized.sshHost,
      sshPort: normalized.sshPort,
      sshUser: normalized.reuseDesktopUser ? (this.editUser ?? '').trim() : normalized.sshUser,
      reuseDesktopUser: normalized.reuseDesktopUser,
      authType: normalized.authType,
      sshPassword: normalized.authType === SSH_AUTH_PASSWORD && normalized.reuseDesktopPassword
        ? (this.editPassword ?? '')
        : normalized.sshPassword,
      reuseDesktopPassword: normalized.reuseDesktopPassword,
      privateKeyPath: normalized.privateKeyPath,
      publicKeyPath: normalized.publicKeyPath,
      privateKeyPassphrase: normalized.privateKeyPassphrase,
      knownHostsPath: normalized.knownHostsPath,
      strictHostKeyCheck: normalized.strictHostKeyCheck,
      remoteHost: normalized.remoteHost,
      remotePort: normalized.remotePort
    };
    const error = this.validateEditSshConfig(
      resolveEffectiveSshTunnelConfig(
        persisted,
        address,
        this.editUser ?? '',
        this.editPassword ?? ''
      )
    );
    if (!error) return persisted;
    this.toast(error);
    return null;
  }

  private async saveEditDialog(): Promise<void> {
    const addr = (this.editAddress ?? '').trim();
    if (addr && !parseAddress(addr)) {
      this.toast('地址格式不正确，例如 192.168.1.2:5900 或 [::1]:5900');
      return;
    }
    const sshTunnel = this.buildEditSshConfig(addr);
    if (!sshTunnel) return;
    if (!parseAddress(resolveConnectionAddress(addr, sshTunnel))) {
      this.toast('请填写地址，或在开启 SSH 隧道时提供有效的转发目标');
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
    this.showPassword = false;
    this.scheduleScrollToConnection(id);
    await this.saveConnections();
    this.closeEditDialog();
  }

  private async deleteConnection(id: string): Promise<void> {
    const c = (this.connections ?? []).find(it => it.id === id);
    if (!c) return;
    if (this.connected) {
      this.toast('已连接时不能删除连接配置');
      return;
    }
    try {
      const pa = this.getUIContext()?.getPromptAction?.();
      if (!pa?.showDialog) return;
      const res = await pa.showDialog({
        title: '删除连接',
        message: `确认删除“${normalizeConnName(c.name, c.address, c.sshTunnel)}”？`,
        buttons: [{ text: '取消', color: this.cTextSecondary }, { text: '删除', color: this.cError }]
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
      this.scheduleScrollToConnection(this.selectedConnId);
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
    const info = (vnc as VncClient).getFramebufferInfo?.();
    this.fbW = info?.width ?? 0;
    this.fbH = info?.height ?? 0;
    this.fbStride = info?.stride ?? 0;
    this.vncState = info?.state ?? -1;
    if (info?.name) {
      this.serverName = info.name;
      this.maybeAdoptServerNameAsConnName();
    }
  }



  private maybeAdoptServerNameAsConnName(): void {
    if (!this.connected) return;
    if (this.didAdoptServerName) return;
    if ((this.connName ?? '').trim()) {
      this.didAdoptServerName = true;
      return;
    }
    const name = (this.serverName ?? '').trim();
    if (!name) return;

    const selectedId = (this.selectedConnId ?? '').trim();
    const curr = this.connections ?? [];
    let changed = false;
    const next: ConnectionItem[] = [];
    for (let i = 0; i < curr.length; i++) {
      const it = curr[i];
      if (selectedId && it.id === selectedId) {
        if (!(it.name ?? '').trim()) {
          changed = true;
          next.push({
            id: it.id,
            name,
            address: it.address,
            user: it.user,
            password: it.password,
            storePassword: it.storePassword,
            touchScrollStep: it.touchScrollStep,
            sshTunnel: normalizeSshTunnelConfigForAddress(it.sshTunnel, it.address),
            lastUsedAt: it.lastUsedAt
          });
        } else {
          next.push(it);
        }
      } else {
        next.push(it);
      }
    }

    this.connName = name;
    this.didAdoptServerName = true;
    if (changed) {
      this.connections = next;
      void this.saveConnections();
    }
  }

  private async ensurePixelMap(): Promise<void> {
    if (this.pm || this.creatingPm) return;
    this.refreshFramebufferInfo();
    if (this.fbW <= 0 || this.fbH <= 0) return;
    const buf: ArrayBuffer | null = (vnc as VncClient).copyFrameRGBA?.(this.debugByteOrder) ?? null;
    if (!buf) return;

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
      const opts: image.InitializationOptions = {
        size: { width: this.fbW, height: this.fbH },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        alphaType: image.AlphaType.UNPREMUL,
        editable: true // make it editable so we can writeBufferToPixels
      };
      const pm = await image.createPixelMap(buf, opts);
      this.pm = pm as image.PixelMap;
      this.pmVersion++;
    } catch (e) {
      console.error('Failed to create PixelMap', e);
    } finally {
      this.creatingPm = false;
    }
  }

  private async updatePixelMap(): Promise<void> {
    if (!this.pm) return;
    const buf: ArrayBuffer | null = (vnc as VncClient).copyFrameRGBA?.(this.debugByteOrder) ?? null;
    if (!buf) return;

    if (this.debugEnabled) {
      try {
        const view = new Uint8Array(buf);
        if (view.length >= 4) {
          this.firstPixel = `Pixel: ${view[0]},${view[1]},${view[2]},${view[3]}`;
        }
      } catch (e) {
      }
    }

    try {
      const opts: image.InitializationOptions = {
        size: { width: this.fbW, height: this.fbH },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        alphaType: image.AlphaType.UNPREMUL,
        editable: true
      };
      const newPm = await image.createPixelMap(buf, opts);
      const oldPm = this.pm;
      this.pm = newPm as image.PixelMap;
      this.pmVersion++;
      if (oldPm) {
        setTimeout(() => {
          try { oldPm.release(); } catch (e) {}
        }, 100);
      }
    } catch (e) {
      console.error('Failed to update pixelmap', e);
    }
  }

  private async bootstrapFirstFrame(): Promise<void> {
    this.debugByteOrder = 0;
    this.debugPmFormat = 1; // 1 = swap R/B (BGRA) for correct colors on RGBA_8888
    (vnc as VncClient).setDebugOptions?.(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
    (vnc as VncClient).refresh?.();
    for (let i = 0; i < 4; i++) {
      const prc = (vnc as VncClient).process?.() ?? -1;
      if (prc !== 0) {
        this.lastError = ((vnc as VncClient).getLastError?.() as string) ?? '';
        this.disconnect(true);
        this.toast(this.lastError || '连接失败');
        return;
      }
    }
    await this.ensurePixelMap();
  }

  private async tick(): Promise<void> {
    if (!this.connected) return;
    if (this.ticking) return;
    this.ticking = true;
    try {
      const now = Date.now();
      this.refreshFramebufferInfo();
      
      const prc = (vnc as VncClient).process?.() ?? -1;
      if (prc !== 0) {
        this.lastError = ((vnc as VncClient).getLastError?.() as string) ?? '';
        this.disconnect(true);
        this.toast(this.lastError || '连接已断开');
        return;
      }

      const dmg = (vnc as VncClient).consumeDamage?.() ?? null;

      if (!this.pm) {
        await this.ensurePixelMap();
      } else if (dmg) {
        await this.updatePixelMap();
      }

      this.lastError = ((vnc as VncClient).getLastError?.() as string) ?? '';

      if (this.debugEnabled) {
        if (now - this.lastDebugTs > 500) {
          this.lastDebugTs = now;
          const info = (vnc as VncClient).getDebugInfo?.() as VncDebugInfo;
          const log = ((vnc as VncClient).getDebugLog?.(false) as string) ?? '';
          const p00 = info?.p00 ?? [];
          const pc = info?.pCenter ?? [];
          const pd = info?.pendingDamage ?? null;
          const pdText = pd ? `${pd.x},${pd.y} ${pd.w}x${pd.h}` : '-';
          this.debugInfoText =
            `proc#${info?.processCount ?? 0} rc=${info?.lastProcessRc ?? 0} upd#${info?.fbUpdateCount ?? 0} ` +
            `lastUpd=${info?.lastUpdateX ?? 0},${info?.lastUpdateY ?? 0} ${info?.lastUpdateW ?? 0}x${info?.lastUpdateH ?? 0} ` +
            `pending=${pdText} checksum=${info?.checksum ?? 0} ` +
            `p00=[${p00.join(',')}] pc=[${pc.join(',')}]`;
          this.debugLogText = log.length > 6000 ? log.slice(log.length - 6000) : log;
        }
      }
    } finally {
      this.ticking = false;
    }
  }

  private startLoop(): void {
    if (this.timerId !== -1) return;
    this.timerId = setInterval(() => { void this.tick(); }, 16);
  }

  private stopLoop(): void {
    if (this.timerId === -1) return;
    clearInterval(this.timerId);
    this.timerId = -1;
  }

  private requestInputFocus(): void {
    try {
      const fc = this.getUIContext()?.getFocusController?.();
      fc?.setKeyProcessingMode?.(KeyProcessingMode.ANCESTOR_EVENT);
      fc?.requestFocus?.(this.inputLayerKey);
    } catch (e) {
    }
  }

  private async connect(): Promise<void> {
    if (this.connecting) return;
    this.connecting = true;
    this.lastError = '';
    this.didAdoptServerName = false;

    await new Promise<void>((resolve) => setTimeout(resolve, 0));

    try {
      this.saveSelectedName();
      const parsed = parseAddress(this.address);
      if (!parsed) {
        this.toast('地址格式不正确，例如 192.168.1.2:5900 或 [::1]:5900');
        return;
      }
      (vnc as VncClient).setDebugOptions?.(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
      const rc = (await (vnc as VncClient).connect?.(parsed.host, parsed.port, this.user, this.password)) ?? -1;
      this.connected = (rc === 0);
      this.pm = undefined;
      this.lastMask = 0;
      this.refreshFramebufferInfo();
      this.maybeAdoptServerNameAsConnName();
      this.lastError = ((vnc as VncClient).getLastError?.() as string) ?? '';
      if (!this.connected) {
        this.toast(this.lastError || '连接失败');
        return;
      }
      this.touchConnectionUsed();
      await this.bootstrapFirstFrame();
      if (!this.connected) return;
      this.refreshFramebufferInfo();
      this.maybeAdoptServerNameAsConnName();
      if (this.windowW < 900) {
        this.showPanel = false;
        if (!this.didShowPanelGestureHint) {
          this.didShowPanelGestureHint = true;
          this.toast('已进入全屏视图：从左侧边缘右滑可打开连接面板');
        }
      }
      this.startLoop();
      setTimeout(() => this.requestInputFocus(), 0);
    } catch (e) {
      this.connected = false;
      this.pm = undefined;
      const msg = (e as Error)?.message;
      this.lastError = msg ?? '连接失败';
      this.toast(this.lastError);
    } finally {
      this.connecting = false;
    }
  }

  private setDevToolsEnabled(enable: boolean): void {
    this.devToolsEnabled = enable;
    if (!enable) {
      this.debugEnabled = false;
      this.debugInfoText = '';
      this.debugLogText = '';
      this.firstPixel = '';
      (vnc as VncClient).setDebugOptions?.(false, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
    } else {
      (vnc as VncClient).setDebugOptions?.(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
    }
  }

  private getPanelBarTitle(): string {
    if (this.connected) return '已连接';
    const c = this.getSelectedConnection();
    if (!c) return '快速连接';
    return normalizeConnName(c.name, c.address, c.sshTunnel);
  }

  private getPanelBarSubtitle(): string {
    const addr = resolveConnectionAddress(this.address, this.getSelectedConnection()?.sshTunnel);
    if (addr) return addr;
    const c = this.getSelectedConnection();
    return resolveConnectionAddress(c?.address ?? '', c?.sshTunnel) || '填写地址并连接，例如 192.168.1.2:5900';
  }

  private disconnect(preserveError: boolean = false): void {
    this.stopLoop();
    (vnc as VncClient).disconnect?.();
    this.connected = false;
    this.connecting = false;
    this.ticking = false;
    this.didAdoptServerName = false;
    if (this.pm) {
      try { this.pm.release(); } catch (e) {}
    }
    this.pm = undefined;
    this.pmVersion = 0;
    this.lastMask = 0;
    this.fbW = 0;
    this.fbH = 0;
    this.fbStride = 0;
    if (!preserveError) this.lastError = '';
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

    const scale = Math.min(this.viewerW / this.fbW, this.viewerH / this.fbH);
    const contentW = this.fbW * scale;
    const contentH = this.fbH * scale;
    const offsetX = (this.viewerW - contentW) / 2;
    const offsetY = (this.viewerH - contentH) / 2;

    this.lastX = x;
    this.lastY = y;

    const localX = (x - offsetX) / scale;
    const localY = (y - offsetY) / scale;

    const rx = Math.max(0, Math.min(this.fbW - 1, Math.floor(localX)));
    const ry = Math.max(0, Math.min(this.fbH - 1, Math.floor(localY)));
    return new RemotePoint(rx, ry);
  }

  private async saveImage(): Promise<void> {
    if (!this.pm) {
      this.toast('没有图像数据');
      return;
    }
    try {
      const context = this.getHostContext();
      if (!context) return;
      const buf: ArrayBuffer | null = (vnc as VncClient).copyFrameRGBA?.(this.debugByteOrder) ?? null;
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
      this.toast(`已保存: ${path}`);
    } catch (e) {
      console.error('Failed to save image', e);
      this.toast(`保存失败: ${e}`);
    }
  }

  @Builder
  private buildControls(): void {
    Column() {
      Row() {
        Text('连接')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1);
        Button('新增')
          .height(32)
          .fontSize(12)
          .fontColor(this.cPrimary)
          .backgroundColor(this.cSurfaceAlt)
          .border({ width: 1, color: this.cBorder })
          .borderRadius(12)
          .enabled(!this.connected)
          .onClick(() => this.openCreateDialog());
        Text('收起')
          .fontSize(12)
          .fontColor(this.cTextSecondary)
          .margin({ left: 12 })
          .onClick(() => {
            this.showPanel = false;
            if (this.connected && !this.didShowPanelGestureHint) {
              this.didShowPanelGestureHint = true;
              this.toast('从左侧边缘右滑可打开连接面板');
            }
          });
      }
      .padding({ left: 12, right: 12, top: 12, bottom: 8 });

      if (this.connections.length === 0) {
        Text('暂无已保存连接。点击“新增连接”添加，或直接在下方输入地址连接。')
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
                    Text(((c.name ?? '').trim()) ? (c.name ?? '').trim() : (c.address ?? ''))
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
                        Text(`账号: ${(c.user ?? '').trim()}`).fontSize(12).fontColor(this.cTextSecondary).margin({ left: ((c.name ?? '').trim()) ? 8 : 0 });
                      }
                      if (c.storePassword && (c.password ?? '').length > 0) {
                        Text('已保存密码').fontSize(12).fontColor(this.cTextSecondary).margin({ left: 8 });
                      }
                    }.margin({ top: 2 });
                  }.layoutWeight(1);
                  if (!this.connected && c.id === this.selectedConnId) {
                    Text('编辑/删除')
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
        Text('快速连接')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1);
        Button(this.authOpen ? '收起认证' : '连接认证')
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
        Text('地址（直连时填写）')
          .fontSize(12)
          .fontColor(this.cTextSecondary)
          .width('100%')
          .padding({ bottom: 4 });
        TextInput({ text: this.address, placeholder: '例如 192.168.1.2:5900；SSH 隧道时可留空' })
          .onChange((v: string) => this.address = v)
          .enabled(!this.connected)
          .padding({ bottom: 8 });

        if (this.authOpen) {
          Text('账号（可选）')
            .fontSize(12)
            .fontColor(this.cTextSecondary)
            .width('100%')
            .padding({ bottom: 4 });
          TextInput({ text: this.user, placeholder: '账号' })
            .onChange((v: string) => this.user = v)
            .enabled(!this.connected)
            .padding({ bottom: 8 });

          Text('密码（可选）')
            .fontSize(12)
            .fontColor(this.cTextSecondary)
            .width('100%')
            .padding({ bottom: 4 });
          TextInput({ text: this.password, placeholder: '密码' })
            .type(InputType.Password)
            .onChange((v: string) => this.password = v)
            .enabled(!this.connected)
            .padding({ bottom: 8 });
          if (this.selectedConnId) {
            Row() {
              Text('记住密码')
                .fontSize(12)
                .fontColor(this.cTextSecondary)
                .layoutWeight(1);
              BrandSwitch({ isOn: this.isSelectedStorePasswordEnabled(), isEnabled: !this.connected, onChange: (next: boolean) => {
                if (next !== this.isSelectedStorePasswordEnabled()) this.toggleSelectedStorePassword();
              }});
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
        Button(this.connected ? '断开连接' : (this.connecting ? '连接中…' : '连接'))
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
            else void this.connect();
          });
      }
      .padding({ left: 12, right: 12, bottom: 12 });

      if (this.connected) {
        Row() {
          Text(`已连接 ${this.fbW}x${this.fbH}`)
            .fontSize(12)
            .fontColor(this.cTextSecondary)
            .layoutWeight(1);
          Button(this.devToolsEnabled ? '开发者工具:开' : '开发者工具:关')
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
            Button(this.debugEnabled ? '调试:开' : '调试:关')
              .fontSize(12)
              .height(28)
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => {
                this.debugEnabled = !this.debugEnabled;
                (vnc as VncClient).setDebugOptions?.(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
                if (!this.debugEnabled) {
                  this.debugInfoText = '';
                  this.debugLogText = '';
                  this.firstPixel = '';
                }
              });
            Button(`格式:${this.debugPmFormat === 0 ? 'RGBA' : 'ARGB'}`)
              .fontSize(12)
              .height(28)
              .margin({ left: 6 })
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => {
                this.debugPmFormat = (this.debugPmFormat + 1) % 2;
                (vnc as VncClient).setDebugOptions?.(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
                this.pm = undefined;
                void this.ensurePixelMap();
              });
            Button(`顺序:${this.debugByteOrder}`)
              .fontSize(12)
              .height(28)
              .margin({ left: 6 })
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => {
                this.debugByteOrder = (this.debugByteOrder + 1) % 4;
                (vnc as VncClient).setDebugOptions?.(this.debugEnabled, this.debugLevel, this.debugByteOrder, this.debugPmFormat);
                this.pm = undefined;
                void this.ensurePixelMap();
              });
          }.padding({ left: 12, right: 12, bottom: 8 });

          Row() {
            Button('刷新画面')
              .fontSize(12)
              .height(28)
              .layoutWeight(1)
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => (vnc as VncClient).refresh?.());
            Button('存图')
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
  private buildRouteStepChip(label: string, highlighted: boolean = false): void {
    Text(label)
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(highlighted ? this.cPrimary : this.cTextSecondary)
      .backgroundColor(highlighted ? this.cPrimarySoft : this.cSurfaceAlt)
      .border({ width: 1, color: highlighted ? this.cPrimaryOutline : this.cBorder })
      .borderRadius(999)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 });
  }

  @Builder
  private buildRoutePreview(routeLabel: string, vncTarget: string, sshServer: string): void {
    Column() {
      Row() {
        Column() {
          Text('当前连接方式')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.cPrimary)
            .width('100%');
          Text(routeLabel === 'SSH 隧道' ? '经 SSH 安全连接' : '直接连接')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.cTextPrimary)
            .width('100%')
            .padding({ top: 2 });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        Text(routeLabel)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.cPrimary)
          .backgroundColor(this.cSurfaceAlt)
          .border({ width: 1, color: this.cPrimaryOutline })
          .borderRadius(999)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Text(routeLabel === 'SSH 隧道' ? `先连接 SSH ${sshServer}，再转发到 ${vncTarget}` : `本机直接访问 ${vncTarget}`)
        .fontSize(11)
        .lineHeight(16)
        .fontColor(this.cTextSecondary)
        .width('100%')
        .padding({ top: 4 });
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.cPrimarySoft)
    .borderRadius(16);
  }

  @Builder
  private buildInheritedFieldCard(label: string, value: string, supportingText: string, missing: boolean = false): void {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.cPrimary)
        .width('100%');
      Text(value)
        .fontSize(13)
        .lineHeight(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(missing ? this.cTextTertiary : this.cTextPrimary)
        .width('100%');
      Text(supportingText)
        .fontSize(11)
        .lineHeight(16)
        .fontColor(this.cTextSecondary)
        .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(this.cPrimarySoft)
    .border({ width: 1, color: this.cPrimaryOutline })
    .borderRadius(14)
    .margin({ bottom: 8 });
  }

  @Builder
  private buildEditAdvancedSection(): void {
    Column() {
      Column() {
        Text('触控滚动')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.cTextPrimary)
          .width('100%')
          .padding({ bottom: 4 });
        Text('调整触摸滚动步长。')
          .fontSize(11)
          .lineHeight(16)
          .fontColor(this.cTextSecondary)
          .width('100%')
          .padding({ bottom: 10 });
        Text('触摸滚动步长')
          .fontSize(12)
          .fontColor(this.cTextSecondary)
          .width('100%')
          .padding({ bottom: 6 });
        Row() {
          Button('自动')
            .height(28)
            .fontSize(12)
            .fontColor(this.editTouchScrollStep <= 0 ? this.cPrimaryFg : this.cPrimary)
            .backgroundColor(this.editTouchScrollStep <= 0 ? this.cPrimary : this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(12)
            .onClick(() => this.updateEditTouchScrollStep(0));
          Button('慢')
            .height(28)
            .fontSize(12)
            .margin({ left: 6 })
            .fontColor(this.editTouchScrollStep === 18 ? this.cPrimaryFg : this.cPrimary)
            .backgroundColor(this.editTouchScrollStep === 18 ? this.cPrimary : this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(12)
            .onClick(() => this.updateEditTouchScrollStep(18));
          Button('中')
            .height(28)
            .fontSize(12)
            .margin({ left: 6 })
            .fontColor(this.editTouchScrollStep === 12 ? this.cPrimaryFg : this.cPrimary)
            .backgroundColor(this.editTouchScrollStep === 12 ? this.cPrimary : this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(12)
            .onClick(() => this.updateEditTouchScrollStep(12));
          Button('快')
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
        Text(this.editTouchScrollStep <= 0 ? '当前：自动（按系统自适应）' : `当前：${this.editTouchScrollStep}px`)
          .fontSize(11)
          .fontColor(this.cTextTertiary)
          .width('100%')
          .padding({ top: 6 });
      }
      .width('100%')
      .padding(12)
      .backgroundColor(this.cSurfaceAlt)
      .border({ width: 1, color: this.cBorder })
      .borderRadius(16)
      .margin({ bottom: 12 });

      Column() {
        Text('SSH 隧道')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.cTextPrimary)
          .width('100%')
          .padding({ bottom: 4 });
        Text(this.editSshEnabled
          ? '通过 SSH 服务器转发到桌面时，在这里配置。'
          : '只有通过堡垒机、跳板机或内网隧道访问时，才需要开启。')
          .fontSize(11)
          .lineHeight(16)
          .fontColor(this.cTextSecondary)
          .width('100%')
          .padding({ bottom: 10 });

        Row() {
          Column() {
            Text(this.editSshEnabled ? '已开启 SSH 隧道' : '直接连接')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.editSshEnabled ? this.cPrimary : this.cTextPrimary)
              .width('100%');
            Text(this.editSshEnabled ? '先连接 SSH 服务器，再转发到目标桌面。' : '默认直接连接目标桌面，需要时再开启 SSH。')
              .fontSize(11)
              .lineHeight(16)
              .fontColor(this.cTextSecondary)
              .width('100%')
              .padding({ top: 2 });
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start);
          BrandSwitch({
            isOn: this.editSshEnabled,
            isEnabled: true,
            onChange: (next: boolean) => this.toggleEditSshEnabled(next)
          });
        }
        .padding({ bottom: 10 });
        if (this.editSshEnabled) {
          TextInput({ text: this.editSshHost, placeholder: 'SSH 服务器，例如 bastion.example.com' })
            .onChange((v: string) => this.editSshHost = v)
            .padding({ bottom: 8 });

          if (this.editSshReuseDesktopUser) {
            this.buildInheritedFieldCard(
              'SSH 用户名',
              (this.editUser ?? '').trim() ? `跟随基本页账号：${(this.editUser ?? '').trim()}` : '等待复用基本页中的桌面用户名',
              (this.editUser ?? '').trim()
                ? '当前字段由基本页“账号”接管；关闭上方复用开关后可单独填写。'
                : '当前字段由基本页“账号”接管；先在基本页填写后，这里会自动同步。',
              (this.editUser ?? '').trim().length === 0
            );
          } else {
            TextInput({ text: this.editSshUser, placeholder: 'SSH 用户名' })
              .onChange((v: string) => this.editSshUser = v)
              .padding({ bottom: 8 });
          }

          Row() {
            Text(this.isReusingEditDesktopCredentials() ? '重用桌面账号密码' : '单独填写 SSH 账号信息')
              .fontSize(12)
              .fontColor(this.cTextSecondary)
              .layoutWeight(1);
            BrandSwitch({
              isOn: this.isReusingEditDesktopCredentials(),
              isEnabled: true,
              onChange: (next: boolean) => this.setEditSshReuseDesktopCredentials(next)
            });
          }
          .padding({ bottom: 8 });

          Text(this.isReusingEditDesktopCredentials()
            ? (this.editSshAuthType === SSH_AUTH_PUBLIC_KEY
              ? ((this.editUser ?? '').trim() ? `当前复用基本页中的桌面用户名：${(this.editUser ?? '').trim()}` : '请先在基本页填写桌面用户名。')
              : ((this.editUser ?? '').trim()
                ? `当前复用基本页中的桌面账号；用户名：${(this.editUser ?? '').trim()}`
                : '请先在基本页填写桌面用户名和密码。'))
            : 'SSH 账号信息可以与桌面账号不同。')
            .fontSize(11)
            .lineHeight(16)
            .fontColor(this.cTextTertiary)
            .width('100%')
            .padding({ bottom: 8 });

          Text('登录方式')
            .fontSize(12)
            .fontColor(this.cTextSecondary)
            .width('100%')
            .padding({ bottom: 6 });
          Row() {
            Button('密码登录')
              .height(28)
              .fontSize(12)
              .fontColor(this.editSshAuthType === SSH_AUTH_PASSWORD ? this.cPrimaryFg : this.cPrimary)
              .backgroundColor(this.editSshAuthType === SSH_AUTH_PASSWORD ? this.cPrimary : this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => this.setEditSshAuthType(SSH_AUTH_PASSWORD));
            Button('密钥登录')
              .height(28)
              .fontSize(12)
              .margin({ left: 6 })
              .fontColor(this.editSshAuthType === SSH_AUTH_PUBLIC_KEY ? this.cPrimaryFg : this.cPrimary)
              .backgroundColor(this.editSshAuthType === SSH_AUTH_PUBLIC_KEY ? this.cPrimary : this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(12)
              .onClick(() => this.setEditSshAuthType(SSH_AUTH_PUBLIC_KEY));
          }
          .width('100%')
          .padding({ bottom: 8 });

          if (this.editSshAuthType === SSH_AUTH_PUBLIC_KEY) {
            TextInput({ text: this.editSshPrivateKeyPath, placeholder: '私钥路径，例如 /data/storage/el2/base/files/id_ed25519' })
              .onChange((v: string) => this.editSshPrivateKeyPath = v)
              .padding({ bottom: 8 });
            TextInput({ text: this.editSshPrivateKeyPassphrase, placeholder: '私钥口令（可选）' })
              .type(InputType.Password)
              .onChange((v: string) => this.editSshPrivateKeyPassphrase = v)
              .padding({ bottom: 8 });
          } else {
            if (this.editSshReuseDesktopPassword) {
              this.buildInheritedFieldCard(
                'SSH 密码',
                (this.editPassword ?? '') ? '已复用基本页中的桌面密码' : '等待复用基本页中的桌面密码',
                (this.editPassword ?? '')
                  ? '当前字段由基本页“密码”接管；关闭上方复用开关后可单独填写。'
                  : '当前字段由基本页“密码”接管；先在基本页填写后，这里会自动同步。',
                (this.editPassword ?? '').length === 0
              );
            } else {
              TextInput({ text: this.editSshPassword, placeholder: 'SSH 密码' })
                .type(InputType.Password)
                .onChange((v: string) => this.editSshPassword = v)
                .padding({ bottom: 8 });
            }
            Text(this.editSshReuseDesktopPassword
              ? ((this.editPassword ?? '') ? 'SSH 密码跟随基本页中的桌面密码。' : '请先在基本页填写桌面密码。')
              : '如果 SSH 使用独立密码，可单独填写。')
              .fontSize(11)
              .lineHeight(16)
              .fontColor(this.cTextTertiary)
              .width('100%')
              .padding({ bottom: 8 });
          }

          TextInput({ text: this.editSshPortText, placeholder: 'SSH 端口' })
            .type(InputType.Number)
            .onChange((v: string) => this.editSshPortText = v)
            .padding({ bottom: 8 });

          if (this.editSshAuthType === SSH_AUTH_PUBLIC_KEY) {
            TextInput({ text: this.editSshPublicKeyPath, placeholder: '公钥路径（可选）' })
              .onChange((v: string) => this.editSshPublicKeyPath = v)
              .padding({ bottom: 8 });
          }

          Row() {
            Text('严格校验主机指纹')
              .fontSize(12)
              .fontColor(this.cTextSecondary)
              .layoutWeight(1);
            BrandSwitch({
              isOn: this.editSshStrictHostKeyCheck,
              isEnabled: true,
              onChange: (next: boolean) => this.editSshStrictHostKeyCheck = next
            });
          }
          .padding({ bottom: 8 });

          if (this.editSshStrictHostKeyCheck || !!(this.editSshKnownHostsPath ?? '').trim()) {
            TextInput({ text: this.editSshKnownHostsPath, placeholder: 'known_hosts 路径（开启严格校验时必填）' })
              .onChange((v: string) => this.editSshKnownHostsPath = v)
              .padding({ bottom: 8 });
          }

          Text('单独指定桌面目标')
            .fontSize(12)
            .fontColor(this.cTextSecondary)
            .width('100%')
            .padding({ bottom: 6 });
          Text('默认预填为远端 127.0.0.1。只有需要从 SSH 服务器再转发到其他内网主机时，才修改这里。')
            .fontSize(11)
            .lineHeight(16)
            .fontColor(this.cTextTertiary)
            .width('100%')
            .padding({ bottom: 8 });
          Row() {
            TextInput({ text: this.editSshRemoteHost, placeholder: '默认预填 127.0.0.1；需要其他内网主机时再修改' })
              .onChange((v: string) => this.editSshRemoteHost = v)
              .layoutWeight(1);
            TextInput({ text: this.editSshRemotePortText, placeholder: '端口' })
              .type(InputType.Number)
              .onChange((v: string) => this.editSshRemotePortText = v)
              .width(96)
              .margin({ left: 8 });
          }
          .width('100%');
        } else {
          Text('开启 SSH 后，这里会出现服务器、认证方式、端口、安全校验和目标覆盖等设置。')
            .fontSize(11)
            .lineHeight(16)
            .fontColor(this.cTextSecondary)
            .width('100%');
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor(this.cSurfaceAlt)
      .border({ width: 1, color: this.cBorder })
      .borderRadius(16);
    }
    .width('100%');
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
            Text(this.editId ? '编辑连接' : '新增连接')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1);
            Button('关闭')
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
            this.buildRoutePreview(
              this.getRouteLabelForAddress(this.editAddress, this.getEditPreviewSshConfig()),
              this.getVncTargetForAddress(this.editAddress, this.getEditPreviewSshConfig()),
              this.getSshServerForAddress(this.editAddress, this.getEditPreviewSshConfig())
            );

            Row() {
              Button('基本')
                .layoutWeight(1)
                .height(32)
                .fontSize(12)
                .fontColor(this.editTabIndex === EDIT_TAB_BASIC ? this.cPrimaryFg : this.cPrimary)
                .backgroundColor(this.editTabIndex === EDIT_TAB_BASIC ? this.cPrimary : this.cSurfaceAlt)
                .border({ width: 1, color: this.cBorder })
                .borderRadius(14)
                .onClick(() => this.editTabIndex = EDIT_TAB_BASIC);
              Button(this.hasAnyEditAdvancedOptions() ? '高级（已配置）' : '高级')
                .layoutWeight(1)
                .height(32)
                .margin({ left: 8 })
                .fontSize(12)
                .fontColor(this.editTabIndex === EDIT_TAB_ADVANCED ? this.cPrimaryFg : this.cPrimary)
                .backgroundColor(this.editTabIndex === EDIT_TAB_ADVANCED ? this.cPrimary : this.cSurfaceAlt)
                .border({ width: 1, color: this.cBorder })
                .borderRadius(14)
                .onClick(() => this.editTabIndex = EDIT_TAB_ADVANCED);
            }
            .padding({ left: 14, right: 14, top: 12, bottom: 10 })
            .width('100%');

            List({ space: 0 }) {
              ListItem() {
                Column() {
                  if (this.editTabIndex === EDIT_TAB_BASIC) {
                    Column() {
                      Text('远程桌面')
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.cTextPrimary)
                        .width('100%')
                        .padding({ bottom: 4 });
                      Text(this.editSshEnabled
                        ? '这里填写最终要访问的桌面地址。启用 SSH 时，如果不单独覆盖目标，会默认使用这里的地址。'
                        : '填写要连接的桌面地址和常用登录信息。')
                        .fontSize(11)
                        .lineHeight(16)
                        .fontColor(this.cTextSecondary)
                        .width('100%')
                        .padding({ bottom: 10 });

                      Text('连接名称（可选）')
                        .fontSize(12)
                        .fontColor(this.cTextSecondary)
                        .width('100%')
                        .padding({ bottom: 4 });
                      TextInput({ text: this.editName, placeholder: '例如 办公室电脑' })
                        .onChange((v: string) => this.editName = v)
                        .padding({ bottom: 10 });

                      Text('桌面地址')
                        .fontSize(12)
                        .fontColor(this.cTextSecondary)
                        .width('100%')
                        .padding({ bottom: 4 });
                      TextInput({
                        text: this.editAddress,
                        placeholder: this.editSshEnabled
                          ? '例如 192.168.1.2:5900；不单独指定目标时会使用这里'
                          : '例如 192.168.1.2:5900'
                      })
                        .onChange((v: string) => this.editAddress = v)
                        .padding({ bottom: 10 });

                      Text('桌面用户名（可选）')
                        .fontSize(12)
                        .fontColor(this.cTextSecondary)
                        .width('100%')
                        .padding({ bottom: 4 });
                      TextInput({ text: this.editUser, placeholder: '桌面用户名' })
                        .onChange((v: string) => this.updateEditUser(v))
                        .padding({ bottom: 10 });

                      Text('桌面密码（可选）')
                        .fontSize(12)
                        .fontColor(this.cTextSecondary)
                        .width('100%')
                        .padding({ bottom: 4 });
                      TextInput({ text: this.editPassword, placeholder: '桌面密码（可选）' })
                        .type(InputType.Password)
                        .onChange((v: string) => this.updateEditPassword(v))
                        .padding({ bottom: 10 });

                      Row() {
                        Text('保存桌面密码')
                          .fontSize(12)
                          .fontColor(this.cTextSecondary)
                          .layoutWeight(1);
                        BrandSwitch({ isOn: this.editStorePassword, isEnabled: true, onChange: (next: boolean) => this.editStorePassword = next });
                      }
                      .padding({ bottom: 4 });
                    }
                    .width('100%')
                    .padding(12)
                    .backgroundColor(this.cSurfaceAlt)
                    .border({ width: 1, color: this.cBorder })
                    .borderRadius(16)
                    .margin({ bottom: 12 });
                  } else {
                    this.buildEditAdvancedSection();
                  }
                }
                .width('100%')
                .padding({ left: 14, right: 14, bottom: 14 });
              }
            }
            .layoutWeight(1)
            .width('100%')
            .divider({ strokeWidth: 0 })
            .edgeEffect(EdgeEffect.Spring);
          }
          .layoutWeight(1)
          .width('100%');

          Row() {
            Button('取消')
              .layoutWeight(1)
              .height(36)
              .fontColor(this.cPrimary)
              .backgroundColor(this.cSurfaceAlt)
              .border({ width: 1, color: this.cBorder })
              .borderRadius(14)
              .onClick(() => this.closeEditDialog());
            Button('保存')
              .layoutWeight(1)
              .height(36)
              .margin({ left: 10 })
              .fontColor(this.cPrimaryFg)
              .backgroundColor(this.cPrimary)
              .borderRadius(14)
              .onClick(() => { void this.saveEditDialog(); });
          }
          .padding({ left: 14, right: 14, bottom: 14, top: 10 });
        }
        .width('100%')
        .height('88%')
        .constraintSize({ maxWidth: 460 })
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

  @State private editTouchScrollStep: number = 0;

  private normalizeTouchScrollStep(step: number): number {
    if (!Number.isFinite(step)) return 0;
    const v = Math.floor(step);
    if (v <= 0) return 0;
    return Math.max(4, Math.min(48, v));
  }

  private updateEditTouchScrollStep(step: number): void {
    this.editTouchScrollStep = this.normalizeTouchScrollStep(step);
  }

  @Builder
  private buildViewer(): void {
    Stack() {
      if (this.pm) {
        Image(this.pm)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height('100%')
          .opacity(this.pmVersion % 2 === 0 ? 1 : 0.999)
        Column() {
        }
          .id(this.inputLayerKey)
          .width('100%')
          .height('100%')
          .opacity(0.001)
          .focusable(true)
          .defaultFocus(true)
          .onAppear(() => {
            if (!this.connected) return;
            this.requestInputFocus();
          })
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.viewerW = (newValue.width as number) ?? 1;
            this.viewerH = (newValue.height as number) ?? 1;
          })
          .onTouch((ev: TouchEvent) => {
            const t = ev?.touches?.[0] ?? ev?.changedTouches?.[0];
            const type = ev?.type;
            const localX = t?.x ?? 0;
            const localY = t?.y ?? 0;
            this.lastX = localX;
            this.lastY = localY;
            if (!this.showPanel) {
              if (type === TouchType.Down && localX <= 10) {
                this.edgeSwipeActive = true;
                this.edgeSwipeStartX = localX;
                this.edgeSwipeStartY = localY;
                return;
              }
              if (type === TouchType.Move && this.edgeSwipeActive) {
                const dx = localX - this.edgeSwipeStartX;
                const dy = Math.abs(localY - this.edgeSwipeStartY);
                if (dx >= 40 && dy <= 30) {
                  this.edgeSwipeActive = false;
                  this.showPanel = true;
                  return;
                }
                if (dy >= 50 || localX >= 80) {
                  this.edgeSwipeActive = false;
                  return;
                }
                return;
              }
              if ((type === TouchType.Up || type === TouchType.Cancel) && this.edgeSwipeActive) {
                this.edgeSwipeActive = false;
                return;
              }
            }
          })
      } else {
        Text(this.connected ? '正在等待首帧…' : '未连接')
          .fontSize(14)
          .fontColor(this.cOnInk);
      }
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor(this.cInk)
    .margin({ left: 12, right: 12, bottom: 12 })
    .borderRadius(8)
    .clip(true);
  }

  private getFilteredConnections(): ConnectionItem[] {
    const all = this.connections ?? [];
    const kw = (this.keyword ?? '').trim().toLowerCase();
    if (!kw) return all;
    const out: ConnectionItem[] = [];
    for (let i = 0; i < all.length; i++) {
      const c = all[i];
      const name = normalizeConnName(c?.name ?? '', c?.address ?? '', c?.sshTunnel).toLowerCase();
      const addr = resolveConnectionAddress(c?.address ?? '', c?.sshTunnel).toLowerCase();
      const user = (c?.user ?? '').toLowerCase();
      if (name.indexOf(kw) !== -1 || addr.indexOf(kw) !== -1 || user.indexOf(kw) !== -1) {
        out.push(c);
      }
    }
    return out;
  }

  private scheduleScrollToConnection(id: string): void {
    if (!id) return;
    setTimeout(() => {
      const list = this.getFilteredConnections();
      const index = list.findIndex((item: ConnectionItem) => item.id === id);
      if (index < 0) return;
      try {
        this.connectionListScroller.scrollToIndex(index);
      } catch (e) {
      }
    }, 0);
  }

  private getKeyboardTargetConnection(): ConnectionItem | null {
    const list = this.getFilteredConnections();
    if (list.length === 0) return null;
    const currentId = this.selectedConnId ?? '';
    const current = list.find((item: ConnectionItem) => item.id === currentId);
    if (current) return current;
    return list[0] ?? null;
  }

  private openSelectedConnectionFromKeyboard(): boolean {
    const target = this.getKeyboardTargetConnection();
    if (!target) return false;
    if (target.id !== this.selectedConnId) {
      this.selectConnection(target.id);
    }
    void this.openViewerWindow(target);
    return true;
  }

  private deleteSelectedConnectionFromKeyboard(): boolean {
    const target = this.getKeyboardTargetConnection();
    if (!target) return false;
    if (target.id !== this.selectedConnId) {
      this.selectConnection(target.id);
    }
    void this.deleteConnection(target.id);
    return true;
  }

  private moveConnectionSelection(step: number): boolean {
    const list = this.getFilteredConnections();
    if (list.length === 0) return false;
    const currentId = this.selectedConnId ?? '';
    const currentIndex = list.findIndex((item: ConnectionItem) => item.id === currentId);
    let nextIndex = currentIndex;
    if (currentIndex < 0) {
      nextIndex = step >= 0 ? 0 : list.length - 1;
    } else {
      nextIndex = Math.max(0, Math.min(list.length - 1, currentIndex + step));
    }
    const next = list[nextIndex];
    if (!next?.id) return false;
    if (next.id !== currentId) {
      this.selectConnection(next.id);
    }
    return true;
  }

  private handleConnectionListKeyEvent(ev: KeyEvent): boolean {
    if (this.editOpen || this.aboutOpen || this.agreementDialogMode !== AGREEMENT_DIALOG_NONE) return false;
    const code = ev?.keyCode ?? 0;
    if (ev?.type === KeyType.Down && (code === KeyCode.KEYCODE_DPAD_UP || code === 19)) {
      return this.moveConnectionSelection(-1);
    }
    if (ev?.type === KeyType.Down && (code === KeyCode.KEYCODE_DPAD_DOWN || code === 20)) {
      return this.moveConnectionSelection(1);
    }
    if (ev?.type === KeyType.Up &&
      (code === KeyCode.KEYCODE_ENTER || code === 66 || code === KeyCode.KEYCODE_NUMPAD_ENTER)) {
      return this.openSelectedConnectionFromKeyboard();
    }
    if (ev?.type === KeyType.Up &&
      (code === KeyCode.KEYCODE_DEL || code === 67 || code === KeyCode.KEYCODE_FORWARD_DEL || code === 112)) {
      return this.deleteSelectedConnectionFromKeyboard();
    }
    return false;
  }

  private formatLastUsed(ts: number): string {
    const v = ts ?? 0;
    if (!v || !Number.isFinite(v)) return '从未连接';
    try {
      const d = new Date(v);
      const y = d.getFullYear();
      const m = `${d.getMonth() + 1}`.padStart(2, '0');
      const day = `${d.getDate()}`.padStart(2, '0');
      const hh = `${d.getHours()}`.padStart(2, '0');
      const mm = `${d.getMinutes()}`.padStart(2, '0');
      return `上次连接 ${y}-${m}-${day} ${hh}:${mm}`;
    } catch (e) {
      return '上次连接 -';
    }
  }

  private formatDisplayHostPort(host: string, port: number): string {
    const trimmedHost = (host ?? '').trim();
    if (!trimmedHost) return '未填写';
    const displayHost = trimmedHost.includes(':') && !trimmedHost.startsWith('[') ? `[${trimmedHost}]` : trimmedHost;
    return `${displayHost}:${port}`;
  }

  private getNormalizedSshForAddress(address: string, sshTunnel?: SshTunnelConfig): SshTunnelConfig {
    return normalizeSshTunnelConfigForAddress(sshTunnel, address ?? '');
  }

  private getEditPreviewSshConfig(): SshTunnelConfig {
    const parsed = parseAddress(this.editAddress ?? '');
    const persisted = normalizeSshTunnelConfig({
      enabled: this.editSshEnabled,
      sshHost: this.editSshHost,
      sshPort: normalizePortText(this.editSshPortText, DEFAULT_SSH_PORT),
      sshUser: this.editSshUser,
      reuseDesktopUser: this.editSshReuseDesktopUser,
      authType: this.editSshAuthType,
      sshPassword: this.editSshPassword,
      reuseDesktopPassword: this.editSshReuseDesktopPassword,
      privateKeyPath: this.editSshPrivateKeyPath,
      publicKeyPath: this.editSshPublicKeyPath,
      privateKeyPassphrase: this.editSshPrivateKeyPassphrase,
      knownHostsPath: this.editSshKnownHostsPath,
      strictHostKeyCheck: this.editSshStrictHostKeyCheck,
      remoteHost: this.editSshRemoteHost,
      remotePort: normalizePortText(this.editSshRemotePortText, DEFAULT_VNC_PORT)
    }, parsed?.host ?? '', parsed?.port ?? DEFAULT_VNC_PORT);
    const previewSsh: SshTunnelConfig = {
      enabled: persisted.enabled,
      sshHost: persisted.sshHost,
      sshPort: persisted.sshPort,
      sshUser: persisted.reuseDesktopUser ? (this.editUser ?? '').trim() : persisted.sshUser,
      reuseDesktopUser: persisted.reuseDesktopUser,
      authType: persisted.authType,
      sshPassword: persisted.authType === SSH_AUTH_PASSWORD && persisted.reuseDesktopPassword
        ? (this.editPassword ?? '')
        : persisted.sshPassword,
      reuseDesktopPassword: persisted.reuseDesktopPassword,
      privateKeyPath: persisted.privateKeyPath,
      publicKeyPath: persisted.publicKeyPath,
      privateKeyPassphrase: persisted.privateKeyPassphrase,
      knownHostsPath: persisted.knownHostsPath,
      strictHostKeyCheck: persisted.strictHostKeyCheck,
      remoteHost: persisted.remoteHost,
      remotePort: persisted.remotePort
    };
    return resolveEffectiveSshTunnelConfig(
      previewSsh,
      this.editAddress ?? '',
      this.editUser ?? '',
      this.editPassword ?? ''
    );
  }

  private getNormalizedConnectionSsh(connection: ConnectionItem): SshTunnelConfig {
    return resolveEffectiveSshTunnelConfig(
      connection?.sshTunnel,
      connection?.address ?? '',
      connection?.user ?? '',
      connection?.password ?? ''
    );
  }

  private isConnectionUsingSsh(connection: ConnectionItem): boolean {
    return this.getNormalizedConnectionSsh(connection).enabled;
  }

  private isRouteUsingSsh(address: string, sshTunnel?: SshTunnelConfig): boolean {
    return this.getNormalizedSshForAddress(address, sshTunnel).enabled;
  }

  private getRouteLabelForAddress(address: string, sshTunnel?: SshTunnelConfig): string {
    return this.isRouteUsingSsh(address, sshTunnel) ? 'SSH 隧道' : '直连';
  }

  private getConnectionRouteLabel(connection: ConnectionItem): string {
    return this.getRouteLabelForAddress(connection?.address ?? '', connection?.sshTunnel);
  }

  private getVncTargetForAddress(address: string, sshTunnel?: SshTunnelConfig): string {
    const normalizedSsh = this.getNormalizedSshForAddress(address, sshTunnel);
    if (!normalizedSsh.enabled) {
      const trimmedAddress = (address ?? '').trim();
      return trimmedAddress ? trimmedAddress : '未填写';
    }
    return this.formatDisplayHostPort(normalizedSsh.remoteHost, normalizedSsh.remotePort);
  }

  private getConnectionVncTarget(connection: ConnectionItem): string {
    return this.getVncTargetForAddress(connection?.address ?? '', connection?.sshTunnel);
  }

  private getSshServerForAddress(address: string, sshTunnel?: SshTunnelConfig): string {
    const normalizedSsh = this.getNormalizedSshForAddress(address, sshTunnel);
    if (!normalizedSsh.enabled) return '';
    const userPrefix = normalizedSsh.sshUser ? `${normalizedSsh.sshUser}@` : '';
    return `${userPrefix}${this.formatDisplayHostPort(normalizedSsh.sshHost, normalizedSsh.sshPort)}`;
  }

  private getConnectionSshServer(connection: ConnectionItem): string {
    return this.getSshServerForAddress(connection?.address ?? '', connection?.sshTunnel);
  }

  private getPathSummaryForAddress(address: string, sshTunnel?: SshTunnelConfig): string {
    const vncTarget = this.getVncTargetForAddress(address, sshTunnel);
    if (!this.isRouteUsingSsh(address, sshTunnel)) {
      return `本机 -> VNC ${vncTarget}`;
    }
    const sshServer = this.getSshServerForAddress(address, sshTunnel);
    return `本机 -> SSH ${sshServer} -> VNC ${vncTarget}`;
  }

  private getConnectionPathSummary(connection: ConnectionItem): string {
    return this.getPathSummaryForAddress(connection?.address ?? '', connection?.sshTunnel);
  }

  private touchConnectionUsedById(id: string): void {
    if (!id) return;
    const now = Date.now();
    const curr = this.connections ?? [];
    const next: ConnectionItem[] = [];
    for (let i = 0; i < curr.length; i++) {
      const it = curr[i];
      if (it.id === id) {
        next.push({
          id: it.id,
          name: it.name,
          address: it.address,
          user: it.user,
          password: it.password,
          storePassword: it.storePassword,
          touchScrollStep: it.touchScrollStep,
          sshTunnel: normalizeSshTunnelConfigForAddress(it.sshTunnel, it.address),
          lastUsedAt: now
        });
      } else {
        next.push(it);
      }
    }
    next.sort((a, b) => (b.lastUsedAt ?? 0) - (a.lastUsedAt ?? 0));
    this.connections = next;
    this.selectedConnId = id;
    void this.saveConnections();
  }

  private async openViewerWindow(c: ConnectionItem): Promise<void> {
    if (!parseAddress(resolveConnectionAddress(c?.address ?? '', c?.sshTunnel))) {
      this.toast('请填写地址，或在开启 SSH 隧道时提供有效的转发目标');
      return;
    }
    try {
      const ctx = this.getHostContext();
      if (!ctx) return;
      const bn = ctx?.abilityInfo?.bundleName;
      const bundleName = (typeof bn === 'string' && bn) ? bn : 'com.hengqutiandi.vncviewer';
      const params: ViewerAbilityParams = {
        address: String(c.address ?? ''),
        user: String(c.user ?? ''),
        password: String(c.password ?? ''),
        name: String((c.name ?? '').trim()),
        sshConfig: JSON.stringify(this.getNormalizedConnectionSsh(c)),
        touchScrollStep: this.normalizeTouchScrollStep(c.touchScrollStep)
      };
      const want: StartWant = {
        bundleName,
        moduleName: 'entry',
        abilityName: 'ViewerAbility',
        parameters: params
      };
      this.touchConnectionUsedById(c.id);
      await ctx?.startAbility?.(want);
    } catch (e) {
      const error = e as ErrorLike;
      const msg = (typeof error?.message === 'string' && error.message)
        ? error.message
        : ((e instanceof Error) ? e.message : `${e}`);
      console.error('openViewerWindow failed', e);
      this.toast(`打开连接窗口失败: ${msg}`);
    }
  }

  private isBtnPressed(key: string): boolean {
    return (this.pressedBtnKey ?? '') === key;
  }

  private handleBtnTouch(key: string, ev: TouchEvent): void {
    const type = ev?.type;
    if (type === TouchType.Down) {
      this.pressedBtnKey = key;
      return;
    }
    if (type === TouchType.Up || type === TouchType.Cancel) {
      if (this.pressedBtnKey === key) this.pressedBtnKey = '';
    }
  }

  @Builder
  private buildIconButton(key: string, icon: Resource, iconColor: string, bg: string, bgPressed: string, border: BorderSpec | null, onClick: () => void, enabled: boolean = true, marginLeft: number = 0): void {
    Button() {
      Image(icon)
        .width(this.iconSize)
        .height(this.iconSize)
        .objectFit(ImageFit.Contain)
        .fillColor(iconColor);
    }
    .width(this.iconBtnSize)
    .height(this.iconBtnSize)
    .padding(0)
    .margin({ left: marginLeft })
    .backgroundColor(this.isBtnPressed(key) ? bgPressed : bg)
    .border(border ? border : this.borderNone)
    .borderRadius(this.iconBtnRadius)
    .shadow({ radius: 12, color: 'rgba(12,20,22,0.12)', offsetX: 0, offsetY: 3 })
    .enabled(enabled)
    .onTouch((ev: TouchEvent) => this.handleBtnTouch(key, ev))
    .onClick(() => onClick());
  }

  @Builder
  private buildListPane(): void {
    Column() {
      Row() {
        Text('连接管理')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.cTextPrimary)
          .layoutWeight(1);

        Row() {
          Text(`v${BUILD_VERSION}`)
            .fontSize(12)
            .fontColor(this.cTextSecondary);
          Button('关于')
            .height(30)
            .fontSize(12)
            .fontColor(this.cPrimary)
            .backgroundColor(this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(12)
            .padding({ left: 12, right: 12 })
            .margin({ left: 10 })
            .onClick(() => this.aboutOpen = true);
        }
        .alignItems(VerticalAlign.Center);
      }
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: 16, right: 16, top: 16, bottom: 10 });

      Row() {
        TextInput({ text: this.keyword, placeholder: '搜索：名称 / 地址 / 账号' })
          .onChange((v: string) => this.keyword = v)
          .height(40)
          .fontSize(14)
          .backgroundColor(this.cSurfaceAlt)
          .border(this.borderThin)
          .borderRadius(14)
          .padding({ left: 12, right: 12 })
          .layoutWeight(1);
        if ((this.keyword ?? '').trim()) {
          Button('清除')
            .height(36)
            .fontSize(12)
            .margin({ left: 10 })
            .fontColor(this.cPrimary)
            .backgroundColor(this.cSurfaceAlt)
            .border({ width: 1, color: this.cBorder })
            .borderRadius(12)
            .onClick(() => this.keyword = '');
        }

        this.buildIconButton(
          'top_add',
          $r('app.media.ic_plus'),
          this.cPrimaryFg,
          this.cPrimary,
          this.cPrimaryPressed,
          null,
          () => this.openCreateDialog(),
          true,
          10
        );
      }
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, bottom: 10 });

      if (this.getFilteredConnections().length === 0) {
        Column() {
          Text(this.connections.length === 0 ? '暂无连接配置' : '未找到匹配的连接')
            .fontSize(14)
            .fontColor(this.cTextSecondary)
            .margin({ bottom: 6 });
          if (this.connections.length === 0) {
            Button() {
              Row() {
                Image($r('app.media.ic_plus'))
                  .width(18)
                  .height(18)
                  .objectFit(ImageFit.Contain)
                  .fillColor(this.cPrimaryFg)
                  .margin({ right: 8 });
                Text('新增连接')
                  .fontColor(this.cPrimaryFg)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium);
              }
              .alignItems(VerticalAlign.Center);
            }
              .height(40)
              .backgroundColor(this.cPrimary)
              .borderRadius(14)
              .padding({ left: 14, right: 14 })
              .onClick(() => this.openCreateDialog());
          }
        }
        .padding(16)
        .margin({ left: 16, right: 16, top: 8 })
        .backgroundColor(this.cSurfaceAlt)
        .border({ width: 1, color: this.cBorder })
        .borderRadius(14);
      } else {
        List({ scroller: this.connectionListScroller }) {
          ForEach(this.getFilteredConnections(), (c: ConnectionItem) => {
            ListItem() {
              Row() {
                Column() {
                  Row() {
                    Text(normalizeConnName(c.name ?? '', c.address ?? '', c.sshTunnel))
                      .fontSize(15)
                      .fontWeight(c.id === this.selectedConnId ? FontWeight.Medium : FontWeight.Regular)
                      .fontColor(this.cTextPrimary)
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis });
                    Text(this.getConnectionRouteLabel(c))
                      .fontSize(11)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.cPrimary)
                      .backgroundColor(this.cPrimarySoft)
                      .borderRadius(10)
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .margin({ left: 8 });
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center);
                  Text(this.getConnectionPathSummary(c))
                    .fontSize(11)
                    .fontColor(this.cPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 4 });
                  Text(`VNC：${this.getConnectionVncTarget(c)}`)
                    .fontSize(12)
                    .fontColor(this.cTextSecondary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 4 });
                  if (this.isConnectionUsingSsh(c)) {
                    Text(`SSH：${this.getConnectionSshServer(c)}`)
                      .fontSize(12)
                      .fontColor(this.cTextSecondary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 2 });
                  }
                  Text(this.formatLastUsed(c.lastUsedAt))
                    .fontSize(12)
                    .fontColor(this.cTextTertiary)
                    .margin({ top: 4 });
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start);

                Row() {
                  this.buildIconButton(
                    `conn_${c.id}_open`,
                    $r('app.media.ic_plug'),
                    this.cPrimaryFg,
                    this.cPrimary,
                    this.cPrimaryPressed,
                    null,
                    () => { void this.openViewerWindow(c); },
                    true,
                    0
                  );

                  this.buildIconButton(
                    `conn_${c.id}_edit`,
                    $r('app.media.ic_edit'),
                    this.cPrimary,
                    this.cSurfaceAlt,
                    this.cSurfacePressed,
                    this.borderThin,
                    () => this.openEditDialog(c.id),
                    true,
                    8
                  );

                  this.buildIconButton(
                    `conn_${c.id}_delete`,
                    $r('app.media.ic_trash'),
                    this.cError,
                    this.cSurfaceAlt,
                    this.cErrorSoft,
                    this.borderThin,
                    () => { void this.deleteConnection(c.id); },
                    true,
                    8
                  );
                }
              }
              .alignItems(VerticalAlign.Center)
              .padding(14)
              .backgroundColor(c.id === this.selectedConnId ? this.cPrimarySoft : this.cSurfaceAlt)
              .border(c.id === this.selectedConnId ? { width: 1.5, color: this.cPrimaryOutline } : { width: 1, color: this.cBorder })
              .borderRadius(14)
              .shadow({ radius: 14, color: 'rgba(12,20,22,0.10)', offsetX: 0, offsetY: 4 })
              .onClick(() => this.selectConnection(c.id))
              .stateStyles({
                focused: {
                  .border({ width: 2, color: this.cFocusOutline })
                  .backgroundColor(this.cPrimarySoft)
                }
              })
              .focusable(true);
            }
            .padding({ left: 16, right: 16, top: 8 });
          }, (c: ConnectionItem) => c.id);
        }
        .cachedCount(4)
        .edgeEffect(EdgeEffect.None)
        .focusable(true)
        .defaultFocus(true)
        .onKeyEvent((ev: KeyEvent) => this.handleConnectionListKeyEvent(ev))
        .layoutWeight(1);
      }
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  private buildDetailPane(): void {
    Column() {
      if (this.getSelectedConnection()) {
        this.buildDetailContent();
      } else {
        Column() {
          Text('未选择连接')
            .fontSize(14)
            .fontColor(this.cTextSecondary)
            .margin({ bottom: 6 });
        }
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height('100%');
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor(this.cSurface);
  }

  @Builder
  private buildDetailContent(): void {
    Column() {
      if (this.getSelectedConnection()) {
        Text('当前选中')
          .fontSize(14)
          .fontColor(this.cTextSecondary)
          .margin({ bottom: 12 });
        Text(normalizeConnName(this.getSelectedConnection()?.name ?? '', this.getSelectedConnection()?.address ?? '', this.getSelectedConnection()?.sshTunnel))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.cTextPrimary)
          .margin({ bottom: 20 });

        this.buildDetailLine({
          label: '地址',
          value: this.getSelectedConnection()?.address ?? ''
        });
        this.buildDetailLine({
          label: '账号',
          value: this.getSelectedConnection()?.user ?? '未提供'
        });
        this.buildDetailLine({
          label: '密码保存',
          value: this.getSelectedConnection()?.storePassword ? '已开启' : '未开启'
        });
        this.buildDetailLine({
          label: '触控滚动步长',
          value: this.getSelectedConnection()?.touchScrollStep === 1
            ? '慢 (1px)'
            : (this.getSelectedConnection()?.touchScrollStep === 8
              ? '快 (8px)'
              : `${this.getSelectedConnection()?.touchScrollStep ?? 0}px`)
        });
        this.buildDetailLine({
          label: '最近使用',
          value: this.formatLastUsed(this.getSelectedConnection()?.lastUsedAt ?? 0)
        });
      }

      Blank()
        .layoutWeight(1);
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height('100%')
    .padding(24)
    .backgroundColor(this.cPrimarySoft)
    .borderRadius(20);
  }

  @Builder
  private buildDetailLine(line: ConnectionDetailLine): void {
    Column() {
      Text(line.label)
        .fontSize(12)
        .fontColor(this.cTextSecondary)
        .margin({ bottom: 4 });
      Text(line.value)
        .fontSize(14)
        .fontColor(this.cTextPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ bottom: 16 });
  }

  @Builder
  private buildConnectionManager(): void {
    GridRow({
      columns: { sm: 4, md: 8, lg: 12 },
      gutter: { x: 0, y: 0 }
    }) {
      GridCol({ span: { sm: 4, md: 4, lg: 5 } }) {
        this.buildListPane()
      }
      GridCol({ span: { sm: 0, md: 4, lg: 7 } }) {
        this.buildDetailPane()
      }
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  private buildAboutOverlay(): void {
    if (this.aboutOpen) {
      Stack() {
        Column() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(12,20,22,0.60)')
        .onClick(() => this.closeAboutDialog());

        Column() {
          Row() {
            Column() {
              Row() {
                Text('🐯')
                  .fontSize(32)
                  .margin({ right: 12 });
                Column() {
                  Text('翠虎远程桌面')
                    .fontSize(22)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.cTextPrimary);
                  Text(`Version ${BUILD_VERSION}`)
                    .fontSize(13)
                    .fontColor(this.cTextSecondary)
                    .margin({ top: 2 });
                }
                .alignItems(HorizontalAlign.Start);
              }
              .alignItems(VerticalAlign.Center);
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);

            Button() {
              Image($r('app.media.ic_close'))
                .width(18)
                .height(18)
                .fillColor(this.cTextSecondary)
            }
            .width(36)
            .height(36)
            .backgroundColor(Color.Transparent)
            .borderRadius(18)
            .onClick(() => this.closeAboutDialog());
          }
          .alignItems(VerticalAlign.Center)
          .width('100%')
          .padding({ left: 24, right: 20, top: 24, bottom: 20 });

          Blank()
            .height(1)
            .color(this.cBorder)
            .margin({ left: 24, right: 24 });

          Scroll() {
            Column() {
              Column() {
                Row() {
                  Image($r('app.media.ic_building'))
                    .width(18)
                    .height(18)
                    .objectFit(ImageFit.Contain)
                    .opacity(0.92)
                    .margin({ right: 8 });
                  Text('公司信息')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.cTextPrimary);
                }
                .alignItems(VerticalAlign.Center)
                .margin({ bottom: 16 });

                Column() {
                  Row() {
                    Text('开发团队')
                      .fontSize(13)
                      .fontColor(this.cTextSecondary)
                      .width(80);
                    Text('横渠天地（北京）科技有限公司')
                      .fontSize(15)
                      .lineHeight(22)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.cTextPrimary)
                      .layoutWeight(1);
                  }
                  .alignItems(VerticalAlign.Top)
                  .margin({ bottom: 14 });

                  this.buildAboutActionRow(
                    '商务合作',
                    PROJECT_CONTACT_EMAIL,
                    '写邮件',
                    `mailto:${PROJECT_CONTACT_EMAIL}`,
                    '邮箱已复制'
                  );

                  Blank().height(14);

                  this.buildAboutActionRow(
                    '官方网站',
                    PROJECT_HOMEPAGE_URL,
                    '访问',
                    PROJECT_HOMEPAGE_URL,
                    '网址已复制'
                  );
                }
                .width('100%')
                .padding(18)
                .backgroundColor(this.cSurface)
                .border({ width: 1, color: this.cBorder })
                .borderRadius(16);
              }
              .padding({ left: 24, right: 24, top: 20 });

              Column() {
                Row() {
                  Image($r('app.media.ic_shield'))
                    .width(18)
                    .height(18)
                    .objectFit(ImageFit.Contain)
                    .opacity(0.92)
                    .margin({ right: 8 });
                  Text('协议与隐私')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.cTextPrimary);
                }
                .alignItems(VerticalAlign.Center)
                .margin({ bottom: 16 });

                Column() {
                  this.buildAboutAgreementRow('隐私协议', '查看隐私协议', AGREEMENT_DIALOG_PRIVACY);
                  Blank().height(14);
                  this.buildAboutAgreementRow('用户协议', '查看用户协议', AGREEMENT_DIALOG_USER);
                }
                .width('100%')
                .padding(18)
                .backgroundColor(this.cSurface)
                .border({ width: 1, color: this.cBorder })
                .borderRadius(16);
              }
              .padding({ left: 24, right: 24, top: 16 });

              Column() {
                Row() {
                  Image($r('app.media.ic_shield'))
                    .width(18)
                    .height(18)
                    .objectFit(ImageFit.Contain)
                    .opacity(0.92)
                    .margin({ right: 8 });
                  Text('开源许可')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.cTextPrimary);
                }
                .alignItems(VerticalAlign.Center)
                .margin({ bottom: 16 });

                Column() {
                  Row() {
                    Text('开源许可')
                      .fontSize(13)
                      .fontColor(this.cTextSecondary)
                      .width(80);
                    Text('本应用采用 GPL-2.0 许可发布，并包含多个第三方开源组件。')
                      .fontSize(14)
                      .lineHeight(21)
                      .fontColor(this.cTextPrimary)
                      .layoutWeight(1);
                  }
                  .alignItems(VerticalAlign.Top)
                  .margin({ bottom: 14 });

                  this.buildAboutActionRow(
                    '源码获取',
                    PROJECT_SOURCE_URL,
                    '访问',
                    PROJECT_SOURCE_URL,
                    '网址已复制'
                  );

                  Blank().height(14);

                  Row() {
                    Text('第三方组件')
                      .fontSize(13)
                      .fontColor(this.cTextSecondary)
                      .width(80);
                    Text('• TigerVNC (GPL-2.0)\n• libssh2 (BSD-3-Clause)\n• mbedTLS (Apache-2.0 / GPL-2.0)\n• GnuTLS (LGPL-2.1+)\n• Nettle (GPL-2.0+ / LGPL-3.0+)')
                      .fontSize(14)
                      .lineHeight(21)
                      .fontColor(this.cTextPrimary)
                      .layoutWeight(1);
                  }
                  .alignItems(VerticalAlign.Top)
                  .margin({ bottom: 14 });

                  Row() {
                    Text('免责声明')
                      .fontSize(13)
                      .fontColor(this.cTextSecondary)
                      .width(80);
                    Text('本软件按“现状”提供，不附带任何明示或暗示担保。详见各许可证全文。')
                      .fontSize(14)
                      .lineHeight(21)
                      .fontColor(this.cTextPrimary)
                      .layoutWeight(1);
                  }
                  .alignItems(VerticalAlign.Top);
                }
                .width('100%')
                .padding(18)
                .backgroundColor(this.cSurface)
                .border({ width: 1, color: this.cBorder })
                .borderRadius(16);
              }
              .padding({ left: 24, right: 24, top: 16, bottom: 24 });
            }
          }
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .align(Alignment.Top)
        }
        .width('100%')
        .height('86%')
        .constraintSize({ maxWidth: 480 })
        .backgroundColor(this.cSurfaceAlt)
        .borderRadius(24)
        .shadow({ radius: 32, color: 'rgba(12,20,22,0.18)', offsetX: 0, offsetY: 8 });
      }
      .alignContent(Alignment.Center)
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  private buildAgreementOverlay(): void {
    if (this.agreementDialogMode !== AGREEMENT_DIALOG_NONE) {
      Stack() {
        Column() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(12,20,22,0.66)')
        .onClick(() => {
          if (!this.isLaunchAgreementDialog()) {
            this.closeAgreementDialog();
          }
        });

        Column() {
          Row() {
            Column() {
              Text(this.getAgreementDialogTitle())
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.cTextPrimary);
              Text(this.isLaunchAgreementDialog()
                ? '首次使用前，请完整阅读并确认《翠虎远程桌面隐私协议》与《翠虎远程桌面用户协议》，同意后方可继续使用应用。'
                : '以下内容与首启展示保持一致，支持在应用内随时查看完整文本。')
                .fontSize(13)
                .lineHeight(20)
                .fontColor(this.cTextSecondary)
                .margin({ top: 6 });
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);

            if (!this.isLaunchAgreementDialog()) {
              Button() {
                Image($r('app.media.ic_close'))
                  .width(18)
                  .height(18)
                  .fillColor(this.cTextSecondary);
              }
              .width(36)
              .height(36)
              .backgroundColor(Color.Transparent)
              .borderRadius(18)
              .onClick(() => this.closeAgreementDialog());
            }
          }
          .alignItems(VerticalAlign.Top)
          .width('100%')
          .padding({ left: 24, right: 20, top: 24, bottom: 20 });

          Blank()
            .height(1)
            .color(this.cBorder)
            .margin({ left: 24, right: 24 });

          Scroll() {
            Column({ space: 20 }) {
              if (this.agreementDialogMode === AGREEMENT_DIALOG_LAUNCH) {
                this.buildAgreementSection('隐私协议', this.privacyPolicyBlocks);
                Blank().height(1).color(this.cBorder).width('100%');
                this.buildAgreementSection('用户协议', this.userAgreementBlocks);
              } else if (this.agreementDialogMode === AGREEMENT_DIALOG_PRIVACY) {
                this.buildAgreementSection('隐私协议', this.privacyPolicyBlocks);
              } else {
                this.buildAgreementSection('用户协议', this.userAgreementBlocks);
              }
            }
            .width('100%')
            .padding({ left: 24, right: 24, top: 20, bottom: 20 })
            .alignItems(HorizontalAlign.Start);
          }
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .align(Alignment.Top);

          Blank()
            .height(1)
            .color(this.cBorder)
            .margin({ left: 24, right: 24 });

          Row() {
            if (this.isLaunchAgreementDialog()) {
              Button('退出应用')
                .layoutWeight(1)
                .height(44)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.cTextPrimary)
                .backgroundColor(this.cSurfaceAlt)
                .border({ width: 1, color: this.cBorder })
                .borderRadius(14)
                .onClick(() => {
                  void this.exitApplication();
                });

              Blank().width(12);

              Button('同意并继续')
                .layoutWeight(1)
                .height(44)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.cPrimaryFg)
                .backgroundColor(this.cPrimary)
                .borderRadius(14)
                .onClick(() => {
                  void this.acceptLaunchAgreements();
                });
            } else {
              Button('关闭')
                .width('100%')
                .height(44)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.cPrimaryFg)
                .backgroundColor(this.cPrimary)
                .borderRadius(14)
                .onClick(() => this.closeAgreementDialog());
            }
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 16, bottom: 20 })
          .alignItems(VerticalAlign.Center);
        }
        .width('100%')
        .height('88%')
        .constraintSize({ maxWidth: 720 })
        .backgroundColor(this.cSurfaceAlt)
        .borderRadius(24)
        .shadow({ radius: 32, color: 'rgba(12,20,22,0.18)', offsetX: 0, offsetY: 8 });
      }
      .alignContent(Alignment.Center)
      .width('100%')
      .height('100%');
    }
  }

  build() {
    Stack() {
      this.buildConnectionManager();
      this.buildEditOverlay();
      this.buildAboutOverlay();
      this.buildAgreementOverlay();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.cSurface)
    .focusable(true)
    .onKeyEvent((ev: KeyEvent) => this.handleConnectionListKeyEvent(ev));
  }
}
