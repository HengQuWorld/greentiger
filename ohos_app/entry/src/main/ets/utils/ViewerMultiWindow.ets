export interface SharedViewerRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface VncClientLike {
  sendPointer(x: number, y: number, mask: number): void;
  sendKey(keysym: number, down: boolean): void;
}

export interface SharedViewerSessionSnapshot {
  sessionId: string;
  title: string;
  connected: boolean;
  fbW: number;
  fbH: number;
  frameVersion: number;
  updatedAt: number;
  frame: ArrayBuffer | null;
  monitors: SharedViewerRect[];
}

export interface ViewerWindowBinding {
  windowName: string;
  sessionId: string;
  monitorIndex: number;
  title: string;
}

class ViewerSessionEntry {
  snapshot: SharedViewerSessionSnapshot;
  windowNames: string[] = [];
  vncClient: VncClientLike | null = null;

  constructor(sessionId: string) {
    this.snapshot = {
      sessionId,
      title: '',
      connected: false,
      fbW: 0,
      fbH: 0,
      frameVersion: 0,
      updatedAt: 0,
      frame: null,
      monitors: []
    };
  }
}

export class ViewerMultiWindowStore {
  private static instance: ViewerMultiWindowStore = new ViewerMultiWindowStore();
  private readonly sessions: Map<string, ViewerSessionEntry> = new Map();
  private readonly windowBindings: Map<string, ViewerWindowBinding> = new Map();
  private readonly claimedWindows: Set<string> = new Set();

  static getInstance(): ViewerMultiWindowStore {
    return ViewerMultiWindowStore.instance;
  }

  private getOrCreateSession(sessionId: string): ViewerSessionEntry {
    let entry = this.sessions.get(sessionId);
    if (!entry) {
      entry = new ViewerSessionEntry(sessionId);
      this.sessions.set(sessionId, entry);
    }
    return entry;
  }

  private cloneRects(rects: SharedViewerRect[]): SharedViewerRect[] {
    const next: SharedViewerRect[] = [];
    for (let i = 0; i < rects.length; i++) {
      const rect = rects[i];
      next.push({
        x: Math.floor(rect.x),
        y: Math.floor(rect.y),
        w: Math.floor(rect.w),
        h: Math.floor(rect.h)
      });
    }
    return next;
  }

  ensureSession(sessionId: string): void {
    this.getOrCreateSession(sessionId);
  }

  updateSessionTitle(sessionId: string, title: string): void {
    const entry = this.getOrCreateSession(sessionId);
    entry.snapshot.title = title;
  }

  updateSessionConnectionState(sessionId: string, connected: boolean): void {
    const entry = this.getOrCreateSession(sessionId);
    entry.snapshot.connected = connected;
    entry.snapshot.updatedAt = Date.now();
  }

  publishFrame(sessionId: string, title: string, connected: boolean, fbW: number, fbH: number, frame: ArrayBuffer | null, monitors: SharedViewerRect[]): void {
    const entry = this.getOrCreateSession(sessionId);
    entry.snapshot.title = title;
    entry.snapshot.connected = connected;
    entry.snapshot.fbW = Math.max(0, Math.floor(fbW));
    entry.snapshot.fbH = Math.max(0, Math.floor(fbH));
    entry.snapshot.frame = frame;
    entry.snapshot.monitors = this.cloneRects(monitors);
    entry.snapshot.frameVersion++;
    entry.snapshot.updatedAt = Date.now();
  }

  clearSessionFrame(sessionId: string, title: string): void {
    const entry = this.getOrCreateSession(sessionId);
    entry.snapshot.title = title;
    entry.snapshot.connected = false;
    entry.snapshot.fbW = 0;
    entry.snapshot.fbH = 0;
    entry.snapshot.frame = null;
    entry.snapshot.monitors = [];
    entry.snapshot.frameVersion++;
    entry.snapshot.updatedAt = Date.now();
  }

  getSessionSnapshot(sessionId: string): SharedViewerSessionSnapshot | null {
    const entry = this.sessions.get(sessionId);
    if (!entry) return null;
    return {
      sessionId: entry.snapshot.sessionId,
      title: entry.snapshot.title,
      connected: entry.snapshot.connected,
      fbW: entry.snapshot.fbW,
      fbH: entry.snapshot.fbH,
      frameVersion: entry.snapshot.frameVersion,
      updatedAt: entry.snapshot.updatedAt,
      frame: entry.snapshot.frame,
      monitors: this.cloneRects(entry.snapshot.monitors)
    };
  }

  registerWindow(binding: ViewerWindowBinding): void {
    const entry = this.getOrCreateSession(binding.sessionId);
    this.windowBindings.set(binding.windowName, {
      windowName: binding.windowName,
      sessionId: binding.sessionId,
      monitorIndex: binding.monitorIndex,
      title: binding.title
    });
    if (!entry.windowNames.includes(binding.windowName)) {
      entry.windowNames.push(binding.windowName);
    }
  }

  getWindowBinding(windowName: string): ViewerWindowBinding | null {
    const binding = this.windowBindings.get(windowName);
    if (!binding) return null;
    return {
      windowName: binding.windowName,
      sessionId: binding.sessionId,
      monitorIndex: binding.monitorIndex,
      title: binding.title
    };
  }

  removeWindow(windowName: string): void {
    const binding = this.windowBindings.get(windowName);
    if (!binding) return;
    this.windowBindings.delete(windowName);
    this.claimedWindows.delete(windowName);
    const entry = this.sessions.get(binding.sessionId);
    if (!entry) return;
    entry.windowNames = entry.windowNames.filter((name: string): boolean => name !== windowName);
  }

  isWindowClaimed(windowName: string): boolean {
    return this.claimedWindows.has(windowName);
  }

  claimWindow(windowName: string): void {
    this.claimedWindows.add(windowName);
  }

  listWindowNames(sessionId: string): string[] {
    const entry = this.sessions.get(sessionId);
    if (!entry) return [];
    return entry.windowNames.slice();
  }

  listAllSessions(): string[] {
    return Array.from(this.sessions.keys());
  }

  setVncClient(sessionId: string, client: VncClientLike | null): void {
    const entry = this.getOrCreateSession(sessionId);
    entry.vncClient = client;
  }

  getVncClient(sessionId: string): VncClientLike | null {
    const entry = this.sessions.get(sessionId);
    if (!entry) return null;
    return entry.vncClient;
  }

  disposeSession(sessionId: string): void {
    const entry = this.sessions.get(sessionId);
    if (!entry) return;
    const names = entry.windowNames.slice();
    for (let i = 0; i < names.length; i++) {
      this.windowBindings.delete(names[i]);
    }
    this.sessions.delete(sessionId);
  }
}

export const viewerMultiWindowStore = ViewerMultiWindowStore.getInstance();
