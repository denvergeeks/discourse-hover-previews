import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { eq } from "truth-helpers";
import { iconNode } from "discourse/lib/icon-library";
import {
  sanitizeURL,
  safeAvatarURL,
  sanitizeExcerpt,
  formatNumber,
  findCategoryById,
  normalizeTag,
  getCachedValue,
  setCachedValue,
} from "../lib/hover-preview-utils";

// ─── Small pure helpers ───────────────────────────────────────────────────────

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
  return ["manual", "auto_fit_height"].includes(value) ? value : "auto_fit_height";
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

// ─── Sub-components ───────────────────────────────────────────────────────────

const CardThumbnail = <template>
  {{#if @imageUrl}}
    <div class="topic-hover-card__thumbnail">
      {{#if (eq @mode "auto_fit_height")}}
        {{! auto-fit: blurred bg + sharp fg, desktop only }}
        <img
          class="topic-hover-card__thumbnail-bg"
          src={{@imageUrl}}
          alt=""
          loading="lazy"
          decoding="async"
          aria-hidden="true"
        />
        <span class="topic-hover-card__thumbnail-overlay" aria-hidden="true"></span>
        <img
          class="topic-hover-card__thumbnail-fg"
          src={{@imageUrl}}
          alt=""
          loading="lazy"
          decoding="async"
        />
      {{else}}
        {{! manual / mobile: single cover image }}
        <img src={{@imageUrl}} alt="" loading="lazy" decoding="async" />
      {{/if}}
    </div>
  {{/if}}
</template>;

const CardCategory = <template>
  {{#if @name}}
    <span class="topic-hover-card__category">
      <span
        class="topic-hover-card__category-badge"
        style={{if @color (concat "--thc-category-color:" @color) null}}
      >
        <span class="topic-hover-card__category-text">{{@name}}</span>
      </span>
    </span>
  {{/if}}
</template>;

const CardSkeleton = <template>
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
</template>;

const CardError = <template>
  <div class="topic-hover-card">
    <div class="topic-hover-card__body">
      <div class="topic-hover-card__loading">Could not load topic.</div>
    </div>
  </div>
</template>;

// ─── Main Card Component ──────────────────────────────────────────────────────

export default class TopicHoverCard extends Component {
  @service site;

  /**
   * @param {object} args
   * @param {object|null} args.topic        - loaded topic JSON, null while loading
   * @param {boolean}     args.isLoading    - true while fetch is in-flight
   * @param {boolean}     args.hasError     - true if fetch failed
   * @param {boolean}     args.isMobile     - layout context
   * @param {object}      args.settingsObj  - theme settings object (passed from initializer)
   * @param {Map}         args.excerptCache - shared excerpt LRU cache
   * @param {function}    args.onClose      - callback: close button clicked (mobile)
   * @param {function}    args.onOpenTopic  - callback: "Open topic" button clicked (mobile)
   */

  get topic() {
    return this.args.topic;
  }

  get isMobile() {
    return this.args.isMobile ?? false;
  }

  get s() {
    return this.args.settingsObj;
  }

  // ── Derived display values ──────────────────────────────────────────────────

  get density() {
    return densitySetting(this.isMobile, this.s);
  }

  get placement() {
    return thumbnailPlacement(this.isMobile, this.s);
  }

  get sizeMode() {
    return thumbnailSizeMode(this.isMobile, this.s);
  }

  get sizePercent() {
    return thumbnailSizePercent(this.isMobile, this.s);
  }

  get autoFitMaxWidth() {
    return thumbnailAutoFitMaxWidth(this.isMobile, this.s);
  }

  get topBottomHeight() {
    return thumbnailTopBottomHeight(this.isMobile, this.s);
  }

  get topBottomHeightIsAuto() {
    return this.topBottomHeight.trim().toLowerCase() === "auto";
  }

  get showThumbnail() {
    return mobileBool("show_thumbnail", "show_thumbnail_mobile", this.isMobile, this.s);
  }

  get imageUrl() {
    return this.showThumbnail ? sanitizeURL(this.topic?.image_url) : null;
  }

  get cardClasses() {
    const p = this.placement;
    const sm =
      this.sizeMode === "auto_fit_height"
        ? "topic-hover-card--thumb-size-auto-fit-height"
        : "topic-hover-card--thumb-size-manual";
    const th =
      this.topBottomHeightIsAuto
        ? "topic-hover-card--thumb-top-bottom-height-auto"
        : "topic-hover-card--thumb-top-bottom-height-custom";
    return [
      "topic-hover-card",
      `topic-hover-card--thumb-${p}`,
      sm,
      th,
      `topic-hover-card--density-${this.density}`,
    ].join(" ");
  }

  get cardStyle() {
    return [
      `--thc-thumbnail-size-percent:${this.sizePercent}`,
      `--thc-auto-thumb-max-width:${this.autoFitMaxWidth}`,
      `--thc-top-bottom-thumb-height:${this.topBottomHeight}`,
    ].join(";");
  }

  // ── Title ───────────────────────────────────────────────────────────────────

  get showTitle() {
    return mobileBool("show_title", "show_title_mobile", this.isMobile, this.s);
  }

  get titleText() {
    return this.topic?.fancy_title ?? this.topic?.title ?? "(no title)";
  }

  // ── Excerpt ─────────────────────────────────────────────────────────────────

  get excerptStyle() {
    return `--thc-excerpt-lines:${this.excerptLines}`;
  }

  get showExcerpt() {
    return mobileBool("show_excerpt", "show_excerpt_mobile", this.isMobile, this.s);
  }

  get excerptLines() {
    return mobileInt("excerpt_length", "excerpt_length_mobile", 3, this.isMobile, this.s);
  }

  get excerptText() {
    if (!this.topic) return "";
    const cache = this.args.excerptCache;
    const key = this.topic.id ?? null;

    if (key) {
      const cached = getCachedValue(cache, key);
      if (cached) return cached;
    }

    const firstPost = this.topic.post_stream?.posts?.[0];
    const src = this.topic.excerpt || firstPost?.excerpt || firstPost?.cooked || "";
    const cleaned = sanitizeExcerpt(src);

    if (key) setCachedValue(cache, key, cleaned, 500);
    return cleaned.length >= 20 ? cleaned : "";
  }

  // ── Category ─────────────────────────────────────────────────────────────────

  get showCategory() {
    return mobileBool("show_category", "show_category_mobile", this.isMobile, this.s);
  }

  get category() {
    if (!this.showCategory || !this.topic?.category_id) return null;
    return findCategoryById(this.site.categories, this.topic.category_id);
  }

  get categoryName() {
    return (
      this.category?.name ||
      this.category?.slug ||
      this.topic?.category_name ||
      this.topic?.category_slug ||
      ""
    );
  }

  get categoryColor() {
    const raw = this.category?.color || this.topic?.category_color || null;
    return raw ? `#${String(raw).replace(/^#/, "")}` : null;
  }

  // ── Tags ─────────────────────────────────────────────────────────────────────

  get showTags() {
    return mobileBool("show_tags", "show_tags_mobile", this.isMobile, this.s);
  }

  get tags() {
    if (!this.showTags || !Array.isArray(this.topic?.tags)) return [];
    return this.topic.tags.map(normalizeTag).filter(Boolean);
  }

  // ── OP ───────────────────────────────────────────────────────────────────────

  get showOp() {
    return mobileBool("show_op", "show_op_mobile", this.isMobile, this.s);
  }

  get opUsername() {
    return (
      this.topic?.details?.created_by?.username ||
      this.topic?.posters?.[0]?.user?.username ||
      ""
    );
  }

  get opAvatarUrl() {
    const template =
      this.topic?.details?.created_by?.avatar_template ||
      this.topic?.posters?.[0]?.user?.avatar_template ||
      null;
    return safeAvatarURL(template, 24);
  }

  // ── Publish date ─────────────────────────────────────────────────────────────

  get showPublishDate() {
    return mobileBool(
      "show_publish_date",
      "show_publish_date_mobile",
      this.isMobile,
      this.s
    );
  }

  get publishDate() {
    if (!this.showPublishDate || !this.topic?.created_at) return null;
    try {
      return new Date(this.topic.created_at).toLocaleDateString(undefined, {
        year: "numeric",
        month: "short",
        day: "numeric",
      });
    } catch {
      return null;
    }
  }

  // ── Stats ────────────────────────────────────────────────────────────────────

  get showViews() {
    return mobileBool("show_views", "show_views_mobile", this.isMobile, this.s);
  }

  get showReplies() {
    return mobileBool("show_reply_count", "show_reply_count_mobile", this.isMobile, this.s);
  }

  get showLikes() {
    return mobileBool("show_likes", "show_likes_mobile", this.isMobile, this.s);
  }

  get showActivity() {
    return mobileBool("show_activity", "show_activity_mobile", this.isMobile, this.s);
  }

  get viewCount() {
    return formatNumber(this.topic?.views);
  }

  get replyCount() {
    return formatNumber(this.topic?.posts_count > 0 ? this.topic.posts_count - 1 : 0);
  }

  get likeCount() {
    return formatNumber(this.topic?.like_count);
  }

  get activityDate() {
    if (!this.showActivity || !this.topic?.last_posted_at) return null;
    try {
      return new Date(this.topic.last_posted_at).toLocaleDateString(undefined, {
        year: "numeric",
        month: "short",
        day: "numeric",
      });
    } catch {
      return null;
    }
  }

  get hasAnyStats() {
    return (
      (this.showViews && this.topic?.views) ||
      this.showReplies ||
      (this.showLikes && this.topic?.like_count) ||
      (this.showActivity && this.activityDate)
    );
  }

  get hasAnyMeta() {
    return (
      (this.showOp && this.opUsername) ||
      (this.showPublishDate && this.publishDate) ||
      this.hasAnyStats
    );
  }

  // ── Derived booleans (strict-mode friendly) ─────────────────────────────────

  get hasExcerpt() {
    return !!(this.showExcerpt && this.excerptText);
  }

  get hasCategory() {
    return !!(this.showCategory && this.categoryName);
  }

  get hasTags() {
    return !!(this.showTags && this.tags.length);
  }

  get hasBadges() {
    return !!(this.hasCategory || this.hasTags);
  }

  get hasOp() {
    return !!(this.showOp && this.opUsername);
  }

  get hasPublishDate() {
    return !!(this.showPublishDate && this.publishDate);
  }

  get hasViews() {
    return !!(this.showViews && this.topic?.views);
  }

  get hasLikes() {
    return !!(this.showLikes && this.topic?.like_count);
  }

  get hasActivityDate() {
    return !!(this.showActivity && this.activityDate);
  }

  // ── Mobile open URL ─────────────────────────────────────────────────────────

  get topicUrl() {
    const t = this.topic;
    if (!t) return "#";
    return `${window.location.origin}/t/${t.slug || t.id}/${t.id}`;
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  @action
  handleClose(event) {
    event.preventDefault();
    event.stopPropagation();
    this.args.onClose?.();
  }

  @action
  handleOpenTopic(event) {
    event.stopPropagation();
    this.args.onOpenTopic?.();
  }

  <template>
    {{#if @isLoading}}
      <CardSkeleton />
    {{else if @hasError}}
      <CardError />
    {{else if @topic}}
      {{! Thumbnail placement: top or left goes before body; bottom/right goes after }}
      <div class={{this.cardClasses}} style={{this.cardStyle}}>
        {{#if (eq this.placement "top")}}
          <CardThumbnail
            @imageUrl={{this.imageUrl}}
            @mode={{this.sizeMode}}
            @isMobile={{this.isMobile}}
          />
        {{/if}}
        {{#if (eq this.placement "left")}}
          <CardThumbnail
            @imageUrl={{this.imageUrl}}
            @mode={{this.sizeMode}}
            @isMobile={{this.isMobile}}
          />
        {{/if}}

        <div class="topic-hover-card__body">
          {{#if this.isMobile}}
            <button
              class="topic-hover-card__close"
              type="button"
              aria-label="Close preview"
              {{on "click" this.handleClose}}
            >
              <svg
                class="topic-hover-card__close-icon"
                viewBox="0 0 16 16"
                aria-hidden="true"
                focusable="false"
              >
                <path d="M4.2 4.2 11.8 11.8M11.8 4.2 4.2 11.8" />
              </svg>
            </button>
          {{/if}}

          {{#if this.showTitle}}
            <div class="topic-hover-card__title">
              {{this.titleText}}
            </div>
          {{/if}}

          {{#if this.hasExcerpt}}
            <div
              class="topic-hover-card__excerpt"
              style={{this.excerptStyle}}
            >
              {{this.excerptText}}
            </div>
          {{/if}}

          {{#if this.hasAnyMeta}}
            <div class="topic-hover-card__metadata">

              {{#if this.hasOp}}
                <span class="topic-hover-card__meta-group">
                  <span class="topic-hover-card__op">
                    {{#if this.opAvatarUrl}}
                      <img
                        src={{this.opAvatarUrl}}
                        width="24"
                        height="24"
                        alt={{this.opUsername}}
                        loading="lazy"
                        decoding="async"
                      />
                    {{/if}}
                    <span class="username">{{this.opUsername}}</span>
                  </span>
                </span>
              {{/if}}

              {{#if this.hasPublishDate}}
                <span class="topic-hover-card__meta-group">
                  <span
                    class="topic-hover-card__meta-separator"
                    aria-hidden="true"
                  >
                    ·
                  </span>
                  <span class="topic-hover-card__publish-date">
                    {{this.publishDate}}
                  </span>
                </span>
              {{/if}}

              {{#if this.hasAnyStats}}
                <span class="topic-hover-card__meta-group">
                  <span
                    class="topic-hover-card__meta-separator"
                    aria-hidden="true"
                  >
                    ·
                  </span>
                  <span class="topic-hover-card__stats">

                    {{#if this.hasViews}}
                      <span class="topic-hover-card__stat">
                        {{iconNode "far-eye"}}
                        <span>{{this.viewCount}}</span>
                      </span>
                    {{/if}}

                    {{#if this.showReplies}}
                      <span class="topic-hover-card__stat">
                        {{iconNode "reply"}}
                        <span>{{this.replyCount}}</span>
                      </span>
                    {{/if}}

                    {{#if this.hasLikes}}
                      <span class="topic-hover-card__stat">
                        {{iconNode "heart"}}
                        <span>{{this.likeCount}}</span>
                      </span>
                    {{/if}}

                    {{#if this.hasActivityDate}}
                      <span class="topic-hover-card__stat">
                        {{iconNode "clock"}}
                        <span>{{this.activityDate}}</span>
                      </span>
                    {{/if}}

                  </span>
                </span>
              {{/if}}

            </div>
          {{/if}}

          {{! Badges: category + tags }}
          {{#if this.hasBadges}}
            <div class="topic-hover-card__badges">

              {{#if this.hasCategory}}
                <CardCategory
                  @name={{this.categoryName}}
                  @color={{this.categoryColor}}
                />
              {{/if}}

              {{#if this.hasTags}}
                <div class="topic-hover-card__tags">
                  {{#each this.tags as |tag|}}
                    <span class="topic-hover-card__tag">
                      <span class="topic-hover-card__tag-text">
                        {{tag}}
                      </span>
                    </span>
                  {{/each}}
                </div>
              {{/if}}

            </div>
          {{/if}}

          {{! Mobile "Open topic" action }}
          {{#if this.isMobile}}
            <div class="topic-hover-card__mobile-actions">
              <a
                class="btn btn-primary topic-hover-card__open-topic"
                href={{this.topicUrl}}
                {{on "click" this.handleOpenTopic}}
              >
                Open topic
              </a>
            </div>
          {{/if}}

        </div>{{! end __body }}

        {{#if (eq this.placement "right")}}
          <CardThumbnail
            @imageUrl={{this.imageUrl}}
            @mode={{this.sizeMode}}
            @isMobile={{this.isMobile}}
          />
        {{/if}}
        {{#if (eq this.placement "bottom")}}
          <CardThumbnail
            @imageUrl={{this.imageUrl}}
            @mode={{this.sizeMode}}
            @isMobile={{this.isMobile}}
          />
        {{/if}}
      </div>
    {{/if}}
  </template>
}