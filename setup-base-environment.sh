#!/usr/bin/env bash

set -Eeuo pipefail

readonly GITHUB_REPOSITORY="dayu-sec/web-scaffolds-bootstrap"
readonly GITHUB_BRANCH="main"
readonly TEMPLATE_RELATIVE_PATH="templates/base-development-environment.toml"
readonly TEMPLATE_DOWNLOAD_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${GITHUB_BRANCH}/${TEMPLATE_RELATIVE_PATH}"
readonly MANAGED_CONFIG_FILENAME="base-development-environment.toml"
readonly SCRIPT_FILE="${0:-}"

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
PROFILE_CONFIG_FILE=""
INTERACTIVE_CONFIG_FILE=""

print_usage() {
  cat <<'EOF'
用法：
  setup-base-environment.sh [选项]

安装 mise、配置 Shell，并同步和安装全局基础开发环境。

选项：
  --shell <bash|zsh|fish>  指定要配置的 Shell；默认从 SHELL 环境变量侦测
  -y, --yes               非交互执行，自动确认 mise 安装
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
  if ! exec 3<>/dev/tty; then
    fail "当前环境无法交互，请在终端中运行，或使用 --yes 非交互执行。"
  fi
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

bash_profile_file() {
  if [[ -f "$HOME/.bash_profile" ]]; then
    printf '%s\n' "$HOME/.bash_profile"
  elif [[ -f "$HOME/.bash_login" ]]; then
    printf '%s\n' "$HOME/.bash_login"
  elif [[ -f "$HOME/.profile" ]]; then
    printf '%s\n' "$HOME/.profile"
  else
    printf '%s\n' "$HOME/.bash_profile"
  fi
}

resolve_shell_config_files() {
  case "$ACTIVE_SHELL" in
    bash)
      PROFILE_CONFIG_FILE="$(bash_profile_file)"
      INTERACTIVE_CONFIG_FILE="$HOME/.bashrc"
      ;;
    zsh)
      PROFILE_CONFIG_FILE="$HOME/.zprofile"
      INTERACTIVE_CONFIG_FILE="$HOME/.zshrc"
      ;;
    fish)
      PROFILE_CONFIG_FILE="$HOME/.config/fish/config.fish"
      INTERACTIVE_CONFIG_FILE="$PROFILE_CONFIG_FILE"
      ;;
  esac
}

config_has_shims() {
  local config_file="$1"

  [[ -f "$config_file" ]] || return 1
  grep -Eq "^[[:space:]]*[^#[:space:]].*(mise[[:space:]]+activate[[:space:]]+${ACTIVE_SHELL}[^#]*--shims|mise/shims)" "$config_file"
}

config_has_interactive_activation() {
  local config_file="$1"

  [[ -f "$config_file" ]] || return 1
  grep -E "^[[:space:]]*[^#[:space:]].*mise[[:space:]]+activate[[:space:]]+${ACTIVE_SHELL}([[:space:]]|\\)|\\||$)" "$config_file" |
    grep -Eqv -- '--shims'
}

append_config_line() {
  local config_file="$1"
  local line="$2"

  mkdir -p "$(dirname "$config_file")"
  touch "$config_file"
  [[ ! -s "$config_file" ]] || printf '\n' >>"$config_file"
  printf '%s\n' "$line" >>"$config_file"
}

profile_activation_line() {
  # 使用本次发现的绝对路径，避免 profile 加载时 mise 尚未进入 PATH。
  # shellcheck disable=SC2016
  printf 'eval "$(%s activate %s --shims)"\n' "$MISE_BIN" "$ACTIVE_SHELL"
}

interactive_activation_line() {
  # shellcheck disable=SC2016
  printf 'eval "$(%s activate %s)"\n' "$MISE_BIN" "$ACTIVE_SHELL"
}

configure_bash_or_zsh_activation() {
  local existing_interactive_config=""

  if config_has_shims "$PROFILE_CONFIG_FILE"; then
    print_step_result "${ACTIVE_SHELL} 非交互配置已存在：${PROFILE_CONFIG_FILE}"
  else
    append_config_line "$PROFILE_CONFIG_FILE" "$(profile_activation_line)"
    print_step_result "已添加 ${ACTIVE_SHELL} 非交互配置：${PROFILE_CONFIG_FILE}"
  fi

  if config_has_interactive_activation "$INTERACTIVE_CONFIG_FILE"; then
    existing_interactive_config="$INTERACTIVE_CONFIG_FILE"
  elif config_has_interactive_activation "$PROFILE_CONFIG_FILE"; then
    existing_interactive_config="$PROFILE_CONFIG_FILE"
  fi

  if [[ -n "$existing_interactive_config" ]]; then
    print_step_result "${ACTIVE_SHELL} 交互配置已存在：${existing_interactive_config}"
  else
    append_config_line "$INTERACTIVE_CONFIG_FILE" "$(interactive_activation_line)"
    print_step_result "已添加 ${ACTIVE_SHELL} 交互配置：${INTERACTIVE_CONFIG_FILE}"
  fi
}

configure_fish_activation() {
  local has_interactive=false
  local has_shims=false

  config_has_interactive_activation "$PROFILE_CONFIG_FILE" && has_interactive=true
  config_has_shims "$PROFILE_CONFIG_FILE" && has_shims=true

  if [[ "$has_interactive" == true && "$has_shims" == true ]]; then
    print_step_result "fish 交互与非交互配置已存在：${PROFILE_CONFIG_FILE}"
    return
  fi

  mkdir -p "$(dirname "$PROFILE_CONFIG_FILE")"
  touch "$PROFILE_CONFIG_FILE"
  [[ ! -s "$PROFILE_CONFIG_FILE" ]] || printf '\n' >>"$PROFILE_CONFIG_FILE"

  if [[ "$has_interactive" == false && "$has_shims" == false ]]; then
    printf 'if status is-interactive\n  %s activate fish | source\nelse\n  %s activate fish --shims | source\nend\n' \
      "$MISE_BIN" "$MISE_BIN" >>"$PROFILE_CONFIG_FILE"
    print_step_result "已添加 fish 交互与非交互配置：${PROFILE_CONFIG_FILE}"
  elif [[ "$has_interactive" == false ]]; then
    printf 'if status is-interactive\n  %s activate fish | source\nend\n' "$MISE_BIN" >>"$PROFILE_CONFIG_FILE"
    print_step_result "已添加 fish 交互配置：${PROFILE_CONFIG_FILE}"
  else
    printf 'if not status is-interactive\n  %s activate fish --shims | source\nend\n' "$MISE_BIN" >>"$PROFILE_CONFIG_FILE"
    print_step_result "已添加 fish 非交互配置：${PROFILE_CONFIG_FILE}"
  fi
}

configure_shell_activation() {
  resolve_shell_config_files

  case "$ACTIVE_SHELL" in
    bash | zsh) configure_bash_or_zsh_activation ;;
    fish) configure_fish_activation ;;
  esac
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
  local script_directory=""
  local local_template_file=""

  TEMPLATE_SOURCE_FILE="${ISOLATED_WORK_DIRECTORY}/base-development-environment.toml"

  if [[ -n "$SCRIPT_FILE" && -f "$SCRIPT_FILE" ]]; then
    script_directory="$(cd "$(dirname "$SCRIPT_FILE")" && pwd -P)"
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
  printf '请重新打开终端，使交互与非交互 Shell 配置生效。\n'
}

main() {
  parse_arguments "$@"
  open_interactive_terminal
  print_header
  detect_shell

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
