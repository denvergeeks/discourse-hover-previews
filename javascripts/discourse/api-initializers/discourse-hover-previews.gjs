import { later, cancel } from "@ember/runloop";
import { apiInitializer } from "discourse/lib/api";
import {
  DELAY_HIDE,
  VIEWPORT_MARGIN,
  TOOLTIP_ID,
  TOOLTIP_SELECTOR,
  readConfig,
  logDebug,
  sanitizeURL,
  createViewportState,
  getCachedValue,
  setCachedValue,
  getJSON,
  topicIdFromHref,
  linkInSupportedArea,
  normalizedFieldKeyVariants,
  findTruthyFieldMatch,
  currentUserIsStaffLike,
  escapeHTML,
  safeAvatarURL,
  sanitizeExcerpt,
  normalizeTag,
  formatNumber,
} from "../lib/hover-preview-utils";

function iconSVG(name) {
  switch (name) {
    case "far-eye":
      return `<svg class="svg-icon svg-string" xmlns="http://www.w3.org/2000/svg" aria-hidden="true" width="16" height="16" viewBox="0 0 512 512"><path fill="currentColor" d="M256 112c-92.6 0-174.2 51.3-217.9 128C81.8 316.7 163.4 368 256 368s174.2-51.3 217.9-128C430.2 163.3 348.6 112 256 112Zm0 208a80 80 0 1 1 0-160 80 80 0 1 1 0 160Z"></path></svg>`;
    case "reply":
      return `<svg class="svg-icon svg-string" xmlns="http://www.w3.org/2000/svg" aria-hidden="true" width="16" height="16" viewBox="0 0 512 512"><path fill="currentColor" d="M8.3 189.3 184.5 37.6c12.6-10.8 31.5-1.9 31.5 14.8V136c128.9 0 232 103.1 232 232 0 17.7-14.3 32-32 32s-32-14.3-32-32c0-93.7-74.3-168-168-168v83.6c0 16.7-18.9 25.6-31.5 14.8L8.3 246.7c-11.1-9.5-11.1-26.6 0-36.1Z"></path></svg>`;
    case "heart":
      return `<svg class="svg-icon svg-string" xmlns="http://www.w3.org/2000/svg" aria-hidden="true" width="16" height="16" viewBox="0 0 512 512"><path fill="currentColor" d="m47.6 300.4 184 169.1c13.3 12.2 33.5 12.2 46.8 0l184-169.1c75.8-69.7 81.6-188.9 13-265.7-66.2-74.2-181.3-74.2-247.5 0L256 56.5l-21.9-21.8c-66.2-74.2-181.3-74.2-247.5 0-68.7 76.8-62.9 196 13 265.7Z"></path></svg>`;
    case "clock":
      return `<svg class="svg-icon svg-string" xmlns="http://www.w3.org/2000/svg" aria-hidden="true" width="16" height="16" viewBox="0 0 512 512"><path fill="currentColor" d="M256 48a208 208 0 1 0 0 416 208 208 0 1 0 0-416Zm32 224h-64V144c0-17.7 14.3-32 32-32s32 14.3 32 32v96h64c17.7 0 32 14.3 32 32s-14.3 32-32 32Z"></path></svg>`;
    default:
      return "";
  }
}

function mobileBool(name, mobileName, isMobile, settingsObj) {
  return isMobile ? !!settingsObj[mobileName] : !!settingsObj[name];
}

function mobileInt(name, mobileName, fallback, isMobile, settingsObj) {
  const raw = isMobile
    ? (settingsObj[mobileName] ?? settingsObj[name] ?? fallback)
    : (settingsObj[name] ?? fallback);
  const n = Number(raw);
  return Number.isFinite(n) ? n : fallback;
}

function densitySetting(isMobile, settingsObj) {
  const value = isMobile
    ? (settingsObj.density_mobile ?? settingsObj.density ?? "default")
    : (settingsObj.density ?? "default");
  return ["default", "cozy", "compact"].includes(value) ? value : "default";
}

function thumbnailSizeMode(isMobile, settingsObj) {
  const value = isMobile
    ? (settingsObj.thumbnail_size_mode_mobile ??
        settingsObj.thumbnail_size_mode ??
        "auto_fit_height")
    : (settingsObj.thumbnail_size_mode ?? "auto_fit_height");
  return ["manual", "auto_fit_height"].includes(value)
    ? value
    : "auto_fit_height";
}

function thumbnailPlacement(isMobile, settingsObj) {
  const value = isMobile
    ? (settingsObj.thumbnail_placement_mobile ??
        settingsObj.thumbnail_placement ??
        "top")
    : (settingsObj.thumbnail_placement ?? "left");
  return ["top", "right", "bottom", "left"].includes(value) ? value : "left";
}

function thumbnailSizePercent(isMobile, settingsObj) {
  const raw = isMobile
    ? (settingsObj.thumbnail_size_percent_mobile ??
        settingsObj.thumbnail_size_percent ??
        15)
    : (settingsObj.thumbnail_size_percent ?? 15);
  const n = Number(raw);
  return Number.isFinite(n) ? n : 15;
}

function thumbnailAutoFitMaxWidth(isMobile, settingsObj) {
  const raw = isMobile
    ? (settingsObj.thumbnail_auto_fit_max_width_mobile ??
        settingsObj.thumbnail_auto_fit_max_width ??
        "10rem")
    : (settingsObj.thumbnail_auto_fit_max_width ?? "10rem");
  return typeof raw === "string" && raw.trim() ? raw : "10rem";
}

function thumbnailTopBottomHeight(isMobile, settingsObj) {
  const raw = isMobile
    ? (settingsObj.thumbnail_height_top_bottom_mobile ??
        settingsObj.thumbnail_height_top_bottom ??
        "auto")
    : (settingsObj.thumbnail_height_top_bottom ?? "auto");
  return typeof raw === "string" && raw.trim() ? raw : "auto";
}

function categoryBadgeHTML(name, color) {
  if (!name) return "";
  const style = color
    ? ` style="--thc-category-color:${escapeHTML(color)}"`
    : "";
  return `<span class="topic-hover-card__category"><span class="topic-hover-card__category-badge"${style}><span class="topic-hover-card__category-text">${escapeHTML(name)}</span></span></span>`;
}

function tagHTML(tag) {
  return `<span class="topic-hover-card__tag"><span class="topic-hover-card__tag-text">${escapeHTML(tag)}</span></span>`;
}

function thumbnailHTML({ imageUrl, mode }) {
  if (!imageUrl) return "";

  if (mode === "auto_fit_height") {
    return `
      <div class="topic-hover-card__thumbnail">
        <img
          class="topic-hover-card__thumbnail-bg"
          src="${escapeHTML(imageUrl)}"
          alt=""
          loading="lazy"
          decoding="async"
          aria-hidden="true"
        />
        <span class="topic-hover-card__thumbnail-overlay" aria-hidden="true"></span>
        <img
          class="topic-hover-card__thumbnail-fg"
          src="${escapeHTML(imageUrl)}"
          alt=""
          loading="lazy"
          decoding="async"
        />
      </div>
    `;
  }

  return `
    <div class="topic-hover-card__thumbnail">
      <img src="${escapeHTML(imageUrl)}" alt="" loading="lazy" decoding="async" />
    </div>
  `;
}

function buildCardHTML(topic, settingsObj, siteCategories, excerptCache, isMobile) {
  const density = densitySetting(isMobile, settingsObj);
  const placement = thumbnailPlacement(isMobile, settingsObj);
  const sizeMode = thumbnailSizeMode(isMobile, settingsObj);
  const sizePercent = thumbnailSizePercent(isMobile, settingsObj);
  const autoFitMaxWidth = thumbnailAutoFitMaxWidth(isMobile, settingsObj);
  const topBottomHeight = thumbnailTopBottomHeight(isMobile, settingsObj);
  const topBottomHeightIsAuto = topBottomHeight.trim().toLowerCase() === "auto";

  const cardClasses = [
    "topic-hover-card",
    `topic-hover-card--thumb-${placement}`,
    sizeMode === "auto_fit_height"
      ? "topic-hover-card--thumb-size-auto-fit-height"
      : "topic-hover-card--thumb-size-manual",
    topBottomHeightIsAuto
      ? "topic-hover-card--thumb-top-bottom-height-auto"
      : "topic-hover-card--thumb-top-bottom-height-custom",
    `topic-hover-card--density-${density}`,
  ].join(" ");

  const cardStyle = [
    `--thc-thumbnail-size-percent:${sizePercent}`,
    `--thc-auto-thumb-max-width:${autoFitMaxWidth}`,
    `--thc-top-bottom-thumb-height:${topBottomHeight}`,
  ].join(";");

  const showThumbnail = mobileBool(
    "show_thumbnail",
    "show_thumbnail_mobile",
    isMobile,
    settingsObj
  );
  const showTitle = mobileBool(
    "show_title",
    "show_title_mobile",
    isMobile,
    settingsObj
  );
  const showExcerpt = mobileBool(
    "show_excerpt",
    "show_excerpt_mobile",
    isMobile,
    settingsObj
  );
  const showCategory = mobileBool(
    "show_category",
    "show_category_mobile",
    isMobile,
    settingsObj
  );
  const showTags = mobileBool(
    "show_tags",
    "show_tags_mobile",
    isMobile,
    settingsObj
  );
  const showOp = mobileBool("show_op", "show_op_mobile", isMobile, settingsObj);
  const showPublishDate = mobileBool(
    "show_publish_date",
    "show_publish_date_mobile",
    isMobile,
    settingsObj
  );
  const showViews = mobileBool(
    "show_views",
    "show_views_mobile",
    isMobile,
    settingsObj
  );
  const showReplies = mobileBool(
    "show_reply_count",
    "show_reply_count_mobile",
    isMobile,
    settingsObj
  );
  const showLikes = mobileBool(
    "show_likes",
    "show_likes_mobile",
    isMobile,
    settingsObj
  );
  const showActivity = mobileBool(
    "show_activity",
    "show_activity_mobile",
    isMobile,
    settingsObj
  );

  const imageUrl = showThumbnail ? sanitizeURL(topic?.image_url) : null;
  const titleText = topic?.fancy_title ?? topic?.title ?? "(no title)";

  const excerptLines = mobileInt(
    "excerpt_length",
    "excerpt_length_mobile",
    3,
    isMobile,
    settingsObj
  );

  let excerptText = "";
  const excerptKey = topic?.id ?? null;
  if (excerptKey) {
    const cachedExcerpt = getCachedValue(excerptCache, excerptKey);
    if (cachedExcerpt) {
      excerptText = cachedExcerpt;
    }
  }
  if (!excerptText) {
    const firstPost = topic?.post_stream?.posts?.[0];
    const src = topic?.excerpt || firstPost?.excerpt || firstPost?.cooked || "";
    const cleaned = sanitizeExcerpt(src);
    excerptText = cleaned.length >= 20 ? cleaned : "";
    if (excerptKey) {
      setCachedValue(excerptCache, excerptKey, excerptText, 500);
    }
  }

  const category = showCategory
    ? siteCategories?.find?.((c) => String(c.id) === String(topic?.category_id)) || null
    : null;
  const categoryName =
    category?.name ||
    category?.slug ||
    topic?.category_name ||
    topic?.category_slug ||
    "";
  const categoryColorRaw = category?.color || topic?.category_color || null;
  const categoryColor = categoryColorRaw
    ? `#${String(categoryColorRaw).replace(/^#/, "")}`
    : null;

  const tags =
    showTags && Array.isArray(topic?.tags)
      ? topic.tags.map(normalizeTag).filter(Boolean)
      : [];

  const opUsername =
    topic?.details?.created_by?.username ||
    topic?.posters?.[0]?.user?.username ||
    "";
  const avatarTemplate =
    topic?.details?.created_by?.avatar_template ||
    topic?.posters?.[0]?.user?.avatar_template ||
    null;
  const opAvatarUrl = safeAvatarURL(avatarTemplate, 24);

  let publishDate = null;
  if (showPublishDate && topic?.created_at) {
    try {
      publishDate = new Date(topic.created_at).toLocaleDateString(undefined, {
        year: "numeric",
        month: "short",
        day: "numeric",
      });
    } catch {
      publishDate = null;
    }
  }

  let activityDate = null;
  if (showActivity && topic?.last_posted_at) {
    try {
      activityDate = new Date(topic.last_posted_at).toLocaleDateString(undefined, {
        year: "numeric",
        month: "short",
        day: "numeric",
      });
    } catch {
      activityDate = null;
    }
  }

  const hasExcerpt = !!(showExcerpt && excerptText);
  const hasCategory = !!(showCategory && categoryName);
  const hasTags = !!(showTags && tags.length);
  const hasOp = !!(showOp && opUsername);
  const hasPublishDate = !!(showPublishDate && publishDate);
  const hasViews = !!(showViews && topic?.views);
  const hasReplies = !!showReplies;
  const hasLikes = !!(showLikes && topic?.like_count);
  const hasActivityDate = !!(showActivity && activityDate);
  const hasAnyStats = !!(hasViews || hasReplies || hasLikes || hasActivityDate);
  const hasAnyMeta = !!(hasOp || hasPublishDate || hasAnyStats);
  const hasBadges = !!(hasCategory || hasTags);

  const topicUrl = `${window.location.origin}/t/${topic?.slug || topic?.id}/${topic?.id}`;

  const thumb = thumbnailHTML({ imageUrl, mode: sizeMode });
  const beforeBody = placement === "top" || placement === "left" ? thumb : "";
  const afterBody = placement === "right" || placement === "bottom" ? thumb : "";

  return `
    <div class="${cardClasses}" style="${escapeHTML(cardStyle)}">
      ${beforeBody}
      <div class="topic-hover-card__body">
        ${
          isMobile
            ? `
          <button
            class="topic-hover-card__close"
            type="button"
            aria-label="Close preview"
            data-thc-close="true"
          >
            <svg class="topic-hover-card__close-icon" viewBox="0 0 16 16" aria-hidden="true" focusable="false">
              <path d="M4.2 4.2 11.8 11.8M11.8 4.2 4.2 11.8" />
            </svg>
          </button>
        `
            : ""
        }

        ${
          showTitle
            ? `<div class="topic-hover-card__title">${escapeHTML(titleText)}</div>`
            : ""
        }

        ${
          hasExcerpt
            ? `<div class="topic-hover-card__excerpt" style="--thc-excerpt-lines:${excerptLines}">${escapeHTML(excerptText)}</div>`
            : ""
        }

        ${
          hasAnyMeta
            ? `
          <div class="topic-hover-card__metadata">
            ${
              hasOp
                ? `
              <span class="topic-hover-card__meta-group">
                <span class="topic-hover-card__op">
                  ${
                    opAvatarUrl
                      ? `<img src="${escapeHTML(opAvatarUrl)}" width="24" height="24" alt="${escapeHTML(opUsername)}" loading="lazy" decoding="async" />`
                      : ""
                  }
                  <span class="username">${escapeHTML(opUsername)}</span>
                </span>
              </span>
            `
                : ""
            }

            ${
              hasPublishDate
                ? `
              <span class="topic-hover-card__meta-group">
                <span class="topic-hover-card__meta-separator" aria-hidden="true">·</span>
                <span class="topic-hover-card__publish-date">${escapeHTML(publishDate)}</span>
              </span>
            `
                : ""
            }

            ${
              hasAnyStats
                ? `
              <span class="topic-hover-card__meta-group">
                <span class="topic-hover-card__meta-separator" aria-hidden="true">·</span>
                <span class="topic-hover-card__stats">
                  ${
                    hasViews
                      ? `<span class="topic-hover-card__stat">${iconSVG("far-eye")}<span>${escapeHTML(formatNumber(topic?.views))}</span></span>`
                      : ""
                  }
                  ${
                    hasReplies
                      ? `<span class="topic-hover-card__stat">${iconSVG("reply")}<span>${escapeHTML(formatNumber(topic?.posts_count > 0 ? topic.posts_count - 1 : 0))}</span></span>`
                      : ""
                  }
                  ${
                    hasLikes
                      ? `<span class="topic-hover-card__stat">${iconSVG("heart")}<span>${escapeHTML(formatNumber(topic?.like_count))}</span></span>`
                      : ""
                  }
                  ${
                    hasActivityDate
                      ? `<span class="topic-hover-card__stat">${iconSVG("clock")}<span>${escapeHTML(activityDate)}</span></span>`
                      : ""
                  }
                </span>
              </span>
            `
                : ""
            }
          </div>
        `
            : ""
        }

        ${
          hasBadges
            ? `
          <div class="topic-hover-card__badges">
            ${hasCategory ? categoryBadgeHTML(categoryName, categoryColor) : ""}
            ${
              hasTags
                ? `<div class="topic-hover-card__tags">${tags.map(tagHTML).join("")}</div>`
                : ""
            }
          </div>
        `
            : ""
        }

        ${
          isMobile
            ? `
          <div class="topic-hover-card__mobile-actions">
            <a
              class="btn btn-primary topic-hover-card__open-topic"
              href="${escapeHTML(topicUrl)}"
              data-thc-open-topic="true"
            >
              Open topic
            </a>
          </div>
        `
            : ""
        }
      </div>
      ${afterBody}
    </div>
  `;
}

function buildLoadingHTML() {
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
    </div>
  `;
}

function buildErrorHTML() {
  return `
    <div class="topic-hover-card">
      <div class="topic-hover-card__body">
        <div class="topic-hover-card__loading">Could not load topic.</div>
      </div>
    </div>
  `;
}

export default apiInitializer((api) => {
  const config = readConfig(settings);
  const currentUser = api.getCurrentUser();
  const siteService = api.container.lookup("service:site");
  const viewport = createViewportState();

  let tooltipEl = null;
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
  const excerptCache = new Map();
  const inFlightFetches = new Map();
  const cleanupFns = [];

  function addCleanup(target, type, handler, options) {
    target.addEventListener(type, handler, options);
    cleanupFns.push(() => target.removeEventListener(type, handler, options));
  }

  function runCleanup() {
    cancel(showTimer);
    cancel(hideTimer);
    cancel(clearSuppressionTimer);
    showTimer = hideTimer = clearSuppressionTimer = null;

    while (cleanupFns.length) {
      try {
        cleanupFns.pop()?.();
      } catch {
        // no-op
      }
    }
  }

  function ensureTooltip() {
    if (tooltipEl?.isConnected) return;

    tooltipEl = document.getElementById(TOOLTIP_ID);
    if (!tooltipEl) {
      tooltipEl = document.createElement("div");
      tooltipEl.id = TOOLTIP_ID;
      tooltipEl.className = "topic-hover-card-tooltip";
      tooltipEl.setAttribute("role", "tooltip");
      tooltipEl.setAttribute("aria-live", "polite");
      document.body.appendChild(tooltipEl);
    }

    tooltipEl.style.setProperty("--thc-width", config.cardWidth);
    tooltipEl.style.setProperty("--thc-mobile-width", `${config.mobileWidthPercent}vw`);

    cleanupFns.push(() => {
      tooltipEl?.remove();
      tooltipEl = null;
    });
  }

  function renderLoading() {
    if (!tooltipEl) return;
    tooltipEl.innerHTML = buildLoadingHTML();
  }

  function renderError() {
    if (!tooltipEl) return;
    tooltipEl.innerHTML = buildErrorHTML();
  }

  function renderTopic(topic) {
    if (!tooltipEl) return;
    tooltipEl.innerHTML = buildCardHTML(
      topic,
      settings,
      siteService?.categories || [],
      excerptCache,
      viewport.isMobileLayout()
    );
  }

  function positionTooltip(anchorRect) {
    if (!tooltipEl || viewport.isMobileInteractionMode()) return;

    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const cardH = tooltipEl.offsetHeight || 320;
    const cardW = Math.min(tooltipEl.offsetWidth || 512, vw - VIEWPORT_MARGIN * 2);

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

    tooltipEl.style.top = `${top}px`;
    tooltipEl.style.left = `${left}px`;
    tooltipEl.classList.toggle("is-above", isAbove);
  }

  function positionNextFrame(anchorRect) {
    requestAnimationFrame(() => positionTooltip(anchorRect));
  }

  function abortCurrentRequest() {
    try {
      currentAbortController?.abort();
    } catch {
      // no-op
    }
    currentAbortController = null;
  }

  function clearAriaDescribedBy() {
    document
      .querySelectorAll(`[aria-describedby="${TOOLTIP_ID}"]`)
      .forEach((el) => el.removeAttribute("aria-describedby"));
  }

  function hideCard() {
    abortCurrentRequest();
    if (!tooltipEl) return;

    tooltipEl.classList.remove("is-visible");
    clearAriaDescribedBy();

    later(() => {
      if (!tooltipEl?.classList.contains("is-visible")) {
        currentTopicId = null;
      }
    }, 400);
  }

  function scheduleHide() {
    cancel(hideTimer);
    hideTimer = later(() => {
      if (!isInsideCard) {
        hideCard();
      }
      suppressNextClick = false;
    }, DELAY_HIDE);
  }

  function scheduleShow(topicId, anchorEl) {
    cancel(showTimer);
    cancel(hideTimer);
    showTimer = later(() => showCard(topicId, anchorEl), config.delayShow);
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

  function showCard(topicId, anchorEl) {
    ensureTooltip();
    cancel(hideTimer);

    const anchorRect =
      anchorEl instanceof Element ? anchorEl.getBoundingClientRect() : anchorEl;

    if (anchorEl instanceof Element) {
      clearAriaDescribedBy();
      anchorEl.setAttribute("aria-describedby", TOOLTIP_ID);
    }

    if (currentTopicId === topicId && tooltipEl.classList.contains("is-visible")) {
      positionNextFrame(anchorRect);
      return;
    }

    abortCurrentRequest();
    currentAbortController = new AbortController();
    currentTopicId = topicId;

    const cachedTopic = getCachedValue(topicCache, topicId);

    if (cachedTopic) {
      renderTopic(cachedTopic);
    } else {
      renderLoading();
    }

    tooltipEl.classList.add("is-visible");
    positionNextFrame(anchorRect);

    if (!cachedTopic) {
      fetchTopic(topicId, currentAbortController.signal)
        .then((data) => {
          if (!tooltipEl || currentTopicId !== topicId) return;
          renderTopic(data);
          positionNextFrame(anchorRect);
        })
        .catch((error) => {
          if (error?.name === "AbortError") return;
          logDebug(config, "Could not load topic", { topicId, error });
          if (!tooltipEl || currentTopicId !== topicId) return;
          renderError();
          positionNextFrame(anchorRect);
        });
    }
  }

  async function resolveUserFieldIdForAdmins() {
    if (!config.resolveUserFieldIdForAdmins) return null;
    if (!currentUserIsStaffLike(currentUser)) return null;
    if (!config.userPreferenceFieldName) return null;
    if (/^\d+$/.test(String(config.userPreferenceFieldName).trim())) return null;

    if (resolvedUserFieldId !== null) return resolvedUserFieldId;
    if (resolvedUserFieldIdPromise) return resolvedUserFieldIdPromise;

    resolvedUserFieldIdPromise = getJSON("/admin/config/user-fields.json")
      .then((result) => {
        const fields = Array.isArray(result) ? result : result?.user_fields || [];
        const wanted = String(config.userPreferenceFieldName).trim().toLowerCase();
        const match = fields.find((f) => {
          const name = String(f?.name || "").trim().toLowerCase();
          return (
            name === wanted ||
            `user_field_${f?.id}` === wanted ||
            String(f?.id) === wanted
          );
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
      return (await store?.find("user", currentUser.username)) || null;
    } catch (error) {
      logDebug(config, "Could not fetch full current user record", { error });
      return null;
    }
  }

  async function hoverCardsDisabledForUser() {
    if (!currentUser || !config.userPreferenceFieldName) return false;

    const directCandidates = normalizedFieldKeyVariants(config.userPreferenceFieldName);
    const cfCustom = currentUser?.custom_fields || {};
    const cfUser = currentUser?.user_fields || {};

    if (
      findTruthyFieldMatch(cfCustom, directCandidates) ||
      findTruthyFieldMatch(cfUser, directCandidates)
    ) {
      return true;
    }

    const resolvedId = await resolveUserFieldIdForAdmins();
    const resolvedCandidates = resolvedId
      ? normalizedFieldKeyVariants(resolvedId)
      : [];

    if (resolvedCandidates.length) {
      if (
        findTruthyFieldMatch(cfCustom, resolvedCandidates) ||
        findTruthyFieldMatch(cfUser, resolvedCandidates)
      ) {
        return true;
      }
    }

    const fullUser = await fetchFullCurrentUser();
    const fuFields = fullUser?.user_fields || {};
    const fuCustom = fullUser?.custom_fields || {};

    if (
      findTruthyFieldMatch(fuFields, directCandidates) ||
      findTruthyFieldMatch(fuCustom, directCandidates)
    ) {
      return true;
    }

    if (resolvedCandidates.length) {
      if (
        findTruthyFieldMatch(fuFields, resolvedCandidates) ||
        findTruthyFieldMatch(fuCustom, resolvedCandidates)
      ) {
        return true;
      }
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
    if (!target.closest(".topic-hover-card")) return;

    if (target.closest("[data-thc-close]")) {
      event.preventDefault();
      event.stopPropagation();
      hideCard();
      return;
    }

    if (target.closest("[data-thc-open-topic]")) {
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
    if (!link || !linkInSupportedArea(link, config, settings)) return;

    const topicId = topicIdFromHref(link.href);
    if (!topicId) return;

    scheduleShow(topicId, link);
  }

  function onMouseOut(event) {
    if (viewport.isMobileInteractionMode()) return;
    if (!(event.target instanceof Element)) return;

    const link = event.target.closest("a[href]");
    if (!link || !linkInSupportedArea(link, config, settings)) return;

    scheduleHide();
  }

  function onTouchStart(event) {
    if (!viewport.isMobileInteractionMode() || !config.mobileEnabled) return;
    if (!(event.target instanceof Element)) return;
    if (event.target.closest(TOOLTIP_SELECTOR)) return;

    const link = event.target.closest("a[href]");
    if (!link || !linkInSupportedArea(link, config, settings)) return;

    const topicId = topicIdFromHref(link.href);
    if (!topicId) return;

    event.preventDefault();
    event.stopPropagation();
    suppressNextClick = true;
    resetSuppressedClickSoon();
    showCard(topicId, link);
  }

  function onDocumentClick(event) {
    if (!viewport.isMobileInteractionMode() || !config.mobileEnabled) return;
    if (!(event.target instanceof Element)) return;

    if (suppressNextClick) {
      const link = event.target.closest("a[href]");
      if (
        link &&
        linkInSupportedArea(link, config, settings) &&
        topicIdFromHref(link.href)
      ) {
        event.preventDefault();
        event.stopPropagation();
        suppressNextClick = false;
        return;
      }
    }

    if (event.target.closest(TOOLTIP_SELECTOR)) return;

    if (tooltipEl?.classList.contains("is-visible")) {
      hideCard();
    }

    suppressNextClick = false;
  }

  function onScroll(event) {
    if (event.target?.closest?.(".topic-hover-card, .topic-hover-card-tooltip")) return;
    cancel(showTimer);
    hideCard();
    suppressNextClick = false;
  }

  function onResize() {
    if (tooltipEl?.classList.contains("is-visible")) {
      hideCard();
    }
    suppressNextClick = false;
  }

  function bindEvents() {
    ensureTooltip();
    addCleanup(tooltipEl, "mouseenter", onTooltipMouseEnter);
    addCleanup(tooltipEl, "mouseleave", onTooltipMouseLeave);
    addCleanup(tooltipEl, "click", onTooltipClick);
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

    api.onPageChange(() => {
      cancel(showTimer);
      cancel(hideTimer);
      cancel(clearSuppressionTimer);
      hideCard();
      currentTopicId = null;
      suppressNextClick = false;
    });

    logDebug(config, "Hover cards initialized", {
      mobileEnabled: config.mobileEnabled,
      topicCacheMax: config.topicCacheMax,
      configuredField: config.userPreferenceFieldName,
      currentViewportIsMobile: viewport.isMobileInteractionMode(),
    });
  })().catch((error) => {
    // eslint-disable-next-line no-console
    console.error("[topic-hover-cards] Fatal init error:", error);
    runCleanup();
  });
});