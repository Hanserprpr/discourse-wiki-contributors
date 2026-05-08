# frozen_string_literal: true

# name: discourse-wiki-contributors
# about: Show a lightweight contributors list for Discourse wiki posts
# version: 0.2.0
# authors: Hanserprpr
# url: https://github.com/Hanserprpr/discourse-wiki-contributors
# required_version: 3.0.0

enabled_site_setting :wiki_contributors_enabled

register_asset "stylesheets/common/wiki-contributors.scss"

after_initialize do
  module ::DiscourseWikiContributors
    PLUGIN_NAME = "discourse-wiki-contributors"
    DEFAULT_LIMIT = 10
    MAX_LIMIT = 50
    MAX_ALL_LIMIT = 200

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseWikiContributors
    end

    class ContributorsQuery
      def self.call(post:, limit:)
        new(post: post, limit: limit).call
      end

      def initialize(post:, limit:)
        @post = post
        @limit = normalize_limit(limit)
      end

      def call
        return [] unless revision_user_column

        rows = query_revision_rows
        return [] if rows.blank?

        # 统计口径：
        # - 贡献者来源仍然只看 PostRevision 的编辑者；
        # - 排除系统用户、被删除/未激活/staged 用户，避免显示自动任务或不可访问账户；
        # - 同一用户多次修订聚合为一次，并统计 edit_count；
        # - 默认不把原帖作者强行加入贡献者，除非作者确实在 PostRevision 中出现。
        users_by_id =
          User
            .where(id: rows.map { |row| row[:user_id] }.uniq)
            .where(active: true)
            .where(staged: false)
            .where.not(id: system_user_id)
            .index_by(&:id)

        rows.filter_map do |row|
          user = users_by_id[row[:user_id]]
          next unless user

          {
            id: user.id,
            username: user.username,
            name: user.name,
            avatar_template: user.avatar_template,
            edit_count: row[:edit_count].to_i,
            last_edited_at: row[:last_edited_at]&.iso8601
          }
        end.take(limit)
      end

      private

      attr_reader :post, :limit

      def normalize_limit(value)
        value = value.to_i
        value = DiscourseWikiContributors::DEFAULT_LIMIT if value <= 0
        [value, DiscourseWikiContributors::MAX_ALL_LIMIT].min
      end

      def revision_user_column
        @revision_user_column ||= DiscourseWikiContributors.revision_user_column
      end

      def revision_time_column
        @revision_time_column ||= DiscourseWikiContributors.revision_time_column
      end

      def system_user_id
        Discourse.system_user&.id
      rescue StandardError
        -1
      end

      def query_revision_rows
        quoted_user_column = ActiveRecord::Base.connection.quote_column_name(revision_user_column)
        quoted_time_column = ActiveRecord::Base.connection.quote_column_name(revision_time_column)

        # 数据来源：PostRevision。
        #
        # 常见 Discourse 版本中：
        # - post_revisions.user_id 表示修订操作者
        # - post_revisions.created_at 表示修订时间
        #
        # 如果你的 Discourse 版本字段不同，请进入容器运行：
        #   rails c
        #   PostRevision.column_names
        # 然后调整 DiscourseWikiContributors.revision_user_column / revision_time_column
        # 中的候选字段。
        PostRevision
          .where(post_id: post.id)
          .where.not(revision_user_column => nil)
          .group(revision_user_column)
          .order(Arel.sql("MAX(#{quoted_time_column}) DESC"))
          .limit(DiscourseWikiContributors::MAX_ALL_LIMIT)
          .pluck(
            Arel.sql("#{quoted_user_column} AS user_id"),
            Arel.sql("COUNT(*) AS edit_count"),
            Arel.sql("MAX(#{quoted_time_column}) AS last_edited_at")
          )
          .map do |user_id, edit_count, last_edited_at|
            {
              user_id: user_id.to_i,
              edit_count: edit_count.to_i,
              last_edited_at: last_edited_at
            }
          end
      end
    end

    def self.revision_user_column
      columns = PostRevision.column_names

      # 不同 Discourse 版本或迁移历史中，修订记录上的用户字段可能不同。
      # 如遇 500，请用 `PostRevision.column_names` 检查字段，并在这里追加候选字段。
      if columns.include?("user_id")
        "user_id"
      elsif columns.include?("editor_id")
        "editor_id"
      elsif columns.include?("created_by_id")
        "created_by_id"
      else
        Rails.logger.warn(
          "[#{PLUGIN_NAME}] No supported user column found on PostRevision. " \
          "Columns: #{columns.join(', ')}"
        )
        nil
      end
    end

    def self.revision_time_column
      columns = PostRevision.column_names

      # 常见修订时间字段是 created_at；少数版本或自定义迁移可能不同。
      if columns.include?("created_at")
        "created_at"
      elsif columns.include?("updated_at")
        "updated_at"
      elsif columns.include?("revised_at")
        "revised_at"
      elsif columns.include?("edited_at")
        "edited_at"
      else
        "created_at"
      end
    end

    def self.cache_ttl
      ttl = SiteSetting.wiki_contributors_cache_ttl_minutes.to_i
      ttl = 10 if ttl <= 0
      ttl.minutes
    end

    def self.cache_key(post_id:, limit:, include_all:)
      user_column = revision_user_column || "none"
      time_column = revision_time_column || "none"
      "wiki-contributors:v2:post:#{post_id}:limit:#{limit}:all:#{include_all}:user:#{user_column}:time:#{time_column}"
    end

    def self.clear_cache_for(post_id)
      return unless post_id

      # delete_matched 在 Discourse.cache 后端中可用；如果某些后端不支持，降级为 no-op，
      # 最多等待 TTL 自然过期，不影响正确性。
      Discourse.cache.delete_matched("wiki-contributors:v2:post:#{post_id}:*")
    rescue StandardError => e
      Rails.logger.warn("[#{PLUGIN_NAME}] Failed to clear cache for post #{post_id}: #{e.class}: #{e.message}")
    end
  end

  class ::DiscourseWikiContributors::WikiContributorsController < ::ApplicationController
    requires_plugin DiscourseWikiContributors::PLUGIN_NAME

    def show
      raise Discourse::NotFound unless SiteSetting.wiki_contributors_enabled

      post = Post.find_by(id: params[:post_id])
      raise Discourse::NotFound unless post
      raise Discourse::NotFound unless post.wiki

      guardian = Guardian.new(current_user)

      # 不绕过 Discourse 自带权限：必须能看 topic 和 post 才返回贡献者信息。
      raise Discourse::InvalidAccess unless guardian.can_see?(post.topic)
      raise Discourse::InvalidAccess unless guardian.can_see_post?(post)

      include_all = ActiveModel::Type::Boolean.new.cast(params[:all])
      limit = resolved_limit(include_all: include_all)
      cache_key = DiscourseWikiContributors.cache_key(post_id: post.id, limit: limit, include_all: include_all)

      payload =
        Discourse.cache.fetch(cache_key, expires_in: DiscourseWikiContributors.cache_ttl) do
          {
            post_id: post.id,
            contributors: DiscourseWikiContributors::ContributorsQuery.call(post: post, limit: limit),
            total: total_contributors(post),
            limit: limit,
            all: include_all,
            show_edit_count: SiteSetting.wiki_contributors_show_edit_count
          }
        end

      # show_edit_count 是显示设置，不参与贡献者统计；每次响应使用最新设置，避免等缓存过期。
      payload = payload.merge(show_edit_count: SiteSetting.wiki_contributors_show_edit_count)

      render_json_dump(payload)
    end

    private

    def resolved_limit(include_all:)
      configured_limit = SiteSetting.wiki_contributors_limit.to_i
      configured_limit = DiscourseWikiContributors::DEFAULT_LIMIT if configured_limit <= 0

      if include_all
        DiscourseWikiContributors::MAX_ALL_LIMIT
      else
        [configured_limit, DiscourseWikiContributors::MAX_LIMIT].min
      end
    end

    def total_contributors(post)
      user_column = DiscourseWikiContributors.revision_user_column
      return 0 unless user_column

      scope =
        PostRevision
          .where(post_id: post.id)
          .where.not(user_column => nil)

      system_user_id = begin
        Discourse.system_user&.id
      rescue StandardError
        -1
      end
      scope = scope.where.not(user_column => system_user_id) if system_user_id

      user_ids = scope.distinct.pluck(user_column)
      return 0 if user_ids.blank?

      User.where(id: user_ids).where(active: true).where(staged: false).count
    end
  end

  DiscourseWikiContributors::Engine.routes.draw do
    get "/:post_id" => "wiki_contributors#show", constraints: { post_id: /\d+/ }
  end

  Discourse::Application.routes.append do
    mount ::DiscourseWikiContributors::Engine, at: "/wiki-contributors"
  end

  on(:post_edited) do |post, *_args|
    DiscourseWikiContributors.clear_cache_for(post&.id)
  end

  on(:post_destroyed) do |post, *_args|
    DiscourseWikiContributors.clear_cache_for(post&.id)
  end
end
