# frozen_string_literal: true

# name: discourse-wiki-contributors
# about: Show a lightweight contributors list for Discourse wiki posts
# version: 0.1.0
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

        users_by_id = User.where(id: rows.map { |row| row[:user_id] }.uniq).index_by(&:id)

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
        end
      end

      private

      attr_reader :post, :limit

      def normalize_limit(value)
        value = value.to_i
        value = DiscourseWikiContributors::DEFAULT_LIMIT if value <= 0
        [value, DiscourseWikiContributors::MAX_LIMIT].min
      end

      def revision_user_column
        @revision_user_column ||= DiscourseWikiContributors.revision_user_column
      end

      def revision_time_column
        @revision_time_column ||= DiscourseWikiContributors.revision_time_column
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
          .limit(limit)
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
      else
        "created_at"
      end
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

      limit = SiteSetting.wiki_contributors_limit.to_i
      limit = DiscourseWikiContributors::DEFAULT_LIMIT if limit <= 0
      limit = [limit, DiscourseWikiContributors::MAX_LIMIT].min

      render_json_dump(
        post_id: post.id,
        contributors: DiscourseWikiContributors::ContributorsQuery.call(post: post, limit: limit),
        total: total_contributors(post),
        limit: limit,
        show_edit_count: SiteSetting.wiki_contributors_show_edit_count
      )
    end

    private

    def total_contributors(post)
      user_column = DiscourseWikiContributors.revision_user_column
      return 0 unless user_column

      PostRevision
        .where(post_id: post.id)
        .where.not(user_column => nil)
        .distinct
        .count(user_column)
    end
  end

  DiscourseWikiContributors::Engine.routes.draw do
    get "/:post_id" => "wiki_contributors#show", constraints: { post_id: /\d+/ }
  end

  Discourse::Application.routes.append do
    mount ::DiscourseWikiContributors::Engine, at: "/wiki-contributors"
  end
end
