# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseWikiContributors::WikiContributorsController do
  fab!(:viewer) { Fabricate(:user) }
  fab!(:editor_1) { Fabricate(:user, username: "editor_one") }
  fab!(:editor_2) { Fabricate(:user, username: "editor_two") }
  fab!(:topic) { Fabricate(:topic) }
  fab!(:wiki_post) { Fabricate(:post, topic: topic, wiki: true) }
  fab!(:regular_post) { Fabricate(:post, topic: topic, wiki: false) }

  before do
    SiteSetting.wiki_contributors_enabled = true
    SiteSetting.wiki_contributors_limit = 1
    SiteSetting.wiki_contributors_show_edit_count = true
    sign_in(viewer)
  end

  def revision_user_column
    DiscourseWikiContributors.revision_user_column
  end

  def revision_time_column
    DiscourseWikiContributors.revision_time_column
  end

  def create_revision(post:, user:, created_at:, number:)
    columns = PostRevision.column_names
    attrs = { post_id: post.id }
    attrs[revision_user_column] = user.id
    attrs[revision_time_column] = created_at if revision_time_column != "created_at"
    attrs[:created_at] = created_at if columns.include?("created_at")
    attrs[:updated_at] = created_at if columns.include?("updated_at")
    attrs[:number] = number if columns.include?("number")
    attrs[:modifications] = { "raw" => ["old", "new #{number}"] } if columns.include?("modifications")
    attrs[:hidden] = false if columns.include?("hidden")

    PostRevision.create!(attrs)
  end

  it "returns deduplicated contributors ordered by latest edit time" do
    skip "PostRevision has no supported user column" unless revision_user_column

    create_revision(post: wiki_post, user: editor_1, created_at: 3.days.ago, number: 1)
    create_revision(post: wiki_post, user: editor_2, created_at: 2.days.ago, number: 2)
    create_revision(post: wiki_post, user: editor_1, created_at: 1.day.ago, number: 3)

    get "/wiki-contributors/#{wiki_post.id}.json"

    expect(response.status).to eq(200)
    json = response.parsed_body
    expect(json["post_id"]).to eq(wiki_post.id)
    expect(json["total"]).to eq(2)
    expect(json["limit"]).to eq(1)
    expect(json["contributors"].length).to eq(1)
    expect(json["contributors"].first["username"]).to eq(editor_1.username)
    expect(json["contributors"].first["edit_count"]).to eq(2)
  end

  it "returns more contributors when all=true" do
    skip "PostRevision has no supported user column" unless revision_user_column

    create_revision(post: wiki_post, user: editor_1, created_at: 2.days.ago, number: 1)
    create_revision(post: wiki_post, user: editor_2, created_at: 1.day.ago, number: 2)

    get "/wiki-contributors/#{wiki_post.id}.json", params: { all: true }

    expect(response.status).to eq(200)
    json = response.parsed_body
    expect(json["all"]).to eq(true)
    expect(json["contributors"].map { |row| row["username"] }).to contain_exactly(
      editor_1.username,
      editor_2.username
    )
  end

  it "returns 404 for non-wiki posts" do
    get "/wiki-contributors/#{regular_post.id}.json"

    expect(response.status).to eq(404)
  end

  it "returns 404 when disabled" do
    SiteSetting.wiki_contributors_enabled = false

    get "/wiki-contributors/#{wiki_post.id}.json"

    expect(response.status).to eq(404)
  end
end
