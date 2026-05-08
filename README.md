# discourse-wiki-contributors

Discourse 插件：在 Wiki 帖正文上方显示贡献者名单。

## 功能

- 仅 Wiki 帖显示贡献者名单。
- 贡献者来自 `PostRevision` 编辑历史。
- 同一用户多次编辑自动去重。
- 显示用户名、头像、编辑次数、最近编辑时间。
- 按最近编辑时间倒序。
- 超过限制时只显示前 N 位，并显示“等 N 位贡献者”。
- 不修改 Discourse 核心代码。
- 不绕过 Discourse 权限逻辑。

## 站点设置

- `wiki_contributors_enabled`：默认 `true`
- `wiki_contributors_limit`：默认 `10`，最大 `50`
- `wiki_contributors_show_edit_count`：默认 `true`

## API

```http
GET /wiki-contributors/:post_id
```

示例：

```json
{
  "post_id": 123,
  "contributors": [
    {
      "id": 1,
      "username": "rpc",
      "name": "阮品侪",
      "avatar_template": "/user_avatar/example.com/rpc/{size}/1_2.png",
      "edit_count": 5,
      "last_edited_at": "2026-05-09T12:00:00Z"
    }
  ],
  "total": 3,
  "limit": 10,
  "show_edit_count": true
}
```

## 安装

官方 `discourse_docker` 部署方式：

```bash
cd /var/discourse
nano containers/app.yml
```

在 `hooks.after_code` 加入：

```yml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/Hanserprpr/discourse-wiki-contributors.git
```

如果已有其他插件，把 clone 命令追加到已有 `cmd` 列表即可：

```yml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/Hanserprpr/discourse-wiki-contributors.git
```

重建：

```bash
cd /var/discourse
./launcher rebuild app
```

进入容器：

```bash
./launcher enter app
```

## 测试

### 1. 创建 Wiki 帖

1. 创建一个帖子。
2. 将帖子设置为 Wiki。
3. 用多个用户编辑该 Wiki 帖。
4. 刷新主题页面。

预期：首楼正文上方显示：

```text
Wiki 贡献者
本文由 3 位成员共同维护
```

并显示头像、用户名、编辑次数、最近编辑时间。

### 2. 测试 API

进入容器：

```bash
cd /var/discourse
./launcher enter app
rails c
```

查找 Wiki 帖：

```ruby
post = Post.where(wiki: true).last
post.id
```

访问：

```text
https://你的论坛域名/wiki-contributors/POST_ID
```

### 3. 非 Wiki 帖

非 Wiki 帖访问 `/wiki-contributors/:post_id` 应返回 404。

### 4. 权限测试

对私密分类中的 Wiki 帖，用无权限用户访问 API，应该无法看到贡献者信息。

## 排查错误

### 插件是否加载

```bash
cd /var/discourse
./launcher enter app
rails c
```

```ruby
SiteSetting.respond_to?(:wiki_contributors_enabled)
SiteSetting.wiki_contributors_enabled
```

### 查看 PostRevision 字段

```ruby
PostRevision.column_names
```

插件默认兼容这些用户字段：

- `user_id`
- `editor_id`
- `created_by_id`

默认兼容这些时间字段：

- `created_at`
- `updated_at`
- `revised_at`

如果你的 Discourse 版本字段不同，请修改 `plugin.rb` 中：

```ruby
DiscourseWikiContributors.revision_user_column
DiscourseWikiContributors.revision_time_column
```

### 查看日志

```bash
cd /var/discourse
./launcher logs app
```

或：

```bash
./launcher enter app
tail -f /var/www/discourse/log/production.log
```

搜索：

```text
discourse-wiki-contributors
```

### 前端不显示

检查：

1. 帖子是否是 Wiki：

```ruby
post = Post.find(POST_ID)
post.wiki
```

2. 插件是否开启：

```ruby
SiteSetting.wiki_contributors_enabled
```

3. 浏览器 Network 中是否请求：

```text
/wiki-contributors/POST_ID
```

常见状态：

- `404`：非 Wiki、帖子不存在、或插件关闭；
- `403`：当前用户无权限；
- `500`：多半是当前 Discourse 的 `PostRevision` 字段与插件默认字段不同。

## 设计说明

本插件不新增数据库表，不改变 Wiki 和编辑历史逻辑。每次请求时从 `PostRevision` 聚合统计贡献者。

如果论坛规模很大、Wiki 编辑历史很多，可后续增加缓存或索引优化。
