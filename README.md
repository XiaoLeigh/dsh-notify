# dsh-notify

[English](#english) · 中文

让 DeepSeek Harness（DSH）在**需要你出手**或**一轮结束**时弹 Windows 通知 + 提示音。

- 需要你批准（sandbox 提权等 `approval/asked`）→ 立刻提醒
- 模型问你问题（`ask_user_question`）→ 立刻提醒
- 一轮任务结束（`turn/end` 的 `completed`）→ 超过阈值才提醒，避免每句闲聊都弹
- 轮次失败（`error`）、输出被截断（`max-tokens`）、被拒绝（`blocked`）→ 立刻提醒
- 你手动中止（`aborted`）→ 默认不提醒

插件跑在 **host 进程**里，监听 `session/event`，然后调用 `lib/win-notify.ps1` 发一条
**Codex 风格的原生 toast**：

- 首次发送时由 `lib/ensure-appid.ps1` 自动完成两件注册：
  1. 注册表 `HKCU\Software\Classes\AppUserModelId\DeepSeek.Harness.Notify`
     （DisplayName = `DeepSeek Harness`，IconUri 指向 DSH 的 exe）；
  2. 在开始菜单建 `DeepSeek Harness.lnk`，把它的 `System.AppUserModel.ID` 设为同一个 AUMID。

  **第 2 条才是能不能显示的关键。** 只写注册表而不建快捷方式时，Windows 会**收下** toast
  （通知历史里查得到记录）但**从不显示**，也不报错 —— 这就是之前"日志有记录、屏幕没东西"的根因。
  快捷方式只在缺失时创建一次，被删掉也会自动重建；它同时会成为开始菜单里的一个图标。
- 音频用本包自带的 `assets/codex-notification.wav`（Codex 的原声），找不到就回退系统提示音。
  注意：这个 wav 是 OpenAI Codex 的资源，仅为本地复刻体验随包携带，**不在 MIT 授权范围内**；
  要公开分发请先换成自己的音效或删掉它（删掉后自动回退系统提示音）。
- 点击 toast 会激活 `dshnotify://focus`，由 `lib/focus-window.ps1` 把 DSH 窗口还原并置前。
- toast 通道不可用时（例如在低完整性沙箱里跑）回退到托盘气泡 + 系统提示音。

> 注意：在 DSH 的**沙箱内**（完整性级别 Low）调 WinRT toast 会抛
> `The process has no package identity (0x80073D54)`。那是沙箱限制，不是插件问题；
> 插件在 host 进程里发通知，不受此限。

## 图标

通知左上角的应用图标是 DSH 的鲸鱼标志，渲染成纯色剪影：

- `assets/whale-on-dark.ico` —— 白色鲸鱼，深色通知背景用（当前生效的就是它）
- `assets/whale-on-light.ico` —— 近黑鲸鱼，浅色背景用

脚本按 `SystemUsesLightTheme` 选哪一个（Windows 11 混搭模式很常见：应用浅色、系统深色，
而通知跟随**系统**主题），换主题后下一次通知会自动换图标。

### 切换颜色

三种方式，从省事到彻底：

| 想要 | 做法 | 何时生效 |
|---|---|---|
| 跟着 Windows 深浅色自动换 | 什么都不用做（默认 `icon: auto`），改 设置 → 个性化 → 颜色 → **Windows 模式** | 下一条通知 |
| 固定用白色 / 固定用黑色 | 在包内 `cordis.patch.yml` 的 `config:` 里加 `icon: white`（或 `black`） | 重启 DSH |
| 换成任意自己的图标 | 把 `icon:` 设成 `.ico` 的绝对路径；或直接覆盖 `assets/whale-on-*.ico` | 用路径需重启；覆盖文件下一条通知即生效 |

```yaml
# node_modules/dsh-notify/cordis.patch.yml
- insert:
    - id: dsh-notify
      name: dsh-notify
      config:
        icon: white        # auto | white | black | D:\path\to\my.ico
```

`white` = `assets/whale-on-dark.ico`（白鲸鱼），`black` = `assets/whale-on-light.ico`
（近黑鲸鱼）。写错或文件不存在时自动退回 `auto`，不会把通知弄坏。

切换后如果图标没变，是 shell 缓存了 AUMID 的图标，跑一次 `ie4uinit.exe -show` 或重启
explorer 即可。

> 鲸鱼图形来自 DSH 自带的 favicon 标记，属于 DeepSeek 的商标，只是用来标识被通知的应用；
> 它不在本项目的 MIT 授权范围内。给别的产品做通知时请换成自己的图标。

## 默认行为

| 场景 | 是否通知 | 说明 |
|---|---|---|
| 需要批准 | ✅ | 声音更明显的 chime |
| 需要你回答问题 | ✅ | chime |
| 轮次完成，用时 ≥ 20s | ✅ | 小于 20s 的快速问答保持安静 |
| 轮次完成，用时 < 20s | ❌ | 想全都提醒就把 `minSeconds` 设为 0 |
| 失败 / 输出截断 / blocked | ✅ | 不管用时多短都提醒 |
| 你按了停止（aborted） | ❌ | `notifyAborted: true` 可打开 |
| 子代理（subagent）轮次 | ❌ | 只提醒主会话，避免刷屏 |

## 配置

默认值写死在 `lib/index.js` 的 `DEFAULTS` 里。要改行为，不用动代码，
在 profile 的 `cordis.patch.yml` 里给这一条加 `config:` 即可：

```yaml
- insert:
    - id: dsh-notify
      name: dsh-notify
      config:
        minSeconds: 0        # 每一轮结束都提醒
        sound: chime         # default | chime | none
        title: DSH
        notifyCompleted: true
        notifyFailure: true
        notifyTruncated: true
        notifyBlocked: true
        notifyAborted: false
        notifyApproval: true
        notifyQuestion: true
```

改完保存，DSH 的 HMR 会重新组合 profile，通常不需要重启。

## 安装位置

- 源码 / 开发副本：`<克隆目录>\dsh-notify`（本文档里的示例路径都可替换成你自己的）
- 已安装副本：`%USERPROFILE%\.dsh\profiles\desktop\node_modules\dsh-notify`
- 注册条目：`%USERPROFILE%\.dsh\profiles\desktop\package.json`
  - `dependencies["dsh-notify"] = "file:<克隆目录>/dsh-notify"`
  - `dsh.profile.bundles` 末尾的 `"dsh-notify"`（由包内 `cordis.patch.yml` 插入这一行）

所以它既出现在侧栏**插件**页（可开关、可卸载），也出现在 设置 → 插件 → **插件列表**
的全局分组里（标题会被设置页截成 `notify`，因为没配本地化 meta）。

> `file:` 指向源码目录，**别删源码目录**，否则以后在插件页安装/更新别的插件时 pnpm
> 解析这个依赖会失败。要搬家就把源码移到固定位置，并同步改 `dependencies` 的路径。

更新方式：改源码目录后同步到已安装副本（若 pnpm 已把它变成符号链接，改源码即生效）：

```powershell
Copy-Item <克隆目录>\dsh-notify\* `
  "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-notify" -Recurse -Force
```

## 卸载

1. 在侧栏**插件**页对它卸载；或手工改 `%USERPROFILE%\.dsh\profiles\desktop\package.json`，
   从 `dependencies` 与 `dsh.profile.bundles` 里删掉 `dsh-notify`。
2. 删除 `%USERPROFILE%\.dsh\profiles\desktop\node_modules\dsh-notify`。
3. 重启 DSH。

安装前的备份：同目录下 `package.json.bak-*`、`cordis.patch.yml.bak*`。

## 排查

- 加载与每次通知都会往 `%TEMP%\dsh-notify.log` 追加一行（文件超过 64 KB 后停止写入）：
  - `loaded (minSeconds=20)` 表示插件已挂载
  - `notify ...` 表示某次通知已发出
  - `diag: il= setting=Enabled shown=True ...` 由**子进程**写的，只有它出现才说明
    PowerShell 真的运行过并成功调用了 toast API；只有 `notify` 没有 `diag`，
    说明子进程没跑起来。
- 日志里没有 `loaded`：条目没被组合（检查 YAML 缩进、包是否在 node_modules 里）。
- 有 `notify` 但没有弹窗：Windows「专注助手 / 请勿打扰」会拦通知；
  检查 设置 → 系统 → 通知 里是否允许该应用。
- **注意 `spawn` 的选项**：发通知的子进程**不能**用 `detached: true`。实测在 Windows 上
  这样创建的子进程会在 60ms 内被干掉，什么都不执行；去掉 `detached` 后正常（约 300ms
  完成并退出）。这个坑曾让"日志有记录、屏幕没东西"再次出现。
- 手动测脚本：
  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
    "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-notify\lib\win-notify.ps1" `
    -Title "DSH" -Body "测试通知" -Sound chime
  ```

## 已知限制

- 只支持 Windows（用 WinRT toast；`package.json` 已声明 `os: ["win32"]`）。
- 点击只把 DSH 窗口切回来，不会定位到具体会话（Codex 那种会话深链需要额外的
  客户端副作用，暂未做）。
- 只在 DSH host 进程活着时工作；DSH 关掉就不会提醒。
- 「专注助手 / 勿扰」计时期间，toast 仍会被系统压掉，这与插件无关。

## English

A Windows toast notifier for DeepSeek Harness: it fires when the agent needs you
(approval prompts, `ask_user_question`), when a turn finishes, and when a turn
fails, is truncated or is blocked.

```bash
# 1) install into a DSH profile (pick the one you use)
dsh plugin --profile desktop add <path-or-git-url>
# or from source:
#   git clone https://github.com/XiaoLeigh/dsh-notify
#   dsh plugin --profile desktop add file:<abs-path>/dsh-notify
# 2) restart DSH
```

Notes for anyone reading the code:

- Toasts from an **unpackaged** process only *display* when a Start-menu shortcut
  carries the AppUserModelID, so `lib/ensure-appid.ps1` creates one on first use
  (a registry-only AUMID is accepted by the API but never shown).
- The notifier child process must **not** be spawned with `detached: true`;
  on Windows it is killed within ~60ms and nothing happens.
- Everything is defensive: a notification can never fail a turn or the host boot.

MIT licensed. The bundled `assets/chime.wav` is synthesised for this project; if
you drop OpenAI's `codex-notification.wav` next to it locally it will be preferred
(that file is git-ignored and not redistributed here).