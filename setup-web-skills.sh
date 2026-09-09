#!/usr/bin/env bash

# 脚本使用 bash 数组等特性；显式用其他 Shell 执行会绕过 shebang，提前给出明确提示。
if [ -z "${BASH_VERSION:-}" ]; then
  printf '错误：本脚本需要 bash 运行。请执行 bash setup-web-skills.sh，或 curl ... | bash。\n' >&2
  exit 1
fi

set -Eeuo pipefail

# Web Skills 通过公开 GitHub 仓库分发，无需 Token；默认取 main 分支，可用 --branch 指定其他分支。
readonly GITHUB_REPOSITORY="dayu-sec/web-skills"
readonly DEFAULT_GITHUB_BRANCH="main"
# 交互界面的空转轮次上限：每轮为一次 1 秒读超时，约等于一小时无按键后放弃等待。
readonly IDLE_ROUNDS_BEFORE_CANCEL=3600
GITHUB_BRANCH="$DEFAULT_GITHUB_BRANCH"
GITHUB_ARCHIVE_URL=""

# 以下为跨函数共享的可变状态；Bash 没有结构体，只能用全局变量在参数解析、交互选择与安装各阶段之间传递数据。
FORCE_INSTALL=false
VERBOSE=false
TARGET_SELECTION_REQUIRED=false
TARGET_ARGUMENT=""
PROFILE_ARGUMENT=""
INTERACTIVE_TERMINAL_OPEN=false
INVOCATION_DIRECTORY="${PWD:-}"
WORK_DIRECTORY=""
ARCHIVE_FILE=""
ARCHIVE_MANIFEST_FILE=""
EXTRACTED_DIRECTORY=""
ARCHIVE_ROOT_DIRECTORY=""
AGENT_CONFIG_DIRECTORY=""
SKILLS_DIRECTORY=""
ARCHIVE_SKILLS=""
PROFILES_DIRECTORY=""
SELECTED_PROFILES=""
SELECTED_SKILLS=""
TERMINAL_STATE_SAVED=""
PENDING_SIGNAL=""
PICKER_KEY=""
PICKER_CURSOR=0
PICKER_RENDERED_LINES=0
MENU_LABELS=()
MENU_TOTAL=0
MENU_CURSOR=0
PROFILE_TOTAL=0
PROFILE_NAMES=()
PROFILE_LABELS=()
PROFILE_MARKS=()
ARCHIVE_SIZE_BYTES=0
RESOURCE_FILE_COUNT=0
SKILL_COUNT=0

# 安装概览由 help、交互确认和 README 共同遵循，避免目标语义与实际发布范围漂移。
print_installation_overview() {
  cat <<'EOF'
安装内容：
  1. 下载 GitHub 上 dayu-sec/web-skills 的 main 分支源码归档
  2. 校验归档并只选择其中的 skills/ 与 profiles/ 资源
  3. 按选定组合确定本次安装 Skill 名单
  4. 名单内的每个 Skill 在目标 skills/ 下整目录替换

安装器只处理名单内的 Skill 目录名；名单之外的目录一律不读取、不列出、不删除。
安装器不会读取、创建、复制、追加、覆盖或删除任何 AGENTS.md。
EOF
}

# 帮助文本与 print_installation_overview 共享安装说明段落，避免 --help 与实际安装步骤描述不一致。
print_usage() {
  cat <<'EOF'
用法：
  setup-web-skills.sh [选项]

未指定 --target 时：
  通过交互菜单选择项目级 ./.agents、用户级 $HOME/.agents，
  或自定义 Agent 配置根目录；Skill 最终安装到所选目录下的 skills/。

未指定 --profile 时：
  在可交互终端下勾选安装组合；使用 --force 时安装全部 Skill。
  无法交互的环境必须同时指定 --target 与 --force。

EOF
  print_installation_overview
  cat <<'EOF'

选项：
  --target <目录>   Agent 配置根目录；未指定时通过交互菜单选择
                    支持绝对路径、~/ 开头的路径或相对当前目录的路径
  --profile <名单>  安装组合，逗号分隔；指定后跳过交互勾选
  --branch <分支>   GitHub 分支，默认 main
  -f, --force       跳过组合勾选与安装确认，直接安装全部 Skill
  -v, --verbose     显示详细安装信息
  -h, --help        显示帮助

示例：
  setup-web-skills.sh --target ./.agents
  setup-web-skills.sh --target ./.agents --profile monolith,ui-internal --force
  setup-web-skills.sh --target "$HOME/.agents" --force

说明：
  脚本安装 GitHub 公开仓库指定分支的当前 Skills，不需要 GitHub Token。
  可用组合由 web-skills 仓库的 profiles/ 定义，本脚本不硬编码任何组合或 Skill 名称。
  Source code 归档、解压目录和校验文件仅保存在临时目录，退出时自动清理。
EOF
}

# 统一失败出口：交互终端已打开时把错误写到控制终端（fd 3），避免被菜单的转义序列吞掉。
fail() {
  restore_terminal_state
  if [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]]; then
    printf '错误：%s\n' "$*" >&3
  else
    printf '错误：%s\n' "$*" >&2
  fi
  exit 1
}

# 交互界面会改动终端属性；正常退出、失败和中断都必须还原，否则终端会停在无回显状态。
enter_raw_mode() {
  TERMINAL_STATE_SAVED="$(stty -g <&3)" ||
    fail "无法读取终端属性，请改用 --target 与 --profile 非交互执行。"
  stty -icanon -echo min 1 time 0 <&3 ||
    fail "无法进入终端原始模式，请改用 --target 与 --profile 非交互执行。"
  PENDING_SIGNAL=""
  trap 'note_pending_signal INT' INT
  trap 'note_pending_signal TERM' TERM
}

# bash 的 read -n 会在读取前保存终端属性、退栈时写回，因此在信号处理函数里直接恢复
# 会被它覆盖，终端最终停在无回显状态。交互期间只记录信号，等 read 返回、控制权回到
# 脚本自身之后再恢复终端并退出。
note_pending_signal() {
  PENDING_SIGNAL="$1"
}

handle_pending_signal() {
  local received="$PENDING_SIGNAL"

  [[ -n "$received" ]] || return 0
  PENDING_SIGNAL=""
  leave_raw_mode
  printf '\n已取消。\n' >&3
  case "$received" in
    INT) exit 130 ;;
    *) exit 143 ;;
  esac
}

leave_raw_mode() {
  trap 'exit 130' INT
  trap 'exit 143' TERM
  restore_terminal_state
}

# 只有真正保存过终端属性、且交互终端已打开时才尝试恢复，避免在非交互路径上误操作未打开的 fd 3。
restore_terminal_state() {
  [[ -n "$TERMINAL_STATE_SAVED" ]] || return 0
  [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]] || return 0
  stty "$TERMINAL_STATE_SAVED" <&3 2>/dev/null || true
  TERMINAL_STATE_SAVED=""
}

# 临时目录由本次 mktemp 独占，成功、失败或中断都不得遗留下载制品和解压内容。
cleanup() {
  local exit_code=$?

  trap - EXIT INT TERM
  set +e
  PENDING_SIGNAL=""
  restore_terminal_state
  if [[ -n "$WORK_DIRECTORY" && -d "$WORK_DIRECTORY" ]]; then
    rm -rf -- "$WORK_DIRECTORY"
  fi
  if [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]]; then
    exec 3>&-
  fi
  exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 只做参数解析与基础格式校验；路径、组合名等语义校验交给后续专职函数处理。
parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --target)
        (($# >= 2)) || fail "--target 需要提供值。"
        [[ -n "$2" ]] || fail "--target 不能是空字符串。"
        TARGET_ARGUMENT="$2"
        shift 2
        ;;
      --profile)
        (($# >= 2)) || fail "--profile 需要提供值。"
        [[ -n "$2" ]] || fail "--profile 不能是空字符串。"
        PROFILE_ARGUMENT="$2"
        shift 2
        ;;
      --branch)
        (($# >= 2)) || fail "--branch 需要提供值。"
        [[ -n "$2" ]] || fail "--branch 不能是空字符串。"
        case "$2" in
          -* | *' '* | *'..'* | */) fail "--branch 不是合法的分支名：${2}。" ;;
        esac
        GITHUB_BRANCH="$2"
        shift 2
        ;;
      -f | --force)
        FORCE_INSTALL=true
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
        fail "无法识别的参数：${1}。使用 --help 查看用法。"
        ;;
    esac
  done

  if [[ -z "$TARGET_ARGUMENT" ]]; then
    TARGET_SELECTION_REQUIRED=true
  fi

  GITHUB_ARCHIVE_URL="https://github.com/${GITHUB_REPOSITORY}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"
}

# 在联网下载前集中做前置检查，让配置缺失或命令缺失尽早失败，而不是下载后才报错。
validate_runtime_dependencies() {
  [[ -n "$GITHUB_REPOSITORY" ]] || fail "请先配置 GITHUB_REPOSITORY。"
  [[ -n "$GITHUB_BRANCH" ]] || fail "请先配置 GITHUB_BRANCH。"
  [[ -n "$GITHUB_ARCHIVE_URL" ]] || fail "请先配置 GITHUB_ARCHIVE_URL。"
  [[ -n "${HOME:-}" && "$HOME" != "/" ]] || fail "HOME 未设置或指向根目录，拒绝安装。"
  [[ -n "$INVOCATION_DIRECTORY" && "$INVOCATION_DIRECTORY" == /* ]] ||
    fail "无法确定脚本启动时的当前目录。"

  local command_name
  for command_name in curl tar mktemp find cp awk rm sort stty; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少必需命令：${command_name}。"
  done
}

# 位置选择、组合勾选和最终确认都固定从控制终端读取，不占用管道标准输入。
# 已指定 --target 且带 --force 时全程无需交互，直接跳过，不打开 /dev/tty。
open_interactive_terminal() {
  if [[ "$TARGET_SELECTION_REQUIRED" != true && "$FORCE_INSTALL" == true ]]; then
    return
  fi
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    fail "当前环境无法交互，请使用 --target <Agent 配置根目录> --force 执行。"
  fi
  INTERACTIVE_TERMINAL_OPEN=true
}

# 只绘制选项行并记录行数供上层用转义序列回退重绘。
# PICKER_RENDERED_LINES 统计的是换行符个数，而 \033[A 回退的是物理行，
# 因此重绘区内不能出现长度不可控、可能被终端折行的内容——标题等一次性输出留在重绘区之外。
render_single_choice_menu() {
  local index=0
  local pointer=""

  PICKER_RENDERED_LINES=0

  while ((index < MENU_TOTAL)); do
    if ((index == MENU_CURSOR)); then
      pointer=">"
    else
      pointer=" "
    fi
    printf '  %s %s\n' "$pointer" "${MENU_LABELS[index]}" >&3
    PICKER_RENDERED_LINES=$((PICKER_RENDERED_LINES + 1))
    index=$((index + 1))
  done
}

# 单选菜单与组合勾选共用同一套按键与终端处理，保持交互一致。
run_single_choice_menu() {
  local title="$1"

  enter_raw_mode
  printf '\n%s\n' "$title" >&3
  printf '  ↑↓ 或 j/k 移动，回车确认，q 取消\n\n' >&3
  MENU_CURSOR=0
  PICKER_RENDERED_LINES=0
  while true; do
    if ((PICKER_RENDERED_LINES > 0)); then
      printf '\033[%dA\033[J' "$PICKER_RENDERED_LINES" >&3
    fi
    render_single_choice_menu
    read_picker_key
    handle_pending_signal

    case "$PICKER_KEY" in
      up)
        if ((MENU_CURSOR > 0)); then
          MENU_CURSOR=$((MENU_CURSOR - 1))
        fi
        ;;
      down)
        if ((MENU_CURSOR < MENU_TOTAL - 1)); then
          MENU_CURSOR=$((MENU_CURSOR + 1))
        fi
        ;;
      enter)
        leave_raw_mode
        printf '\n' >&3
        return 0
        ;;
      quit)
        leave_raw_mode
        printf '\n已取消。\n' >&3
        exit 0
        ;;
    esac
  done
}

# 未通过 --target 指定安装位置时，用单选菜单在项目级、用户级与自定义目录之间选择。
collect_interactive_target() {
  local custom_target=""

  if [[ "$TARGET_SELECTION_REQUIRED" != true ]]; then
    return 0
  fi

  MENU_LABELS=(
    "项目级 ./.agents"
    "用户级 ~/.agents"
    "自定义 Agent 配置根目录"
  )
  MENU_TOTAL=3
  run_single_choice_menu "请选择 Web Skills 安装位置
  项目级 ${INVOCATION_DIRECTORY%/}/.agents
  用户级 ${HOME%/}/.agents"

  case "$MENU_CURSOR" in
    0)
      TARGET_ARGUMENT=".agents"
      ;;
    1)
      TARGET_ARGUMENT="${HOME%/}/.agents"
      ;;
    *)
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
  esac
}

# --target 表示 Agent 配置根目录；所有 Skill 都安装到该目录下的 skills/。
resolve_installation_directories() {
  # 去除尾部斜杠，保持路径一致性；避免 "$HOME/" 绕过 HOME 目录保护检查。
  [[ "$TARGET_ARGUMENT" != "/" ]] && TARGET_ARGUMENT="${TARGET_ARGUMENT%/}"

  local normalized_home="${HOME%/}"

  case "$TARGET_ARGUMENT" in
    "")
      AGENT_CONFIG_DIRECTORY="${INVOCATION_DIRECTORY%/}/.agents"
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
      AGENT_CONFIG_DIRECTORY="${INVOCATION_DIRECTORY%/}/${TARGET_ARGUMENT#./}"
      ;;
  esac

  [[ -n "$AGENT_CONFIG_DIRECTORY" && "$AGENT_CONFIG_DIRECTORY" != "/" ]] ||
    fail "Agent 配置根目录不能指向文件系统根目录。"
  [[ "$AGENT_CONFIG_DIRECTORY" != "$normalized_home" ]] ||
    fail "Agent 配置根目录不能直接指向 HOME，请使用 HOME 下的 Agent 子目录。"

  SKILLS_DIRECTORY="${AGENT_CONFIG_DIRECTORY}/skills"
}

# 目标路径若已存在但不是目录，直接失败，避免后续 mkdir -p / cp -R 出现歧义行为。
validate_installation_target() {
  if [[ -e "$AGENT_CONFIG_DIRECTORY" && ! -d "$AGENT_CONFIG_DIRECTORY" ]]; then
    fail "Agent 配置根目录已存在但不是目录：${AGENT_CONFIG_DIRECTORY}。"
  fi
  if [[ -e "$SKILLS_DIRECTORY" && ! -d "$SKILLS_DIRECTORY" ]]; then
    fail "Skills 目标已存在但不是目录：${SKILLS_DIRECTORY}。"
  fi
}

# 在独占的 mktemp 临时目录下预先规划归档、清单与解压目录路径，供后续下载与校验函数使用。
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

  # 路径以 / 开头或包含 ../ 视为越界，防止归档条目在解压时跳出临时目录（类似 zip slip）。
  if awk '
    /^\// || /(^|\/)\.\.(\/|$)/ { unsafe = 1 }
    END { exit unsafe ? 0 : 1 }
  ' "$ARCHIVE_MANIFEST_FILE"; then
    fail "Source code 归档包含越出资源根的路径。"
  fi

  # GitHub 生成的归档顶层目录名包含仓库名与分支/commit 信息，无法预先硬编码，
  # 这里从清单动态推导，且只接受单一顶层目录。
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
  local skill_name=""
  local archive_skill_count=0
  ARCHIVE_SKILLS=""
  while IFS= read -r -d '' source_skill; do
    [[ -d "$source_skill" ]] ||
      fail "skills/ 只能包含一级 Skill 目录：${source_skill##*/}。"
    [[ -f "${source_skill}/SKILL.md" ]] ||
      fail "Skill 目录缺少 SKILL.md：${source_skill##*/}。"
    skill_name="${source_skill##*/}"
    ARCHIVE_SKILLS="${ARCHIVE_SKILLS}${skill_name}
"
    archive_skill_count=$((archive_skill_count + 1))
  done < <(find "${EXTRACTED_DIRECTORY}/skills" -mindepth 1 -maxdepth 1 -print0)

  ((archive_skill_count > 0)) || fail "Source code 中没有可安装的 Skill。"
  ARCHIVE_SKILLS="$(printf '%s' "$ARCHIVE_SKILLS" | sort -u)"
}

# 组合名称和组合内容全部来自归档 profiles/，脚本不硬编码任何组合名或 Skill 名。
load_profiles() {
  local profile_file=""
  local profile_name=""
  local profile_description=""

  PROFILES_DIRECTORY="${EXTRACTED_DIRECTORY}/profiles"
  [[ -d "$PROFILES_DIRECTORY" ]] || return 0

  for profile_file in "$PROFILES_DIRECTORY"/*.list; do
    [[ -f "$profile_file" ]] || continue
    profile_name="${profile_file##*/}"
    profile_name="${profile_name%.list}"
    profile_description="$(awk '
      NR == 1 && /^#/ { sub(/^#[[:space:]]*/, ""); print; exit }
    ' "$profile_file")"
    [[ -n "$profile_description" ]] || profile_description="$profile_name"

    PROFILE_NAMES[PROFILE_TOTAL]="$profile_name"
    PROFILE_LABELS[PROFILE_TOTAL]="$profile_description"
    PROFILE_MARKS[PROFILE_TOTAL]=0
    PROFILE_TOTAL=$((PROFILE_TOTAL + 1))
  done

  ((PROFILE_TOTAL > 0)) || fail "profiles/ 中没有可用的安装组合。"
}

# 线性查找组合名是否已加载，供 --profile 校验未知组合名使用。
profile_exists() {
  local wanted="$1"
  local index=0

  while ((index < PROFILE_TOTAL)); do
    if [[ "${PROFILE_NAMES[index]}" == "$wanted" ]]; then
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

# 输出全部可用组合名，供 --profile 传入未知组合时的错误提示引用。
list_available_profile_names() {
  local index=0

  while ((index < PROFILE_TOTAL)); do
    printf '  %s\n' "${PROFILE_NAMES[index]}"
    index=$((index + 1))
  done
}

# 带去重地追加组合名；交互勾选与 --profile 解析都经过这里，保证两条路径的去重语义一致。
append_selected_profile() {
  local profile_name="$1"

  case "
${SELECTED_PROFILES}" in
    *"
${profile_name}
"*) return 0 ;;
  esac
  SELECTED_PROFILES="${SELECTED_PROFILES}${profile_name}
"
}

# 组合勾选菜单的一次性绘制，含每项的勾选状态标记，渲染行数计入 PICKER_RENDERED_LINES 供重绘使用。
render_profile_picker() {
  local index=0
  local marker=""
  local pointer=""

  PICKER_RENDERED_LINES=0

  while ((index < PROFILE_TOTAL)); do
    if ((PROFILE_MARKS[index] == 1)); then
      marker="x"
    else
      marker=" "
    fi
    if ((index == PICKER_CURSOR)); then
      pointer=">"
    else
      pointer=" "
    fi
    printf '  %s [%s] %-12s %s\n' \
      "$pointer" "$marker" "${PROFILE_NAMES[index]}" "${PROFILE_LABELS[index]}" >&3
    PICKER_RENDERED_LINES=$((PICKER_RENDERED_LINES + 1))
    index=$((index + 1))
  done
}

# read -n 期间由 bash 接管终端属性，stty 的 min/time 不生效，超时只能用 read -t，
# 且 bash 3.2 的 -t 仅接受整数秒。轮询的目的不是等按键，而是让被 trap 记下的中断信号
# 有机会被处理：trap 返回后 bash 会重启被打断的阻塞 read，不设超时就永远拿不回控制权。
read_picker_key() {
  local first=""
  local second=""
  local third=""
  local read_status=0
  local idle_rounds=0

  PICKER_KEY="other"
  while true; do
    read_status=0
    IFS= read -r -s -n 1 -t 1 first <&3 || read_status=$?
    if ((read_status == 0)); then
      break
    fi
    handle_pending_signal
    # bash 3.2 的超时返回 1，与 EOF 同码，无法按退出码区分；改用连续空转轮次兜底，
    # 正常静置只是继续等待，终端异常导致的立即失败会在很短时间内耗尽轮次。
    idle_rounds=$((idle_rounds + 1))
    if ((idle_rounds >= IDLE_ROUNDS_BEFORE_CANCEL)); then
      PICKER_KEY="quit"
      return 0
    fi
  done

  case "$first" in
    "")
      PICKER_KEY="enter"
      return 0
      ;;
    " ")
      PICKER_KEY="space"
      return 0
      ;;
    j | J)
      PICKER_KEY="down"
      return 0
      ;;
    k | K)
      PICKER_KEY="up"
      return 0
      ;;
    a | A)
      PICKER_KEY="all"
      return 0
      ;;
    n | N)
      PICKER_KEY="none"
      return 0
      ;;
    q | Q)
      PICKER_KEY="quit"
      return 0
      ;;
    $'\e') ;;
    *)
      return 0
      ;;
  esac

  # 裸 ESC 不是绑定键：只在读到 CSI（[）或 SS3（O）引导符时才继续读第三个字节，
  # 否则立即返回，避免多等一轮超时并多吞一个按键。SS3 序列出现在 tmux/screen 的
  # 光标应用模式下，方向键为 \eOA / \eOB。
  IFS= read -r -s -n 1 -t 1 second <&3 || second=""
  case "$second" in
    "[" | O) ;;
    *) return 0 ;;
  esac

  IFS= read -r -s -n 1 -t 1 third <&3 || third=""
  case "$third" in
    A) PICKER_KEY="up" ;;
    B) PICKER_KEY="down" ;;
  esac
}

# 批量设置全部组合的勾选状态，供全选（a）/全清（n）按键复用。
set_all_profile_marks() {
  local mark="$1"
  local index=0

  while ((index < PROFILE_TOTAL)); do
    PROFILE_MARKS[index]="$mark"
    index=$((index + 1))
  done
}

# 把当前勾选状态转换为 SELECTED_PROFILES；复用 append_selected_profile 保持去重语义。
collect_selected_profiles_from_marks() {
  local index=0

  while ((index < PROFILE_TOTAL)); do
    if ((PROFILE_MARKS[index] == 1)); then
      append_selected_profile "${PROFILE_NAMES[index]}"
    fi
    index=$((index + 1))
  done
}

# 组合勾选交互主循环；回车时若未勾选任何组合则继续循环，不允许提交空选择。
pick_profiles_interactively() {
  enter_raw_mode
  printf '\n请勾选要安装的 Skill 组合\n' >&3
  printf '  ↑↓ 或 j/k 移动，空格选择/取消，a 全选，n 全清，回车确认，q 取消\n\n' >&3

  PICKER_CURSOR=0
  PICKER_RENDERED_LINES=0
  while true; do
    if ((PICKER_RENDERED_LINES > 0)); then
      printf '\033[%dA\033[J' "$PICKER_RENDERED_LINES" >&3
    fi
    render_profile_picker
    read_picker_key
    handle_pending_signal

    case "$PICKER_KEY" in
      up)
        if ((PICKER_CURSOR > 0)); then
          PICKER_CURSOR=$((PICKER_CURSOR - 1))
        fi
        ;;
      down)
        if ((PICKER_CURSOR < PROFILE_TOTAL - 1)); then
          PICKER_CURSOR=$((PICKER_CURSOR + 1))
        fi
        ;;
      space)
        if ((PROFILE_MARKS[PICKER_CURSOR] == 1)); then
          PROFILE_MARKS[PICKER_CURSOR]=0
        else
          PROFILE_MARKS[PICKER_CURSOR]=1
        fi
        ;;
      all)
        set_all_profile_marks 1
        ;;
      none)
        set_all_profile_marks 0
        ;;
      enter)
        collect_selected_profiles_from_marks
        if [[ -n "$SELECTED_PROFILES" ]]; then
          leave_raw_mode
          printf '\n' >&3
          return 0
        fi
        ;;
      quit)
        leave_raw_mode
        printf '\n已取消。\n' >&3
        exit 0
        ;;
    esac
  done
}

# 解析 --profile 的逗号分隔名单；遇到未知组合立即失败并列出全部可用组合，不做模糊匹配。
resolve_profile_argument() {
  local remaining="$PROFILE_ARGUMENT"
  local profile_name=""

  while [[ -n "$remaining" ]]; do
    profile_name="${remaining%%,*}"
    if [[ "$profile_name" == "$remaining" ]]; then
      remaining=""
    else
      remaining="${remaining#*,}"
    fi
    [[ -n "$profile_name" ]] || continue
    if ! profile_exists "$profile_name"; then
      fail "未知组合：${profile_name}。可用组合：
$(list_available_profile_names)"
    fi
    append_selected_profile "$profile_name"
  done

  [[ -n "$SELECTED_PROFILES" ]] || fail "--profile 没有解析出任何组合。"
}

# 把已选组合展开为具体 Skill 名单；多个组合共享的 Skill 靠 sort -u 去重，不在此处手动判重。
expand_selected_profiles() {
  local profile_name=""
  local profile_file=""
  local skill_name=""

  while IFS= read -r profile_name; do
    [[ -n "$profile_name" ]] || continue
    profile_file="${PROFILES_DIRECTORY}/${profile_name}.list"
    [[ -f "$profile_file" ]] || fail "无法定位组合清单：${profile_name}.list。"
    # 末行缺少换行符时 read 返回非零，需补判变量非空，否则最后一个 Skill 会被静默漏装。
    while IFS= read -r skill_name || [[ -n "$skill_name" ]]; do
      case "$skill_name" in "" | \#*) continue ;; esac
      SELECTED_SKILLS="${SELECTED_SKILLS}${skill_name}
"
    done <"$profile_file"
  done <<EOF
$SELECTED_PROFILES
EOF

  SELECTED_SKILLS="$(printf '%s' "$SELECTED_SKILLS" | sort -u)"
}

# 组合清单由 web-skills 维护；与归档 skills/ 不同步时立即失败，不静默跳过。
validate_selected_skills() {
  local skill_name=""

  SKILL_COUNT=0
  while IFS= read -r skill_name; do
    [[ -n "$skill_name" ]] || continue
    case "$skill_name" in
      */* | . | ..) fail "组合清单包含非法 Skill 名：${skill_name}。" ;;
    esac
    [[ -d "${EXTRACTED_DIRECTORY}/skills/${skill_name}" ]] ||
      fail "组合清单引用了归档中不存在的 Skill：${skill_name}。"
    SKILL_COUNT=$((SKILL_COUNT + 1))
  done <<EOF
$SELECTED_SKILLS
EOF

  ((SKILL_COUNT > 0)) || fail "选定组合没有解析出任何 Skill。"
}

# 只在 --verbose 时统计已选 Skill 下的资源文件数，避免非 verbose 路径承担多余的 find 开销。
count_selected_resources() {
  local skill_name=""
  local file_count=0

  RESOURCE_FILE_COUNT=0
  while IFS= read -r skill_name; do
    [[ -n "$skill_name" ]] || continue
    file_count="$(find "${EXTRACTED_DIRECTORY}/skills/${skill_name}" -type f |
      wc -l | tr -d '[:space:]')"
    RESOURCE_FILE_COUNT=$((RESOURCE_FILE_COUNT + file_count))
  done <<EOF
$SELECTED_SKILLS
EOF
}

# 汇总四条取值路径的优先级：--profile 显式指定 > 归档未提供 profiles/ 时全装 > 交互勾选 > --force 且未指定 --profile 时全装。
resolve_selected_skills() {
  if [[ -n "$PROFILE_ARGUMENT" ]]; then
    ((PROFILE_TOTAL > 0)) ||
      fail "Source code 归档没有提供 profiles/，无法使用 --profile。"
    resolve_profile_argument
  elif ((PROFILE_TOTAL == 0)); then
    printf '提示：Source code 归档没有提供 profiles/，本次安装全部 Skill。\n'
    SELECTED_SKILLS="$ARCHIVE_SKILLS"
  elif [[ "$INTERACTIVE_TERMINAL_OPEN" == true && "$FORCE_INSTALL" != true ]]; then
    pick_profiles_interactively
  else
    SELECTED_SKILLS="$ARCHIVE_SKILLS"
  fi

  if [[ -n "$SELECTED_PROFILES" ]]; then
    expand_selected_profiles
  fi
  validate_selected_skills
}

# 把已选组合名拼成一行摘要；安装预览与安装完成摘要共用同一个函数，避免文案分叉。
print_selected_profiles() {
  local output_fd="$1"
  local profile_name=""
  local joined=""

  while IFS= read -r profile_name; do
    [[ -n "$profile_name" ]] || continue
    if [[ -n "$joined" ]]; then
      joined="${joined}、${profile_name}"
    else
      joined="$profile_name"
    fi
  done <<EOF
$SELECTED_PROFILES
EOF

  [[ -n "$joined" ]] || return 0
  printf '  安装组合：%s\n' "$joined" >&"$output_fd"
}

# 安装前的详细预览；仅当 --force 且未加 --verbose 时，main() 才会跳过调用直接确认。
print_installation_preview() {
  local output_fd=1
  local skill_name=""

  [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]] && output_fd=3
  printf '\n即将安装 Web Skills：\n' >&"$output_fd"
  printf '  GitHub 来源：%s@%s\n' "$GITHUB_REPOSITORY" "$GITHUB_BRANCH" >&"$output_fd"
  if [[ "$VERBOSE" == true ]]; then
    printf '  Source code：tar.gz，%s 字节\n' "$ARCHIVE_SIZE_BYTES" >&"$output_fd"
  fi
  print_selected_profiles "$output_fd"
  printf '  Skill 数量：%s\n' "$SKILL_COUNT" >&"$output_fd"
  if [[ "$VERBOSE" == true ]]; then
    count_selected_resources
    printf '  资源文件：%s\n' "$RESOURCE_FILE_COUNT" >&"$output_fd"
  fi
  printf '  Agent 配置根：%s\n' "$AGENT_CONFIG_DIRECTORY" >&"$output_fd"
  printf '  Skills 目录：%s\n' "$SKILLS_DIRECTORY" >&"$output_fd"
  printf '  载入 Skill：\n' >&"$output_fd"
  while IFS= read -r skill_name; do
    [[ -n "$skill_name" ]] || continue
    printf '    - %s\n' "$skill_name" >&"$output_fd"
  done <<EOF
$SELECTED_SKILLS
EOF
  if [[ "$VERBOSE" == true ]]; then
    printf '  安装方式：名单内的 Skill 目录整目录替换；名单之外的目录不做处理\n' >&"$output_fd"
  fi
}

# --force 时跳过二次确认；否则只有显式输入 n/no 才会取消，其余输入（含直接回车）一律视为继续。
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

# 名单内的 Skill 目录名归 web-skills 所有：先移除同名条目再整目录写入，
# 避免上游已删除的资源在目标位置长期残留。
install_skills() {
  local skill_name=""
  local source_skill=""
  local target_skill=""

  mkdir -p "$SKILLS_DIRECTORY"
  [[ -w "$SKILLS_DIRECTORY" ]] || fail "Skills 目录不可写：${SKILLS_DIRECTORY}。"

  while IFS= read -r skill_name; do
    [[ -n "$skill_name" ]] || continue
    source_skill="${EXTRACTED_DIRECTORY}/skills/${skill_name}"
    target_skill="${SKILLS_DIRECTORY}/${skill_name}"
    # 先移除同名目标再校验确已不存在，避免遗留的软链接或特殊文件让后续 cp -R 产生歧义。
    rm -rf -- "$target_skill"
    [[ ! -e "$target_skill" && ! -L "$target_skill" ]] ||
      fail "无法替换已存在的目标：${target_skill}。"
    cp -R "$source_skill" "$target_skill"
    [[ -f "${target_skill}/SKILL.md" ]] ||
      fail "安装后缺少 ${skill_name}。"
  done <<EOF
$SELECTED_SKILLS
EOF
}

# 安装完成后的摘要；字段与 print_installation_preview 基本对称，便于核对预览与实际安装结果是否一致。
print_summary() {
  local skill_name=""

  printf '\nWeb Skills 安装完成。\n'
  printf '  GitHub 来源：%s@%s\n' "$GITHUB_REPOSITORY" "$GITHUB_BRANCH"
  printf '  Agent 配置根：%s\n' "$AGENT_CONFIG_DIRECTORY"
  printf '  Skills 目录：%s\n' "$SKILLS_DIRECTORY"
  print_selected_profiles 1
  printf '  Skill 数量：%s\n' "$SKILL_COUNT"

  if [[ "$VERBOSE" == true ]]; then
    printf '  已安装 Skill：\n'
    while IFS= read -r skill_name; do
      [[ -n "$skill_name" ]] || continue
      printf '    - %s\n' "$skill_name"
    done <<EOF
$SELECTED_SKILLS
EOF
  fi
  printf '\n重新启动对应 Agent 会话后即可加载最新 Skills。\n'
}

# 主流程：函数调用顺序即安装的完整生命周期；异常与正常退出统一交给顶部注册的 trap cleanup 处理。
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
  load_profiles
  resolve_selected_skills
  if [[ "$VERBOSE" == true || "$FORCE_INSTALL" != true ]]; then
    print_installation_preview
  fi
  confirm_installation
  install_skills
  print_summary
}

main "$@"
