import { later, cancel } from "@ember/runloop";
import { apiInitializer } from "discourse/lib/api";

const DELAY_SHOW = settings.card_delay_ms ?? 300;
const DELAY_HIDE = 200;
const CARD_WIDTH = settings.card_width || "32rem";
const MOBILE_ENABLED = settings.enable_on_mobile ?? false;
const MOBILE_WIDTH_PERCENT = settings.mobile_width_percent ?? 100;
const TOPIC_CACHE_MAX = settings.topic_cache_max ?? 100;
const USER_PREFERENCE_FIELD_NAME =
  settings.user_preference_field_name || "disable_topic_hover_cards";
const DEBUG_MODE = settings.debug_mode ?? false;
const RESOLVE_USER_FIELD_ID_FOR_ADMINS =
  settings.resolve_user_field_id_for_admins ?? true;
const VIEWPORT_MARGIN = 12;

const TOPIC_LINK_RE = /\/t\/(?:[^/]+\/)?([0-9]+)(?:\/[0-9]+)?/;

function isMobileView() {
  const hasHover =
    window.matchMedia("(any-hover: hover)").matches ||
    window.matchMedia("(hover: hover)").matches;

  if (hasHover) {
    return false;
  }

  return window.innerWidth < 768;
}

function isMobileLayout() {
  return window.innerWidth < 768;
}

async function getJSON(url) {
  const response = await fetch(url, {
    credentials: "same-origin",
    headers: {
      Accept: "application/json",
    },
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

function parsedTopicUrl(href) {
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

function topicIdFromHref(href) {
  const parsed = parsedTopicUrl(href);
  return parsed ? parsed.topicId : null;
}

function fmtNum(n) {
  if (!n && n !== 0) return "0";
  if (n >= 1000) return (n / 1000).toFixed(1).replace(/\.0$/, "") + "k";
  return String(n);
}

function stripHtml(html) {
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
    <div class="topic-hover-card topic-hover-card--density-default">
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

function dIconSVG(name) {
  const paths = {
    eye: "M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zM12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z",
    comment:
      "M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z",
    heart:
      "M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z",
    clock:
      "M12 2a10 10 0 1 0 0 20A10 10 0 0 0 12 2zm0 18a8 8 0 1 1 0-16 8 8 0 0 1 0 16zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67V7z",
    close:
      "M18 6 6 18M6 6l12 12",
  };

  const d = paths[name] ?? "";
  return `<svg class="d-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/></svg>`;
}

function findCategoryById(site, categoryId) {
  if (!site || !categoryId) return null;

  const categories = site.categoriesList?.categories || site.categories || [];
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
  return isMobile ? settings[mobileName] : settings[name];
}

function mobileInt(name, mobileName, fallback, isMobile) {
  return isMobile
    ? settings[mobileName] ?? settings[name] ?? fallback
    : settings[name] ?? fallback;
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

function debugLog(...args) {
  if (!DEBUG_MODE) return;
  console.info("[topic-hover-cards]", ...args);
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

  if (/^\d+$/.test(raw)) {
    keys.add(`user_field_${raw}`);
  }

  if (/^user_field_\d+$/.test(raw)) {
    keys.add(raw.replace(/^user_field_/, ""));
  }

  return [...keys];
}

function findTruthyFieldMatch(record, candidateKeys) {
  if (!record || !candidateKeys?.length) return null;

  for (const key of candidateKeys) {
    if (key in record && fieldValueIsTruthy(record[key])) {
      return {
        key,
        value: record[key],
      };
    }
  }

  return null;
}

function getCachedTopic(cache, topicId) {
  if (!cache.has(topicId)) {
    return null;
  }

  const value = cache.get(topicId);
  cache.delete(topicId);
  cache.set(topicId, value);

  return value;
}

function setCachedTopic(cache, topicId, topic) {
  if (cache.has(topicId)) {
    cache.delete(topicId);
  }

  cache.set(topicId, topic);

  if (cache.size > TOPIC_CACHE_MAX) {
    cache.delete(cache.keys().next().value);
  }
}

let resolvedUserFieldIdPromise = null;
let resolvedUserFieldId = null;

async function resolveUserFieldIdForAdmins(currentUser) {
  if (!RESOLVE_USER_FIELD_ID_FOR_ADMINS) return null;
  if (!currentUserIsStaffLike(currentUser)) return null;
  if (!USER_PREFERENCE_FIELD_NAME) return null;

  if (resolvedUserFieldId !== null) {
    return resolvedUserFieldId;
  }

  if (resolvedUserFieldIdPromise) {
    return resolvedUserFieldIdPromise;
  }

  resolvedUserFieldIdPromise = getJSON("/admin/config/user-fields.json")
    .then((result) => {
      const fields = Array.isArray(result) ? result : result?.user_fields || [];
      const wanted = String(USER_PREFERENCE_FIELD_NAME).trim().toLowerCase();

      const match = fields.find((field) => {
        const id = field?.id;
        const name = String(field?.name || "").trim().toLowerCase();
        return (
          name === wanted ||
          `user_field_${id}` === wanted ||
          String(id) === wanted
        );
      });

      resolvedUserFieldId = match?.id ?? null;

      debugLog("Resolved admin user-field mapping", {
        configuredField: USER_PREFERENCE_FIELD_NAME,
        resolvedUserFieldId,
      });

      return resolvedUserFieldId;
    })
    .catch((error) => {
      debugLog("Could not resolve user-field ID from admin endpoint", error);
      resolvedUserFieldId = null;
      return null;
    })
    .finally(() => {
      resolvedUserFieldIdPromise = null;
    });

  return resolvedUserFieldIdPromise;
}

async function fetchFullCurrentUser(api, currentUser) {
  if (!currentUser?.username) return null;

  try {
    const store = api.container.lookup("service:store");
    const user = await store.find("user", currentUser.username);
    return user || null;
  } catch (error) {
    debugLog("Could not fetch full current user record", error);
    return null;
  }
}

async function hoverCardsDisabledForUser(api, currentUser) {
  if (!currentUser || !USER_PREFERENCE_FIELD_NAME) return false;

  const directCandidates = normalizedFieldKeyVariants(
    USER_PREFERENCE_FIELD_NAME
  );

  const currentUserCustomFields = currentUser?.custom_fields || {};
  const currentUserUserFields = currentUser?.user_fields || {};

  let match =
    findTruthyFieldMatch(currentUserCustomFields, directCandidates) ||
    findTruthyFieldMatch(currentUserUserFields, directCandidates);

  if (match) {
    debugLog("Disable field matched on currentUser", {
      configuredField: USER_PREFERENCE_FIELD_NAME,
      matchedKey: match.key,
      value: match.value,
      source:
        match.key in currentUserCustomFields
          ? "currentUser.custom_fields"
          : "currentUser.user_fields",
    });
    return true;
  }

  const resolvedId = await resolveUserFieldIdForAdmins(currentUser);
  const resolvedCandidates = resolvedId
    ? normalizedFieldKeyVariants(resolvedId)
    : [];

  if (resolvedCandidates.length) {
    match =
      findTruthyFieldMatch(currentUserCustomFields, resolvedCandidates) ||
      findTruthyFieldMatch(currentUserUserFields, resolvedCandidates);

    if (match) {
      debugLog("Disable field matched on currentUser via resolved ID", {
        configuredField: USER_PREFERENCE_FIELD_NAME,
        resolvedId,
        matchedKey: match.key,
        value: match.value,
        source:
          match.key in currentUserCustomFields
            ? "currentUser.custom_fields"
            : "currentUser.user_fields",
      });
      return true;
    }
  }

  const fullUser = await fetchFullCurrentUser(api, currentUser);
  const fullUserFields = fullUser?.user_fields || {};
  const fullUserCustomFields = fullUser?.custom_fields || {};

  match =
    findTruthyFieldMatch(fullUserFields, directCandidates) ||
    findTruthyFieldMatch(fullUserCustomFields, directCandidates);

  if (match) {
    debugLog("Disable field matched on fetched full user", {
      configuredField: USER_PREFERENCE_FIELD_NAME,
      matchedKey: match.key,
      value: match.value,
      source:
        match.key in fullUserFields ? "user.user_fields" : "user.custom_fields",
    });
    return true;
  }

  if (resolvedCandidates.length) {
    match =
      findTruthyFieldMatch(fullUserFields, resolvedCandidates) ||
      findTruthyFieldMatch(fullUserCustomFields, resolvedCandidates);

    if (match) {
      debugLog("Disable field matched on fetched full user via resolved ID", {
        configuredField: USER_PREFERENCE_FIELD_NAME,
        resolvedId,
        matchedKey: match.key,
        value: match.value,
        source:
          match.key in fullUserFields ? "user.user_fields" : "user.custom_fields",
      });
      return true;
    }
  }

  debugLog("No disable field match found anywhere", {
    configuredField: USER_PREFERENCE_FIELD_NAME,
    directCandidates,
    resolvedCandidates,
    currentUserCustomFieldKeys: Object.keys(currentUserCustomFields),
    currentUserUserFieldKeys: Object.keys(currentUserUserFields),
    fullUserFieldKeys: Object.keys(fullUserFields),
    fullUserCustomFieldKeys: Object.keys(fullUserCustomFields),
  });

  return false;
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
  const parsed = parsedTopicUrl(link?.href);
  if (!parsed) return false;

  const currentTopicId = currentTopicIdFromLocation();
  if (currentTopicId && parsed.topicId === currentTopicId) {
    return true;
  }

  return (
    parsed.url.pathname.replace(/\/+$/, "") === currentTopicPathFromLocation()
  );
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

function isEligiblePreviewLink(link) {
  if (!link) return false;

  const parsed = parsedTopicUrl(link.href);
  if (!parsed) {
    return false;
  }

  if (inCookedPost(link)) {
    if (isCurrentTopicLink(link)) {
      debugLog("Skipping current-topic cooked-post link", {
        href: link.href,
      });
      return false;
    }

    if (isCookedPostFragmentLink(link)) {
      debugLog("Skipping cooked-post fragment link", {
        href: link.href,
      });
      return false;
    }
  }

  return true;
}

function isTopicAnchor(link) {
  return isEligiblePreviewLink(link);
}

function buildThumbnailHTML(topic, mode, isMobile) {
  if (!topic.image_url) {
    return "";
  }

  if (isMobile || mode === "manual") {
    return `
      <div class="topic-hover-card__thumbnail">
        <img src="${topic.image_url}" alt="" loading="lazy">
      </div>
    `;
  }

  return `
    <div class="topic-hover-card__thumbnail">
      <img class="topic-hover-card__thumbnail-bg" src="${topic.image_url}" alt="" loading="lazy" aria-hidden="true">
      <span class="topic-hover-card__thumbnail-overlay" aria-hidden="true"></span>
      <img class="topic-hover-card__thumbnail-fg" src="${topic.image_url}" alt="" loading="lazy">
    </div>
  `;
}

function buildCardHTML(topic, site, isMobile = false) {
  const topicUrl = `${window.location.origin}/t/${topic.slug || topic.id}/${topic.id}`;

  const showThumbnail = mobileBool(
    "show_thumbnail",
    "show_thumbnail_mobile",
    isMobile
  );
  const showCategory = mobileBool(
    "show_category",
    "show_category_mobile",
    isMobile
  );
  const showTags = mobileBool("show_tags", "show_tags_mobile", isMobile);
  const showTitle = mobileBool("show_title", "show_title_mobile", isMobile);
  const showExcerpt = mobileBool(
    "show_excerpt",
    "show_excerpt_mobile",
    isMobile
  );
  const showOp = mobileBool("show_op", "show_op_mobile", isMobile);
  const showPublishDate = mobileBool(
    "show_publish_date",
    "show_publish_date_mobile",
    isMobile
  );
  const showViews = mobileBool("show_views", "show_views_mobile", isMobile);
  const showReplyCount = mobileBool(
    "show_reply_count",
    "show_reply_count_mobile",
    isMobile
  );
  const showLikes = mobileBool("show_likes", "show_likes_mobile", isMobile);
  const showActivity = mobileBool(
    "show_activity",
    "show_activity_mobile",
    isMobile
  );

  const excerptLength = mobileInt(
    "excerpt_length",
    "excerpt_length_mobile",
    3,
    isMobile
  );

  const desktopImageSizePercent = settings.image_size_percent ?? 15;
  const configuredPlacement = settings.thumbnail_placement || "left";
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
         ${dIconSVG("close")}
       </button>`
    : "";

  const thumbnail =
    topic.image_url && showThumbnail
      ? buildThumbnailHTML(topic, sizeMode, isMobile)
      : "";

  let categoryHTML = "";
  if (showCategory && topic.category_id) {
    const category = findCategoryById(site, topic.category_id);

    const name =
      category?.name ||
      category?.slug ||
      topic.category_name ||
      topic.category_slug ||
      "";

    const color = category?.color
      ? `#${category.color}`
      : topic.category_color
        ? `#${topic.category_color}`
        : "var(--tertiary, var(--primary-medium))";

    if (name) {
      categoryHTML = `
        <span class="topic-hover-card__category">
          <span class="topic-hover-card__category-badge" style="--thc-category-color: ${color};">
            <span class="topic-hover-card__category-text">${name}</span>
          </span>
        </span>
      `;
    }
  }

  let tagsHTML = "";
  if (showTags && Array.isArray(topic.tags) && topic.tags.length) {
    const normalizedTags = topic.tags
      .map((tag) => normalizeTag(tag))
      .filter(Boolean);

    if (normalizedTags.length) {
      tagsHTML = `
        <div class="topic-hover-card__tags">
          ${normalizedTags
            .map(
              (tag) => `
                <span class="topic-hover-card__tag">
                  <span class="topic-hover-card__tag-text">${tag}</span>
                </span>`
            )
            .join("")}
        </div>
      `;
    }
  }

  const badgesHTML =
    categoryHTML || tagsHTML
      ? `<div class="topic-hover-card__badges">${categoryHTML}${tagsHTML}</div>`
      : "";

  const title = topic.fancy_title ?? topic.title ?? "(no title)";

  const titleHTML = showTitle
    ? `<div class="topic-hover-card__title">${title}</div>`
    : "";

  const firstPost = topic.post_stream?.posts?.[0];
  const excerptSource =
    topic.excerpt || firstPost?.excerpt || firstPost?.cooked || "";
  const cleanedExcerpt = stripHtml(excerptSource);
  const finalExcerpt = cleanedExcerpt.length >= 20 ? cleanedExcerpt : "";

  const excerpt =
    showExcerpt && finalExcerpt
      ? `<div class="topic-hover-card__excerpt" style="--thc-excerpt-lines:${excerptLength};">${finalExcerpt}</div>`
      : "";

  let opHTML = "";
  if (showOp) {
    const op =
      topic.details?.created_by ||
      (topic.post_stream?.posts?.[0]?.username && {
        username: topic.post_stream.posts[0].username,
        avatar_template: topic.post_stream.posts[0].avatar_template,
      }) ||
      topic.posters?.[0]?.user;

    if (op) {
      const avatarTemplate = op.avatar_template?.replace("{size}", "24");
      const avatarURL = avatarTemplate
        ? avatarTemplate.startsWith("http")
          ? avatarTemplate
          : window.location.origin + avatarTemplate
        : null;
      const avatarImg = avatarURL
        ? `<img src="${avatarURL}" width="24" height="24" alt="" loading="lazy">`
        : "";
      opHTML = `<span class="topic-hover-card__op">${avatarImg}<span class="username">${op.username}</span></span>`;
    }
  }

  let publishDate = "";
  if (showPublishDate && topic.created_at) {
    const d = new Date(topic.created_at);
    const fmt = d.toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
    });
    publishDate = `<span class="topic-hover-card__publish-date">${fmt}</span>`;
  }

  const statItems = [];

  if (showViews) {
    statItems.push(
      `<span class="topic-hover-card__stat">${dIconSVG("eye")} ${fmtNum(topic.views)}</span>`
    );
  }

  if (showReplyCount) {
    statItems.push(
      `<span class="topic-hover-card__stat">${dIconSVG("comment")} ${fmtNum(
        topic.reply_count ?? topic.posts_count - 1
      )}</span>`
    );
  }

  if (showLikes) {
    const likes = topic.like_count ?? topic.topic_post_like_count ?? 0;
    statItems.push(
      `<span class="topic-hover-card__stat">${dIconSVG("heart")} ${fmtNum(
        likes
      )}</span>`
    );
  }

  if (showActivity && topic.last_posted_at) {
    const d = new Date(topic.last_posted_at);
    const fmt = d.toLocaleDateString(undefined, {
      month: "short",
      day: "numeric",
      year: "numeric",
    });
    statItems.push(
      `<span class="topic-hover-card__stat">${dIconSVG("clock")} ${fmt}</span>`
    );
  }

  const statsHTML = statItems.length
    ? `<div class="topic-hover-card__stats">${statItems.join("")}</div>`
    : "";

  const metadataItems = [opHTML, publishDate, statsHTML]
    .filter(Boolean)
    .join("");

  const metadata = metadataItems
    ? `<div class="topic-hover-card__metadata">${metadataItems}</div>`
    : "";

  const mobileActions = isMobile
    ? `<div class="topic-hover-card__mobile-actions">
         <a class="btn btn-primary topic-hover-card__open-topic" href="${topicUrl}" data-thc-open-topic>
           Open topic
         </a>
       </div>`
    : "";

  const bodyInner = `
      ${mobileCloseButton}
      ${titleHTML}
      ${excerpt}
      ${metadata}
      ${badgesHTML}
      ${mobileActions}
  `;

const autoFitMaxWidth = settings.thumbnail_auto_fit_max_width || "10rem";

const wrapperStyle = isMobile
  ? ""
  : `style="--thc-image-size-percent:${desktopImageSizePercent}; --thc-auto-thumb-max-width:${autoFitMaxWidth};"`;

  switch (placement) {
    case "left":
      return `
        <div class="topic-hover-card topic-hover-card--thumb-left ${sizeModeClass} ${densityClass}" ${wrapperStyle}>
          ${thumbnail}
          <div class="topic-hover-card__body">
            ${bodyInner}
          </div>
        </div>`;

    case "right":
      return `
        <div class="topic-hover-card topic-hover-card--thumb-right ${sizeModeClass} ${densityClass}" ${wrapperStyle}>
          ${thumbnail}
          <div class="topic-hover-card__body">
            ${bodyInner}
          </div>
        </div>`;

    case "bottom":
      return `
        <div class="topic-hover-card topic-hover-card--thumb-bottom ${sizeModeClass} ${densityClass}" ${wrapperStyle}>
          <div class="topic-hover-card__body">
            ${bodyInner}
          </div>
          ${thumbnail}
        </div>`;

    case "top":
    default:
      return `
        <div class="topic-hover-card topic-hover-card--thumb-top ${sizeModeClass} ${densityClass}" ${wrapperStyle}>
          ${thumbnail}
          <div class="topic-hover-card__body">
            ${bodyInner}
          </div>
        </div>`;
  }
}

export default apiInitializer((api) => {
  const site = api.container.lookup("service:site");
  const currentUser =
    api.getCurrentUser?.() || api.container.lookup("service:current-user");

  (async () => {
    const isDisabled = await hoverCardsDisabledForUser(api, currentUser);

    if (isDisabled) {
      debugLog("Hover cards disabled for current user");
      return;
    }

    if (isMobileView() && !MOBILE_ENABLED) {
      debugLog("Mobile detected and mobile support disabled");
      return;
    }

    let tooltip = null;
    let showTimer = null;
    let hideTimer = null;
    let currentTopicId = null;
    let topicCache = new Map();
    let isInsideCard = false;
    let suppressNextClick = false;

    function ensureTooltip() {
      if (tooltip) return;

      tooltip = document.createElement("div");
      tooltip.className = "topic-hover-card-tooltip";
      tooltip.setAttribute("role", "tooltip");
      tooltip.setAttribute("aria-live", "polite");
      tooltip.style.setProperty("--thc-width", CARD_WIDTH);
      tooltip.style.setProperty(
        "--thc-mobile-width",
        `${MOBILE_WIDTH_PERCENT}vw`
      );

      tooltip.addEventListener("mouseenter", () => {
        isInsideCard = true;
        cancel(hideTimer);
      });

      tooltip.addEventListener("mouseleave", () => {
        isInsideCard = false;
        scheduleHide();
      });

      tooltip.addEventListener("click", (event) => {
        const inCard = event.target.closest(".topic-hover-card");
        if (!inCard) return;

        const closeBtn = event.target.closest("[data-thc-close]");
        if (closeBtn) {
          event.preventDefault();
          event.stopPropagation();
          hideCard();
          return;
        }

        const openBtn = event.target.closest("[data-thc-open-topic]");
        if (openBtn) {
          event.stopPropagation();
          hideCard();
          return;
        }

        if (isMobileView()) {
          event.preventDefault();
          event.stopPropagation();
        }
      });

      document.body.appendChild(tooltip);
    }

    function positionTooltip(anchorRect) {
      if (!tooltip || isMobileView()) return;

      const vw = window.innerWidth;
      const vh = window.innerHeight;
      const cardH = tooltip.offsetHeight || 320;
      const cardW = Math.min(
        tooltip.offsetWidth || 512,
        vw - VIEWPORT_MARGIN * 2
      );

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

    function showCard(topicId, anchorRect) {
      ensureTooltip();
      cancel(hideTimer);

      if (
        currentTopicId === topicId &&
        tooltip.classList.contains("is-visible")
      ) {
        positionTooltip(anchorRect);
        return;
      }

      currentTopicId = topicId;
      const mobile = isMobileLayout();
      const cachedTopic = getCachedTopic(topicCache, topicId);

      if (cachedTopic) {
        tooltip.innerHTML = buildCardHTML(cachedTopic, site, mobile);
      } else {
        tooltip.innerHTML = skeletonHTML();

        fetchTopic(topicId)
          .then((data) => {
            if (currentTopicId === topicId) {
              tooltip.innerHTML = buildCardHTML(data, site, isMobileLayout());
              positionTooltip(anchorRect);
            }
          })
          .catch(() => {
            if (currentTopicId === topicId) {
              tooltip.innerHTML =
                `<div class="topic-hover-card topic-hover-card--density-default"><div class="topic-hover-card__body"><div class="topic-hover-card__loading">Could not load topic.</div></div></div>`;
            }
          });
      }

      positionTooltip(anchorRect);
      tooltip.classList.add("is-visible");
    }

    function hideCard() {
      if (!tooltip) return;
      tooltip.classList.remove("is-visible");
      later(() => {
        if (!tooltip.classList.contains("is-visible")) {
          currentTopicId = null;
        }
      }, 400);
    }

    function scheduleShow(topicId, anchorRect) {
      cancel(showTimer);
      cancel(hideTimer);
      showTimer = later(() => showCard(topicId, anchorRect), DELAY_SHOW);
    }

    function scheduleHide() {
      cancel(hideTimer);
      hideTimer = later(() => {
        if (!isInsideCard) hideCard();
      }, DELAY_HIDE);
    }

    async function fetchTopic(topicId) {
      const cachedTopic = getCachedTopic(topicCache, topicId);
      if (cachedTopic) return cachedTopic;

      const data = await getJSON(`/t/${topicId}.json`);
      setCachedTopic(topicCache, topicId, data);
      return data;
    }

    function linkInSupportedArea(link) {
      if (!isTopicAnchor(link)) {
        return false;
      }

      if (settings.enable_on_suggested_topic_links && inSuggestedTopics(link)) {
        return true;
      }

      if (settings.enable_on_doc_categories && inDocCategoriesView(link)) {
        return true;
      }

      if (settings.enable_on_kanban_boards && inKanbanView(link)) {
        return true;
      }

      if (
        settings.enable_on_category_homepage_topic_lists &&
        inCategoryHomepageTopicList(link)
      ) {
        return true;
      }

      if (settings.enable_on_topic_lists && inTopicList(link)) {
        return true;
      }

      if (inCookedPost(link)) {
        const post = link.closest(".topic-post");
        const isFirstPost = post?.classList.contains("topic-owner");

        if (isFirstPost && settings.enable_on_topics) {
          return true;
        }

        if (!isFirstPost && settings.enable_on_replies) {
          return true;
        }
      }

      return false;
    }

    function onMouseEnter(event) {
      if (isMobileView()) return;

      const link = event.target.closest("a[href]");
      if (!link) return;
      if (!linkInSupportedArea(link)) return;

      const topicId = topicIdFromHref(link.href);
      if (!topicId) return;

      scheduleShow(topicId, link.getBoundingClientRect());
    }

    function onMouseLeave(event) {
      if (isMobileView()) return;

      const link = event.target.closest("a[href]");
      if (!link || !linkInSupportedArea(link)) return;

      scheduleHide();
    }

    function onTouchStart(event) {
      if (!isMobileView() || !MOBILE_ENABLED) return;

      if (event.target.closest(".topic-hover-card-tooltip")) {
        return;
      }

      const link = event.target.closest("a[href]");
      if (!link) return;
      if (!linkInSupportedArea(link)) return;

      const topicId = topicIdFromHref(link.href);
      if (!topicId) return;

      event.preventDefault();
      event.stopPropagation();
      suppressNextClick = true;
      showCard(topicId, link.getBoundingClientRect());
    }

    function onDocumentClick(event) {
      if (!isMobileView() || !MOBILE_ENABLED) return;

      if (suppressNextClick) {
        const link = event.target.closest("a[href]");
        if (link && linkInSupportedArea(link) && topicIdFromHref(link.href)) {
          event.preventDefault();
          event.stopPropagation();
          suppressNextClick = false;
          return;
        }
      }

      if (event.target.closest(".topic-hover-card-tooltip")) {
        return;
      }

      if (tooltip?.classList.contains("is-visible")) {
        hideCard();
      }
    }

    document.addEventListener("mouseover", onMouseEnter, { passive: true });
    document.addEventListener("mouseout", onMouseLeave, { passive: true });
    document.addEventListener("touchstart", onTouchStart, { passive: false });
    document.addEventListener("click", onDocumentClick, true);

    document.addEventListener(
      "scroll",
      (event) => {
        if (
          event.target?.closest?.(
            ".topic-hover-card, .topic-hover-card-tooltip"
          )
        ) {
          return;
        }

        cancel(showTimer);
        hideCard();
      },
      { passive: true, capture: true }
    );

    api.onPageChange(() => {
      cancel(showTimer);
      cancel(hideTimer);
      hideCard();
      currentTopicId = null;
      suppressNextClick = false;
    });

    debugLog("Hover cards initialized", {
      mobileEnabled: MOBILE_ENABLED,
      topicCacheMax: TOPIC_CACHE_MAX,
      configuredField: USER_PREFERENCE_FIELD_NAME,
      thumbnailSizeMode: thumbnailSizeMode(),
      currentViewportIsMobile: isMobileView(),
      locations: {
        topics: settings.enable_on_topics,
        replies: settings.enable_on_replies,
        topicLists: settings.enable_on_topic_lists,
        categoryHomepageTopicLists:
          settings.enable_on_category_homepage_topic_lists,
        docCategories: settings.enable_on_doc_categories,
        kanbanBoards: settings.enable_on_kanban_boards,
        suggested: settings.enable_on_suggested_topic_links,
      },
    });
  })();
});