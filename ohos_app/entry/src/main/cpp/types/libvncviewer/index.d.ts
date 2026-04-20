export class VncClient {
  connect(host: string, port: number, user?: string, pass?: string): Promise<number>;
  disconnect(): void;
  process(): number;
  refresh(): number;
  consumeDamage(): any;
  getFramebufferInfo(): any;
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
  isSecure(): boolean;
  getSecurityLevel(): number;
  setDebugOptions(enabled: boolean, level: number, byteOrder: number, pmFormat: number): void;
  getDebugInfo(): any;
  getDebugLog(clear: boolean): string;
}

export const vnc: any;
export default vnc;
