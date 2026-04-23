import image from '@ohos.multimedia.image';
import { SharedViewerRect } from './ViewerMultiWindow';

export interface ViewportTarget {
  source: SharedViewerRect;
  frame: SharedViewerRect;
}

export interface RemotePoint {
  x: number;
  y: number;
}

export const VNC_MOUSE_LEFT = 1;
export const VNC_MOUSE_MIDDLE = 2;
export const VNC_MOUSE_RIGHT = 4;
export const VNC_SCROLL_UP = 8;
export const VNC_SCROLL_DOWN = 16;

export function getVncMouseButton(button: MouseButton): number {
  if (button === MouseButton.Left) return VNC_MOUSE_LEFT;
  if (button === MouseButton.Middle) return VNC_MOUSE_MIDDLE;
  if (button === MouseButton.Right) return VNC_MOUSE_RIGHT;
  return 0;
}

export function isMacServerTarget(serverName: string): boolean {
  return serverName.toLowerCase().indexOf('mac') !== -1 || serverName.indexOf('Apple') !== -1;
}

export function getScrollClicksForServer(serverName: string): number {
  return isMacServerTarget(serverName) ? 10 : 1;
}

export function cloneFrameBuffer(src: ArrayBuffer): ArrayBuffer {
  const cloned = new ArrayBuffer(src.byteLength);
  new Uint8Array(cloned).set(new Uint8Array(src));
  return cloned;
}

export function releasePixelMap(pm: image.PixelMap | undefined): void {
  if (!pm) return;
  try {
    pm.release();
  } catch (e) {
  }
}

export async function createPixelMapFromBuffer(buf: ArrayBuffer, width: number, height: number): Promise<image.PixelMap> {
  const opts: image.InitializationOptions = {
    size: { width, height },
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    alphaType: image.AlphaType.UNPREMUL,
    editable: true
  };
  return await image.createPixelMap(buf, opts) as image.PixelMap;
}

export function getWindowFrame(windowW: number, windowH: number): SharedViewerRect {
  return {
    x: 0,
    y: 0,
    w: Math.max(1, windowW),
    h: Math.max(1, windowH)
  };
}

export function getViewportScale(source: SharedViewerRect, frame: SharedViewerRect): number {
  return Math.min(frame.w / Math.max(1, source.w), frame.h / Math.max(1, source.h));
}

export function getMonitorImageMetrics(monitorRect: SharedViewerRect, windowW: number, windowH: number, fbW: number, fbH: number): ViewportTarget {
  const source = monitorRect;
  const frame = getWindowFrame(windowW, windowH);
  const scale = getViewportScale(source, frame);
  const contentW = source.w * scale;
  const contentH = source.h * scale;
  return {
    source,
    frame: {
      x: (frame.w - contentW) / 2 - source.x * scale,
      y: (frame.h - contentH) / 2 - source.y * scale,
      w: fbW * scale,
      h: fbH * scale
    }
  };
}

export function mapLocalToRemote(localX: number, localY: number, monitorRect: SharedViewerRect, windowW: number, windowH: number, fbW: number, fbH: number): RemotePoint {
  if (fbW <= 0 || fbH <= 0) return { x: 0, y: 0 };
  const metrics = getMonitorImageMetrics(monitorRect, windowW, windowH, fbW, fbH);
  const imgFrame = metrics.frame;
  const scale = getViewportScale(metrics.source, getWindowFrame(windowW, windowH));
  const remoteX = (localX - imgFrame.x) / scale;
  const remoteY = (localY - imgFrame.y) / scale;
  return {
    x: Math.max(0, Math.min(fbW - 1, Math.floor(remoteX))),
    y: Math.max(0, Math.min(fbH - 1, Math.floor(remoteY)))
  };
}
