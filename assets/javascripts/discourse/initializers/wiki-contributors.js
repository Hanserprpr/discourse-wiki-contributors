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

function formatDate(value) {
  if (!value) {
    return "";
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return "";
  }

  return date.toLocaleString();
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

function buildContributorsHtml(payload) {
  const contributors = payload.contributors || [];
  const total = payload.total || contributors.length;
  const limit = payload.limit || contributors.length;
  const showEditCount = payload.show_edit_count !== false;

  if (contributors.length === 0) {
    return buildStatusHtml("wiki_contributors.empty", "wiki-contributors-empty");
  }

  const contributorItems = contributors
    .map((contributor) => {
      const username = escapeHtml(contributor.username);
      const name = escapeHtml(contributor.name || contributor.username);
      const avatar = escapeHtml(avatarUrl(contributor.avatar_template, 45));
      const editCount = contributor.edit_count || 0;
      const lastEditedAt = formatDate(contributor.last_edited_at);
      const lastEditedTitle = lastEditedAt
        ? escapeHtml(I18n.t("wiki_contributors.last_edited_at", { time: lastEditedAt }))
        : "";

      const editCountHtml = showEditCount
        ? `<span class="wiki-contributors-edit-count">${escapeHtml(
            I18n.t("wiki_contributors.edit_count", { count: editCount })
          )}</span>`
        : "";

      return `
        <li class="wiki-contributors-item">
          <a class="wiki-contributors-user" href="/u/${username}">
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
            ${lastEditedAt ? `<span class="wiki-contributors-last-edited" title="${lastEditedTitle}">${escapeHtml(lastEditedAt)}</span>` : ""}
          </span>
        </li>
      `;
    })
    .join("");

  const moreCount = Math.max(total - limit, 0);
  const moreHtml =
    moreCount > 0
      ? `<div class="wiki-contributors-more">${escapeHtml(
          I18n.t("wiki_contributors.and_more", { count: moreCount })
        )}</div>`
      : "";

  return `
    <section class="wiki-contributors-box">
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

      ${moreHtml}
    </section>
  `;
}

export default apiInitializer("1.8.0", (api) => {
  const siteSettings = api.container.lookup("service:site-settings");

  if (!siteSettings.wiki_contributors_enabled) {
    return;
  }

  api.decorateCookedElement(
    async (cooked, helper) => {
      const post = helper?.widget?.attrs;

      if (!post?.id || !post.wiki) {
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
        const payload = await ajax(`/wiki-contributors/${post.id}`);
        wrapper.innerHTML = buildContributorsHtml(payload);
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
    },
    {
      id: "wiki-contributors-decorator",
      onlyStream: true,
    }
  );
});
