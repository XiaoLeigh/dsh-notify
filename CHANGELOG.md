# 变更记录

## 0.1.1

DeepSeek Harness 的 Windows 原生通知：需要你批准、模型提问、任务完成（≥20s）、失败 /
输出截断 / blocked 时弹出 toast + 提示音，点击切回 DSH 窗口。

### 修掉的三个硬骨头

- **通知不显示（最坑）**：无包标识（unpackaged）的进程必须有一个带
  `System.AppUserModel.ID` 的**开始菜单快捷方式**才会真正显示 toast。只写
  `HKCU\Software\Classes\AppUserModelId\<id>` 注册表时，shell 会「接受」通知
  （通知历史里查得到记录）却永远不弹，也不报任何错。现在首次通知会自动创建该快捷方式，
  被删掉也会自动重建。
- **子进程秒退**：通知子进程不能用 `spawn(..., { detached: true })`。Windows 上这样创建
  的子进程会在约 60ms 内被干掉、什么都不执行，而插件日志仍显示「已发送」。
  去掉 `detached` 后子进程约 300ms 正常完成。
- **图标空白**：toast 左上角的应用图标来自 AUMID 注册。现在指向 DSH 鲸鱼剪影，
  并按 `SystemUsesLightTheme` 在白色 / 近黑两套之间自动切换，也可以 `icon: white|black`
  固定，或用绝对路径换成自己的 `.ico`。

### 其他

- 通知子进程把自己的运行结果写进 `%TEMP%\dsh-notify.log`（`diag: ... shown=True`），
  这样「没弹」时能一眼区分「进程没跑」和「被系统拦掉」。
- 音频换成自带的 `assets/chime.wav`（本项目合成，MIT）；本地若放一份 OpenAI 的
  `codex-notification.wav` 会优先用它，但该文件不进仓库、不进分发包。
- 全部失败路径都是静默的：通知出错永远不会影响一轮对话或 host 启动。