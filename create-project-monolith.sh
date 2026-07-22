#!/usr/bin/env bash

set -Eeuo pipefail

# 模板地址属于脚本维护配置；使用公开 GitHub HTTPS 地址，无需额外认证配置。
readonly TEMPLATE_REPOSITORY="https://github.com/dayu-sec/web-scaffolds-monolith.git"
# 交互提示与名称校验复用同一组边界，修改命名规则时必须保持同步。
readonly NAME_MAX_LENGTH=214
readonly PROJECT_NAME_FORMAT_RULE="只能使用小写字母、数字、点、下划线和连字符"

PROJECT_NAME=""
PROJECT_DESCRIPTION=""
DESCRIPTION_PROVIDED=false
NEW_REPOSITORY=""
REPOSITORY_PROVIDED=false
TARGET_ARGUMENT=""
TEMPLATE_BRANCH=""
KEEP_HISTORY=false
TARGET_DIRECTORY=""
PACKAGE_TEMP_FILE=""
README_TEMP_FILE=""
INTERACTIVE_TERMINAL_OPEN=false
USER_INPUT=""
PROJECT_NAME_ERROR=""

print_usage() {
  cat <<'EOF'
用法：
  create-project-monolith.sh
  create-project-monolith.sh --name <项目名称> [选项]

交互模式：
  不传任何参数时，脚本会逐项询问项目名称、模板分支、描述、目标目录、新仓库地址和 Git 历史选项。

必填参数：
  --name <名称>              package.json 的 name，同时作为 README 一级标题

可选参数：
  --description <描述>       写入 package.json，并排列在 name 属性之后
  --repository <地址>        设置新项目的 origin；未提供时不设置远端
  --target <目录>            克隆目标目录；默认是当前目录下的 <项目名称>
                             传入 . 时直接使用当前目录
  --branch <分支>            指定模板仓库分支；默认使用仓库默认分支
  --keep-history             保留模板仓库的 Git 历史
  -h, --help                 显示帮助

默认行为：
  未提供 --branch 时使用模板仓库默认分支。
  删除模板仓库的 Git 历史并初始化新的 Git 仓库；提供 --keep-history 时保留历史。
  无论是否保留历史，都会删除模板 origin；提供 --repository 时再设置新 origin。
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
  [[ -z "$PACKAGE_TEMP_FILE" || ! -e "$PACKAGE_TEMP_FILE" ]] || rm -f "$PACKAGE_TEMP_FILE"
  [[ -z "$README_TEMP_FILE" || ! -e "$README_TEMP_FILE" ]] || rm -f "$README_TEMP_FILE"
  if [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]]; then
    exec 3>&- || true
  fi
}

trap cleanup EXIT

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --name)
        (($# >= 2)) || fail "--name 需要提供值。"
        PROJECT_NAME="$2"
        shift 2
        ;;
      --description)
        (($# >= 2)) || fail "--description 需要提供值。"
        PROJECT_DESCRIPTION="$2"
        DESCRIPTION_PROVIDED=true
        shift 2
        ;;
      --repository)
        (($# >= 2)) || fail "--repository 需要提供值。"
        [[ -n "$2" ]] || fail "--repository 不能是空字符串。"
        NEW_REPOSITORY="$2"
        REPOSITORY_PROVIDED=true
        shift 2
        ;;
      --target)
        (($# >= 2)) || fail "--target 需要提供值。"
        TARGET_ARGUMENT="$2"
        shift 2
        ;;
      --branch)
        (($# >= 2)) || fail "--branch 需要提供值。"
        [[ -n "$2" ]] || fail "--branch 不能是空字符串。"
        TEMPLATE_BRANCH="$2"
        shift 2
        ;;
      --keep-history)
        KEEP_HISTORY=true
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

validate_project_name() {
  PROJECT_NAME_ERROR=""

  if [[ -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME_ERROR="项目名称不能为空。"
    return 1
  fi

  if [[ ${#PROJECT_NAME} -gt $NAME_MAX_LENGTH ]]; then
    PROJECT_NAME_ERROR="项目名称不能超过 ${NAME_MAX_LENGTH} 个字符。"
    return 1
  fi

  if [[ ! "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    PROJECT_NAME_ERROR="项目名称${PROJECT_NAME_FORMAT_RULE}。"
    return 1
  fi

  return 0
}

# 空值表示沿用仓库默认分支；非空值交给 Git 自身规则校验，交互和参数模式共用同一边界。
validate_template_branch() {
  [[ -z "$TEMPLATE_BRANCH" ]] || git check-ref-format --branch "$TEMPLATE_BRANCH" >/dev/null 2>&1
}

validate_runtime_configuration() {
  [[ -n "$TEMPLATE_REPOSITORY" ]] || fail "请先在脚本中配置 TEMPLATE_REPOSITORY。"

  local command_name
  for command_name in git jq awk mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少必需命令：$command_name。"
  done

  validate_template_branch || fail "模板分支名称无效：${TEMPLATE_BRANCH}。"
}

print_non_interactive_guidance() {
  printf '错误：没有传递参数，并且当前环境无法打开交互终端。\n\n' >&2
  print_usage >&2
  cat >&2 <<'EOF'

通过管道非交互执行时，请显式传递参数，例如：
  curl -fsSL <脚本地址> | bash -s -- --name new-web-project
  wget -qO- <脚本地址> | bash -s -- --name new-web-project --repository <新仓库地址>
EOF
}

# curl 或 wget 通过标准输入传输脚本，因此交互回答必须直接从控制终端读取。
open_interactive_terminal() {
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    print_non_interactive_guidance
    exit 1
  fi

  INTERACTIVE_TERMINAL_OPEN=true
}

read_from_terminal() {
  if ! IFS= read -r USER_INPUT <&3; then
    printf '\n操作已取消。\n' >&3
    exit 130
  fi
}

collect_interactive_arguments() {
  printf '\n创建单体项目\n' >&3

  while true; do
    printf '\n项目名称（必填）：\n规则：最多 %s 个字符；%s。\n> ' \
      "$NAME_MAX_LENGTH" "$PROJECT_NAME_FORMAT_RULE" >&3
    read_from_terminal
    PROJECT_NAME="$USER_INPUT"

    if validate_project_name; then
      break
    fi

    printf '输入无效：%s\n' "$PROJECT_NAME_ERROR" >&3
  done

  while true; do
    printf '\n模板分支（可选，直接回车使用仓库默认分支）：\n> ' >&3
    read_from_terminal
    TEMPLATE_BRANCH="$USER_INPUT"
    if validate_template_branch; then
      break
    fi
    printf '输入无效：模板分支名称无效：%s。\n' "$TEMPLATE_BRANCH" >&3
  done

  printf '\n项目描述（可选，直接回车跳过）：\n> ' >&3
  read_from_terminal
  if [[ -n "$USER_INPUT" ]]; then
    PROJECT_DESCRIPTION="$USER_INPUT"
    DESCRIPTION_PROVIDED=true
  fi

  printf '\n目标目录（直接回车使用 %s）：\n> ' "${PWD}/${PROJECT_NAME}" >&3
  read_from_terminal
  TARGET_ARGUMENT="$USER_INPUT"

  printf '\n新仓库地址（可选，直接回车表示不设置 origin）：\n> ' >&3
  read_from_terminal
  if [[ -n "$USER_INPUT" ]]; then
    NEW_REPOSITORY="$USER_INPUT"
    REPOSITORY_PROVIDED=true
  fi

  while true; do
    printf '\n是否移除模板仓库的 Git 历史？[Y/n]\n> ' >&3
    read_from_terminal
    case "$USER_INPUT" in
      "" | y | Y | yes | YES | Yes)
        KEEP_HISTORY=false
        break
        ;;
      n | N | no | NO | No)
        KEEP_HISTORY=true
        break
        ;;
      *)
        printf '请输入 y 或 n；直接回车表示移除。\n' >&3
        ;;
    esac
  done
}

confirm_interactive_configuration() {
  printf '\n即将创建项目：\n' >&3
  printf '  项目名称：%s\n' "$PROJECT_NAME" >&3
  if [[ "$DESCRIPTION_PROVIDED" == true ]]; then
    printf '  项目描述：%s\n' "$PROJECT_DESCRIPTION" >&3
  else
    printf '  项目描述：未设置\n' >&3
  fi
  printf '  目标目录：%s\n' "$TARGET_DIRECTORY" >&3
  printf '  模板分支：%s\n' "${TEMPLATE_BRANCH:-仓库默认分支}" >&3
  printf '  Git 历史：%s\n' "$([[ "$KEEP_HISTORY" == true ]] && printf '保留' || printf '移除并重新初始化')" >&3
  if [[ "$REPOSITORY_PROVIDED" == true ]]; then
    printf '  origin：%s\n' "$NEW_REPOSITORY" >&3
  else
    printf '  origin：不设置\n' >&3
  fi

  while true; do
    printf '\n确认继续？[Y/n]\n> ' >&3
    read_from_terminal
    case "$USER_INPUT" in
      "" | y | Y | yes | YES | Yes)
        return 0
        ;;
      n | N | no | NO | No)
        printf '操作已取消。\n' >&3
        exit 0
        ;;
      *)
        printf '请输入 y 或 n；直接回车表示继续。\n' >&3
        ;;
    esac
  done
}

resolve_target_directory() {
  if [[ -z "$TARGET_ARGUMENT" ]]; then
    TARGET_DIRECTORY="${PWD}/${PROJECT_NAME}"
  elif [[ "$TARGET_ARGUMENT" == "." ]]; then
    TARGET_DIRECTORY="$PWD"
  elif [[ "$TARGET_ARGUMENT" == /* ]]; then
    TARGET_DIRECTORY="$TARGET_ARGUMENT"
  else
    TARGET_DIRECTORY="${PWD}/${TARGET_ARGUMENT}"
  fi
}

validate_target_directory() {
  [[ ! -e "$TARGET_DIRECTORY" || -d "$TARGET_DIRECTORY" ]] ||
    fail "目标路径已存在且不是目录：$TARGET_DIRECTORY。"

  # git clone 可以使用已存在的空目录，但不能安全覆盖任何已有内容。
  if [[ -d "$TARGET_DIRECTORY" ]] &&
    [[ -n "$(find "$TARGET_DIRECTORY" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    fail "目标目录不是空目录：$TARGET_DIRECTORY。"
  fi
}

prepare_target_directory() {
  mkdir -p "$(dirname "$TARGET_DIRECTORY")"
}

# 生成新的 package.json 后再原子替换，避免 jq 失败时损坏原文件。
prepare_package_json() {
  local package_json="${TARGET_DIRECTORY}/package.json"

  [[ -f "$package_json" ]] || fail "模板中缺少 package.json。"
  jq -e 'type == "object" and has("name")' "$package_json" >/dev/null ||
    fail "package.json 必须是包含顶层 name 属性的 JSON 对象。"

  PACKAGE_TEMP_FILE="$(mktemp "${package_json}.tmp.XXXXXX")"
  cp -p "$package_json" "$PACKAGE_TEMP_FILE"

  if [[ "$DESCRIPTION_PROVIDED" == true ]]; then
    # 先移除旧 description，再紧跟 name 插入，确保属性顺序稳定且不会重复。
    jq --arg name "$PROJECT_NAME" --arg description "$PROJECT_DESCRIPTION" '
      [
        to_entries[]
        | if .key == "description" then
            empty
          elif .key == "name" then
            {"key": "name", "value": $name},
            {"key": "description", "value": $description}
          else
            .
          end
      ]
      | from_entries
    ' "$package_json" >"$PACKAGE_TEMP_FILE"
  else
    jq --arg name "$PROJECT_NAME" '.name = $name' "$package_json" >"$PACKAGE_TEMP_FILE"
  fi
}

# 只修改第一个 Markdown 一级标题，其余 README 内容保持原样。
prepare_readme() {
  local readme="${TARGET_DIRECTORY}/README.md"

  [[ -f "$readme" ]] || fail "模板中缺少 README.md。"

  README_TEMP_FILE="$(mktemp "${readme}.tmp.XXXXXX")"
  cp -p "$readme" "$README_TEMP_FILE"

  awk -v title="$PROJECT_NAME" '
    !replaced && /^#[[:space:]]+/ {
      print "# " title
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        exit 2
      }
    }
  ' "$readme" >"$README_TEMP_FILE" || fail "README.md 中没有找到一级标题。"
}

apply_project_metadata() {
  local package_json="${TARGET_DIRECTORY}/package.json"
  local readme="${TARGET_DIRECTORY}/README.md"

  prepare_package_json
  prepare_readme

  mv "$PACKAGE_TEMP_FILE" "$package_json"
  PACKAGE_TEMP_FILE=""
  mv "$README_TEMP_FILE" "$readme"
  README_TEMP_FILE=""
}

# 先清除模板远端或历史，再按需设置新 origin，避免新项目继续指向模板仓库。
configure_git_repository() {
  if [[ "$KEEP_HISTORY" == true ]]; then
    git -C "$TARGET_DIRECTORY" remote remove origin
  else
    rm -rf "${TARGET_DIRECTORY}/.git"
    git -C "$TARGET_DIRECTORY" init >/dev/null
  fi

  if [[ "$REPOSITORY_PROVIDED" == true ]]; then
    git -C "$TARGET_DIRECTORY" remote add origin "$NEW_REPOSITORY"
  fi
}

print_result() {
  printf '\n项目已创建：%s\n' "$TARGET_DIRECTORY"
  printf 'package name：%s\n' "$PROJECT_NAME"
  printf '模板分支：%s\n' "${TEMPLATE_BRANCH:-仓库默认分支}"
  if [[ "$DESCRIPTION_PROVIDED" == true ]]; then
    printf 'description：%s\n' "$PROJECT_DESCRIPTION"
  fi
  printf 'Git 历史：%s\n' "$([[ "$KEEP_HISTORY" == true ]] && printf '已保留' || printf '已移除并重新初始化')"
  if [[ "$REPOSITORY_PROVIDED" == true ]]; then
    printf 'origin：%s\n' "$NEW_REPOSITORY"
  else
    printf 'origin：未设置\n'
  fi
}

# --branch 只选择模板内容来源，不使用浅克隆或单分支克隆收窄 --keep-history 的语义。
clone_template() {
  if [[ -n "$TEMPLATE_BRANCH" ]]; then
    git clone --branch "$TEMPLATE_BRANCH" -- "$TEMPLATE_REPOSITORY" "$TARGET_DIRECTORY"
  else
    git clone -- "$TEMPLATE_REPOSITORY" "$TARGET_DIRECTORY"
  fi
}

# 项目创建成功后仅在交互模式调用；依赖安装失败时由 set -e 阻止继续启动开发服务器。
prompt_and_run_pnpm() {
  while true; do
    printf '\n是否执行 pnpm install 和 pnpm dev？[Y/n]\n> ' >&3
    read_from_terminal
    case "$USER_INPUT" in
      "" | y | Y | yes | YES | Yes)
        command -v pnpm >/dev/null 2>&1 ||
          fail "未找到 pnpm；项目已创建，但无法执行 pnpm install 和 pnpm dev。"
        printf '\n正在安装依赖...\n' >&3
        (
          cd "$TARGET_DIRECTORY"
          pnpm install
          printf '\n依赖安装完成，正在启动开发服务器；按 Ctrl+C 可停止。\n'
          pnpm dev
        )
        return 0
        ;;
      n | N | no | NO | No)
        printf '已跳过 pnpm install 和 pnpm dev。\n' >&3
        return 0
        ;;
      *)
        printf '请输入 y 或 n；直接回车表示执行。\n' >&3
        ;;
    esac
  done
}

main() {
  if (($# == 0)); then
    open_interactive_terminal
    validate_runtime_configuration
    collect_interactive_arguments
  else
    parse_arguments "$@"
    validate_project_name || fail "$PROJECT_NAME_ERROR"
    validate_runtime_configuration
  fi

  resolve_target_directory
  validate_target_directory

  if [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]]; then
    confirm_interactive_configuration
  fi

  prepare_target_directory

  clone_template
  apply_project_metadata
  configure_git_repository
  print_result

  if [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]]; then
    prompt_and_run_pnpm
  fi
}

main "$@"
