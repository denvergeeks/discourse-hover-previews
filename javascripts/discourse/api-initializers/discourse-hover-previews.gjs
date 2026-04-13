import { later, cancel } from "@ember/runloop";
import { iconHTML } from "discourse/lib/icon-library";
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

function skeletonHTML() {
  return `
    <div class="topic-hover-card topic-hover-card--loading">
      <div class="topic-hover-card__body">
        <div class="topic-hover-card__skeleton topic-hover-card__skeleton--title"></div>
        <div class="topic-hover-card__skeleton topic-hover-card__skeleton--line"></div>
        <div class="topic-hover-card__skeleton topic-hover-card__skeleton--line"></div>
        <div class="topic-hover-card__skeleton topic-hover-card__skeleton--meta"></div>
      </div>
    </div>
  `;
}

function discourseIcon(name) {
  try {
    return iconHTML(name) || "";
  } catch {
    return "";
  }
}

function numberSetting(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function stringSetting(value, fallback = "") {
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function joinMetadataGroups(items, separator = "·") {
  const filtered = items.filter(Boolean);
  if (!filtered.length) return "";

  return filtered
    .map((item, index) =>
      index === 0 ? item : `<span class="topic-hover-card__sep">${escapeHTML(separator)}</span>${item}`
    )
    .join("");
}

function getSiteCategories(api) {
  return api.container.lookup("service:site")?.categories || [];
}

function findCategoryById(categories, categoryId) {
  if (!categories?.length || !categoryId) return null;
  return categories.find((c) => Number(c.id) === Number(categoryId)) || null;
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

function thumbnailSizeMode(isMobile) {
  const value = isMobile
    ? settings.thumbnail_size_mode_mobile ??
      settings.thumbnail_size_mode ??
      "auto_fit_height"
    : settings.thumbnail_size_mode ?? "auto_fit_height";

  return ["manual", "auto_fit_height"].includes(value)
    ? value
    : "auto_fit_height";
}

function thumbnailPlacement(isMobile) {
  const value = isMobile
    ? settings.thumbnail_placement_mobile ??
      settings.thumbnail_placement ??
      "top"
    : settings.thumbnail_placement ?? "left";

  return ["top", "right", "bottom", "left"].includes(value) ? value : "left";
}

function buildThumbnailHTML(topic, mode, isMobile) {
  const imageURL = sanitizeURL(topic.image_url);
  if (!imageURL) return "";

  const topBottomHeight = stringSetting(
    isMobile
      ? settings.thumbnail_height_top_bottom_mobile ??
          settings.thumbnail_height_top_bottom ??
          "auto"
      : settings.thumbnail_height_top_bottom ?? "auto",
    "auto"
  );

  if (isMobile || mode === "manual") {
    return `
      <div class="topic-hover-card__thumb-wrap">
        <img
          class="topic-hover-card__thumb"
          src="${escapeHTML(imageURL)}"
          alt=""
          loading="lazy"
          decoding="async"
          style="--thc-thumb-top-bottom-height:${escapeHTML(topBottomHeight)};"
        />
      </div>
    `;
  }

  return `
    <div class="topic-hover-card__thumb-wrap topic-hover-card__thumb-wrap--auto-fit">
      <img
        class="topic-hover-card__thumb topic-hover-card__thumb--auto-fit"
        src="${escapeHTML(imageURL)}"
        alt=""
        loading="lazy"
        decoding="async"
        style="--thc-thumb-top-bottom-height:${escapeHTML(topBottomHeight)};"
      />
    </div>
  `;
}

function buildCategoryHTML(topic, categories, isMobile) {
  if (!mobileBool("show_category", "show_category_mobile", isMobile)) return "";
  if (!topic.category_id) return "";

  const category = findCategoryById(categories, topic.category_id);
  const name =
    category?.name ||
    category?.slug ||
    topic.category_name ||
    topic.category_slug ||
    "";

  const rawColor = category?.color || topic.category_color || null;
  const color = rawColor ? `#${String(rawColor).replace(/^#/, "")}` : null;

  if (!name) return "";

  return `
    <span class="topic-hover-card__badge topic-hover-card__badge--category"${
      color ? ` style="--thc-category-color:${escapeHTML(color)};"` : ""
    }>
      ${escapeHTML(name)}
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
            <span class="topic-hover-card__badge topic-hover-card__badge--tag">
              ${escapeHTML(tag)}
            </span>
          `
        )
        .join("")}
    </div>
  `;
}

function buildBadgesHTML(topic, categories, isMobile) {
  const categoryHTML = buildCategoryHTML(topic, categories, isMobile);
  const tagsHTML = buildTagsHTML(topic, isMobile);

  if (!categoryHTML && !tagsHTML) return "";

  return `
    <div class="topic-hover-card__badges">
      ${categoryHTML}
      ${tagsHTML}
    </div>
  `;
}

function buildTitleHTML(topic, isMobile) {
  if (!mobileBool("show_title", "show_title_mobile", isMobile)) return "";
  const title = topic.fancy_title ?? topic.title ?? "(no title)";

  return `
    <h3 class="topic-hover-card__title">
      ${escapeHTML(title)}
    </h3>
  `;
}

function buildExcerptHTML(topic, isMobile) {
  if (!mobileBool("show_excerpt", "show_excerpt_mobile", isMobile)) return "";

  const lines = mobileInt("excerpt_length", "excerpt_length_mobile", 3, isMobile);
  const firstPost = topic.post_stream?.posts?.[0];
  const excerptSource =
    topic.excerpt || firstPost?.excerpt || firstPost?.cooked || "";

  const cleanedExcerpt = topic.__thc_excerpt ?? sanitizeExcerpt(excerptSource);
  topic.__thc_excerpt = cleanedExcerpt;

  const finalExcerpt = cleanedExcerpt.length >= 20 ? cleanedExcerpt : "";
  if (!finalExcerpt) return "";

  return `
    <div class="topic-hover-card__excerpt" style="--thc-excerpt-lines:${lines};">
      ${escapeHTML(finalExcerpt)}
    </div>
  `;
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
    ? `<img class="topic-hover-card__op-avatar" src="${escapeHTML(
        avatarURL
      )}" alt="" loading="lazy" decoding="async" />`
    : "";

  return `
    <span class="topic-hover-card__meta-item topic-hover-card__meta-item--op">
      ${avatarImg}
      <span>${escapeHTML(op.username)}</span>
    </span>
  `;
}

function buildPublishDateHTML(topic, isMobile) {
  if (!mobileBool("show_publish_date", "show_publish_date_mobile", isMobile)) {
    return "";
  }

  if (!topic.created_at) return "";
  const d = new Date(topic.created_at);
  if (Number.isNaN(d.getTime())) return "";

  const fmt = d.toLocaleDateString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });

  return `
    <span class="topic-hover-card__meta-item topic-hover-card__meta-item--date">
      ${escapeHTML(fmt)}
    </span>
  `;
}

function buildStatsHTML(topic, isMobile) {
  const stats = [];

  if (mobileBool("show_views", "show_views_mobile", isMobile)) {
    stats.push(`
      <span class="topic-hover-card__stat">
        ${discourseIcon("far-eye")}
        <span>${escapeHTML(formatNumber(topic.views))}</span>
      </span>
    `);
  }

  if (mobileBool("show_reply_count", "show_reply_count_mobile", isMobile)) {
    const replyCount = topic.reply_count ?? Math.max((topic.posts_count ?? 1) - 1, 0);
    stats.push(`
      <span class="topic-hover-card__stat">
        ${discourseIcon("comment")}
        <span>${escapeHTML(formatNumber(replyCount))}</span>
      </span>
    `);
  }

  if (mobileBool("show_likes", "show_likes_mobile", isMobile)) {
    const likes = topic.like_count ?? topic.topic_post_like_count ?? 0;
    stats.push(`
      <span class="topic-hover-card__stat">
        ${discourseIcon("heart")}
        <span>${escapeHTML(formatNumber(likes))}</span>
      </span>
    `);
  }

  if (
    mobileBool("show_activity", "show_activity_mobile", isMobile) &&
    topic.last_posted_at
  ) {
    const d = new Date(topic.last_posted_at);
    if (!Number.isNaN(d.getTime())) {
      const fmt = d.toLocaleDateString(undefined, {
        month: "short",
        day: "numeric",
        year: "numeric",
      });

      stats.push(`
        <span class="topic-hover-card__stat">
          ${discourseIcon("clock")}
          <span>${escapeHTML(fmt)}</span>
        </span>
      `);
    }
  }

  return stats.length
    ? `<span class="topic-hover-card__meta-item topic-hover-card__meta-item--stats">${stats.join(
        ""
      )}</span>`
    : "";
}

function buildMetadataHTML(topic, isMobile) {
  const content = joinMetadataGroups([
    buildOpHTML(topic, isMobile),
    buildPublishDateHTML(topic, isMobile),
    buildStatsHTML(topic, isMobile),
  ]);

  return content
    ? `
      <div class="topic-hover-card__meta">
        ${content}
      </div>
    `
    : "";
}

function buildMobileActionsHTML(topic, isMobile) {
  if (!isMobile) return "";

  const slug = escapeHTML(String(topic.slug || topic.id || ""));
  const id = escapeHTML(String(topic.id || ""));
  const topicUrl = `${window.location.origin}/t/${slug}/${id}`;

  return `
    <div class="topic-hover-card__actions">
      <a
        class="btn btn-primary topic-hover-card__open-topic"
        href="${topicUrl}"
        data-thc-open-topic
      >
        Open topic
      </a>
      <button class="btn btn-default topic-hover-card__close" type="button" data-thc-close>
        Close
      </button>
    </div>
  `;
}

function buildCardHTML(topic, categories, isMobile = false) {
  const showThumbnail = mobileBool(
    "show_thumbnail",
    "show_thumbnail_mobile",
    isMobile
  );

  const desktopThumbnailSizePercent = numberSetting(
    settings.thumbnail_size_percent,
    15
  );

  const mobileThumbnailSizePercent = numberSetting(
    settings.thumbnail_size_percent_mobile ?? settings.thumbnail_size_percent,
    33
  );

  const autoFitMaxWidth = stringSetting(
    isMobile
      ? settings.thumbnail_auto_fit_max_width_mobile ??
          settings.thumbnail_auto_fit_max_width ??
          "8rem"
      : settings.thumbnail_auto_fit_max_width ?? "10rem",
    isMobile ? "8rem" : "10rem"
  );

  const placement = thumbnailPlacement(isMobile);
  const density = densitySetting(isMobile);
  const densityClass = `topic-hover-card--density-${density}`;

  const sizeMode = thumbnailSizeMode(isMobile);
  const sizeModeClass =
    sizeMode === "auto_fit_height"
      ? "topic-hover-card--thumb-size-auto-fit-height"
      : "topic-hover-card--thumb-size-manual";

  const mobileCloseButton = isMobile
    ? `
      <button
        class="topic-hover-card__mobile-x"
        type="button"
        aria-label="Close preview"
        data-thc-close
      >
        &times;
      </button>
    `
    : "";

  const thumbnail =
    topic.image_url && showThumbnail
      ? buildThumbnailHTML(topic, sizeMode, isMobile)
      : "";

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

  const sizePercent = isMobile
    ? mobileThumbnailSizePercent
    : desktopThumbnailSizePercent;

  const wrapperStyle = `
    --thc-thumbnail-size-percent:${sizePercent};
    --thc-auto-thumb-max-width:${escapeHTML(autoFitMaxWidth)};
  `;

  switch (placement) {
    case "left":
      return `
        <div
          class="topic-hover-card topic-hover-card--left ${densityClass} ${sizeModeClass}"
          style="${wrapperStyle}"
        >
          ${thumbnail}
          ${bodyInner}
        </div>
      `;
    case "right":
      return `
        <div
          class="topic-hover-card topic-hover-card--right ${densityClass} ${sizeModeClass}"
          style="${wrapperStyle}"
        >
          ${bodyInner}
          ${thumbnail}
        </div>
      `;
    case "bottom":
      return `
        <div
          class="topic-hover-card topic-hover-card--bottom ${densityClass} ${sizeModeClass}"
          style="${wrapperStyle}"
        >
          ${bodyInner}
          ${thumbnail}
        </div>
      `;
    case "top":
    default:
      return `
        <div
          class="topic-hover-card topic-hover-card--top ${densityClass} ${sizeModeClass}"
          style="${wrapperStyle}"
        >
          ${thumbnail}
          ${bodyInner}
        </div>
      `;
  }
}

export default apiInitializer((api) => {
  const config = readConfig(settings);
  if (!config.enabled) return;

  const categories = getSiteCategories(api);
  const currentUser = api.getCurrentUser?.() || null;
  const viewport = createViewportState();

  let tooltip = null;
  let showTimer = null;
  let hideTimer = null;
  let clearSuppressionTimer = null;
  let currentTopicId = null;
  let currentAbortController = null;
  let currentAnchor = null;
  let isInsideCard = false;
  let suppressNextClick = false;
  let resolvedUserFieldId = null;
  let resolvedUserFieldIdPromise = null;

  const topicCache = new Map();
  const renderCache = new Map();
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

    try {
      currentAbortController?.abort();
    } catch {
      // no-op
    }

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
      tooltip.id = TOOLTIP_ID;
      tooltip.setAttribute("role", "tooltip");
      tooltip.setAttribute("aria-live", "polite");
      document.body.appendChild(tooltip);

      cleanupFns.push(() => {
        if (tooltip?.isConnected) tooltip.remove();
        tooltip = null;
      });
    }

    tooltip.style.setProperty("--thc-width", config.cardWidth);
    tooltip.style.setProperty(
      "--thc-mobile-width",
      `${config.mobileWidthPercent}vw`
    );
  }

  function positionTooltip(anchorRect) {
    if (!tooltip || viewport.isMobileInteractionMode()) return;

    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const cardH = tooltip.offsetHeight || 320;
    const cardW = Math.min(
      tooltip.offsetWidth || 512,
      vw - VIEWPORT_MARGIN * 2
    );

    const gapBelow = 10;
    const gapAbove = 4;

    let top = anchorRect.bottom + gapBelow;
    let isAbove = false;

    if (top + cardH > vh - VIEWPORT_MARGIN) {
      top = anchorRect.top - cardH - gapAbove;
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

    if (currentAnchor) {
      currentAnchor.setAttribute("aria-describedby", TOOLTIP_ID);
    }
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

  function clearCurrentAnchorDescription() {
    if (currentAnchor?.removeAttribute) {
      currentAnchor.removeAttribute("aria-describedby");
    }
    currentAnchor = null;
  }

  function hideCard() {
    abortCurrentRequest();

    if (!tooltip) return;

    tooltip.classList.remove("is-visible");
    clearCurrentAnchorDescription();

    later(() => {
      if (!tooltip?.classList.contains("is-visible")) {
        currentTopicId = null;
      }
    }, 300);
  }

  function scheduleHide() {
    cancel(hideTimer);
    hideTimer = later(() => {
      if (!isInsideCard) hideCard();
      suppressNextClick = false;
    }, DELAY_HIDE);
  }

  function scheduleShow(topicId, anchorRect, anchorEl) {
    cancel(showTimer);
    cancel(hideTimer);

    showTimer = later(() => {
      currentAnchor = anchorEl || null;
      showCard(topicId, anchorRect);
    }, config.delayShow);
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

    if (inFlightFetches.has(topicId)) {
      return inFlightFetches.get(topicId);
    }

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

    if (
      currentTopicId === topicId &&
      tooltip.classList.contains("is-visible")
    ) {
      positionTooltipNextFrame(anchorRect);
      return;
    }

    abortCurrentRequest();
    currentAbortController = new AbortController();
    currentTopicId = topicId;

    const isMobile = viewport.isMobileLayout();
    const cachedTopic = getCachedValue(topicCache, topicId);

    tooltip.innerHTML = cachedTopic
      ? getRenderedCard(cachedTopic, isMobile)
      : skeletonHTML();

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
            <div class="topic-hover-card topic-hover-card--error">
              <div class="topic-hover-card__body">
                Could not load topic.
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

    const raw = String(config.userPreferenceFieldName).trim();
    if (/^\d+$/.test(raw)) return raw;
    if (/^user_field_\d+$/i.test(raw)) return raw.match(/\d+/)?.[0] ?? null;

    if (resolvedUserFieldId !== null) return resolvedUserFieldId;
    if (resolvedUserFieldIdPromise) return resolvedUserFieldIdPromise;

    resolvedUserFieldIdPromise = getJSON("/admin/config/user-fields.json")
      .then((result) => {
        const fields = Array.isArray(result) ? result : result?.user_fields || [];
        const wanted = raw.toLowerCase();

        const match = fields.find((field) => {
          const id = field?.id;
          const name = String(field?.name || "")
            .trim()
            .toLowerCase();

          return (
            name === wanted ||
            `user_field_${id}` === wanted ||
            String(id) === wanted
          );
        });

        resolvedUserFieldId = match?.id ?? null;
        return resolvedUserFieldId;
      })
      .catch((error) => {
        logDebug(
          config,
          "Could not resolve user-field ID from admin endpoint",
          error
        );
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

    const directCandidates = normalizedFieldKeyVariants(
      config.userPreferenceFieldName
    );

    const currentUserCustomFields = currentUser?.custom_fields || {};
    const currentUserUserFields = currentUser?.user_fields || {};

    let match =
      findTruthyFieldMatch(currentUserCustomFields, directCandidates) ||
      findTruthyFieldMatch(currentUserUserFields, directCandidates);

    if (match) return true;

    const resolvedId = await resolveUserFieldIdForAdmins();
    const resolvedCandidates = resolvedId
      ? normalizedFieldKeyVariants(resolvedId)
      : [];

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

    scheduleShow(topicId, link.getBoundingClientRect(), link);
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

    currentAnchor = link;
    suppressNextClick = true;
    resetSuppressedClickSoon();
    showCard(topicId, link.getBoundingClientRect());
  }

  function onDocumentClick(event) {
    if (!viewport.isMobileInteractionMode() || !config.mobileEnabled) return;
    if (!(event.target instanceof Element)) return;

    if (suppressNextClick) {
      const link = event.target.closest("a[href]");
      if (
        link &&
        linkInSupportedArea(link, config) &&
        topicIdFromHref(link.href)
      ) {
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
    if (event.target?.closest?.(".topic-hover-card, #topic-hover-card-tooltip")) {
      return;
    }

    cancel(showTimer);
    hideCard();
    suppressNextClick = false;
  }

  function onResize() {
    if (tooltip?.classList.contains("is-visible")) {
      hideCard();
    }
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

    api.onPageChange(() => {
      cancel(showTimer);
      cancel(hideTimer);
      cancel(clearSuppressionTimer);
      hideCard();
      currentTopicId = null;
      suppressNextClick = false;
      clearCurrentAnchorDescription();
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