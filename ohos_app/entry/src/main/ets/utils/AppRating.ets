import dataPreferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { commentManager } from '@kit.AppGalleryKit';

interface ErrorLike {
  code?: number;
  message?: string;
}

interface RatingWant {
  action: string;
  uri: string;
}

interface RatingState {
  done: boolean;
  neverAsk: boolean;
  promptCount: number;
  lastPromptAt: number;
  sessionCount: number;
}

const PREF_STORE_NAME = 'vnc_store';
const RATING_DONE_KEY = 'app_rating_done_v1';
const RATING_NEVER_ASK_KEY = 'app_rating_never_ask_v1';
const RATING_PROMPT_COUNT_KEY = 'app_rating_prompt_count_v1';
const RATING_LAST_PROMPT_AT_KEY = 'app_rating_last_prompt_at_v1';
const RATING_SESSION_COUNT_KEY = 'app_rating_session_count_v1';

// 达到该累计成功连接次数后才开始考虑提示评价
const PROMPT_MIN_SESSIONS = 3;
// 单个用户最多提示次数（应用市场对评分弹窗有频次约束，这里取保守值）
const PROMPT_MAX_TIMES = 3;
// 两次提示之间的最小间隔，避免反复打扰
const PROMPT_COOLDOWN_MS = 30 * 24 * 60 * 60 * 1000;

const DEFAULT_APP_BUNDLE_NAME = 'com.hengqutiandi.vncviewer';
const STORE_DEEP_LINK_PREFIX = 'store://appgallery.huawei.com/app/detail?id=';
const STORE_APP_LINK_PREFIX = 'https://appgallery.huawei.com/app/detail?id=';

// 1021500006：用户未登录华为账号；1021500007/1021500009：当前版本已评价或一年内已评价；1021500008：评论数已达上限
const ERR_NOT_SIGNED_IN = 1021500006;
const ERR_ALREADY_COMMENTED = 1021500007;
const ERR_COMMENT_LIMIT_REACHED = 1021500008;
const ERR_COMMENTED_WITHIN_YEAR = 1021500009;

export const RATING_RESULT_DIALOG_SHOWN = 0;
export const RATING_RESULT_ALREADY_RATED = 2;
export const RATING_RESULT_FAILED = 3;
// 评价弹窗次数已达上限（一年最多 3 次，打开即计一次）
export const RATING_RESULT_COMMENT_LIMIT = 4;
// 未登录华为账号，应用内评价弹窗无法拉起
export const RATING_RESULT_NEED_SIGNIN = 5;

// 记录一次成功连接，作为评价提示的里程碑计数
export async function recordRatingSession(context?: common.UIAbilityContext): Promise<void> {
  if (!context) return;
  try {
    const pref = await dataPreferences.getPreferences(context, { name: PREF_STORE_NAME });
    const count = await readNumber(pref, RATING_SESSION_COUNT_KEY, 0);
    await pref.put(RATING_SESSION_COUNT_KEY, count + 1);
    await pref.flush();
  } catch (e) {
    console.error('Failed to record rating session', e);
  }
}

export async function shouldPromptRating(context?: common.UIAbilityContext): Promise<boolean> {
  if (!context) return false;
  try {
    const state = await loadRatingState(context);
    if (state.done || state.neverAsk) return false;
    if (state.sessionCount < PROMPT_MIN_SESSIONS) return false;
    if (state.promptCount >= PROMPT_MAX_TIMES) return false;
    if (state.lastPromptAt > 0 && Date.now() - state.lastPromptAt < PROMPT_COOLDOWN_MS) return false;
    return true;
  } catch (e) {
    console.error('Failed to check rating prompt state', e);
    return false;
  }
}

// 用户选择“不再提示”后永久关闭主动询问
export async function markRatingNeverAsk(context?: common.UIAbilityContext): Promise<void> {
  if (!context) return;
  try {
    const pref = await dataPreferences.getPreferences(context, { name: PREF_STORE_NAME });
    await pref.put(RATING_NEVER_ASK_KEY, true);
    await pref.flush();
  } catch (e) {
    console.error('Failed to mark rating never ask', e);
  }
}

export async function markRatingPrompted(context?: common.UIAbilityContext): Promise<void> {
  if (!context) return;
  try {
    const state = await loadRatingState(context);
    const pref = await dataPreferences.getPreferences(context, { name: PREF_STORE_NAME });
    await pref.put(RATING_PROMPT_COUNT_KEY, state.promptCount + 1);
    await pref.put(RATING_LAST_PROMPT_AT_KEY, Date.now());
    await pref.flush();
  } catch (e) {
    console.error('Failed to mark rating prompted', e);
  }
}

async function markRatingDone(context: common.UIAbilityContext): Promise<void> {
  try {
    const pref = await dataPreferences.getPreferences(context, { name: PREF_STORE_NAME });
    await pref.put(RATING_DONE_KEY, true);
    await pref.flush();
  } catch (e) {
    console.error('Failed to mark rating done', e);
  }
}

// 拉起应用内评分弹窗，只返回结果码，跳转应用市场由页面在提示原因后统一处理
// 注意：弹窗由应用市场客户端负责提交，应用侧拿不到“是否已提交成功”的回执，
// 因此只有应用市场返回明确的“已评价”错误码时才记录为已完成。
export async function requestAppRating(context?: common.UIAbilityContext): Promise<number> {
  if (!context) return RATING_RESULT_FAILED;
  try {
    await commentManager.showCommentDialog(context);
    console.info('showCommentDialog finished without error, review submission is unknown');
    return RATING_RESULT_DIALOG_SHOWN;
  } catch (e) {
    const error = e as ErrorLike;
    const code = typeof error?.code === 'number' ? error.code : 0;
    console.error(`showCommentDialog failed, code: ${code}, message: ${error?.message ?? ''}`);
    if (code === ERR_ALREADY_COMMENTED || code === ERR_COMMENTED_WITHIN_YEAR) {
      await markRatingDone(context);
      return RATING_RESULT_ALREADY_RATED;
    }
    // 应用市场规则：评分弹窗打开即计一次（取消也算），同一用户一年内最多 3 次，
    // 超限后 showCommentDialog 会被拒绝（1021500008）
    if (code === ERR_COMMENT_LIMIT_REACHED) {
      return RATING_RESULT_COMMENT_LIMIT;
    }
    if (code === ERR_NOT_SIGNED_IN) {
      return RATING_RESULT_NEED_SIGNIN;
    }
    return RATING_RESULT_FAILED;
  }
}

// 跳转应用市场写评论页（供页面在提示用户后调用）
export async function openAppGalleryReviewPage(context?: common.UIAbilityContext): Promise<boolean> {
  if (!context) return false;
  const bundleName = resolveBundleName(context);
  try {
    const want: RatingWant = {
      action: 'ohos.want.action.appdetail',
      uri: `${STORE_DEEP_LINK_PREFIX}${bundleName}&action=write-review`
    };
    await context.startAbility(want);
    return true;
  } catch (e) {
    console.error('Failed to open AppGallery review page via deep link', e);
  }
  // 兜底：无法通过 deep link 拉起应用市场时，改用链接方式打开应用详情页
  try {
    await context.openLink(`${STORE_APP_LINK_PREFIX}${bundleName}&action=write-review`,
      { appLinkingOnly: false });
    return true;
  } catch (e) {
    console.error('Failed to open AppGallery review page', e);
    return false;
  }
}

function resolveBundleName(context: common.UIAbilityContext): string {
  const bundleName = context?.abilityInfo?.bundleName;
  return (typeof bundleName === 'string' && bundleName) ? bundleName : DEFAULT_APP_BUNDLE_NAME;
}

async function loadRatingState(context: common.UIAbilityContext): Promise<RatingState> {
  const pref = await dataPreferences.getPreferences(context, { name: PREF_STORE_NAME });
  return {
    done: await readBoolean(pref, RATING_DONE_KEY, false),
    neverAsk: await readBoolean(pref, RATING_NEVER_ASK_KEY, false),
    promptCount: await readNumber(pref, RATING_PROMPT_COUNT_KEY, 0),
    lastPromptAt: await readNumber(pref, RATING_LAST_PROMPT_AT_KEY, 0),
    sessionCount: await readNumber(pref, RATING_SESSION_COUNT_KEY, 0)
  };
}

async function readNumber(pref: dataPreferences.Preferences, key: string, fallback: number): Promise<number> {
  const raw = (await pref.get(key, fallback)) as number;
  return (typeof raw === 'number' && Number.isFinite(raw)) ? raw : fallback;
}

async function readBoolean(pref: dataPreferences.Preferences, key: string, fallback: boolean): Promise<boolean> {
  const raw = (await pref.get(key, fallback)) as boolean;
  return typeof raw === 'boolean' ? raw : fallback;
}
