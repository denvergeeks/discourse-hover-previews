import { later, cancel } from "@ember/runloop";
import { iconHTML } from "discourse-common/lib/icon-library";
import { apiInitializer } from "discourse/lib/api";

const DELAY_HIDE = 200;
const VIEWPORT_MARGIN = 12;
const MOBILE_BREAKPOINT = 768;
const TOOLTIP_CLASS = "topic-hover-card-tooltip";
const TOOLTIP_SELECTOR = `.${TOOLTIP_CLASS}`;
const TOPIC_LINK_RE = /\/t\/(?:[^/]+\/)?([0-9]+)(?:\/[0-9]+)?/;

let initialized = false;

function numberSetting(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function stringSetting(value, fallback = "") {
  return typeof value === "string" && value.trim() ? value : fallback;
}

function boolSetting(value, fallback = false) {
  return typeof value === "boolean" ? value : fallback;
}

function readConfig() {
  return {
    delayShow: numberSetting(settings.card_delay_ms, 300),
    cardWidth: stringSetting(settings.card_width, "32rem"),
    mobileEnabled: boolSetting(settings.enable_on_mobile, false),
    mobileWidthPercent: numberSetting(settings.mobile_width_percent, 100),
    topicCacheMax: numberSetting(settings.topic_cache_max, 100),
    userPreferenceFieldName: stringSetting(
      settings.user_preference_field_name,
      "disable_topic_hover_cards"
    ),
    debugMode: boolSetting(settings.debug_mode, false),
    resolveUserFieldIdForAdmins: boolSetting(
      settings.resolve_user_field_id_for_admins,
      true
    ),
  };
}

function logDebug(config, ...args) {
  if (!config.debugMode) return;
  console.info("[topic-hover-cards]", ...args);
}

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function sanitizeURL(url) {
  if (!url) return null;

  try {
    const parsed = new URL(url, window.location.origin);

    if (
      parsed.protocol !== "http:" &&
      parsed.protocol !== "https:" &&
      parsed.protocol !== "data:"
    ) {
      return null;
    }

    return parsed.toString();
  } catch {
    return null;
  }
}

function createViewportState() {
  const anyHoverQuery = window.matchMedia("(any-hover: hover)");
  const hoverQuery = window.matchMedia("(hover: hover)");

  return {
    hasHoverInput() {
      return anyHoverQuery.matches || hoverQuery.matches;
    },
    isNarrowViewport() {
      return window.innerWidth < MOBILE_BREAKPOINT;
    },
    isMobileInteractionMode() {
      return !this.hasHoverInput() && this.isNarrowViewport();
    },
    isMobileLayout() {
      return this.isNarrowViewport();
    },
  };
}

async function getJSON(url, options = {}) {
  const response = await fetch(url, {
    credentials: "same-origin",
    headers: { Accept: "application/json" },
    ...options,
  });

  if (!response.ok) {
    throw new Error(`Request failed: ${response.status} ${response.statusText}`);
  }

  return await response.json();
}

function currentTopicIdFromLocation() {
  const m = window.location.pathname.match(TOPIC_LINK_RE);
  return m ? parseInt(m[1], 10) : null;
}

function currentTopicPathFromLocation() {
  try {
    return new URL(window.location.href).pathname.replace(/\/+$/, "");
  } catch {
    return window.location.pathname.replace(/\/+$/, "");
  }
}

function parseTopicUrl(href) {
  if (!href) return null;

  try {
    const url = new URL(href, window.location.origin);
    if (url.origin !== window.location.origin) return null;

    const match = url.pathname.match(TOPIC_LINK_RE);
    if (!match) return null;

    return { url, topicId: parseInt(match[1], 10) };
  } catch {
    return null;
  }
}

function topicIdFromHref(href) {
  return parseTopicUrl(href)?.topicId ?? null;
}

function formatNumber(n) {
  if (!n && n !== 0) return "0";
  if (n >= 1000) return `${(n / 1000).toFixed(1).replace(/\.0$/, "")}k`;
  return String(n);
}

function sanitizeExcerpt(html) {
  if (!html) return "";

  const doc = new DOMParser().parseFromString(html, "text/html");
  doc
    .querySelectorAll(
      "figure, figcaption, img, picture, source, .lightbox-wrapper, .image-wrapper, .d-lazyload"
    )
    .forEach((el) => el.remove());

  return (doc.body.textContent || "").replace(/\s+/g, " ").trim();
}

function skeletonHTML() {
  return `
    <div class="topic-hover-card topic-hover-card--density-default" aria-busy="true">
      <div class="topic-hover-card__body">
        <div class="topic-hover-card__skeleton">
          <div class="skeleton-line title"></div>
          <div class="skeleton-line title-2"></div>
          <div class="skeleton-line excerpt"></div>
          <div class="skeleton-line excerpt-2"></div>
          <div class="skeleton-line excerpt-3"></div>
          <div class="skeleton-line meta"></div>
        </div>
      </div>
    </div>`;
}

function discourseIcon(name) {
  try {
    return iconHTML(name) || "";
  } catch {
    return "";
  }
}

function getSiteCategories(api) {
  return api.container.lookup("service:site")?.categories || [];
}

function findCategoryById(categories, categoryId) {
  if (!categories?.length || !categoryId) return null;
  return categories.find((c) => Number(c.id) === Number(categoryId)) || null;
}

function normalizeTag(tag) {
  if (!tag) return null;
  if (typeof tag === "string") return tag;
  if (typeof tag === "object") {
    return tag.name || tag.id || tag.text || tag.value || tag.slug || null;
  }
  return String(tag);
}

function mobileBool(name, mobileName, isMobile) {
  return isMobile ? !!settings[mobileName] : !!settings[name];
}

function mobileInt(name, mobileName, fallback, isMobile) {
  const raw = isMobile
    ? settings[mobileName] ?? settings[name] ?? fallback
    : settings[name] ?? fallback;
  return numberSetting(raw, fallback);
}

function densitySetting(isMobile) {
  const value = isMobile
    ? settings.density_mobile ?? settings.density ?? "default"
    : settings.density ?? "default";

  return ["default", "cozy", "compact"].includes(value) ? value : "default";
}

function thumbnailSizeMode() {
  const value = settings.thumbnail_size_mode ?? "auto_fit_height";
  return ["manual", "auto_fit_height"].includes(value)
    ? value
    : "auto_fit_height";
}

function thumbnailPlacement() {
  const value = settings.thumbnail_placement ?? "left";
  return ["top", "right", "bottom", "left"].includes(value) ? value : "left";
}

function fieldValueIsTruthy(value) {
  if (value === true || value === 1) return true;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    return ["1", "true", "yes", "on", "checked"].includes(normalized);
  }
  return false;
}

function currentUserIsStaffLike(currentUser) {
  return !!(currentUser?.admin || currentUser?.staff || currentUser?.moderator);
}

function normalizedFieldKeyVariants(fieldNameOrKey) {
  if (!fieldNameOrKey) return [];
  const raw = String(fieldNameOrKey).trim();
  if (!raw) return [];

  const keys = new Set([raw]);
  if (/^\d+$/.test(raw)) keys.add(`user_field_${raw}`);
  if (/^user_field_\d+$/.test(raw)) keys.add(raw.replace(/^user_field_/, ""));
  return [...keys];
}

function findTruthyFieldMatch(record, candidateKeys) {
  if (!record || !candidateKeys?.length) return null;

  for (const key of candidateKeys) {
    if (key in record && fieldValueIsTruthy(record[key])) {
      return { key, value: record[key] };
    }
  }

  return null;
}

function getCachedValue(cache, key) {
  if (!cache.has(key)) return null;
  const value = cache.get(key);
  cache.delete(key);
  cache.set(key, value);
  return value;
}

function setCachedValue(cache, key, value, max) {
  if (cache.has(key)) cache.delete(key);
  cache.set(key, value);
  if (cache.size > max) {
    cache.delete(cache.keys().next().value);
  }
}

function inDocCategoriesView(link) {
  return !!link.closest(
    ".doc-categories a, .doc-categories-container a, [class*='doc-categories'] a"
  );
}

function inKanbanView(link) {
  return !!link.closest(
    ".kanban-board a, .kanban-column a, .kanban-card a, [class*='kanban'] a"
  );
}

function inCategoryHomepageTopicList(link) {
  return !!link.closest(
    ".categories-and-latest-topics a.title, " +
      ".categories-and-latest-topics .main-link a, " +
      ".categories-and-featured-topics a.title, " +
      ".categories-and-featured-topics .main-link a, " +
      ".categories-with-featured-topics a.title, " +
      ".categories-with-featured-topics .main-link a, " +
      ".categories-only a.title, " +
      ".categories-only .main-link a"
  );
}

function inTopicList(link) {
  return !!link.closest(
    ".topic-list a.title, .topic-list .main-link a, [class*='topic-list'] a.title, [class*='topic-list'] .main-link a"
  );
}

function inSuggestedTopics(link) {
  return !!link.closest(
    ".suggested-topics a.title, .suggested-topics .main-link a"
  );
}

function inCookedPost(link) {
  return !!link.closest(".topic-post .cooked a");
}

function isCurrentTopicLink(link) {
  const parsed = parseTopicUrl(link?.href);
  if (!parsed) return false;

  const currentTopicId = currentTopicIdFromLocation();
  if (currentTopicId && parsed.topicId === currentTopicId) return true;

  return parsed.url.pathname.replace(/\/+$/, "") === currentTopicPathFromLocation();
}

function isCookedPostFragmentLink(link) {
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

function isEligiblePreviewLink(link, config) {
  if (!link) return false;
  if (!parseTopicUrl(link.href)) return false;

  if (inCookedPost(link)) {
    if (isCurrentTopicLink(link)) {
      logDebug(config, "Skipping current-topic cooked-post link", { href: link.href });
      return false;
    }

    if (isCookedPostFragmentLink(link)) {
      logDebug(config, "Skipping cooked-post fragment link", { href: link.href });
      return false;
    }
  }

  return true;
}

function linkInSupportedArea(link, config) {
  if (!isEligiblePreviewLink(link, config)) return false;
  if (settings.enable_on_suggested_topic_links && inSuggestedTopics(link)) return true;
  if (settings.enable_on_doc_categories && inDocCategoriesView(link)) return true;
  if (settings.enable_on_kanban_boards && inKanbanView(link)) return true;
  if (
    settings.enable_on_category_homepage_topic_lists &&
    inCategoryHomepageTopicList(link)
  ) {
    return true;
  }
  if (settings.enable_on_topic_lists && inTopicList(link)) return true;

  if (inCookedPost(link)) {
    const post = link.closest(".topic-post");
    const isFirstPost = post?.classList.contains("topic-owner");
    if (isFirstPost && settings.enable_on_topics) return true;
    if (!isFirstPost && settings.enable_on_replies) return true;
  }

  return false;
}

function safeAvatarURL(avatarTemplate, size = 24) {
  if (!avatarTemplate) return null;
  const replaced = avatarTemplate.replace("{size}", String(size));
  const full = replaced.startsWith("http")
    ? replaced
    : `${window.location.origin}${replaced}`;
  return sanitizeURL(full);
}

function buildThumbnailHTML(topic, mode, isMobile) {
  const imageURL = sanitizeURL(topic.image_url);
  if (!imageURL) return "";

  if (isMobile || mode === "manual") {
    return `
      <div class="topic-hover-card__thumbnail">
        <img src="${escapeHTML(imageURL)}" alt="" loading="lazy" decoding="async">
      </div>
    `;
  }

  return `
    <div class="topic-hover-card__thumbnail">
      <img class="topic-hover-card__thumbnail-bg" src="${escapeHTML(imageURL)}" alt="" loading="lazy" decoding="async" aria-hidden="true">
      <span class="topic-hover-card__thumbnail-overlay" aria-hidden="true"></span>
      <img class="topic-hover-card__thumbnail-fg" src="${escapeHTML(imageURL)}" alt="" loading="lazy" decoding="async">
    </div>
  `;
}

function buildCategoryHTML(topic, categories, isMobile) {
  if (!mobileBool("show_category", "show_category_mobile", isMobile)) return "";
  if (!topic.category_id) return "";

  const category = findCategoryById(categories, topic.category_id);
  const name =
    category?.name || category?.slug || topic.category_name || topic.category_slug || "";

  const rawColor = category?.color || topic.category_color || null;
  const color = rawColor ? `#${String(rawColor).replace(/^#/, "")}` : null;

  if (!name) return "";

  return `
    <span class="topic-hover-card__category">
      <span class="topic-hover-card__category-badge"${
        color ? ` style="--thc-category-color: ${escapeHTML(color)};"` : ""
      }>
        <span class="topic-hover-card__category-text">${escapeHTML(name)}</span>
      </span>
    </span>
  `;
}

function buildTagsHTML(topic, isMobile) {
  if (!mobileBool("show_tags", "show_tags_mobile", isMobile)) return "";
  if (!Array.isArray(topic.tags) || !topic.tags.length) return "";

  const tags = topic.tags.map(normalizeTag).filter(Boolean);
  if (!tags.length) return "";

  return `
    <div class="topic-hover-card__tags">
      ${tags
        .map(
          (tag) => `
            <span class="topic-hover-card__tag">
              <span class="topic-hover-card__tag-text">${escapeHTML(tag)}</span>
            </span>`
        )
        .join("")}
    </div>
  `;
}

function buildBadgesHTML(topic, categories, isMobile) {
  const categoryHTML = buildCategoryHTML(topic, categories, isMobile);
  const tagsHTML = buildTagsHTML(topic, isMobile);
  if (!categoryHTML && !tagsHTML) return "";
  return `<div class="topic-hover-card__badges">${categoryHTML}${tagsHTML}</div>`;
}

function buildTitleHTML(topic, isMobile) {
  if (!mobileBool("show_title", "show_title_mobile", isMobile)) return "";
  const title = topic.fancy_title ?? topic.title ?? "(no title)";
  return `<div class="topic-hover-card__title">${escapeHTML(title)}</div>`;
}

function buildExcerptHTML(topic, isMobile) {
  if (!mobileBool("show_excerpt", "show_excerpt_mobile", isMobile)) return "";

  const lines = mobileInt("excerpt_length", "excerpt_length_mobile", 3, isMobile);
  const firstPost = topic.post_stream?.posts?.[0];
  const excerptSource = topic.excerpt || firstPost?.excerpt || firstPost?.cooked || "";
  const cleanedExcerpt = topic.__thc_excerpt ?? sanitizeExcerpt(excerptSource);
  topic.__thc_excerpt = cleanedExcerpt;
  const finalExcerpt = cleanedExcerpt.length >= 20 ? cleanedExcerpt : "";

  if (!finalExcerpt) return "";
  return `<div class="topic-hover-card__excerpt" style="--thc-excerpt-lines:${lines};">${escapeHTML(finalExcerpt)}</div>`;
}

function buildOpHTML(topic, isMobile) {
  if (!mobileBool("show_op", "show_op_mobile", isMobile)) return "";

  const op =
    topic.details?.created_by ||
    (topic.post_stream?.posts?.[0]?.username && {
      username: topic.post_stream.posts[0].username,
      avatar_template: topic.post_stream.posts[0].avatar_template,
    }) ||
    topic.posters?.[0]?.user;

  if (!op?.username) return "";

  const avatarURL = safeAvatarURL(op.avatar_template, 24);
  const avatarImg = avatarURL
    ? `<img src="${escapeHTML(avatarURL)}" width="24" height="24" alt="" loading="lazy" decoding="async">`
    : "";

  return `<span class="topic-hover-card__op">${avatarImg}<span class="username">${escapeHTML(
    op.username
  )}</span></span>`;
}

function buildPublishDateHTML(topic, isMobile) {
  if (!mobileBool("show_publish_date", "show_publish_date_mobile", isMobile)) return "";
  if (!topic.created_at) return "";

  const d = new Date(topic.created_at);
  if (Number.isNaN(d.getTime())) return "";

  const fmt = d.toLocaleDateString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
  return `<span class="topic-hover-card__publish-date">${escapeHTML(fmt)}</span>`;
}

function buildStatsHTML(topic, isMobile) {
  const stats = [];

  if (mobileBool("show_views", "show_views_mobile", isMobile)) {
    stats.push(
      `<span class="topic-hover-card__stat">${discourseIcon("far-eye")} ${escapeHTML(
        formatNumber(topic.views)
      )}</span>`
    );
  }

  if (mobileBool("show_reply_count", "show_reply_count_mobile", isMobile)) {
    const replyCount = topic.reply_count ?? Math.max((topic.posts_count ?? 1) - 1, 0);
    stats.push(
      `<span class="topic-hover-card__stat">${discourseIcon("comment")} ${escapeHTML(
        formatNumber(replyCount)
      )}</span>`
    );
  }

  if (mobileBool("show_likes", "show_likes_mobile", isMobile)) {
    const likes = topic.like_count ?? topic.topic_post_like_count ?? 0;
    stats.push(
      `<span class="topic-hover-card__stat">${discourseIcon("heart")} ${escapeHTML(
        formatNumber(likes)
      )}</span>`
    );
  }

  if (mobileBool("show_activity", "show_activity_mobile", isMobile) && topic.last_posted_at) {
    const d = new Date(topic.last_posted_at);
    if (!Number.isNaN(d.getTime())) {
      const fmt = d.toLocaleDateString(undefined, {
        month: "short",
        day: "numeric",
        year: "numeric",
      });
      stats.push(
        `<span class="topic-hover-card__stat">${discourseIcon("clock")} ${escapeHTML(
          fmt
        )}</span>`
      );
    }
  }

  return stats.length ? `<div class="topic-hover-card__stats">${stats.join("")}</div>` : "";
}

function buildMetadataHTML(topic, isMobile) {
  const content = [
    buildOpHTML(topic, isMobile),
    buildPublishDateHTML(topic, isMobile),
    buildStatsHTML(topic, isMobile),
  ]
    .filter(Boolean)
    .join("");

  return content ? `<div class="topic-hover-card__metadata">${content}</div>` : "";
}

function buildMobileActionsHTML(topic, isMobile) {
  if (!isMobile) return "";
  const slug = escapeHTML(String(topic.slug || topic.id || ""));
  const id = escapeHTML(String(topic.id || ""));
  const topicUrl = `${window.location.origin}/t/${slug}/${id}`;
  return `<div class="topic-hover-card__mobile-actions"><a class="btn btn-primary topic-hover-card__open-topic" href="${topicUrl}" data-thc-open-topic>Open topic</a></div>`;
}

function buildCardHTML(topic, categories, isMobile = false) {
  const showThumbnail = mobileBool("show_thumbnail", "show_thumbnail_mobile", isMobile);
  const desktopThumbnailSizePercent = numberSetting(settings.thumbnail_size_percent, 15);
  const autoFitMaxWidth = stringSetting(
    settings.thumbnail_auto_fit_max_width,
    "10rem"
  );
  const configuredPlacement = thumbnailPlacement();
  const placement = isMobile ? "top" : configuredPlacement;
  const density = densitySetting(isMobile);
  const densityClass = `topic-hover-card--density-${density}`;
  const sizeMode = isMobile ? "manual" : thumbnailSizeMode();
  const sizeModeClass =
    sizeMode === "auto_fit_height"
      ? "topic-hover-card--thumb-size-auto-fit-height"
      : "topic-hover-card--thumb-size-manual";

  const mobileCloseButton = isMobile
    ? `<button class="topic-hover-card__close" type="button" data-thc-close aria-label="Close preview">
        <svg class="topic-hover-card__close-icon" viewBox="0 0 16 16" aria-hidden="true" focusable="false">
          <path d="M4.2 4.2 11.8 11.8M11.8 4.2 4.2 11.8" />
        </svg>
      </button>`
    : "";

  const thumbnail =
    topic.image_url && showThumbnail ? buildThumbnailHTML(topic, sizeMode, isMobile) : "";

  const bodyInner = `
    <div class="topic-hover-card__body">
      ${mobileCloseButton}
      ${buildTitleHTML(topic, isMobile)}
      ${buildExcerptHTML(topic, isMobile)}
      ${buildMetadataHTML(topic, isMobile)}
      ${buildBadgesHTML(topic, categories, isMobile)}
      ${buildMobileActionsHTML(topic, isMobile)}
    </div>
  `;

  const wrapperStyle = isMobile
    ? ""
    : `style="--thc-thumbnail-size-percent:${desktopThumbnailSizePercent}; --thc-auto-thumb-max-width:${escapeHTML(
        autoFitMaxWidth
      )};"`;

  switch (placement) {
    case "left":
      return `<div class="topic-hover-card topic-hover-card--thumb-left ${sizeModeClass} ${densityClass}" ${wrapperStyle}>${thumbnail}${bodyInner}</div>`;
    case "right":
      return `<div class="topic-hover-card topic-hover-card--thumb-right ${sizeModeClass} ${densityClass}" ${wrapperStyle}>${thumbnail}${bodyInner}</div>`;
    case "bottom":
      return `<div class="topic-hover-card topic-hover-card--thumb-bottom ${sizeModeClass} ${densityClass}" ${wrapperStyle}>${bodyInner}${thumbnail}</div>`;
    case "top":
    default:
      return `<div class="topic-hover-card topic-hover-card--thumb-top ${sizeModeClass} ${densityClass}" ${wrapperStyle}>${thumbnail}${bodyInner}</div>`;
  }
}

export default apiInitializer((api) => {
  if (initialized) return;
  initialized = true;

  const config = readConfig();
  const categories = getSiteCategories(api);
  const currentUser = api.getCurrentUser?.() || null;
  const viewport = createViewportState();

  let tooltip = null;
  let showTimer = null;
  let hideTimer = null;
  let clearSuppressionTimer = null;
  let currentTopicId = null;
  let currentAbortController = null;
  let isInsideCard = false;
  let suppressNextClick = false;
  let resolvedUserFieldId = null;
  let resolvedUserFieldIdPromise = null;

  const topicCache = new Map();
  const renderCache = new Map();
  const inFlightFetches = new Map();
  const cleanupFns = [];
  let pageChangeBound = false;

  function addCleanup(target, type, handler, options) {
    target.addEventListener(type, handler, options);
    cleanupFns.push(() => target.removeEventListener(type, handler, options));
  }

  function runCleanup() {
    while (cleanupFns.length) {
      const fn = cleanupFns.pop();
      try {
        fn?.();
      } catch {
        // no-op
      }
    }
  }

  function ensureTooltip() {
    if (tooltip?.isConnected) return;

    tooltip = document.querySelector(TOOLTIP_SELECTOR);
    if (!tooltip) {
      tooltip = document.createElement("div");
      tooltip.className = TOOLTIP_CLASS;
      tooltip.setAttribute("role", "tooltip");
      tooltip.setAttribute("aria-live", "polite");
      document.body.appendChild(tooltip);
      cleanupFns.push(() => {
        if (tooltip?.isConnected) tooltip.remove();
        tooltip = null;
      });
    }

    tooltip.style.setProperty("--thc-width", config.cardWidth);
    tooltip.style.setProperty("--thc-mobile-width", `${config.mobileWidthPercent}vw`);
  }

  function positionTooltip(anchorRect) {
    if (!tooltip || viewport.isMobileInteractionMode()) return;

    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const cardH = tooltip.offsetHeight || 320;
    const cardW = Math.min(tooltip.offsetWidth || 512, vw - VIEWPORT_MARGIN * 2);

    let top = anchorRect.bottom + 10;
    let isAbove = false;

    if (top + cardH > vh - VIEWPORT_MARGIN) {
      top = anchorRect.top - cardH - 10;
      isAbove = true;
    }

    top = Math.max(VIEWPORT_MARGIN, top);

    let left = anchorRect.left;
    if (left + cardW > vw - VIEWPORT_MARGIN) {
      left = vw - cardW - VIEWPORT_MARGIN;
    }
    left = Math.max(VIEWPORT_MARGIN, left);

    tooltip.style.top = `${top}px`;
    tooltip.style.left = `${left}px`;
    tooltip.classList.toggle("is-above", isAbove);
  }

  function positionTooltipNextFrame(anchorRect) {
    requestAnimationFrame(() => positionTooltip(anchorRect));
  }

  function getRenderCacheKey(topicId, isMobile) {
    return `${topicId}:${isMobile ? "mobile" : "desktop"}`;
  }

  function getRenderedCard(topic, isMobile) {
    const key = getRenderCacheKey(topic.id, isMobile);
    const cached = getCachedValue(renderCache, key);
    if (cached) return cached;

    const html = buildCardHTML(topic, categories, isMobile);
    setCachedValue(renderCache, key, html, config.topicCacheMax * 2);
    return html;
  }

  function abortCurrentRequest() {
    try {
      currentAbortController?.abort();
    } catch {
      // no-op
    }
    currentAbortController = null;
  }

  function hideCard() {
    abortCurrentRequest();

    if (!tooltip) return;
    tooltip.classList.remove("is-visible");

    later(() => {
      if (!tooltip?.classList.contains("is-visible")) {
        currentTopicId = null;
      }
    }, 400);
  }

  function scheduleHide() {
    cancel(hideTimer);
    hideTimer = later(() => {
      if (!isInsideCard) hideCard();
      suppressNextClick = false;
    }, DELAY_HIDE);
  }

  function scheduleShow(topicId, anchorRect) {
    cancel(showTimer);
    cancel(hideTimer);
    showTimer = later(() => showCard(topicId, anchorRect), config.delayShow);
  }

  function resetSuppressedClickSoon() {
    cancel(clearSuppressionTimer);
    clearSuppressionTimer = later(() => {
      suppressNextClick = false;
    }, 700);
  }

  async function fetchTopic(topicId, signal) {
    const cached = getCachedValue(topicCache, topicId);
    if (cached) return cached;

    if (inFlightFetches.has(topicId)) return inFlightFetches.get(topicId);

    const promise = getJSON(`/t/${topicId}.json`, { signal })
      .then((data) => {
        setCachedValue(topicCache, topicId, data, config.topicCacheMax);
        return data;
      })
      .finally(() => {
        inFlightFetches.delete(topicId);
      });

    inFlightFetches.set(topicId, promise);
    return promise;
  }

  function showCard(topicId, anchorRect) {
    ensureTooltip();
    cancel(hideTimer);

    if (currentTopicId === topicId && tooltip.classList.contains("is-visible")) {
      positionTooltipNextFrame(anchorRect);
      return;
    }

    abortCurrentRequest();
    currentAbortController = new AbortController();
    currentTopicId = topicId;

    const isMobile = viewport.isMobileLayout();
    const cachedTopic = getCachedValue(topicCache, topicId);

    tooltip.innerHTML = cachedTopic ? getRenderedCard(cachedTopic, isMobile) : skeletonHTML();
    tooltip.classList.add("is-visible");
    positionTooltipNextFrame(anchorRect);

    if (!cachedTopic) {
      fetchTopic(topicId, currentAbortController.signal)
        .then((data) => {
          if (!tooltip || currentTopicId !== topicId) return;
          tooltip.innerHTML = getRenderedCard(data, viewport.isMobileLayout());
          positionTooltipNextFrame(anchorRect);
        })
        .catch((error) => {
          if (error?.name === "AbortError") return;
          logDebug(config, "Could not load topic", { topicId, error });
          if (!tooltip || currentTopicId !== topicId) return;
          tooltip.innerHTML = `
            <div class="topic-hover-card">
              <div class="topic-hover-card__body">
                <div class="topic-hover-card__loading">Could not load topic.</div>
              </div>
            </div>
          `;
          positionTooltipNextFrame(anchorRect);
        });
    }
  }

  async function resolveUserFieldIdForAdmins() {
    if (!config.resolveUserFieldIdForAdmins) return null;
    if (!currentUserIsStaffLike(currentUser)) return null;
    if (!config.userPreferenceFieldName) return null;

    if (resolvedUserFieldId !== null) return resolvedUserFieldId;
    if (resolvedUserFieldIdPromise) return resolvedUserFieldIdPromise;

    resolvedUserFieldIdPromise = getJSON("/admin/config/user-fields.json")
      .then((result) => {
        const fields = Array.isArray(result) ? result : result?.user_fields || [];
        const wanted = String(config.userPreferenceFieldName).trim().toLowerCase();

        const match = fields.find((field) => {
          const id = field?.id;
          const name = String(field?.name || "").trim().toLowerCase();
          return name === wanted || `user_field_${id}` === wanted || String(id) === wanted;
        });

        resolvedUserFieldId = match?.id ?? null;
        return resolvedUserFieldId;
      })
      .catch((error) => {
        logDebug(config, "Could not resolve user-field ID from admin endpoint", error);
        resolvedUserFieldId = null;
        return null;
      })
      .finally(() => {
        resolvedUserFieldIdPromise = null;
      });

    return resolvedUserFieldIdPromise;
  }

  async function fetchFullCurrentUser() {
    if (!currentUser?.username) return null;

    try {
      const store = api.container.lookup("service:store");
      return (await store.find("user", currentUser.username)) || null;
    } catch (error) {
      logDebug(config, "Could not fetch full current user record", error);
      return null;
    }
  }

  async function hoverCardsDisabledForUser() {
    if (!currentUser || !config.userPreferenceFieldName) return false;

    const directCandidates = normalizedFieldKeyVariants(config.userPreferenceFieldName);
    const currentUserCustomFields = currentUser?.custom_fields || {};
    const currentUserUserFields = currentUser?.user_fields || {};

    let match =
      findTruthyFieldMatch(currentUserCustomFields, directCandidates) ||
      findTruthyFieldMatch(currentUserUserFields, directCandidates);
    if (match) return true;

    const resolvedId = await resolveUserFieldIdForAdmins();
    const resolvedCandidates = resolvedId ? normalizedFieldKeyVariants(resolvedId) : [];

    if (resolvedCandidates.length) {
      match =
        findTruthyFieldMatch(currentUserCustomFields, resolvedCandidates) ||
        findTruthyFieldMatch(currentUserUserFields, resolvedCandidates);
      if (match) return true;
    }

    const fullUser = await fetchFullCurrentUser();
    const fullUserFields = fullUser?.user_fields || {};
    const fullUserCustomFields = fullUser?.custom_fields || {};

    match =
      findTruthyFieldMatch(fullUserFields, directCandidates) ||
      findTruthyFieldMatch(fullUserCustomFields, directCandidates);
    if (match) return true;

    if (resolvedCandidates.length) {
      match =
        findTruthyFieldMatch(fullUserFields, resolvedCandidates) ||
        findTruthyFieldMatch(fullUserCustomFields, resolvedCandidates);
      if (match) return true;
    }

    return false;
  }

  function onTooltipMouseEnter() {
    isInsideCard = true;
    cancel(hideTimer);
  }

  function onTooltipMouseLeave() {
    isInsideCard = false;
    scheduleHide();
  }

  function onTooltipClick(event) {
    const target = event.target;
    if (!(target instanceof Element)) return;

    const inCard = target.closest(".topic-hover-card");
    if (!inCard) return;

    const closeBtn = target.closest("[data-thc-close]");
    if (closeBtn) {
      event.preventDefault();
      event.stopPropagation();
      hideCard();
      return;
    }

    const openBtn = target.closest("[data-thc-open-topic]");
    if (openBtn) {
      event.stopPropagation();
      hideCard();
      return;
    }

    if (viewport.isMobileInteractionMode()) {
      event.preventDefault();
      event.stopPropagation();
    }
  }

  function onMouseOver(event) {
    if (viewport.isMobileInteractionMode()) return;
    if (!(event.target instanceof Element)) return;

    const link = event.target.closest("a[href]");
    if (!link || !linkInSupportedArea(link, config)) return;

    const topicId = topicIdFromHref(link.href);
    if (!topicId) return;

    scheduleShow(topicId, link.getBoundingClientRect());
  }

  function onMouseOut(event) {
    if (viewport.isMobileInteractionMode()) return;
    if (!(event.target instanceof Element)) return;

    const link = event.target.closest("a[href]");
    if (!link || !linkInSupportedArea(link, config)) return;
    scheduleHide();
  }

  function onTouchStart(event) {
    if (!viewport.isMobileInteractionMode() || !config.mobileEnabled) return;
    if (!(event.target instanceof Element)) return;
    if (event.target.closest(TOOLTIP_SELECTOR)) return;

    const link = event.target.closest("a[href]");
    if (!link || !linkInSupportedArea(link, config)) return;

    const topicId = topicIdFromHref(link.href);
    if (!topicId) return;

    event.preventDefault();
    event.stopPropagation();
    suppressNextClick = true;
    resetSuppressedClickSoon();
    showCard(topicId, link.getBoundingClientRect());
  }

  function onDocumentClick(event) {
    if (!viewport.isMobileInteractionMode() || !config.mobileEnabled) return;
    if (!(event.target instanceof Element)) return;

    if (suppressNextClick) {
      const link = event.target.closest("a[href]");
      if (link && linkInSupportedArea(link, config) && topicIdFromHref(link.href)) {
        event.preventDefault();
        event.stopPropagation();
        suppressNextClick = false;
        return;
      }
    }

    if (event.target.closest(TOOLTIP_SELECTOR)) return;
    if (tooltip?.classList.contains("is-visible")) hideCard();
    suppressNextClick = false;
  }

  function onScroll(event) {
    if (event.target?.closest?.(".topic-hover-card, .topic-hover-card-tooltip")) return;
    cancel(showTimer);
    hideCard();
    suppressNextClick = false;
  }

  function onResize() {
    if (tooltip?.classList.contains("is-visible")) hideCard();
    suppressNextClick = false;
  }

  function bindEvents() {
    ensureTooltip();
    addCleanup(tooltip, "mouseenter", onTooltipMouseEnter);
    addCleanup(tooltip, "mouseleave", onTooltipMouseLeave);
    addCleanup(tooltip, "click", onTooltipClick);
    addCleanup(document, "mouseover", onMouseOver, { passive: true });
    addCleanup(document, "mouseout", onMouseOut, { passive: true });
    addCleanup(document, "touchstart", onTouchStart, { passive: false });
    addCleanup(document, "click", onDocumentClick, true);
    addCleanup(document, "scroll", onScroll, { passive: true, capture: true });
    addCleanup(window, "resize", onResize, { passive: true });
  }

  (async () => {
    const disabledForUser = await hoverCardsDisabledForUser();
    if (disabledForUser) {
      logDebug(config, "Hover cards disabled for current user");
      return;
    }

    bindEvents();

    if (!pageChangeBound) {
      api.onPageChange(() => {
        cancel(showTimer);
        cancel(hideTimer);
        cancel(clearSuppressionTimer);
        hideCard();
        currentTopicId = null;
        suppressNextClick = false;
      });
      pageChangeBound = true;
    }

    logDebug(config, "Hover cards initialized", {
      mobileEnabled: config.mobileEnabled,
      topicCacheMax: config.topicCacheMax,
      configuredField: config.userPreferenceFieldName,
      thumbnailSizeMode: thumbnailSizeMode(),
      currentViewportIsMobile: viewport.isMobileInteractionMode(),
    });
  })().catch((error) => {
    console.error("[topic-hover-cards] Fatal init error:", error);
    runCleanup();
  });
});