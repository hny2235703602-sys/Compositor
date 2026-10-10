# Compositor 助手版

这是 [Compositor](https://github.com/robbietilton/Compositor) 的一份分支。编辑器里多了一个助手面板，界面可以显示中文。关于窗口里的版本是 **1.4.7-ai**。

编出来的 App 只在执行编译的那台 Mac 上打开。要在另一台电脑上用，把这个仓库克隆过去，在那台电脑上再运行一次下面的脚本。不要把桌面上的 `Compositor.app` 拷给别人，也不要从上游的 GitHub Releases 或 Homebrew 安装：那是没有这个面板的官方版。

## 安装

需要 Apple 芯片的 Mac、macOS 26 和 Xcode 26。

```sh
git clone https://github.com/hny2235703602-sys/Compositor.git
cd Compositor
scripts/package-local-app.sh
```

脚本会做完这些事：

1. 用本机签名编译 Release。
2. 确认包里有主程序、`AIPanelWorker`、`Looks.json` 和 `Knowledge.json`，并且能启动。
3. 把 App 放到桌面，路径是 `~/Desktop/Compositor.app`。

如果桌面上已经有一份 `Compositor.app`，脚本会先把它改名为 `Compositor.app.bak-` 加时间戳，再放入新的。编译失败时不会动桌面上的旧 App。

## 使用

双击桌面上的 `Compositor.app`。

助手在窗口工具栏右侧、**Fit** 左边，按钮文字是「助手」，图标是一颗火花。没有菜单项，也没有快捷键。面板默认收起，点这个按钮展开。再点一次，或者点面板标题栏上的侧栏按钮，会把它收起。对话会留着。

第一次使用时，在面板下方的连接区填入：

- **Endpoint**：OpenAI 兼容地址，例如 `https://api.deepseek.com`
- **Key**：你自己的 API key，然后点保存
- 拉取模型列表，选一个模型

Key 只存在这台 Mac 上这个 App 自己的目录里，不会写进工程，也不会随仓库上传。

在输入框里用中文或英文说明要做的调整，然后发送。对文档的修改可以按 **⌘Z** 一步一步退回。
