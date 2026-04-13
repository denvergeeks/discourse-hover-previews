// ─── Constants ────────────────────────────────────────────────────────────────

export const TOOLTIP_ID = "topic-hover-card-tooltip";
export const TOOLTIP_SELECTOR = `#${TOOLTIP_ID}`;
export const DELAY_HIDE = 280;
export const VIEWPORT_MARGIN = 8;
export const MOBILE_BREAKPOINT = 767;
export const TOPIC_LINK_RE = /\/t\/(?:[^/]+\/)?([0-9]+)(?:\/[0-9]+)?/;

// ─── Config reader ────────────────────────────────────────────────────────────

function intSetting(raw, fallback, min = null, max = null) {
  const n = Number(raw);
  if (!Number.isFinite(n)) return fallback;

  let value = n;
  if (min !== null) value = Math.max(min, value);
  if (max !== null) value = Math.min(max, value);
  return value;
}

function stringSetting(raw, fallback = "") {
  return typeof raw === "string" ? raw.trim() || fallback : fallback;
}

export function readConfig(settings) {
  return {
    enabled: settings.enabled !== false,
    debugMode: !!settings.debug_mode,

    delayShow: intSetting(settings.delay_show, 280, 0, 5000),
    cardWidth: stringSetting(settings.card_width, "32rem"),
    mobileWidthPercent: intSetting(settings.mobile_width_percent, 92, 40, 100),
    mobileEnabled: settings.mobile_enabled !== false,

    topicCacheMax: intSetting(settings.topic_cache_max, 100, 1, 1000),

    enableOnTopicList: settings.enable_on_topic_list !== false,
    enableOnLatest: settings.enable_on_latest !== false,
    enableOnCategories: settings.enable_on_categories !== false,
    enableOnTags: settings.enable_on_tags !== false,
    enableOnSearch: settings.enable_on_search !== false,
    enableOnTopicPage: settings.enable_on_topic_page !== false,
    enableOnUserProfile: settings.enable_on_user_profile !== false,
    enableOnOther: settings.enable_on_other !== false,

    userPreferenceFieldName: stringSetting(
      settings.user_preference_field_name,
      ""
    ),
    resolveUserFieldIdForAdmins:
      settings.resolve_user_field_id_for_admins !== false,
  };
}

// ─── Debug ────────────────────────────────────────────────────────────────────

export function logDebug(config, ...args) {
  if (config?.debugMode) {
    // eslint-disable-next-line no-console
    console.debug("[hover-previews]", ...args);
  }
}

// ─── Viewport state ───────────────────────────────────────────────────────────

export function createViewportState() {
  return {
    isMobileLayout() {
      return window.innerWidth <= MOBILE_BREAKPOINT;
    },

    isMobileInteractionMode() {
      return (
        this.isMobileLayout() ||
        window.matchMedia("(hover: none)").matches ||
        window.matchMedia("(pointer: coarse)").matches
      );
    },
  };
}

// ─── Simple LRU cache helpers ────────────────────────────────────────────────

export function getCachedValue(map, key) {
  if (!map.has(key)) return undefined;
  const value = map.get(key);
  map.delete(key);
  map.set(key, value);
  return value;
}

export function setCachedValue(map, key, value, max = 100) {
  if (map.has(key)) {
    map.delete(key);
  }
  map.set(key, value);

  while (map.size > max) {
    const firstKey = map.keys().next().value;
    map.delete(firstKey);
  }
}

// ─── HTTP / JSON helper ──────────────────────────────────────────────────────

export async function getJSON(url, options = {}) {
  const response = await fetch(url, {
    credentials: "same-origin",
    headers: {
      Accept: "application/json",
      "X-Requested-With": "XMLHttpRequest",
    },
    ...options,
  });

  if (!response.ok) {
    const error = new Error(`HTTP ${response.status} for ${url}`);
    error.status = response.status;
    throw error;
  }

  return await response.json();
}

// ─── URL / text sanitizers ───────────────────────────────────────────────────

export function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function sanitizeURL(url) {
  if (!url) return null;

  try {
    const parsed = new URL(url, window.location.origin);

    if (!["http:", "https:"].includes(parsed.protocol)) {
      return null;
    }

    return parsed.toString();
  } catch {
    return null;
  }
}

export function safeAvatarURL(template, size = 24) {
  if (!template) return null;

  const replaced = String(template).replace("{size}", String(size));
  const full = replaced.startsWith("http")
    ? replaced
    : `${window.location.origin}${replaced}`;

  return sanitizeURL(full);
}

export function sanitizeExcerpt(html) {
  if (!html) return "";

  const doc = new DOMParser().parseFromString(html, "text/html");
  doc
    .querySelectorAll(
      "figure, figcaption, img, picture, source, .lightbox-wrapper, .image-wrapper, .d-lazyload"
    )
    .forEach((el) => el.remove());

  return (doc.body.textContent || "").replace(/\s+/g, " ").trim();
}

export function normalizeTag(tag) {
  if (!tag) return null;
  if (typeof tag === "string") return tag.trim();

  if (typeof tag === "object") {
    return (
      tag.name ||
      tag.id ||
      tag.text ||
      tag.value ||
      tag.slug ||
      null
    );
  }

  return String(tag).trim();
}

export function formatNumber(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return "0";

  if (n >= 1000) {
    return `${(n / 1000).toFixed(1).replace(/\.0$/, "")}k`;
  }

  return String(n);
}

// ─── Topic URL parsing ───────────────────────────────────────────────────────

export function currentTopicIdFromLocation() {
  const m = window.location.pathname.match(TOPIC_LINK_RE);
  return m ? parseInt(m[1], 10) : null;
}

export function currentTopicPathFromLocation() {
  try {
    return new URL(window.location.href).pathname.replace(/\/+$/, "");
  } catch {
    return window.location.pathname.replace(/\/+$/, "");
  }
}

export function parseTopicUrl(href) {
  if (!href) return null;

  try {
    const url = new URL(href, window.location.origin);
    if (url.origin !== window.location.origin) return null;

    const match = url.pathname.match(TOPIC_LINK_RE);
    if (!match) return null;

    return {
      url,
      topicId: parseInt(match[1], 10),
    };
  } catch {
    return null;
  }
}

export function topicIdFromHref(href) {
  return parseTopicUrl(href)?.topicId ?? null;
}

// ─── Link area detection ─────────────────────────────────────────────────────

export function inCookedPost(link) {
  return !!link?.closest(".topic-post .cooked a");
}

export function isCurrentTopicLink(link) {
  const parsed = parseTopicUrl(link?.href);
  if (!parsed) return false;

  const currentTopicId = currentTopicIdFromLocation();
  if (currentTopicId && parsed.topicId === currentTopicId) return true;

  return parsed.url.pathname.replace(/\/+$/, "") === currentTopicPathFromLocation();
}

export function isCookedPostFragmentLink(link) {
  if (!link || !inCookedPost(link)) return false;

  const href = link.getAttribute("href") || "";
  if (href.startsWith("#")) return true;

  try {
    const url = new URL(link.href, window.location.origin);
    return !!url.hash;
  } catch {
    return false;
  }
}

export function isEligiblePreviewLink(link, config) {
  if (!link) return false;
  if (link.closest(".topic-hover-card, #topic-hover-card-tooltip")) return false;

  const parsed = parseTopicUrl(link.href);
  if (!parsed) return false;

  if (inCookedPost(link)) {
    if (isCurrentTopicLink(link)) {
      logDebug(config, "Skipping current-topic cooked-post link", {
        href: link.href,
      });
      return false;
    }

    if (isCookedPostFragmentLink(link)) {
      logDebug(config, "Skipping cooked-post fragment link", {
        href: link.href,
      });
      return false;
    }
  }

  return true;
}

export function linkInSupportedArea(link, config) {
  if (!(link instanceof Element)) return false;
  if (!isEligiblePreviewLink(link, config)) return false;

  if (config.enableOnTopicPage && link.closest(".topic-post, .topic-body, .suggested-topics")) {
    return true;
  }

  if (config.enableOnSearch && link.closest(".search-results, .search-result-topic")) {
    return true;
  }

  if (config.enableOnUserProfile && link.closest(".user-main, .user-content")) {
    return true;
  }

  if (
    config.enableOnTopicList &&
    link.closest(
      ".topic-list, .latest-topic-list, .top-topic-list, .new-topic-list, .unread-topic-list"
    )
  ) {
    return true;
  }

  if (config.enableOnLatest && link.closest(".latest-topic-list")) {
    return true;
  }

  if (
    config.enableOnCategories &&
    link.closest(".categories-list, .category-list, .category-boxes, .categories-and-latest-topics, .categories-and-featured-topics, .categories-with-featured-topics, .categories-only")
  ) {
    return true;
  }

  if (config.enableOnTags && link.closest(".tag-topic-list, .tags-page, .discourse-tag")) {
    return true;
  }

  if (config.enableOnOther && link.closest(".cooked")) {
    return true;
  }

  return false;
}

// ─── User preference field helpers ───────────────────────────────────────────

function fieldValueIsTruthy(value) {
  if (value === true || value === 1) return true;

  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    return ["1", "true", "yes", "on", "checked"].includes(normalized);
  }

  return false;
}

export function normalizedFieldKeyVariants(raw) {
  const value = String(raw ?? "").trim();
  if (!value) return [];

  const lower = value.toLowerCase();
  const variants = new Set([value, lower]);

  if (/^\d+$/.test(value)) {
    variants.add(`user_field_${value}`);
  }

  const prefixed = lower.match(/^user_field_(\d+)$/);
  if (prefixed) {
    variants.add(prefixed[1]);
    variants.add(`user_field_${prefixed[1]}`);
  }

  return [...variants];
}

export function findTruthyFieldMatch(fields, candidates) {
  if (!fields || !candidates?.length) return false;

  return candidates.some((candidate) => {
    const value = fields[candidate];
    return fieldValueIsTruthy(value);
  });
}

export function currentUserIsStaffLike(user) {
  return !!(user?.admin || user?.moderator || user?.staff);
}