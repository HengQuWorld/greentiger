export interface ConnectionItem {
  id: string;
  name: string;
  address: string;
  user: string;
  password: string;
  storePassword: boolean;
  touchScrollStep: number;
  sshTunnel: SshTunnelConfig;
  lastUsedAt: number;
}

export interface ConnectionJson {
  id?: string;
  name?: string;
  address?: string;
  user?: string;
  password?: string;
  storePassword?: boolean;
  touchScrollStep?: number;
  sshTunnel?: SshTunnelConfig;
  lastUsedAt?: number;
}

export interface SshTunnelConfig {
  enabled: boolean;
  sshHost: string;
  sshPort: number;
  sshUser: string;
  reuseDesktopUser: boolean;
  authType: number;
  sshPassword: string;
  reuseDesktopPassword: boolean;
  privateKeyPath: string;
  publicKeyPath: string;
  privateKeyPassphrase: string;
  knownHostsPath: string;
  strictHostKeyCheck: boolean;
  remoteHost: string;
  remotePort: number;
}

export type WantParamValue = string | number | boolean | undefined;

export class HostPort {
  host: string;
  port: number;

  constructor(host: string, port: number) {
    this.host = host;
    this.port = port;
  }
}

export const DEFAULT_VNC_PORT = 5900;
export const DEFAULT_SSH_PORT = 22;
export const SSH_AUTH_NONE = 0;
export const SSH_AUTH_PASSWORD = 1;
export const SSH_AUTH_PUBLIC_KEY = 2;

export function generateId(): string {
  const rand = Math.floor(Math.random() * 0x7fffffff).toString(16);
  return `${Date.now().toString(16)}_${rand}`;
}

export function formatHostPort(host: string, port: number): string {
  const trimmedHost = (host ?? '').trim();
  if (!trimmedHost) return '';
  if (trimmedHost.indexOf(':') !== -1 && !trimmedHost.startsWith('[')) {
    return `[${trimmedHost}]:${port}`;
  }
  return `${trimmedHost}:${port}`;
}

export function parseAddress(input: string): HostPort | null {
  const raw = (input ?? '').trim();
  if (!raw) return null;

  if (raw.startsWith('[')) {
    const end = raw.indexOf(']');
    if (end > 1) {
      const host = raw.slice(1, end).trim();
      const rest = raw.slice(end + 1).trim();
      if (rest.startsWith(':')) {
        const portStr = rest.slice(1).trim();
        const port = Number.parseInt(portStr, 10);
        if (host && Number.isFinite(port) && port >= 1 && port <= 65535) return new HostPort(host, port);
        return null;
      }
      return host ? new HostPort(host, DEFAULT_VNC_PORT) : null;
    }
    return null;
  }

  const lastColon = raw.lastIndexOf(':');
  if (lastColon > 0) {
    const hostPart = raw.slice(0, lastColon).trim();
    const portPart = raw.slice(lastColon + 1).trim();
    if (portPart && /^[0-9]+$/.test(portPart)) {
      const port = Number.parseInt(portPart, 10);
      if (!Number.isFinite(port) || port < 1 || port > 65535) return null;
      if (!hostPart) return null;
      return new HostPort(hostPart, port);
    }
  }

  return new HostPort(raw, DEFAULT_VNC_PORT);
}

export function isValidPort(port: number): boolean {
  return Number.isFinite(port) && port >= 1 && port <= 65535;
}

export function normalizePort(port: number, fallback: number): number {
  return isValidPort(port) ? Math.floor(port) : fallback;
}

export function normalizePortText(text: string, fallback: number): number {
  const raw = (text ?? '').trim();
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return normalizePort(parsed, fallback);
}

export function normalizeSshAuthType(authType: number): number {
  const value = Math.floor(authType);
  if (value === SSH_AUTH_NONE || value === SSH_AUTH_PUBLIC_KEY) return value;
  return SSH_AUTH_PASSWORD;
}

export function normalizeSshTunnelConfig(config?: SshTunnelConfig, remoteHost: string = '',
  remotePort: number = DEFAULT_VNC_PORT): SshTunnelConfig {
  const nextRemoteHost = (remoteHost ?? '').trim();
  const nextRemotePort = normalizePort(remotePort, DEFAULT_VNC_PORT);
  const configRemoteHost = (typeof config?.remoteHost === 'string' ? config.remoteHost : '').trim();

  return {
    enabled: !!config?.enabled,
    sshHost: (typeof config?.sshHost === 'string' ? config.sshHost : '').trim(),
    sshPort: normalizePort(config?.sshPort ?? DEFAULT_SSH_PORT, DEFAULT_SSH_PORT),
    sshUser: (typeof config?.sshUser === 'string' ? config.sshUser : '').trim(),
    reuseDesktopUser: !!config?.reuseDesktopUser,
    authType: normalizeSshAuthType(config?.authType ?? SSH_AUTH_PASSWORD),
    sshPassword: typeof config?.sshPassword === 'string' ? config.sshPassword : '',
    reuseDesktopPassword: !!config?.reuseDesktopPassword,
    privateKeyPath: (typeof config?.privateKeyPath === 'string' ? config.privateKeyPath : '').trim(),
    publicKeyPath: (typeof config?.publicKeyPath === 'string' ? config.publicKeyPath : '').trim(),
    privateKeyPassphrase: typeof config?.privateKeyPassphrase === 'string' ? config.privateKeyPassphrase : '',
    knownHostsPath: (typeof config?.knownHostsPath === 'string' ? config.knownHostsPath : '').trim(),
    strictHostKeyCheck: !!config?.strictHostKeyCheck,
    remoteHost: configRemoteHost || nextRemoteHost,
    remotePort: normalizePort(config?.remotePort ?? nextRemotePort, nextRemotePort)
  };
}

export function normalizeSshTunnelConfigForAddress(config: SshTunnelConfig | undefined, address: string): SshTunnelConfig {
  const parsed = parseAddress(address);
  return normalizeSshTunnelConfig(config, parsed?.host ?? '', parsed?.port ?? DEFAULT_VNC_PORT);
}

export function resolveEffectiveSshTunnelConfig(
  config: SshTunnelConfig | undefined,
  address: string,
  desktopUser: string = '',
  desktopPassword: string = ''
): SshTunnelConfig {
  const normalized = normalizeSshTunnelConfigForAddress(config, address);
  if (!normalized.enabled) return normalized;

  const effectiveUser = normalized.reuseDesktopUser && (desktopUser ?? '').trim()
    ? (desktopUser ?? '').trim()
    : normalized.sshUser;
  const effectivePassword = normalized.authType === SSH_AUTH_PASSWORD && normalized.reuseDesktopPassword && (desktopPassword ?? '')
    ? (desktopPassword ?? '')
    : normalized.sshPassword;

  return {
    enabled: normalized.enabled,
    sshHost: normalized.sshHost,
    sshPort: normalized.sshPort,
    sshUser: effectiveUser,
    reuseDesktopUser: normalized.reuseDesktopUser,
    authType: normalized.authType,
    sshPassword: effectivePassword,
    reuseDesktopPassword: normalized.reuseDesktopPassword,
    privateKeyPath: normalized.privateKeyPath,
    publicKeyPath: normalized.publicKeyPath,
    privateKeyPassphrase: normalized.privateKeyPassphrase,
    knownHostsPath: normalized.knownHostsPath,
    strictHostKeyCheck: normalized.strictHostKeyCheck,
    remoteHost: normalized.remoteHost,
    remotePort: normalized.remotePort
  };
}

export function parseSshTunnelConfigText(text: string, address: string): SshTunnelConfig | null {
  const raw = (text ?? '').trim();
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as SshTunnelConfig;
    return normalizeSshTunnelConfigForAddress(parsed, address);
  } catch (e) {
    return null;
  }
}

export function resolveConnectionAddress(address: string, sshTunnel?: SshTunnelConfig): string {
  const directAddress = (address ?? '').trim();
  if (parseAddress(directAddress)) return directAddress;

  const normalizedSsh = normalizeSshTunnelConfigForAddress(sshTunnel, directAddress);
  if (!normalizedSsh.enabled || !normalizedSsh.remoteHost || !isValidPort(normalizedSsh.remotePort)) {
    return directAddress;
  }
  return formatHostPort(normalizedSsh.remoteHost, normalizedSsh.remotePort);
}

export function normalizeConnName(name: string, address: string, sshTunnel?: SshTunnelConfig): string {
  const normalizedName = (name ?? '').trim();
  if (normalizedName) return normalizedName;
  return resolveConnectionAddress(address, sshTunnel) || '未命名连接';
}

export function parseConnectionsJson(text: string): ConnectionItem[] {
  if (!text) return [];
  try {
    const parsed = JSON.parse(text) as Object;
    if (!(parsed instanceof Array)) return [];

    const arr = parsed as ConnectionJson[];
    const out: ConnectionItem[] = [];
    for (let i = 0; i < arr.length; i++) {
      const c = arr[i] as ConnectionJson;
      const addr = (typeof c?.address === 'string' ? c.address : '').trim();
      const sshTunnel = normalizeSshTunnelConfigForAddress(c?.sshTunnel, addr);
      if (!parseAddress(resolveConnectionAddress(addr, sshTunnel))) continue;

      const id = typeof c?.id === 'string' && c.id ? c.id : generateId();
      const name = typeof c?.name === 'string' ? c.name : '';
      const user = typeof c?.user === 'string' ? c.user : '';
      const password = typeof c?.password === 'string' ? c.password : '';
      const storePassword = typeof c?.storePassword === 'boolean' ? c.storePassword : (password.length > 0);
      const touchScrollStep = typeof c?.touchScrollStep === 'number' && Number.isFinite(c.touchScrollStep)
        ? Math.max(0, Math.min(48, Math.floor(c.touchScrollStep)))
        : 0;
      const lastUsedAt = typeof c?.lastUsedAt === 'number' && Number.isFinite(c.lastUsedAt) ? c.lastUsedAt : 0;

      out.push({
        id,
        name,
        address: addr,
        user,
        password: storePassword ? password : '',
        storePassword,
        touchScrollStep,
        sshTunnel,
        lastUsedAt
      });
    }
    return out;
  } catch (e) {
    return [];
  }
}
