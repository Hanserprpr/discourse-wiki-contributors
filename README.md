# discourse-wiki-contributors

Discourse 插件：在 Wiki 帖正文上方显示贡献者名单。

## 功能

- 仅 Wiki 帖显示贡献者名单。
- 贡献者来自 `PostRevision` 编辑历史。
- 同一用户多次编辑自动去重。
- 显示用户名、头像、编辑次数、最近编辑时间。
- 按最近编辑时间倒序。
- 默认只显示前 N 位，点击“查看全部贡献者”后加载更多。
- 最近编辑时间在前端显示为相对时间，鼠标悬停显示完整时间。
- 后端使用 `Discourse.cache` 缓存 API 响应，帖子编辑/删除时清理对应缓存。
- 统计口径会排除系统用户、未激活用户和 staged 用户，避免显示自动任务或不可访问账户。
- 不修改 Discourse 核心代码。
- 不绕过 Discourse 权限逻辑。

## 站点设置

- `wiki_contributors_enabled`：默认 `true`
- `wiki_contributors_limit`：默认 `10`，最大 `50`
- `wiki_contributors_show_edit_count`：默认 `true`
- `wiki_contributors_cache_ttl_minutes`：默认 `10`，最大 `1440`

## API

```http
GET /wiki-contributors/:post_id
```

默认返回站点设置限制数量内的贡献者。

```http
GET /wiki-contributors/:post_id?all=true
```

返回更多贡献者，最多 `200` 人，避免超大编辑历史导致一次性响应过重。

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
  "all": false,
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

如果贡献者超过 `wiki_contributors_limit`，会显示“查看全部贡献者”按钮，点击后加载更多。

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
https://你的论坛域名/wiki-contributors/POST_ID?all=true
```

### 3. 非 Wiki 帖

非 Wiki 帖访问 `/wiki-contributors/:post_id` 应返回 404。

### 4. 权限测试

对私密分类中的 Wiki 帖，用无权限用户访问 API，应该无法看到贡献者信息。

### 5. 运行插件测试

在 Discourse 源码/容器环境中运行：

```bash
cd /var/www/discourse
bundle exec rspec plugins/discourse-wiki-contributors/spec
```

如果你通过 `discourse_docker` 进入容器：

```bash
cd /var/discourse
./launcher enter app
cd /var/www/discourse
bundle exec rspec plugins/discourse-wiki-contributors/spec
```

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
- `edited_at`

如果你的 Discourse 版本字段不同，请修改 `plugin.rb` 中：

```ruby
DiscourseWikiContributors.revision_user_column
DiscourseWikiContributors.revision_time_column
```

### 查看缓存

缓存 key 前缀：

```text
wiki-contributors:v2:post:POST_ID
```

帖子编辑或删除时插件会尝试清理对应缓存；如果某些缓存后端不支持 `delete_matched`，最多等待 `wiki_contributors_cache_ttl_minutes` 自然过期。

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

4. 如果 API 正常但页面不显示，检查帖子 DOM 上是否有 Wiki 标记：

```js
document.querySelector("article[data-post-id='POST_ID']")?.closest(".topic-post")?.className
```

新版本前端会同时兼容：

- `helper.widget.attrs.wiki`
- DOM class：`post--wiki` / `wiki`

常见状态：

- `404`：非 Wiki、帖子不存在、或插件关闭；
- `403`：当前用户无权限；
- `500`：多半是当前 Discourse 的 `PostRevision` 字段与插件默认字段不同。

## 设计说明

本插件不新增数据库表，不改变 Wiki 和编辑历史逻辑。贡献者仍以 `PostRevision` 为准。

当前统计口径：

- 同一用户多次修订只显示一次；
- `edit_count` 是该用户在该帖子上的修订记录数；
- `last_edited_at` 是该用户最近一次修订时间；
- 排除系统用户、未激活用户和 staged 用户；
- 不把原作者强行加入贡献者，除非原作者出现在 `PostRevision` 中。

如果论坛规模很大、Wiki 编辑历史很多，可进一步增加数据库索引或更细粒度缓存失效策略。
