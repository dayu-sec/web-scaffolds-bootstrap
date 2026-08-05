#!/usr/bin/env bash

set -Eeuo pipefail

# Web Skills 目前通过公开 GitHub 仓库的 main 分支分发，无需 Token。
readonly GITHUB_REPOSITORY="dayu-sec/web-skills"
readonly GITHUB_BRANCH="main"
readonly GITHUB_ARCHIVE_URL="https://github.com/${GITHUB_REPOSITORY}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"
readonly OBSOLETE_SKILL_PREFIX="dy-sec-"

FORCE_INSTALL=false
TARGET_SELECTION_REQUIRED=false
TARGET_ARGUMENT=""
INTERACTIVE_TERMINAL_OPEN=false
INVOCATION_DIRECTORY="${PWD:-}"
WORK_DIRECTORY=""
ARCHIVE_FILE=""
ARCHIVE_MANIFEST_FILE=""
EXTRACTED_DIRECTORY=""
ARCHIVE_ROOT_DIRECTORY=""
AGENT_CONFIG_DIRECTORY=""
SKILLS_DIRECTORY=""
OBSOLETE_SKILLS_TO_REMOVE=""
ARCHIVE_SIZE_BYTES=0
RESOURCE_FILE_COUNT=0
SKILL_COUNT=0

# 安装概览由 help、交互确认和 README 共同遵循，避免目标语义与实际发布范围漂移。
print_installation_overview() {
  cat <<'EOF'
安装内容：
  1. 下载 GitHub 上 dayu-sec/web-skills 的 main 分支源码归档
  2. 校验归档并只选择其中的 skills/ 资源
  3. 将完整 Skill 目录增量覆盖到指定 Agent 配置根目录下的 skills/
  4. 发现目标 skills/ 下的 dy-sec-* 旧 Skill 时，列出并在新 Skills 安装成功后清除

安装器不会读取、创建、复制、追加、覆盖或删除任何 AGENTS.md。
EOF
}

print_usage() {
  cat <<'EOF'
用法：
  setup-web-skills.sh [选项]

无参数时：
  通过交互菜单选择用户级 $HOME/.agents、项目级 ./.agents，
  或自定义 Agent 配置根目录；Skill 最终安装到所选目录下的 skills/。

EOF
  print_installation_overview
  cat <<'EOF'

选项：
  --target <目录>  Agent 配置根目录；默认是 $HOME/.agents
                   支持绝对路径、~/ 开头的路径或相对当前目录的路径
  -f, --force      跳过安装与旧 Skill 清理确认，直接执行
  -h, --help       显示帮助

示例：
  setup-web-skills.sh --target "$HOME/.agents"
  setup-web-skills.sh --target ./.kiro --force

说明：
  脚本安装 GitHub 公开仓库 main 分支的当前 Skills，不需要 GitHub Token。
  Source code 归档、解压目录和校验文件仅保存在临时目录，退出时自动清理。
  增量覆盖不会删除额外 Skill、plugins/ 或其他 Agent 配置。
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
  if (($# == 0)); then
    TARGET_SELECTION_REQUIRED=true
  fi

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

validate_runtime_dependencies() {
  [[ -n "$GITHUB_REPOSITORY" ]] || fail "请先配置 GITHUB_REPOSITORY。"
  [[ -n "$GITHUB_BRANCH" ]] || fail "请先配置 GITHUB_BRANCH。"
  [[ -n "$GITHUB_ARCHIVE_URL" ]] || fail "请先配置 GITHUB_ARCHIVE_URL。"
  [[ -n "${HOME:-}" && "$HOME" != "/" ]] || fail "HOME 未设置或指向根目录，拒绝安装。"
  [[ -n "$INVOCATION_DIRECTORY" && "$INVOCATION_DIRECTORY" == /* ]] ||
    fail "无法确定脚本启动时的当前目录。"

  local command_name
  for command_name in curl tar mktemp find cp awk rm; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少必需命令：${command_name}。"
  done
}

# 无参数模式和非 force 的最终确认都固定从控制终端读取，不占用管道标准输入。
open_interactive_terminal() {
  if [[ "$TARGET_SELECTION_REQUIRED" != true && "$FORCE_INSTALL" == true ]]; then
    return
  fi
  [[ -r /dev/tty && -w /dev/tty ]] ||
    fail "当前环境无法交互，请使用 --target <Agent 配置根目录> --force 执行。"
  exec 3<>/dev/tty
  INTERACTIVE_TERMINAL_OPEN=true
}

collect_interactive_target() {
  local selection=""
  local custom_target=""

  if [[ "$TARGET_SELECTION_REQUIRED" != true ]]; then
    return 0
  fi

  while true; do
    printf '\n请选择 Web Skills 安装位置：\n' >&3
    printf '  1. 用户级：%s/.agents（默认）\n' "${HOME%/}" >&3
    printf '  2. 项目级：%s/.agents\n' "${INVOCATION_DIRECTORY%/}" >&3
    printf '  3. 自定义 Agent 配置根目录\n' >&3
    printf '请选择 [1]：' >&3
    IFS= read -r selection <&3 || fail "未能读取安装位置。"

    case "$selection" in
      "" | 1)
        TARGET_ARGUMENT="${HOME%/}/.agents"
        return
        ;;
      2)
        TARGET_ARGUMENT=".agents"
        return
        ;;
      3)
        while true; do
          printf '请输入 Agent 配置根目录：' >&3
          IFS= read -r custom_target <&3 || fail "未能读取自定义目录。"
          if [[ -n "$custom_target" ]]; then
            TARGET_ARGUMENT="$custom_target"
            return
          fi
          printf '自定义目录不能为空。\n' >&3
        done
        ;;
      *)
        printf '请输入 1、2、3，或直接按回车选择用户级。\n' >&3
        ;;
    esac
  done
}

# --target 表示 Agent 配置根目录；所有 Skill 都安装到该目录下的 skills/。
resolve_installation_directories() {
  local normalized_home="${HOME%/}"

  case "$TARGET_ARGUMENT" in
    "")
      AGENT_CONFIG_DIRECTORY="${normalized_home}/.agents"
      ;;
    "~")
      AGENT_CONFIG_DIRECTORY="$normalized_home"
      ;;
    \~/*)
      AGENT_CONFIG_DIRECTORY="${normalized_home}/${TARGET_ARGUMENT#\~/}"
      ;;
    /*)
      AGENT_CONFIG_DIRECTORY="$TARGET_ARGUMENT"
      ;;
    \~*)
      fail "--target 不支持 ~user 形式，请使用绝对路径。"
      ;;
    *)
      AGENT_CONFIG_DIRECTORY="${INVOCATION_DIRECTORY%/}/${TARGET_ARGUMENT}"
      ;;
  esac

  [[ -n "$AGENT_CONFIG_DIRECTORY" && "$AGENT_CONFIG_DIRECTORY" != "/" ]] ||
    fail "Agent 配置根目录不能指向文件系统根目录。"
  [[ "$AGENT_CONFIG_DIRECTORY" != "$normalized_home" ]] ||
    fail "Agent 配置根目录不能直接指向 HOME，请使用 HOME 下的 Agent 子目录。"

  SKILLS_DIRECTORY="${AGENT_CONFIG_DIRECTORY}/skills"
}

validate_installation_target() {
  local obsolete_skill_name=""
  local obsolete_skill_directory=""

  if [[ -e "$AGENT_CONFIG_DIRECTORY" && ! -d "$AGENT_CONFIG_DIRECTORY" ]]; then
    fail "Agent 配置根目录已存在但不是目录：${AGENT_CONFIG_DIRECTORY}。"
  fi
  if [[ -e "$SKILLS_DIRECTORY" && ! -d "$SKILLS_DIRECTORY" ]]; then
    fail "Skills 目标已存在但不是目录：${SKILLS_DIRECTORY}。"
  fi
  if [[ -d "$SKILLS_DIRECTORY" ]]; then
    while IFS= read -r -d '' obsolete_skill_directory; do
      [[ -d "$obsolete_skill_directory" || -L "$obsolete_skill_directory" ]] || continue
      obsolete_skill_name="${obsolete_skill_directory##*/}"
      if [[ -n "$OBSOLETE_SKILLS_TO_REMOVE" ]]; then
        OBSOLETE_SKILLS_TO_REMOVE="${OBSOLETE_SKILLS_TO_REMOVE}
${obsolete_skill_name}"
      else
        OBSOLETE_SKILLS_TO_REMOVE="$obsolete_skill_name"
      fi
    done < <(find "$SKILLS_DIRECTORY" -mindepth 1 -maxdepth 1 \
      -name "${OBSOLETE_SKILL_PREFIX}*" -print0)
  fi
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

# 安装前完成归档路径、文件类型和 skills/ 契约校验，不让其他根级资源进入目标目录。
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

  [[ -d "${EXTRACTED_DIRECTORY}/skills" ]] ||
    fail "Source code 根目录缺少 skills/。"
  [[ -z "$(find "${EXTRACTED_DIRECTORY}/skills" -type l -print -quit)" ]] ||
    fail "Source code 归档包含不允许安装的符号链接。"

  local source_skill=""
  local resource_directory=""
  local resource_file_count=0
  SKILL_COUNT=0
  RESOURCE_FILE_COUNT=0
  while IFS= read -r -d '' source_skill; do
    [[ -d "$source_skill" ]] ||
      fail "skills/ 只能包含一级 Skill 目录：${source_skill##*/}。"
    [[ -f "${source_skill}/SKILL.md" ]] ||
      fail "Skill 目录缺少 SKILL.md：${source_skill##*/}。"
    SKILL_COUNT=$((SKILL_COUNT + 1))
    RESOURCE_FILE_COUNT=$((RESOURCE_FILE_COUNT + 1))

    for resource_directory in agents references scripts assets; do
      [[ -d "${source_skill}/${resource_directory}" ]] || continue
      resource_file_count="$(find "${source_skill}/${resource_directory}" -type f |
        wc -l | tr -d '[:space:]')"
      RESOURCE_FILE_COUNT=$((RESOURCE_FILE_COUNT + resource_file_count))
    done
  done < <(find "${EXTRACTED_DIRECTORY}/skills" -mindepth 1 -maxdepth 1 -print0)

  ((SKILL_COUNT > 0)) || fail "Source code 中没有可安装的 Skill。"
}

print_installation_preview() {
  local output_fd=1
  local obsolete_skill_name=""

  [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]] && output_fd=3
  printf '\n即将安装 Web Skills：\n' >&"$output_fd"
  printf '  GitHub 来源：%s@%s\n' "$GITHUB_REPOSITORY" "$GITHUB_BRANCH" >&"$output_fd"
  printf '  Source code：tar.gz，%s 字节\n' "$ARCHIVE_SIZE_BYTES" >&"$output_fd"
  printf '  Skill 数量：%s\n' "$SKILL_COUNT" >&"$output_fd"
  printf '  资源文件：%s\n' "$RESOURCE_FILE_COUNT" >&"$output_fd"
  printf '  Agent 配置根：%s\n' "$AGENT_CONFIG_DIRECTORY" >&"$output_fd"
  printf '  Skills 目录：%s\n' "$SKILLS_DIRECTORY" >&"$output_fd"
  printf '  更新方式：增量覆盖；保留额外 Skill、plugins/ 和其他 Agent 配置\n' >&"$output_fd"
  if [[ -n "$OBSOLETE_SKILLS_TO_REMOVE" ]]; then
    printf '  清除旧 Skill：\n' >&"$output_fd"
    while IFS= read -r obsolete_skill_name; do
      [[ -n "$obsolete_skill_name" ]] || continue
      printf '    - %s/%s\n' "$SKILLS_DIRECTORY" "$obsolete_skill_name" >&"$output_fd"
    done <<EOF
$OBSOLETE_SKILLS_TO_REMOVE
EOF
  fi
}

confirm_installation() {
  local answer=""

  [[ "$FORCE_INSTALL" == true ]] && return
  while true; do
    if [[ -n "$OBSOLETE_SKILLS_TO_REMOVE" ]]; then
      printf '\n按回车安装并清除以上旧 Skill，输入 n 取消：' >&3
    else
      printf '\n按回车继续，输入 n 取消：' >&3
    fi
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

# 先发布并验证归档中的全部 Skills，最后才定向移除旧 Skill。
install_skills() {
  local source_skill=""
  local target_skill=""
  local resource_directory=""
  local obsolete_skill_name=""
  local obsolete_skill_directory=""

  mkdir -p "$SKILLS_DIRECTORY"
  [[ -w "$SKILLS_DIRECTORY" ]] || fail "Skills 目录不可写：${SKILLS_DIRECTORY}。"

  while IFS= read -r -d '' source_skill; do
    target_skill="${SKILLS_DIRECTORY}/${source_skill##*/}"
    mkdir -p "$target_skill"
    cp "${source_skill}/SKILL.md" "${target_skill}/SKILL.md"

    for resource_directory in agents references scripts assets; do
      [[ -d "${source_skill}/${resource_directory}" ]] || continue
      cp -R "${source_skill}/${resource_directory}" "${target_skill}/"
    done
  done < <(find "${EXTRACTED_DIRECTORY}/skills" -mindepth 1 -maxdepth 1 -type d -print0)

  while IFS= read -r -d '' source_skill; do
    target_skill="${SKILLS_DIRECTORY}/${source_skill##*/}"
    [[ -f "${target_skill}/SKILL.md" ]] ||
      fail "安装后缺少 ${source_skill##*/}。"
  done < <(find "${EXTRACTED_DIRECTORY}/skills" -mindepth 1 -maxdepth 1 -type d -print0)

  if [[ -n "$OBSOLETE_SKILLS_TO_REMOVE" ]]; then
    while IFS= read -r obsolete_skill_name; do
      [[ -n "$obsolete_skill_name" ]] || continue
      obsolete_skill_directory="${SKILLS_DIRECTORY}/${obsolete_skill_name}"
      rm -rf -- "$obsolete_skill_directory"
      [[ ! -e "$obsolete_skill_directory" && ! -L "$obsolete_skill_directory" ]] ||
        fail "无法清除旧 Skill：${obsolete_skill_directory}。"
    done <<EOF
$OBSOLETE_SKILLS_TO_REMOVE
EOF
  fi
}

print_summary() {
  local obsolete_skill_name=""

  printf '\nWeb Skills 安装完成。\n'
  printf '  GitHub 来源：%s@%s\n' "$GITHUB_REPOSITORY" "$GITHUB_BRANCH"
  printf '  Agent 配置根：%s\n' "$AGENT_CONFIG_DIRECTORY"
  printf '  Skills 目录：%s\n' "$SKILLS_DIRECTORY"
  printf '  Skill 数量：%s\n' "$SKILL_COUNT"
  if [[ -n "$OBSOLETE_SKILLS_TO_REMOVE" ]]; then
    while IFS= read -r obsolete_skill_name; do
      [[ -n "$obsolete_skill_name" ]] || continue
      printf '  已清除旧 Skill：%s\n' "$obsolete_skill_name"
    done <<EOF
$OBSOLETE_SKILLS_TO_REMOVE
EOF
  fi
  printf '\n重新启动对应 Agent 会话后即可加载最新 Skills。\n'
}

main() {
  parse_arguments "$@"
  validate_runtime_dependencies
  open_interactive_terminal
  collect_interactive_target
  resolve_installation_directories
  validate_installation_target
  prepare_work_directory
  download_source_archive
  validate_and_extract_archive
  print_installation_preview
  confirm_installation
  install_skills
  print_summary
}

main "$@"
