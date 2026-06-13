# Mastodon 任务无结果问题 — 修复方案与执行计划

> 创建日期：2026-06-13
> 状态：部分完成（2 个核心任务已修复，38 个任务待批量处理）

---

## 一、问题现象

全量评测中，2 个 Mastodon 任务未产生任何结果：

- `MastodonImportMutedUsersTask` — 无 result.txt，出现在 `Tasks with no results`
- `MastodonShareLocationTask` — 同上

## 二、根因分析

### 2.1 直接原因：硬编码 Linux 容器路径

两个任务的 `ASSETS_PATH` 写死了 Linux Docker 容器内路径：

```python
# mastodon_import_muted.py:18
ASSETS_PATH = "/app/service/src/mobile_world/tasks/definitions/mastodon/assets/importMuted"

# mastodon_share_location.py:21
ASSETS_PATH = "/app/service/src/mobile_world/tasks/definitions/mastodon/assets/shareLocation"
```

macOS 上服务直接运行（非 Docker 内），`/app/service/...` 路径不存在 → `os.path.exists()` 返回 `False`。

### 2.2 连带原因一：返回值类型错误

`initialize_task_hook` 中文件不存在时返回了 tuple 而非 bool：

```python
if not os.path.exists(file_path):
    return 0.0, f"File path not found: {file_path}"  # tuple！不是 bool
```

`BaseTask.initialize_task()` 中的检查只处理 bool：

```python
# base.py:137
if isinstance(init_hook_res, bool) and not init_hook_res:
    # (0.0, str) 不是 bool 实例 → 条件永远为 False，错误被静默跳过
    return False
```

结果：任务被标记为 `initialized = True`，但文件未推送、Mastodon 后端未启动。

### 2.3 连带原因二：assert 硬崩溃

`is_successful()` 中使用了 `assert` 而非防御性检查：

```python
assert mastodon.is_mastodon_healthy()  # Mastodon 未运行 → AssertionError!
```

服务端返回 HTTP 500 → 客户端 `RuntimeError` → `_process_task_on_env` 返回 `None` → 无 `result.txt`。

### 2.4 完整异常链路

```
macOS: ASSETS_PATH = "/app/service/..."（不存在）
  → initialize_task_hook: os.path.exists() = False
    → return (0.0, str)  # tuple，绕过 BaseTask 检查
      → self.initialized = True（错误）
        → Mastodon 后端从未启动
          → is_successful: assert is_healthy() → AssertionError
            → HTTP 500 → 无 result.txt → "Tasks with no results"
```

### 2.5 为何其他 Mastodon 任务没有此问题

其他 Mastodon 任务的 `initialize_task_hook` 不检查文件存在性，直接调用 `start_mastodon_backend()`。Mastodon 正常启动，`is_successful` 即使因为路径问题返回 0.0，也会正常写入 `result.txt`，不会出现"无结果"。

---

## 三、已完成的修复

### 修改文件

| 文件 | 修改内容 |
|------|---------|
| `src/mobile_world/tasks/definitions/mastodon/mastodon_import_muted.py` | 三项修复 |
| `src/mobile_world/tasks/definitions/mastodon/mastodon_share_location.py` | 三项修复 |

### 三项修复（每个文件）

| 问题 | 修改前 | 修改后 |
|------|--------|--------|
| **硬编码 Linux 路径** | `ASSETS_PATH = "/app/service/src/..."` | 模块级通过 `__file__` 动态解析：`os.path.join(_THIS_DIR, "assets", "...")` |
| **返回值类型错误** | `return 0.0, f"File not found: ..."` | `return False`，并加 `logger.error()` 记录 |
| **assert 硬崩溃** | `assert mastodon.is_mastodon_healthy()` | `if not ...: return 0.0, "Mastodon backend is not healthy"` |

### 路径解析模块级代码

```python
# 放在 import 之后、class 定义之前
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_ASSETS_DIR = os.path.join(_THIS_DIR, "assets", "importMuted")  # 或 shareLocation

class MastodonImportMutedUsersTask(BaseTask):
    ASSETS_PATH = _ASSETS_DIR
    ...
```

---

## 四、待处理：assert is_healthy() 批量修复

### 4.1 影响范围

项目中 ~55 个任务文件使用了 `assert is_healthy()` 模式：

```
Mastodon 任务（38 个）: assert mastodon.is_mastodon_healthy()
Mattermost 任务（17 个）: assert mattermost.is_mattermost_healthy()
```

完整清单见附件 A。

### 4.2 风险分析

| 场景 | assert 行为 | 潜在后果 |
|------|------------|---------|
| 后端正常 | 无影响 | — |
| 后端未启动（正常模式） | AssertionError → HTTP 500 → 无 result.txt | "no results"，无原因说明 |
| 后端未启动（`python -O`） | assert 被移除 → 后续 DB 连接异常 | 错误信息不明确，排查困难 |
| 并发初始化冲突 | 偶发性后端被意外停止 | 难以复现的 flaky test |

### 4.3 修复模式

**修改前：**
```python
def is_successful(self, controller):
    self._check_is_initialized()
    assert mastodon.is_mastodon_healthy()
    ...
```

**修改后：**
```python
def is_successful(self, controller):
    self._check_is_initialized()
    if not mastodon.is_mastodon_healthy():
        return 0.0, "Mastodon backend is not healthy"
    ...
```

### 4.4 执行方式

推荐使用 `sed` 批量替换（两个命令覆盖所有文件）：

```bash
# Mastodon: 替换 assert mastodon.is_mastodon_healthy()
cd /Users/weiyan/Documents/UI-TEST/MobileWorld

find src/mobile_world/tasks/definitions -name "*.py" -exec sed -i '' \
  's/        assert mastodon\.is_mastodon_healthy()/        if not mastodon.is_mastodon_healthy():\n            return 0.0, "Mastodon backend is not healthy"/' {} +

# Mattermost: 替换 assert mattermost.is_mattermost_healthy()
find src/mobile_world/tasks/definitions -name "*.py" -exec sed -i '' \
  's/        assert mattermost\.is_mattermost_healthy()/        if not mattermost.is_mattermost_healthy():\n            return 0.0, "Mattermost backend is not healthy"/' {} +
```

> ⚠️ 执行前建议先 `git stash` 或创建分支，方便回滚。

### 4.5 验证方法

```bash
# 确认无残留 assert
grep -rn "assert mastodon.is_mastodon_healthy\|assert mattermost.is_mattermost_healthy" \
  src/mobile_world/tasks/definitions/ | wc -l
# 期望输出: 0

# 确认替换正确
grep -rn "return 0.0, \"Mastodon backend is not healthy\"" \
  src/mobile_world/tasks/definitions/ | wc -l
# 期望输出: 38（含已手动修复的 2 个）
```

---

## 五、额外建议：修复 BaseTask 的返回值检查

当前 `BaseTask.initialize_task()` 对 hook 返回值的处理不够健壮：

```python
# base.py:136-140 — 当前代码
init_hook_res = self.initialize_task_hook(controller)
if isinstance(init_hook_res, bool) and not init_hook_res:
    return False
```

建议改为同时处理非 bool 返回值（防御任务实现错误）：

```python
# 建议修改
init_hook_res = self.initialize_task_hook(controller)
if isinstance(init_hook_res, bool):
    if not init_hook_res:
        logger.error(f"Failed to initialize task hook for {self.name}")
        return False
elif init_hook_res is not None:
    logger.warning(
        f"initialize_task_hook for {self.name} returned {type(init_hook_res)} instead of bool, "
        f"continuing but this may be a bug"
    )
```

这可以防止未来新增任务重复出现类似的返回值类型错误。

---

## 附件 A：assert is_healthy() 完整清单

### Mastodon 任务（38 个文件）

```
src/mobile_world/tasks/definitions/mastodon/mastodon_add_bookmark.py
src/mobile_world/tasks/definitions/mastodon/mastodon_add_featured_hashtags.py
src/mobile_world/tasks/definitions/mastodon/mastodon_adjust_toots.py
src/mobile_world/tasks/definitions/mastodon/mastodon_calendar_multi_memos.py
src/mobile_world/tasks/definitions/mastodon/mastodon_change_header.py
src/mobile_world/tasks/definitions/mastodon/mastodon_change_language.py
src/mobile_world/tasks/definitions/mastodon/mastodon_conditional_favo.py
src/mobile_world/tasks/definitions/mastodon/mastodon_create_calendar_memo.py
src/mobile_world/tasks/definitions/mastodon/mastodon_create_list.py
src/mobile_world/tasks/definitions/mastodon/mastodon_dump_img_ask_user.py
src/mobile_world/tasks/definitions/mastodon/mastodon_dump_qcode_ask_user.py
src/mobile_world/tasks/definitions/mastodon/mastodon_export_follows.py
src/mobile_world/tasks/definitions/mastodon/mastodon_favorite_toots.py
src/mobile_world/tasks/definitions/mastodon/mastodon_filter_language.py
src/mobile_world/tasks/definitions/mastodon/mastodon_follow.py
src/mobile_world/tasks/definitions/mastodon/mastodon_get_server_info.py
src/mobile_world/tasks/definitions/mastodon/mastodon_import_muted.py        ← 已修复
src/mobile_world/tasks/definitions/mastodon/mastodon_invite.py
src/mobile_world/tasks/definitions/mastodon/mastodon_mall_purchase_commodity.py
src/mobile_world/tasks/definitions/mastodon/mastodon_mall_share_order.py
src/mobile_world/tasks/definitions/mastodon/mastodon_manage_hashtags.py
src/mobile_world/tasks/definitions/mastodon/mastodon_manage_multi_list.py
src/mobile_world/tasks/definitions/mastodon/mastodon_mattermost_post_notice.py
src/mobile_world/tasks/definitions/mastodon/mastodon_multi_invite.py
src/mobile_world/tasks/definitions/mastodon/mastodon_new_filter.py
src/mobile_world/tasks/definitions/mastodon/mastodon_new_post.py
src/mobile_world/tasks/definitions/mastodon/mastodon_open_automated_deletion.py
src/mobile_world/tasks/definitions/mastodon/mastodon_pin_toots.py
src/mobile_world/tasks/definitions/mastodon/mastodon_post_edited_photo.py
src/mobile_world/tasks/definitions/mastodon/mastodon_post_poll.py
src/mobile_world/tasks/definitions/mastodon/mastodon_remove_bookmark.py
src/mobile_world/tasks/definitions/mastodon/mastodon_reply.py
src/mobile_world/tasks/definitions/mastodon/mastodon_report.py
src/mobile_world/tasks/definitions/mastodon/mastodon_revise_photo_alt.py
src/mobile_world/tasks/definitions/mastodon/mastodon_revise_poll.py
src/mobile_world/tasks/definitions/mastodon/mastodon_save_photos.py
src/mobile_world/tasks/definitions/mastodon/mastodon_server_info_report.py
src/mobile_world/tasks/definitions/mastodon/mastodon_share_location.py      ← 已修复
src/mobile_world/tasks/definitions/mastodon/mastodon_unfollow.py
src/mobile_world/tasks/definitions/mastodon/mastodon_update_contacts.py
```

### Mattermost 任务（17 个文件）

```
src/mobile_world/tasks/definitions/work/mattermost_budget_approval_pipeline.py
src/mobile_world/tasks/definitions/work/mattermost_create_channel.py
src/mobile_world/tasks/definitions/work/mattermost_customer_feedback_analysis.py
src/mobile_world/tasks/definitions/work/mattermost_deadline_reconciliation.py
src/mobile_world/tasks/definitions/work/mattermost_email.py
src/mobile_world/tasks/definitions/work/mattermost_incident_escalation.py
src/mobile_world/tasks/definitions/work/mattermost_meeting_planning.py
src/mobile_world/tasks/definitions/work/mattermost_project_handover.py
src/mobile_world/tasks/definitions/work/mattermost_project_status_report.py
src/mobile_world/tasks/definitions/work/mattermost_reading_group.py
src/mobile_world/tasks/definitions/work/mattermost_reply_to_message.py
src/mobile_world/tasks/definitions/work/mattermost_resource_conflict_resolution.py
src/mobile_world/tasks/definitions/work/mattermost_send_file.py
src/mobile_world/tasks/definitions/work/mattermost_shift_coverage.py
src/mobile_world/tasks/definitions/work/mattermost_technical_debt_triage.py
src/mobile_world/tasks/definitions/work/local_file_management.py
src/mobile_world/tasks/definitions/map/download_poi_images_mcp.py
```

---

## 六、执行优先级

| 优先级 | 任务 | 影响 |
|--------|------|------|
| P0 ✅ 已完成 | 修复 `import_muted` 和 `share_location` 路径 + assert | 解决本次 2 个任务无结果问题 |
| P1 | 批量替换所有 `assert is_healthy()` → 防御性检查 | 防止未来其他任务因同样原因"无结果" |
| P2 | 加固 `BaseTask.initialize_task()` 返回值检查 | 防御未来新增任务的返回值类型错误 |
| P3 | 检查其他 4 个使用 `ASSETS_PATH` 的任务 (`change_header`, `save_photos`, `dump_img_ask_user`, `share_photos_ask_user`) 的路径兼容性 | 这些任务不崩溃但路径错误会导致验证失败（0.0 分） |
