#!/usr/bin/env bash

set -Eeuo pipefail

# Web Skills 目前通过公开 GitHub 仓库的 main 分支分发，无需 Token。
readonly GITHUB_REPOSITORY="dayu-sec/web-skills"
readonly GITHUB_BRANCH="main"
readonly GITHUB_ARCHIVE_URL="https://github.com/${GITHUB_REPOSITORY}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"

FORCE_INSTALL=false
TARGET_ARGUMENT=""
INTERACTIVE_TERMINAL_OPEN=false
WORK_DIRECTORY=""
ARCHIVE_FILE=""
ARCHIVE_MANIFEST_FILE=""
EXTRACTED_DIRECTORY=""
TARGET_DIRECTORY=""
ARCHIVE_ROOT_DIRECTORY=""
ARCHIVE_SIZE_BYTES=0
RESOURCE_FILE_COUNT=0
SKILL_COUNT=0

# 安装概览由 help、交互确认和 README 共同遵循，避免来源与实际下载行为漂移。
print_installation_overview() {
  cat <<'EOF'
安装内容：
  1. 下载 GitHub 上 dayu-sec/web-skills 的 main 分支源码归档
  2. 将 Source code（tar.gz）保存到临时目录
  3. 校验并解压 AGENTS.md 和 skills/ 资源
  4. 增量覆盖到指定 Agent 根目录，保留 README.md、.git、.gitignore 和额外文件
EOF
}

print_usage() {
  cat <<'EOF'
用法：
  setup-web-skills.sh [选项]

EOF
  print_installation_overview
  cat <<'EOF'

选项：
  --target <目录>  Agent 根目录；默认是 $HOME/.agents
                   支持绝对路径、~/ 开头的路径或相对当前目录的路径
  -f, --force      跳过安装确认，直接执行增量覆盖
  -h, --help       显示帮助

说明：
  脚本安装 GitHub 公开仓库 main 分支的当前内容，不需要 GitHub Token。
  Source code 归档、解压目录和校验文件仅保存在临时目录，退出时自动清理。
  源码归档中的 README.md、.git 和 .gitignore 不会复制到目标目录。
  增量覆盖不会删除目标中上游当前版本没有的文件；重复执行可用于同步 main 的最新内容。
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

# 临时目录由本次 mktemp 独占，成功、失败或中断都不得遗留下载制品和解压内容。
cleanup() {
  local exit_code=$?

  trap - EXIT
  set +e
  if [[ -n "$WORK_DIRECTORY" && -d "$WORK_DIRECTORY" ]]; then
    rm -rf -- "$WORK_DIRECTORY"
  fi
  if [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]]; then
    exec 3>&-
  fi
  exit "$exit_code"
}

trap cleanup EXIT

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --target)
        (($# >= 2)) || fail "--target 需要提供值。"
        [[ -n "$2" ]] || fail "--target 不能是空字符串。"
        TARGET_ARGUMENT="$2"
        shift 2
        ;;
      -f | --force)
        FORCE_INSTALL=true
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

validate_runtime_configuration() {
  [[ -n "$GITHUB_REPOSITORY" ]] || fail "请先配置 GITHUB_REPOSITORY。"
  [[ -n "$GITHUB_BRANCH" ]] || fail "请先配置 GITHUB_BRANCH。"
  [[ -n "$GITHUB_ARCHIVE_URL" ]] || fail "请先配置 GITHUB_ARCHIVE_URL。"
  [[ -n "${HOME:-}" && "$HOME" != "/" ]] || fail "HOME 未设置或指向根目录，拒绝安装。"

  local command_name
  for command_name in curl tar mktemp find cp awk; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少必需命令：${command_name}。"
  done

  resolve_target_directory
  if [[ -e "$TARGET_DIRECTORY" && ! -d "$TARGET_DIRECTORY" ]]; then
    fail "安装目标已存在但不是目录：${TARGET_DIRECTORY}。"
  fi
}

# --target 表示 Agent 根目录；无论目录名称是什么，AGENTS.md 与 skills/ 都直接安装在其下。
resolve_target_directory() {
  local normalized_home="${HOME%/}"

  case "$TARGET_ARGUMENT" in
    "")
      TARGET_DIRECTORY="${normalized_home}/.agents"
      ;;
    "~")
      TARGET_DIRECTORY="$normalized_home"
      ;;
    "~/"*)
      TARGET_DIRECTORY="${normalized_home}/${TARGET_ARGUMENT#\~/}"
      ;;
    /*)
      TARGET_DIRECTORY="$TARGET_ARGUMENT"
      ;;
    "~"*)
      fail "--target 不支持 ~user 形式，请使用绝对路径。"
      ;;
    *)
      TARGET_DIRECTORY="${PWD}/${TARGET_ARGUMENT}"
      ;;
  esac

  TARGET_DIRECTORY="${TARGET_DIRECTORY%/}"
  [[ -n "$TARGET_DIRECTORY" && "$TARGET_DIRECTORY" != "/" ]] ||
    fail "--target 不能指向文件系统根目录。"
  [[ "$TARGET_DIRECTORY" != "$normalized_home" ]] ||
    fail "--target 不能直接指向 HOME，请使用 HOME 下的 Agent 子目录。"
}

# curl 或 wget 通过标准输入传输脚本，因此交互确认必须直接从控制终端读取。
open_interactive_terminal() {
  [[ "$FORCE_INSTALL" == true ]] && return
  [[ -r /dev/tty && -w /dev/tty ]] ||
    fail "当前环境无法交互，请在终端中运行，或使用 --force 直接执行增量覆盖。"
  exec 3<>/dev/tty
  INTERACTIVE_TERMINAL_OPEN=true
}

prepare_work_directory() {
  local temp_root="${TMPDIR:-/tmp}"

  WORK_DIRECTORY="$(mktemp -d "${temp_root%/}/setup-web-skills.XXXXXX")" ||
    fail "无法创建 Web Skills 临时目录。"
  ARCHIVE_FILE="${WORK_DIRECTORY}/web-skills.tar.gz"
  ARCHIVE_MANIFEST_FILE="${WORK_DIRECTORY}/archive-manifest.txt"
  EXTRACTED_DIRECTORY="${WORK_DIRECTORY}/resources"
}

# GitHub 自动生成分支源码归档；下载失败时只输出稳定状态，不打印可能返回的响应体。
download_source_archive() {
  local http_status_code=""

  printf '正在下载 GitHub Source code（tar.gz）：%s@%s...\n' \
    "$GITHUB_REPOSITORY" "$GITHUB_BRANCH"
  if ! http_status_code="$(curl --silent --show-error --location \
    --output "$ARCHIVE_FILE" \
    --write-out '%{http_code}' \
    "$GITHUB_ARCHIVE_URL")"; then
    fail "无法下载 ${GITHUB_REPOSITORY}@${GITHUB_BRANCH} 的 Source code（tar.gz）。"
  fi

  case "$http_status_code" in
    200) ;;
    404) fail "GitHub 上没有找到 ${GITHUB_REPOSITORY}@${GITHUB_BRANCH}。" ;;
    429) fail "GitHub 请求过于频繁，请稍后重试。" ;;
    *) fail "GitHub Source code 下载返回 HTTP ${http_status_code}。" ;;
  esac

  [[ -s "$ARCHIVE_FILE" ]] || fail "下载得到的 Source code 归档为空。"
  ARCHIVE_SIZE_BYTES="$(wc -c <"$ARCHIVE_FILE" | tr -d '[:space:]')"
}

# 安装前完成路径、文件类型和资源契约校验，避免不可信归档写出临时区或污染目标目录。
validate_and_extract_archive() {
  if ! tar -tzf "$ARCHIVE_FILE" >"$ARCHIVE_MANIFEST_FILE"; then
    fail "下载文件不是有效的 tar.gz 归档。"
  fi
  [[ -s "$ARCHIVE_MANIFEST_FILE" ]] || fail "Source code 归档没有任何内容。"

  if awk '
    /^\// || /(^|\/)\.\.(\/|$)/ { unsafe = 1 }
    END { exit unsafe ? 0 : 1 }
  ' "$ARCHIVE_MANIFEST_FILE"; then
    fail "Source code 归档包含越出资源根的路径。"
  fi

  ARCHIVE_ROOT_DIRECTORY="$(awk -F/ '
    NF > 0 && $1 != "" { roots[$1] = 1 }
    END {
      for (root in roots) {
        count++
        selected = root
      }
      if (count == 1) {
        print selected
      }
    }
  ' "$ARCHIVE_MANIFEST_FILE")"
  [[ -n "$ARCHIVE_ROOT_DIRECTORY" ]] ||
    fail "Source code 归档必须只包含一个顶层目录。"

  mkdir -p "$EXTRACTED_DIRECTORY"
  tar -xzf "$ARCHIVE_FILE" --strip-components=1 -C "$EXTRACTED_DIRECTORY"

  [[ -f "${EXTRACTED_DIRECTORY}/AGENTS.md" ]] ||
    fail "Source code 根目录缺少 AGENTS.md。"
  [[ -d "${EXTRACTED_DIRECTORY}/skills" ]] ||
    fail "Source code 根目录缺少 skills/。"
  [[ -z "$(find "$EXTRACTED_DIRECTORY" -type l -print -quit)" ]] ||
    fail "Source code 归档包含不允许安装的符号链接。"

  SKILL_COUNT="$(find "${EXTRACTED_DIRECTORY}/skills" -mindepth 2 -type f -name SKILL.md | wc -l | tr -d '[:space:]')"
  [[ "$SKILL_COUNT" -gt 0 ]] || fail "Source code 中没有可安装的 Skill。"
  # 预览数量只统计实际安装内容，不把明确排除的根级基础文件算入资源文件。
  RESOURCE_FILE_COUNT="$(find "$EXTRACTED_DIRECTORY" -type f \
    ! -path "${EXTRACTED_DIRECTORY}/README.md" \
    ! -path "${EXTRACTED_DIRECTORY}/.gitignore" \
    ! -path "${EXTRACTED_DIRECTORY}/.git/*" |
    wc -l | tr -d '[:space:]')"
}

print_installation_preview() {
  local output_fd=1

  [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]] && output_fd=3
  printf '\n即将安装 Web Skills：\n' >&"$output_fd"
  printf '  GitHub 来源：%s@%s\n' "$GITHUB_REPOSITORY" "$GITHUB_BRANCH" >&"$output_fd"
  printf '  Source code：tar.gz，%s 字节\n' "$ARCHIVE_SIZE_BYTES" >&"$output_fd"
  printf '  Skill 数量：%s\n' "$SKILL_COUNT" >&"$output_fd"
  printf '  资源文件：%s\n' "$RESOURCE_FILE_COUNT" >&"$output_fd"
  printf '  安装目标：%s\n' "$TARGET_DIRECTORY" >&"$output_fd"
  printf '  更新方式：增量覆盖；保留 README.md、.git、.gitignore 和上游当前版本没有的本地文件\n' >&"$output_fd"
}

confirm_installation() {
  local answer=""

  [[ "$FORCE_INSTALL" == true ]] && return
  while true; do
    printf '\n按回车继续，输入 n 取消：' >&3
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

# 只安装 Agent 入口和 Skill；发布说明与 Git 基础文件留在源仓库，不进入目标目录。
install_resources() {
  local source_entry=""
  local entry_name=""

  mkdir -p "$TARGET_DIRECTORY"
  [[ -w "$TARGET_DIRECTORY" ]] || fail "安装目标不可写：${TARGET_DIRECTORY}。"

  while IFS= read -r -d '' source_entry; do
    entry_name="${source_entry##*/}"
    case "$entry_name" in
      .git | .gitignore | README.md) continue ;;
    esac
    cp -R "$source_entry" "${TARGET_DIRECTORY}/"
  done < <(find "$EXTRACTED_DIRECTORY" -mindepth 1 -maxdepth 1 -print0)

  [[ -f "${TARGET_DIRECTORY}/AGENTS.md" ]] || fail "安装后没有找到 AGENTS.md。"
  [[ -d "${TARGET_DIRECTORY}/skills" ]] || fail "安装后没有找到 skills/。"
}

print_summary() {
  printf '\nWeb Skills 安装完成。\n'
  printf '  GitHub 来源：%s@%s\n' "$GITHUB_REPOSITORY" "$GITHUB_BRANCH"
  printf '  安装目标：%s\n' "$TARGET_DIRECTORY"
  printf '  Skill 数量：%s\n' "$SKILL_COUNT"
  printf '\n重新启动对应 Agent 会话后即可加载最新 Skill 和 AGENTS.md。\n'
}

main() {
  parse_arguments "$@"
  validate_runtime_configuration
  open_interactive_terminal
  prepare_work_directory
  download_source_archive
  validate_and_extract_archive
  print_installation_preview
  confirm_installation
  install_resources
  print_summary
}

main "$@"
