import { appTasks } from '@ohos/hvigor-ohos-plugin';
import * as fs from 'fs';
import * as path from 'path';
import * as childProcess from 'child_process';

function getGitVersionName(): string {
  try {
    return childProcess.execSync('git describe --tags --always --dirty', { encoding: 'utf-8' }).trim();
  } catch (e) {
    return '1.0.0';
  }
}

function getGitVersionCode(versionName: string): number {
  try {
    const cleanVersionName = versionName.replace(/^v/, '').split('-')[0];
    const parts = cleanVersionName.split('.');
    const major = parseInt(parts[0]) || 1;
    const minor = parseInt(parts[1]) || 0;
    const patch = parseInt(parts[2]) || 0;
    
    let commitCount = 0;
    if (versionName.includes('-')) {
      const splits = versionName.split('-');
      if (splits.length > 1) {
        commitCount = parseInt(splits[1]) || 0;
      }
    }
    
    return major * 1000000 + minor * 100000 + patch * 10000 + commitCount;
  } catch (e) {
    return 1000000;
  }
}

const gitVersionName = getGitVersionName();
const gitVersionCode = getGitVersionCode(gitVersionName);
console.log(`[Build] Dynamic App Version: ${gitVersionName} (${gitVersionCode})`);

function getSigningConfig() {
  const propertiesPath = path.resolve(__dirname, 'local.properties');
  let props: Record<string, string> = {};

  if (fs.existsSync(propertiesPath)) {
    const content = fs.readFileSync(propertiesPath, 'utf-8');
    content.split('\n').forEach((line: string) => {
      if (line && !line.trim().startsWith('#')) {
        const [key, ...valueParts] = line.split('=');
        if (key && valueParts.length > 0) {
          props[key.trim()] = valueParts.join('=').trim();
        }
      }
    });
  }

  const signActiveFromEnv = process.env.SIGN_ACTIVE;
  const defaultSignActive = props['sign.active'] || 'debug';

  let activeMode: string;
  if (signActiveFromEnv) {
    activeMode = signActiveFromEnv;
  } else if (props['sign.release.storeFile']) {
    activeMode = 'release';
  } else {
    activeMode = defaultSignActive;
  }

  const prefix = `sign.${activeMode}.`;
  console.log(`[Build] Signing config - activeMode: ${activeMode}`);

  if (!props[`${prefix}storeFile`]) {
    return undefined;
  }

  return {
    type: "HarmonyOS",
    material: {
      certpath: props[`${prefix}certpath`] || '',
      keyAlias: props[`${prefix}keyAlias`] || '',
      keyPassword: props[`${prefix}keyPassword`] || '',
      profile: props[`${prefix}profile`] || '',
      signAlg: "SHA256withECDSA",
      storeFile: props[`${prefix}storeFile`] || '',
      storePassword: props[`${prefix}storePassword`] || ''
    }
  };
}

export default {
  system: appTasks,
  plugins: [],
  config: {
    ohos: {
      overrides: {
        appOpt: {
          versionCode: gitVersionCode,
          versionName: gitVersionName
        },
        signingConfig: getSigningConfig()
      }
    }
  }
};