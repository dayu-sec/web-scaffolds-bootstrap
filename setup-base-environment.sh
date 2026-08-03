#!/usr/bin/env bash

set -Eeuo pipefail

readonly GITHUB_REPOSITORY="dayu-sec/web-scaffolds-bootstrap"
readonly GITHUB_BRANCH="main"
readonly TEMPLATE_RELATIVE_PATH="templates/base-development-environment.toml"
readonly TEMPLATE_DOWNLOAD_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${GITHUB_BRANCH}/${TEMPLATE_RELATIVE_PATH}"
readonly MANAGED_CONFIG_FILENAME="base-development-environment.toml"

ASSUME_YES=false
VERBOSE=false
REQUESTED_SHELL=""
ACTIVE_SHELL=""
ACTIVE_SHELL_PATH=""
MISE_BIN=""
INSTALLER_TEMP_FILE=""
MISE_INSTALL_LOG_FILE=""
ISOLATED_WORK_DIRECTORY=""
TEMPLATE_SOURCE_FILE=""
MANAGED_CONFIG_TEMP_FILE=""
MANAGED_MISE_CONFIG_FILE=""
GLOBAL_TOOLS_INSTALL_LOG_FILE=""
INTERACTIVE_TERMINAL_OPEN=false
CONFLICT_TOOLS=""

print_usage() {
  cat <<'EOF'
用法：
  setup-base-environment.sh [选项]

安装 mise、配置 Shell，并同步和安装全局基础开发环境。

选项：
  --shell <bash|zsh|fish>  指定要配置的 Shell；默认从 SHELL 环境变量侦测
  -y, --yes               非交互执行，自动确认 mise 安装和环境冲突提示
  -v, --verbose           展示 mise 和安装后端的完整输出
  -h, --help              显示帮助
EOF
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
  [[ -z "$MISE_INSTALL_LOG_FILE" || ! -e "$MISE_INSTALL_LOG_FILE" ]] || rm -f "$MISE_INSTALL_LOG_FILE"
  [[ -z "$MANAGED_CONFIG_TEMP_FILE" || ! -e "$MANAGED_CONFIG_TEMP_FILE" ]] || rm -f "$MANAGED_CONFIG_TEMP_FILE"
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
      -v | --verbose)
        VERBOSE=true
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

print_header() {
  printf '\n基础开发环境\n'
}

print_step() {
  local number="$1"
  local description="$2"

  printf '\n[%s/4] %s\n' "$number" "$description"
}

print_step_result() {
  printf '      %s\n' "$*"
}

print_log_tail() {
  local log_file="$1"

  [[ -s "$log_file" ]] || return 0
  printf '\n最近的安装日志：\n'
  tail -n 40 "$log_file" | sed 's/^/  /'
}

# 安装前只接受明确的继续或取消，直接回车表示继续。
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

  printf '\n警告：检测到 %s，可能与 mise 同时修改 PATH。\n' "$CONFLICT_TOOLS"
  if [[ "$ASSUME_YES" == true ]]; then
    printf '继续配置 mise。\n'
    return 0
  fi

  confirm_continue "是否继续配置 mise？"
}

find_mise() {
  if [[ -x "$HOME/.local/bin/mise" ]]; then
    MISE_BIN="$HOME/.local/bin/mise"
  else
    MISE_BIN="$(command -v mise || true)"
  fi
}

# npm backend 安装与 reshim 可能从子进程再次调用 mise，因此不能只依赖绝对路径执行入口。
ensure_mise_on_path() {
  local mise_bin_directory=""

  mise_bin_directory="$(dirname "$MISE_BIN")"
  case ":$PATH:" in
    *":${mise_bin_directory}:"*) ;;
    *) PATH="${mise_bin_directory}:${PATH}" ;;
  esac
  export PATH
}

install_mise() {
  local temp_root="${TMPDIR:-/tmp}"

  command -v curl >/dev/null 2>&1 || fail "安装 mise 需要 curl，请先安装 curl 后重试。"
  confirm_continue "未检测到 mise，即将从 https://mise.run 安装到 $HOME/.local/bin/mise。"

  INSTALLER_TEMP_FILE="$(mktemp "${temp_root%/}/mise-installer.XXXXXX")" || fail "无法创建 mise 安装器临时文件。"
  MISE_INSTALL_LOG_FILE="${INSTALLER_TEMP_FILE}.log"
  curl -fsSL https://mise.run -o "$INSTALLER_TEMP_FILE" ||
    fail "无法下载 mise 安装器。"

  if [[ "$VERBOSE" == true ]]; then
    if ! MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh "$INSTALLER_TEMP_FILE"; then
      print_step_result "安装失败"
      fail "mise 安装失败。"
    fi
  elif ! MISE_INSTALL_PATH="$HOME/.local/bin/mise" MISE_QUIET=1 sh "$INSTALLER_TEMP_FILE" >"$MISE_INSTALL_LOG_FILE" 2>&1; then
    print_step_result "安装失败"
    print_log_tail "$MISE_INSTALL_LOG_FILE"
    fail "mise 安装失败。使用 --verbose 重试可查看完整过程。"
  fi

  find_mise
  [[ -n "$MISE_BIN" && -x "$MISE_BIN" ]] || fail "mise 安装完成后仍未找到可执行文件。"
}

shell_config_file() {
  case "$ACTIVE_SHELL" in
    bash) printf '%s\n' "$HOME/.bash_profile" ;;
    zsh) printf '%s\n' "$HOME/.zprofile" ;;
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
  esac
}

activation_line() {
  # mise 官方要求 profile 中的裸命令已在 PATH；使用本次发现的绝对路径避免登录时的 PATH 顺序问题。
  # 格式字符串保留字面量 $()，由用户启动目标 Shell 时执行。
  # shellcheck disable=SC2016
  case "$ACTIVE_SHELL" in
    bash | zsh) printf 'eval "$(%s activate %s --shims)"\n' "$MISE_BIN" "$ACTIVE_SHELL" ;;
    fish) printf '%s activate fish | source\n' "$MISE_BIN" ;;
  esac
}

shell_activation_is_configured() {
  local config_file="$1"

  grep -Eq "^[[:space:]]*[^#[:space:]].*mise[[:space:]]+activate[[:space:]]+${ACTIVE_SHELL}([[:space:]]|\\)|$)" "$config_file"
}

configure_shell_activation() {
  local config_file=""
  local line=""

  config_file="$(shell_config_file)"
  line="$(activation_line)"
  mkdir -p "$(dirname "$config_file")"
  touch "$config_file"

  if shell_activation_is_configured "$config_file"; then
    print_step_result "${ACTIVE_SHELL} 激活配置已存在：${config_file}"
    return
  fi

  [[ ! -s "$config_file" ]] || printf '\n' >>"$config_file"
  printf '%s\n' "$line" >>"$config_file"
  print_step_result "已添加 ${ACTIVE_SHELL} 激活配置：${config_file}"
}

# 创建本次环境配置专用的中性目录，隔离调用位置中的 mise.toml 和 npm 配置。
prepare_isolated_work_directory() {
  local temp_root="${TMPDIR:-/tmp}"

  ISOLATED_WORK_DIRECTORY="$(mktemp -d "${temp_root%/}/setup-base-environment.XXXXXX")" ||
    fail "无法创建基础环境配置临时目录。"
}

resolve_managed_mise_config_file() {
  local mise_config_directory=""

  [[ -n "${HOME:-}" && "$HOME" != "/" ]] || fail "HOME 未设置或指向文件系统根目录。"

  if [[ -n "${MISE_CONFIG_DIR:-}" ]]; then
    mise_config_directory="${MISE_CONFIG_DIR%/}"
  else
    mise_config_directory="${XDG_CONFIG_HOME:-$HOME/.config}/mise"
  fi

  [[ -n "$mise_config_directory" && "$mise_config_directory" != "/" ]] ||
    fail "mise 全局配置目录不能指向文件系统根目录。"
  MANAGED_MISE_CONFIG_FILE="${mise_config_directory}/conf.d/${MANAGED_CONFIG_FILENAME}"
}

# 本地仓库执行读取同版本模板；curl | bash 没有相邻文件，因此回退到 main 分支 Raw URL。
acquire_base_environment_template() {
  local script_file="${BASH_SOURCE[0]:-}"
  local script_directory=""
  local local_template_file=""

  TEMPLATE_SOURCE_FILE="${ISOLATED_WORK_DIRECTORY}/base-development-environment.toml"

  if [[ -n "$script_file" && -f "$script_file" ]]; then
    script_directory="$(cd "$(dirname "$script_file")" && pwd -P)"
    local_template_file="${script_directory}/${TEMPLATE_RELATIVE_PATH}"
  fi

  if [[ -n "$local_template_file" && -f "$local_template_file" ]]; then
    cp "$local_template_file" "$TEMPLATE_SOURCE_FILE"
  else
    command -v curl >/dev/null 2>&1 || fail "下载基础开发环境模板需要 curl，请先安装 curl 后重试。"
    curl -fsSL "$TEMPLATE_DOWNLOAD_URL" -o "$TEMPLATE_SOURCE_FILE" ||
      fail "无法下载基础开发环境模板：${TEMPLATE_DOWNLOAD_URL}。"
  fi

}

sync_managed_mise_config() {
  local managed_config_directory=""

  managed_config_directory="$(dirname "$MANAGED_MISE_CONFIG_FILE")"
  [[ ! -e "$MANAGED_MISE_CONFIG_FILE" || -f "$MANAGED_MISE_CONFIG_FILE" ]] ||
    fail "mise 全局基础开发环境配置目标已存在但不是文件：${MANAGED_MISE_CONFIG_FILE}。"
  mkdir -p "$managed_config_directory"
  MANAGED_CONFIG_TEMP_FILE="$(mktemp "${managed_config_directory}/.${MANAGED_CONFIG_FILENAME}.XXXXXX")" ||
    fail "无法在 mise 全局 conf.d 中创建临时配置文件。"
  cp "$TEMPLATE_SOURCE_FILE" "$MANAGED_CONFIG_TEMP_FILE"
  chmod 0644 "$MANAGED_CONFIG_TEMP_FILE"
  mv -f "$MANAGED_CONFIG_TEMP_FILE" "$MANAGED_MISE_CONFIG_FILE"
  MANAGED_CONFIG_TEMP_FILE=""

  print_step_result "已同步：${MANAGED_MISE_CONFIG_FILE}"
}

install_global_tools() {
  GLOBAL_TOOLS_INSTALL_LOG_FILE="${ISOLATED_WORK_DIRECTORY}/mise-install.log"

  if [[ "$VERBOSE" == true ]]; then
    if ! (
      cd "$ISOLATED_WORK_DIRECTORY"
      "$MISE_BIN" install --yes --verbose
    ); then
      print_step_result "安装失败"
      fail "mise 未能完成全局工具安装。"
    fi
  elif ! (
    cd "$ISOLATED_WORK_DIRECTORY"
    "$MISE_BIN" install --yes >"$GLOBAL_TOOLS_INSTALL_LOG_FILE" 2>&1
  ); then
    print_step_result "安装失败"
    print_log_tail "$GLOBAL_TOOLS_INSTALL_LOG_FILE"
    fail "mise 未能完成全局工具安装。配置已同步，可以直接重试；使用 --verbose 可查看完整过程。"
  fi

  print_step_result "安装完成"
}

print_summary() {
  printf '\n基础开发环境已配置。\n'
  printf '请执行 '
  case "$ACTIVE_SHELL" in
    bash) printf 'source ~/.bash_profile' ;;
    zsh) printf 'source ~/.zprofile' ;;
    fish) printf 'source ~/.config/fish/config.fish' ;;
  esac
  printf '，或重新打开终端。\n'
}

main() {
  parse_arguments "$@"
  open_interactive_terminal
  print_header
  detect_shell
  detect_conflicting_tools
  print_conflict_guidance

  print_step "1" "检查 mise"
  find_mise
  if [[ -z "$MISE_BIN" ]]; then
    install_mise
    print_step_result "已安装：${MISE_BIN}"
  else
    print_step_result "使用现有 mise：${MISE_BIN}"
  fi

  print_step "2" "配置 Shell"
  configure_shell_activation
  ensure_mise_on_path

  print_step "3" "同步全局配置"
  resolve_managed_mise_config_file
  prepare_isolated_work_directory
  acquire_base_environment_template
  sync_managed_mise_config

  print_step "4" "安装全局配置声明的工具"
  install_global_tools
  print_summary
}

main "$@"
