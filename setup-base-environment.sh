#!/usr/bin/env bash

set -Eeuo pipefail

ASSUME_YES=false
REQUESTED_SHELL=""
ACTIVE_SHELL=""
ACTIVE_SHELL_PATH=""
MISE_BIN=""
INSTALLER_TEMP_FILE=""
ISOLATED_WORK_DIRECTORY=""
INTERACTIVE_TERMINAL_OPEN=false
CONFLICT_TOOLS=""
NODE_VERSION=""
PNPM_VERSION=""

# 安装概览由 help 和交互引导共同使用，避免检查范围的文案在两处发生偏差。
print_installation_overview() {
  cat <<'EOF'
安装内容：
  1. 检查并安装 mise
  2. 为当前登录 Shell 配置 mise 激活脚本
  3. 检查并提示更新全局 Node.js LTS 和 pnpm latest
EOF
}

# 相似工具说明在执行检查前展示，明确脚本只报告冲突而不会主动卸载。
print_conflict_notice() {
  cat <<'EOF'
说明：
  脚本会检查 nvm、fnm、Volta、asdf、nodenv 和 n 等相似工具，但不会自动卸载。
EOF
}

print_usage() {
  cat <<'EOF'
用法：
  setup-base-environment.sh [选项]

EOF
  print_installation_overview
  cat <<'EOF'

选项：
  --shell <bash|zsh|fish>  指定要配置的 Shell；默认从 SHELL 环境变量侦测
  -y, --yes               非交互执行，自动确认安装、环境冲突和全局版本覆盖提示
  -h, --help              显示帮助

EOF
  print_conflict_notice
}

fail() {
  if [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]]; then
    printf '错误：%s\n' "$*" >&3
  else
    printf '错误：%s\n' "$*" >&2
  fi
  exit 1
}

cleanup() {
  [[ -z "$INSTALLER_TEMP_FILE" || ! -e "$INSTALLER_TEMP_FILE" ]] || rm -f "$INSTALLER_TEMP_FILE"
  # 工作目录只使用本次 mktemp 返回的精确路径，异常退出时也不遗留临时状态。
  [[ -z "$ISOLATED_WORK_DIRECTORY" || ! -d "$ISOLATED_WORK_DIRECTORY" ]] || rm -rf -- "$ISOLATED_WORK_DIRECTORY"
  if [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]]; then
    exec 3>&- || true
  fi
}

trap cleanup EXIT

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --shell)
        (($# >= 2)) || fail "--shell 需要提供值。"
        REQUESTED_SHELL="$2"
        shift 2
        ;;
      -y | --yes)
        ASSUME_YES=true
        shift
        ;;
      -h | --help)
        print_usage
        exit 0
        ;;
      *)
        fail "无法识别的参数：$1。使用 --help 查看用法。"
        ;;
    esac
  done
}

open_interactive_terminal() {
  [[ "$ASSUME_YES" == true ]] && return
  [[ -r /dev/tty && -w /dev/tty ]] || fail "当前环境无法交互，请在终端中运行，或使用 --yes 非交互执行。"
  exec 3<>/dev/tty
  INTERACTIVE_TERMINAL_OPEN=true
}

# 交互执行在任何环境检查之前展示与 help 一致的范围和非破坏性边界。
print_interactive_overview() {
  if [[ "$INTERACTIVE_TERMINAL_OPEN" != true ]]; then
    return 0
  fi

  printf '\n基础环境配置\n\n' >&3
  print_installation_overview >&3
  printf '\n' >&3
  print_conflict_notice >&3
}

# 破坏性安装前只接受明确的继续或取消，直接回车表示继续。
confirm_continue() {
  local message="$1"
  local answer=""

  [[ "$ASSUME_YES" == true ]] && return

  while true; do
    printf '%s\n' "$message" >&3
    printf '按回车继续，输入 n 取消：' >&3
    IFS= read -r answer <&3 || fail "未能读取用户输入。"
    case "$answer" in
      "" | y | Y | yes | YES)
        return
        ;;
      n | N | no | NO)
        printf '已取消。\n' >&3
        exit 0
        ;;
      *)
        printf '请输入回车继续，或输入 n 取消。\n' >&3
        ;;
    esac
  done
}

detect_shell() {
  local shell_name=""

  if [[ -n "$REQUESTED_SHELL" ]]; then
    shell_name="$REQUESTED_SHELL"
  elif [[ -n "${SHELL:-}" ]]; then
    shell_name="${SHELL##*/}"
  else
    fail "未检测到登录 Shell，请使用 --shell bash、--shell zsh 或 --shell fish 指定。"
  fi

  case "$shell_name" in
    bash | zsh | fish)
      ACTIVE_SHELL="$shell_name"
      ;;
    *)
      fail "暂不支持 Shell：${shell_name}。请使用 bash、zsh 或 fish。"
      ;;
  esac

  ACTIVE_SHELL_PATH="$(command -v "$ACTIVE_SHELL" || true)"
  [[ -n "$ACTIVE_SHELL_PATH" ]] || fail "未找到 ${ACTIVE_SHELL}，请先安装该 Shell，或通过 --shell 选择已安装的 Shell。"
}

append_conflict() {
  local tool="$1"

  case " $CONFLICT_TOOLS " in
    *" $tool "*) ;;
    *) CONFLICT_TOOLS="${CONFLICT_TOOLS:+$CONFLICT_TOOLS }$tool" ;;
  esac
}

config_contains() {
  local pattern="$1"
  local config_file=""

  for config_file in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.config/fish/config.fish"; do
    [[ -f "$config_file" ]] || continue
    grep -Eq "$pattern" "$config_file" && return 0
  done
  return 1
}

# Shell 函数型版本管理器无法稳定通过 command -v 发现，因此同时检查目录和初始化配置。
detect_conflicting_tools() {
  if command -v nvm >/dev/null 2>&1 || [[ -e "${NVM_DIR:-$HOME/.nvm}" ]] || config_contains 'NVM_DIR|nvm\.sh'; then
    append_conflict "nvm"
  fi
  if command -v fnm >/dev/null 2>&1 ||
    [[ -n "${FNM_DIR:-}" && -e "${FNM_DIR:-}" ]] ||
    [[ -e "$HOME/.fnm" || -e "${XDG_DATA_HOME:-$HOME/.local/share}/fnm" || -e "$HOME/Library/Application Support/fnm" ]] ||
    config_contains 'fnm env|FNM_DIR'; then
    append_conflict "fnm"
  fi
  if command -v volta >/dev/null 2>&1 || [[ -e "${VOLTA_HOME:-$HOME/.volta}" ]] || config_contains 'VOLTA_HOME|/\.volta/bin'; then
    append_conflict "Volta"
  fi
  if command -v asdf >/dev/null 2>&1 || [[ -e "$HOME/.asdf" ]] || config_contains 'asdf\.sh|ASDF_DIR'; then
    append_conflict "asdf"
  fi
  if command -v nodenv >/dev/null 2>&1 || [[ -e "$HOME/.nodenv" ]] || config_contains 'nodenv init|NODENV_ROOT'; then
    append_conflict "nodenv"
  fi
  if command -v n >/dev/null 2>&1 || [[ -n "${N_PREFIX:-}" ]]; then
    append_conflict "n"
  fi
}

print_conflict_guidance() {
  [[ -n "$CONFLICT_TOOLS" ]] || return 0

  printf '\n检测到可能与 mise 重复管理 Node.js 的工具：%s\n' "$CONFLICT_TOOLS"
  printf '多个版本管理器同时修改 PATH，可能导致 node、npm 或 pnpm 实际版本与预期不一致。\n'
  printf '本脚本不会自动删除任何现有工具。建议在确认不再需要后按各工具的安装来源卸载：\n'

  case " $CONFLICT_TOOLS " in
    *" nvm "*)
      printf '  - nvm：先执行 nvm unload，再删除 NVM_DIR 目录及 Shell 配置中的 NVM_DIR/nvm.sh 初始化行。\n'
      ;;
  esac
  case " $CONFLICT_TOOLS " in
    *" fnm "*)
      printf '  - fnm：删除 FNM_DIR 或 fnm 数据目录，并移除 Shell 配置中的 fnm env 初始化行；若由包管理器安装，使用原包管理器卸载。\n'
      ;;
  esac
  case " $CONFLICT_TOOLS " in
    *" Volta "*)
      printf '  - Volta：删除 ~/.volta，并移除 Shell 配置中的 VOLTA_HOME 和 PATH 配置。\n'
      ;;
  esac
  case " $CONFLICT_TOOLS " in
    *" asdf "* | *" nodenv "* | *" n "*)
      printf '  - asdf/nodenv/n：按原安装方式卸载，并清理对应的 Shell 初始化配置。\n'
      ;;
  esac

  confirm_continue "可以先退出并完成清理，也可以继续安装 mise，稍后再处理冲突。"
}

find_mise() {
  if [[ -x "$HOME/.local/bin/mise" ]]; then
    MISE_BIN="$HOME/.local/bin/mise"
  else
    MISE_BIN="$(command -v mise || true)"
  fi
}

install_mise() {
  local temp_root="${TMPDIR:-/tmp}"

  command -v curl >/dev/null 2>&1 || fail "安装 mise 需要 curl，请先安装 curl 后重试。"
  confirm_continue "未检测到 mise，即将从 https://mise.run 安装到 $HOME/.local/bin/mise。"

  INSTALLER_TEMP_FILE="$(mktemp "${temp_root%/}/mise-installer.XXXXXX")" || fail "无法创建 mise 安装器临时文件。"
  printf '\n正在下载安装 mise...\n'
  curl -fsSL https://mise.run -o "$INSTALLER_TEMP_FILE"
  MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh "$INSTALLER_TEMP_FILE"
  find_mise
  [[ -n "$MISE_BIN" && -x "$MISE_BIN" ]] || fail "mise 安装完成后仍未找到可执行文件。"
}

shell_config_file() {
  case "$ACTIVE_SHELL" in
    bash) printf '%s\n' "$HOME/.bashrc" ;;
    zsh) printf '%s\n' "$HOME/.zshrc" ;;
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
  esac
}

activation_line() {
  local command_path="$MISE_BIN"

  if [[ "$MISE_BIN" == "$HOME/.local/bin/mise" ]]; then
    # 保留字面量 ~ 写入用户配置，实际加载 rc 文件时再由目标 Shell 展开。
    # shellcheck disable=SC2088
    command_path="~/.local/bin/mise"
  fi

  # 格式字符串保留字面量 $()，由用户启动目标 Shell 时执行。
  # shellcheck disable=SC2016
  case "$ACTIVE_SHELL" in
    bash | zsh) printf 'eval "$(%s activate %s)"\n' "$command_path" "$ACTIVE_SHELL" ;;
    fish) printf '%s activate fish | source\n' "$command_path" ;;
  esac
}

configure_shell_activation() {
  local config_file=""
  local line=""

  config_file="$(shell_config_file)"
  line="$(activation_line)"
  mkdir -p "$(dirname "$config_file")"
  touch "$config_file"

  # 识别既有 mise 激活配置，避免因安装路径写法不同而重复注入。
  if grep -Eq "^[[:space:]]*([^#].*)?mise activate ${ACTIVE_SHELL}([[:space:]|\")]|$)" "$config_file"; then
    printf '已存在 mise %s 激活配置：%s\n' "$ACTIVE_SHELL" "$config_file"
    return
  fi

  [[ ! -s "$config_file" ]] || printf '\n' >>"$config_file"
  printf '%s\n' "$line" >>"$config_file"
  printf '已写入 mise %s 激活配置：%s\n' "$ACTIVE_SHELL" "$config_file"
}

# 已安装任意全局版本时先交给用户决定，避免静默改动现有工具链。
confirm_global_tool_update() {
  local display_name="$1"
  local current_version="$2"
  local version_spec="$3"
  local answer=""

  [[ "$ASSUME_YES" == true ]] && return 0

  while true; do
    printf 'mise 全局 %s 当前版本为 %s，是否按 %s 覆盖/更新？[Y/n]\n> ' \
      "$display_name" "$current_version" "$version_spec" >&3
    IFS= read -r answer <&3 || fail "未能读取用户输入。"
    case "$answer" in
      "" | y | Y | yes | YES)
        return 0
        ;;
      n | N | no | NO)
        return 1
        ;;
      *)
        printf '请输入 Y 或 n，直接回车默认覆盖/更新。\n' >&3
        ;;
    esac
  done
}

ensure_global_tool() {
  local tool="$1"
  local version_spec="$2"
  local display_name="$3"
  local current_version=""

  # 中性目录结合全局来源和已安装状态筛选，避免项目配置或仅声明未安装的版本造成误判。
  current_version="$({
    cd "$ISOLATED_WORK_DIRECTORY"
    "$MISE_BIN" ls --global --installed --no-header "$tool"
  } 2>/dev/null || true)"
  current_version="$(printf '%s\n' "$current_version" | awk -v expected_tool="$tool" '$1 == expected_tool { print $2; exit }')"

  if [[ -n "$current_version" ]]; then
    if ! confirm_global_tool_update "$display_name" "$current_version" "$version_spec"; then
      printf '保留 mise 全局 %s 当前版本：%s。\n' "$display_name" "$current_version"
      return
    fi

    printf '正在按 %s 覆盖/更新 mise 全局 %s（当前版本：%s）...\n' \
      "$version_spec" "$display_name" "$current_version"
  else
    printf 'mise 全局未安装 %s，正在安装 %s...\n' "$display_name" "$version_spec"
  fi

  (
    cd "$ISOLATED_WORK_DIRECTORY"
    "$MISE_BIN" use --global "$tool@$version_spec"
  )
}

# 安装或保留版本后都实际启动工具，确保 mise 全局配置不是仅声明但不可运行。
verify_global_tool() {
  local tool="$1"
  local display_name="$2"
  local command_output=""
  local runtime_version=""

  if ! command_output="$({
    cd "$ISOLATED_WORK_DIRECTORY"
    "$MISE_BIN" exec -- "$tool" --version
  } 2>&1)"; then
    fail "${display_name} 可运行性检查失败：${command_output}"
  fi

  runtime_version="$(printf '%s\n' "$command_output" | awk '/^v?[0-9]+\.[0-9]+(\.[0-9]+)?/ { print; exit }')"
  [[ -n "$runtime_version" ]] || fail "${display_name} 已执行但未返回可识别的版本：${command_output}"

  case "$tool" in
    node) NODE_VERSION="$runtime_version" ;;
    pnpm) PNPM_VERSION="$runtime_version" ;;
    *) fail "没有为 ${tool} 配置版本记录位置。" ;;
  esac

  printf 'mise 全局 %s 可运行：%s\n' "$display_name" "$runtime_version"
}

# 创建本次环境配置专用的中性目录，隔离调用位置中的 mise.toml 和 npm 配置。
prepare_isolated_work_directory() {
  local temp_root="${TMPDIR:-/tmp}"

  ISOLATED_WORK_DIRECTORY="$(mktemp -d "${temp_root%/}/setup-base-environment.XXXXXX")" ||
    fail "无法创建基础环境配置临时目录。"
}

ensure_global_tools() {
  prepare_isolated_work_directory

  printf '\n正在检查 mise 全局工具...\n'
  ensure_global_tool "node" "lts" "Node.js"
  verify_global_tool "node" "Node.js"
  ensure_global_tool "pnpm" "latest" "pnpm"
  verify_global_tool "pnpm" "pnpm"

  rm -rf -- "$ISOLATED_WORK_DIRECTORY"
  ISOLATED_WORK_DIRECTORY=""
}

print_summary() {
  printf '\n基础环境安装完成。\n'
  printf '  Shell：%s\n' "$ACTIVE_SHELL"
  printf '  mise：%s\n' "$MISE_BIN"
  printf '  Node.js：%s（目标：lts）\n' "$NODE_VERSION"
  printf '  pnpm：%s（目标：latest）\n' "$PNPM_VERSION"
  printf '\n请重新打开终端，或加载配置文件后再使用 node、pnpm 和 mise。\n'
}

main() {
  parse_arguments "$@"
  open_interactive_terminal
  print_interactive_overview
  detect_shell
  detect_conflicting_tools
  print_conflict_guidance
  find_mise
  if [[ -z "$MISE_BIN" ]]; then
    install_mise
    configure_shell_activation
  fi
  printf '使用 mise：%s\n' "$MISE_BIN"
  ensure_global_tools
  print_summary
}

main "$@"
