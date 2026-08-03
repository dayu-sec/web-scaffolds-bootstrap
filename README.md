# Web 项目脚手架

> 大部分情况下，推荐通过 AI 探索、实现任务。

用于从 GitHub 上的预设模板创建单体项目、独立微应用或完整微前端架构项目，并安装团队 Web Skills。

---

## Web Skills 配置

```bash
curl -fsSL "https://raw.githubusercontent.com/dayu-sec/web-scaffolds-bootstrap/main/setup-web-skills.sh" | bash
```

该脚本将 [`dayu-sec/web-skills`](https://github.com/dayu-sec/web-skills) 仓库中 `AGENTS.md` 与 `skills/` 增量覆盖到 `~/.agents`；

如果 Agent 不支持此目录，请手动从 `~/.agents` 复制。

---

## 创建微应用

交互式执行：

```bash
curl -fsSL "https://raw.githubusercontent.com/dayu-sec/web-scaffolds-bootstrap/main/create-microapp.sh" | bash
```

可单独进行微应用开发，不用关心微前端架构项目的整体结构，以及菜单，按文件式路由约定访问。

## 创建微前端架构项目

交互式执行：

```bash
curl -fsSL "https://raw.githubusercontent.com/dayu-sec/web-scaffolds-bootstrap/main/create-project-microapp.sh" | bash
```

创建完成后可以安装配套的 [VS Code 扩展 MFA](https://marketplace.visualstudio.com/items?itemName=NicholasHsiang.vscode-seed-fe-mfa) 进行项目级开发。

---

## 创建单体项目

交互式执行：

```bash
curl -fsSL "https://raw.githubusercontent.com/dayu-sec/web-scaffolds-bootstrap/main/create-project-monolith.sh" | bash
```

---

## 基础环境配置

交互式执行：

```bash
curl -fsSL "https://raw.githubusercontent.com/dayu-sec/web-scaffolds-bootstrap/main/setup-base-environment.sh" | bash
```

该脚本用于配置面向全栈开发的基础环境：安装 mise、同步仓库约定的全局配置，并安装配置中声明的工具。工具清单、版本和安装后处理均以基础开发环境模板为准。

基础开发环境默认配置会同步到 mise 全局 `conf.d/base-development-environment.toml`，不会覆盖用户已有的 `config.toml` 或其他全局配置。用户如需调整默认版本，应在自己的 `config.toml` 中覆盖对应配置。

脚本结束后会根据当前 Shell 提示加载对应配置文件，例如 `source ~/.zprofile` 或 `source ~/.bash_profile`；也可以重新打开终端后再使用 mise 和配置中声明的工具。

安装过程默认只展示阶段结果；遇到问题时，可以使用 `--verbose` 查看 mise 和安装后端的完整输出。
