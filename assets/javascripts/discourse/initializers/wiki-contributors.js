import { apiInitializer } from "discourse/lib/api";
import { ajax } from "discourse/lib/ajax";
import I18n from "discourse-i18n";

function avatarUrl(template, size = 45) {
  if (!template) {
    return "";
  }

  return template.replace("{size}", size);
}

function escapeHtml(value) {
  if (value === null || value === undefined) {
    return "";
  }

  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function formatAbsoluteDate(value) {
  if (!value) {
    return "";
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return "";
  }

  return date.toLocaleString();
}

function formatRelativeDate(value) {
  if (!value) {
    return "";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }

  const seconds = Math.round((date.getTime() - Date.now()) / 1000);
  const units = [
    ["year", 60 * 60 * 24 * 365],
    ["month", 60 * 60 * 24 * 30],
    ["day", 60 * 60 * 24],
    ["hour", 60 * 60],
    ["minute", 60],
  ];

  const locale = typeof I18n.locale === "string" ? I18n.locale.replace("_", "-") : undefined;
  let formatter = null;

  if (typeof Intl !== "undefined" && Intl.RelativeTimeFormat) {
    try {
      formatter = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
    } catch {
      formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
    }
  }

  for (const [unit, unitSeconds] of units) {
    if (Math.abs(seconds) >= unitSeconds) {
      const valueForUnit = Math.round(seconds / unitSeconds);
      return formatter ? formatter.format(valueForUnit, unit) : formatAbsoluteDate(value);
    }
  }

  return formatter ? formatter.format(seconds, "second") : formatAbsoluteDate(value);
}

function buildStatusHtml(statusKey, extraClass) {
  return `
    <section class="wiki-contributors-box ${extraClass}">
      <div class="wiki-contributors-title">${escapeHtml(
        I18n.t("wiki_contributors.title")
      )}</div>
      <div class="wiki-contributors-status">${escapeHtml(
        I18n.t(statusKey)
      )}</div>
    </section>
  `;
}

function userPath(username) {
  return `/u/${encodeURIComponent(String(username || "").toLowerCase())}`;
}

function buildContributorItem(contributor, showEditCount) {
  const username = escapeHtml(contributor.username);
  const name = escapeHtml(contributor.name || contributor.username);
  const avatar = escapeHtml(avatarUrl(contributor.avatar_template, 45));
  const profilePath = escapeHtml(userPath(contributor.username));
  const editCount = contributor.edit_count || 0;
  const relativeEditedAt = formatRelativeDate(contributor.last_edited_at);
  const absoluteEditedAt = formatAbsoluteDate(contributor.last_edited_at);
  const lastEditedTitle = absoluteEditedAt
    ? escapeHtml(I18n.t("wiki_contributors.last_edited_at", { time: absoluteEditedAt }))
    : "";

  const editCountHtml = showEditCount
    ? `<span class="wiki-contributors-edit-count">${escapeHtml(
        I18n.t("wiki_contributors.edit_count", { count: editCount })
      )}</span>`
    : "";

  return `
    <li class="wiki-contributors-item">
      <a
        class="wiki-contributors-user"
        href="${profilePath}"
        data-user-card="${username}"
        aria-label="${username}"
        tabindex="0"
      >
        <img
          class="wiki-contributors-avatar avatar"
          src="${avatar}"
          width="32"
          height="32"
          alt="${username}"
          loading="lazy"
        />
        <span class="wiki-contributors-user-main">
          <span class="wiki-contributors-username">${username}</span>
          ${contributor.name ? `<span class="wiki-contributors-name">${name}</span>` : ""}
        </span>
      </a>
      <span class="wiki-contributors-meta">
        ${editCountHtml}
        ${
          relativeEditedAt
            ? `<span class="wiki-contributors-last-edited" title="${lastEditedTitle}">${escapeHtml(relativeEditedAt)}</span>`
            : ""
        }
      </span>
    </li>
  `;
}

function buildContributorsHtml(payload, expanded = false) {
  const contributors = payload.contributors || [];
  const total = payload.total || contributors.length;
  const limit = payload.limit || contributors.length;
  const showEditCount = payload.show_edit_count !== false;

  if (contributors.length === 0) {
    return buildStatusHtml("wiki_contributors.empty", "wiki-contributors-empty");
  }

  const contributorItems = contributors
    .map((contributor) => buildContributorItem(contributor, showEditCount))
    .join("");

  const moreCount = Math.max(total - contributors.length, 0);
  const moreHtml =
    moreCount > 0
      ? `<button type="button" class="btn btn-small wiki-contributors-load-all" data-post-id="${payload.post_id}">
          ${escapeHtml(I18n.t("wiki_contributors.view_all"))}
          <span class="wiki-contributors-more-count">${escapeHtml(
            I18n.t("wiki_contributors.and_more", { count: moreCount })
          )}</span>
        </button>`
      : "";

  const collapseHtml =
    expanded
      ? `<button type="button" class="btn btn-small wiki-contributors-collapse">
          ${escapeHtml(I18n.t("wiki_contributors.collapse"))}
        </button>`
      : "";

  return `
    <section class="wiki-contributors-box" data-expanded="${expanded ? "true" : "false"}">
      <div class="wiki-contributors-header">
        <div>
          <div class="wiki-contributors-title">${escapeHtml(
            I18n.t("wiki_contributors.title")
          )}</div>
          <div class="wiki-contributors-summary">${escapeHtml(
            I18n.t("wiki_contributors.maintained_by", { count: total })
          )}</div>
        </div>
      </div>

      <ul class="wiki-contributors-list">
        ${contributorItems}
      </ul>

      <div class="wiki-contributors-actions">
        ${moreHtml}
        ${collapseHtml}
      </div>
    </section>
  `;
}

function shouldOpenInNewWindow(event) {
  return event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey;
}

function wireUserCards(wrapper, appEvents) {
  if (!appEvents) {
    return;
  }

  wrapper.querySelectorAll(".wiki-contributors-user[data-user-card]").forEach((link) => {
    if (link.dataset.wikiContributorsUserCardWired === "true") {
      return;
    }

    link.dataset.wikiContributorsUserCardWired = "true";
    link.addEventListener("click", (event) => {
      if (shouldOpenInNewWindow(event)) {
        return;
      }

      event.preventDefault();
      event.stopPropagation();
      appEvents.trigger(
        "topic-header:trigger-user-card",
        link.dataset.userCard,
        link,
        event
      );
    });
  });
}

function wireActions(wrapper, initialPayload, appEvents) {
  wireUserCards(wrapper, appEvents);

  const loadAllButton = wrapper.querySelector(".wiki-contributors-load-all");
  if (loadAllButton) {
    loadAllButton.addEventListener("click", async () => {
      loadAllButton.disabled = true;
      loadAllButton.textContent = I18n.t("wiki_contributors.loading_all");

      try {
        const payload = await ajax(`/wiki-contributors/${initialPayload.post_id}?all=true`);
        wrapper.innerHTML = buildContributorsHtml(payload, true);
        wireActions(wrapper, initialPayload, appEvents);
      } catch (error) {
        wrapper.innerHTML = buildStatusHtml(
          "wiki_contributors.failed",
          "wiki-contributors-error"
        );
        // eslint-disable-next-line no-console
        console.warn("Failed to load all wiki contributors", error);
      }
    });
  }

  const collapseButton = wrapper.querySelector(".wiki-contributors-collapse");
  if (collapseButton) {
    collapseButton.addEventListener("click", () => {
      wrapper.innerHTML = buildContributorsHtml(initialPayload, false);
      wireActions(wrapper, initialPayload, appEvents);
    });
  }
}

function topicPostFor(cooked) {
  const article = cooked.closest("article[data-post-id]");
  return cooked.closest(".topic-post") || article?.closest(".topic-post") || article;
}

function isWikiPost(post, cooked) {
  if (post?.wiki) {
    return true;
  }

  const topicPost = topicPostFor(cooked);
  return !!topicPost?.classList?.contains("post--wiki") || !!topicPost?.classList?.contains("wiki");
}

function postIdFor(post, cooked) {
  if (post?.id) {
    return post.id;
  }

  return cooked.closest("article[data-post-id]")?.getAttribute("data-post-id");
}

async function decorateWikiContributors(cooked, post, appEvents) {
  const postId = postIdFor(post, cooked);

  if (!postId || !isWikiPost(post, cooked)) {
    return;
  }

  if (cooked.dataset.wikiContributorsLoaded === "true") {
    return;
  }

  cooked.dataset.wikiContributorsLoaded = "true";

  const wrapper = document.createElement("div");
  wrapper.className = "wiki-contributors-wrapper";
  wrapper.innerHTML = buildStatusHtml(
    "wiki_contributors.loading",
    "wiki-contributors-loading"
  );

  cooked.prepend(wrapper);

  try {
    const payload = await ajax(`/wiki-contributors/${postId}`);
    wrapper.innerHTML = buildContributorsHtml(payload, false);
    wireActions(wrapper, payload, appEvents);
  } catch (error) {
    wrapper.innerHTML = buildStatusHtml(
      "wiki_contributors.failed",
      "wiki-contributors-error"
    );

    // 不抛出异常，避免影响 Discourse 原有帖子渲染。
    // 排查时查看浏览器 Network 与 Rails production.log。
    // eslint-disable-next-line no-console
    console.warn("Failed to load wiki contributors", error);
  }
}

function decorateVisibleWikiPosts(appEvents) {
  document
    .querySelectorAll(".topic-post.post--wiki .cooked, .topic-post.wiki .cooked")
    .forEach((cooked) => decorateWikiContributors(cooked, null, appEvents));
}

export default apiInitializer("1.8.0", (api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  const appEvents = api.container.lookup("service:app-events");

  if (!siteSettings.wiki_contributors_enabled) {
    return;
  }

  api.decorateCookedElement(
    async (cooked, helper) => {
      await decorateWikiContributors(cooked, helper?.widget?.attrs, appEvents);
    },
    {
      id: "wiki-contributors-decorator",
      onlyStream: true,
    }
  );

  decorateVisibleWikiPosts(appEvents);

  const observer = new MutationObserver(() => decorateVisibleWikiPosts(appEvents));
  observer.observe(document.body, { childList: true, subtree: true });
});
