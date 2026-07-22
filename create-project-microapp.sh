#!/usr/bin/env bash

set -Eeuo pipefail

# 三个模板地址属于脚本维护配置；使用公开 GitHub HTTPS 地址，无需额外认证配置。
readonly PROJECT_SETTINGS_TEMPLATE_REPOSITORY="https://github.com/dayu-sec/web-scaffolds-micro-frontend-project-settings.git"
readonly CONTAINER_TEMPLATE_REPOSITORY="https://github.com/dayu-sec/web-scaffolds-micro-frontend-main-app.git"
readonly MICROAPP_TEMPLATE_REPOSITORY="https://github.com/dayu-sec/web-scaffolds-micro-frontend-micro-app.git"

# 最长派生包名是 project-settings-<name>，为 npm 214 字符上限预留固定前缀长度。
readonly NAME_MAX_LENGTH=197
readonly PROJECT_NAME_FORMAT_RULE="必须使用 kebab-case，只能包含小写字母、数字和单个连字符"
readonly MICROAPP_PATHNAME="app"
readonly MFA_EXTENSION_URL="https://marketplace.visualstudio.com/items?itemName=NicholasHsiang.vscode-seed-fe-mfa"

PROJECT_NAME=""
WORKSPACE_NAME=""
PROJECT_SETTINGS_NAME=""
CONTAINER_NAME=""
MICROAPP_NAME=""
TARGET_DIRECTORY=""
STAGING_DIRECTORY=""
TEMPLATE_BRANCH=""
KEEP_HISTORY=false
INTERACTIVE_TERMINAL_OPEN=false
USER_INPUT=""
PROJECT_NAME_ERROR=""

print_usage() {
  cat <<'EOF'
用法：
  create-project-microapp.sh
  create-project-microapp.sh --name <项目名称> [选项]

交互模式：
  不传任何参数时，脚本会询问项目名称、模板分支和 Git 历史选项，并在创建前展示派生名称供确认。

必填参数：
  --name <名称>              微前端项目名称

可选参数：
  --branch <分支>            指定三个模板仓库的统一分支；默认使用各仓库默认分支
  --keep-history             保留三个模板仓库的 Git 历史
  -h, --help                 显示帮助

名称规则：
  必须使用严格 kebab-case，只能包含小写字母、数字和单个连字符；最多 197 个字符。
  示例：security-center

生成结构：
  <项目名称>-web/
  ├── project/
  ├── container/
  │   └── container-<项目名称>/
  └── microapps/
      └── app-<项目名称>/

默认行为：
  未提供 --branch 时使用三个模板仓库各自的默认分支。
  删除三个模板仓库的 Git 历史并分别初始化新仓库；提供 --keep-history 时保留历史。
  两种模式都会删除模板 origin，且不会创建或验证新的远程仓库。
  脚本不会处理菜单、Sitemap、运行时配置，也不会执行 pnpm install 或 pnpm dev。
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

# 失败或中断时只清理本次 mktemp 创建的暂存目录，最终目录一旦发布便不再由 trap 管理。
cleanup() {
  local exit_code=$?

  trap - EXIT
  set +e
  if [[ -n "$STAGING_DIRECTORY" && -d "$STAGING_DIRECTORY" ]]; then
    rm -rf -- "$STAGING_DIRECTORY"
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
      --name)
        (($# >= 2)) || fail "--name 需要提供值。"
        PROJECT_NAME="$2"
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

  if [[ ! "$PROJECT_NAME" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
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
  [[ -n "$PROJECT_SETTINGS_TEMPLATE_REPOSITORY" ]] ||
    fail "请先配置 PROJECT_SETTINGS_TEMPLATE_REPOSITORY。"
  [[ -n "$CONTAINER_TEMPLATE_REPOSITORY" ]] ||
    fail "请先配置 CONTAINER_TEMPLATE_REPOSITORY。"
  [[ -n "$MICROAPP_TEMPLATE_REPOSITORY" ]] ||
    fail "请先配置 MICROAPP_TEMPLATE_REPOSITORY。"

  local command_name
  for command_name in git jq awk mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少必需命令：${command_name}。"
  done

  validate_template_branch || fail "模板分支名称无效：${TEMPLATE_BRANCH}。"
}

print_non_interactive_guidance() {
  printf '错误：没有传递参数，并且当前环境无法打开交互终端。\n\n' >&2
  print_usage >&2
  cat >&2 <<'EOF'

通过管道非交互执行时，请显式传递参数，例如：
  curl -fsSL <脚本地址> | bash -s -- --name security-center
  wget -qO- <脚本地址> | bash -s -- --name security-center --keep-history
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
  printf '\n创建微前端架构项目\n' >&3

  while true; do
    printf '\n项目名称（必填）：\n规则：最多 %s 个字符；%s。\n示例：security-center\n> ' \
      "$NAME_MAX_LENGTH" "$PROJECT_NAME_FORMAT_RULE" >&3
    read_from_terminal
    PROJECT_NAME="$USER_INPUT"

    if validate_project_name; then
      break
    fi

    printf '输入无效：%s\n' "$PROJECT_NAME_ERROR" >&3
  done

  while true; do
    printf '\n模板分支（三个模板统一使用；可选，直接回车使用各仓库默认分支）：\n> ' >&3
    read_from_terminal
    TEMPLATE_BRANCH="$USER_INPUT"
    if validate_template_branch; then
      break
    fi
    printf '输入无效：模板分支名称无效：%s。\n' "$TEMPLATE_BRANCH" >&3
  done

  while true; do
    printf '\n是否移除三个模板仓库的 Git 历史？[Y/n]\n> ' >&3
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

# 所有架构名称只从项目名派生，避免交互输入形成不一致的宿主、微应用和配置标识。
derive_project_names() {
  WORKSPACE_NAME="${PROJECT_NAME}-web"
  PROJECT_SETTINGS_NAME="project-settings-${PROJECT_NAME}"
  CONTAINER_NAME="container-${PROJECT_NAME}"
  MICROAPP_NAME="app-${PROJECT_NAME}"
  TARGET_DIRECTORY="${PWD}/${WORKSPACE_NAME}"
}

validate_target_directory() {
  [[ ! -e "$TARGET_DIRECTORY" ]] || fail "目标目录已存在，不会覆盖：${TARGET_DIRECTORY}。"
}

confirm_interactive_configuration() {
  printf '\n即将创建微前端架构项目：\n' >&3
  printf '  工作区：%s\n' "$WORKSPACE_NAME" >&3
  printf '  项目配置：%s\n' "$PROJECT_SETTINGS_NAME" >&3
  printf '  主应用：%s\n' "$CONTAINER_NAME" >&3
  printf '  首个微应用：%s\n' "$MICROAPP_NAME" >&3
  printf '  微应用 pathname：%s\n' "$MICROAPP_PATHNAME" >&3
  printf '  目标目录：%s\n' "$TARGET_DIRECTORY" >&3
  printf '  模板分支：%s\n' "${TEMPLATE_BRANCH:-各仓库默认分支}" >&3
  if [[ "$KEEP_HISTORY" == true ]]; then
    printf '  Git 历史：保留，移除模板 origin\n' >&3
  else
    printf '  Git 历史：移除并分别重新初始化\n' >&3
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

# 三个模板由同一发布批次维护；--branch 必须统一选择同名分支，不能产生跨版本组合。
clone_template_repository() {
  local repository="$1"
  local target_directory="$2"

  if [[ -n "$TEMPLATE_BRANCH" ]]; then
    git clone --branch "$TEMPLATE_BRANCH" -- "$repository" "$target_directory"
  else
    git clone -- "$repository" "$target_directory"
  fi
}

# 模板统一克隆到最终目录的同级暂存区，所有校验通过后再一次性发布工作区。
clone_templates() {
  STAGING_DIRECTORY="$(mktemp -d "${PWD}/.${WORKSPACE_NAME}.tmp.XXXXXX")"
  mkdir -p "${STAGING_DIRECTORY}/container" "${STAGING_DIRECTORY}/microapps"

  clone_template_repository "$PROJECT_SETTINGS_TEMPLATE_REPOSITORY" "${STAGING_DIRECTORY}/project"
  clone_template_repository "$CONTAINER_TEMPLATE_REPOSITORY" \
    "${STAGING_DIRECTORY}/container/${CONTAINER_NAME}"
  clone_template_repository "$MICROAPP_TEMPLATE_REPOSITORY" \
    "${STAGING_DIRECTORY}/microapps/${MICROAPP_NAME}"
}

# 将仓库包名和 README 首个一级标题同步为同一应用标识，其余模板内容保持不变。
update_repository_identity() {
  local repository_directory="$1"
  local repository_name="$2"
  local package_json="${repository_directory}/package.json"
  local readme="${repository_directory}/README.md"
  local package_temp_file=""
  local readme_temp_file=""

  [[ -f "$package_json" ]] || fail "模板中缺少 package.json：${repository_directory}。"
  jq -e 'type == "object" and has("name")' "$package_json" >/dev/null ||
    fail "package.json 必须是包含顶层 name 属性的 JSON 对象：${repository_directory}。"

  package_temp_file="$(mktemp "${package_json}.tmp.XXXXXX")"
  cp -p "$package_json" "$package_temp_file"
  jq --arg name "$repository_name" '.name = $name' "$package_json" >"$package_temp_file"
  mv "$package_temp_file" "$package_json"

  [[ -f "$readme" ]] || fail "模板中缺少 README.md：${repository_directory}。"
  readme_temp_file="$(mktemp "${readme}.tmp.XXXXXX")"
  cp -p "$readme" "$readme_temp_file"
  if ! awk -v title="$repository_name" '
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
  ' "$readme" >"$readme_temp_file"; then
    rm -f -- "$readme_temp_file"
    fail "README.md 中没有找到一级标题：${repository_directory}。"
  fi
  mv "$readme_temp_file" "$readme"
}

# meta.json 是装配关系的唯一修改入口；菜单、Sitemap 和生成配置不属于本脚本职责。
update_project_meta() {
  local meta_json="${STAGING_DIRECTORY}/project/meta.json"
  local meta_temp_file=""

  [[ -f "$meta_json" ]] || fail "项目配置模板中缺少 meta.json。"
  jq -e '
    type == "object"
    and (.container | type == "object")
    and (.container.repository | type == "object")
    and (.container.repository.url | type == "string")
    and (.microapps | type == "array" and length > 0)
    and (.microapps[0] | type == "object")
    and (.microapps[0].repository | type == "object")
    and (.microapps[0].repository.url | type == "string")
    and (.preference | type == "object")
  ' "$meta_json" >/dev/null ||
    fail "meta.json 缺少可用的 container、首个 microapp 或 preference 配置。"

  meta_temp_file="$(mktemp "${meta_json}.tmp.XXXXXX")"
  cp -p "$meta_json" "$meta_temp_file"

  # 仅替换 URL 最后一段仓库名，并保留模板 URL 前缀与可选的 .git 后缀。
  if ! jq \
    --arg workspace_name "$WORKSPACE_NAME" \
    --arg container_name "$CONTAINER_NAME" \
    --arg microapp_name "$MICROAPP_NAME" \
    --arg microapp_pathname "$MICROAPP_PATHNAME" '
      def rename_repository($repository_name):
        . as $url
        | if test("/[^/]+(?:\\.git)?$") then
            (endswith(".git")) as $has_git
            | sub(
                "[^/]+(?:\\.git)?$";
                $repository_name + (if $has_git then ".git" else "" end)
              )
          else
            error("仓库 URL 缺少可替换的末级名称")
          end;

      .name = $workspace_name
      | .container.name = $container_name
      | .container.repository.url |= rename_repository($container_name)
      | .microapps = [
          .microapps[0]
          | .name = $microapp_name
          | .pathname = $microapp_pathname
          | .repository.url |= rename_repository($microapp_name)
        ]
      | .preference.default_microapp = $microapp_name
    ' "$meta_json" >"$meta_temp_file"; then
    rm -f -- "$meta_temp_file"
    fail "无法按命名规则更新 meta.json 中的仓库 URL。"
  fi

  jq -e \
    --arg workspace_name "$WORKSPACE_NAME" \
    --arg container_name "$CONTAINER_NAME" \
    --arg microapp_name "$MICROAPP_NAME" \
    --arg microapp_pathname "$MICROAPP_PATHNAME" '
      .name == $workspace_name
      and .container.name == $container_name
      and (.microapps | length == 1)
      and .microapps[0].name == $microapp_name
      and .microapps[0].pathname == $microapp_pathname
      and .preference.default_microapp == $microapp_name
      and .preference.default_microapp == .microapps[0].name
    ' "$meta_temp_file" >/dev/null || {
      rm -f -- "$meta_temp_file"
      fail "meta.json 的默认微应用未与首个微应用同步。"
    }

  mv "$meta_temp_file" "$meta_json"
}

apply_project_metadata() {
  update_repository_identity "${STAGING_DIRECTORY}/project" "$PROJECT_SETTINGS_NAME"
  update_repository_identity \
    "${STAGING_DIRECTORY}/container/${CONTAINER_NAME}" "$CONTAINER_NAME"
  update_repository_identity \
    "${STAGING_DIRECTORY}/microapps/${MICROAPP_NAME}" "$MICROAPP_NAME"
  update_project_meta
}

# 每个目录都是独立 Git 边界；默认重建历史，保留模式也必须解除模板 origin。
configure_git_repository() {
  local repository_directory="$1"

  if [[ "$KEEP_HISTORY" == true ]]; then
    git -C "$repository_directory" remote remove origin
  else
    rm -rf -- "${repository_directory}/.git"
    git -C "$repository_directory" init -q
  fi
}

configure_git_repositories() {
  configure_git_repository "${STAGING_DIRECTORY}/project"
  configure_git_repository "${STAGING_DIRECTORY}/container/${CONTAINER_NAME}"
  configure_git_repository "${STAGING_DIRECTORY}/microapps/${MICROAPP_NAME}"
}

# 暂存区与最终目录位于同一父目录，mv 成功即表示完整工作区已经发布。
publish_workspace() {
  mv -- "$STAGING_DIRECTORY" "$TARGET_DIRECTORY"
  STAGING_DIRECTORY=""
}

print_result() {
  printf '\n微前端架构项目已创建：%s\n' "$TARGET_DIRECTORY"
  printf '模板分支：%s\n' "${TEMPLATE_BRANCH:-各仓库默认分支}"
  printf '项目配置：project/（%s）\n' "$PROJECT_SETTINGS_NAME"
  printf '主应用：container/%s\n' "$CONTAINER_NAME"
  printf '首个微应用：microapps/%s\n' "$MICROAPP_NAME"
  printf '默认微应用：%s\n' "$MICROAPP_NAME"
  if [[ "$KEEP_HISTORY" == true ]]; then
    printf 'Git 历史：已保留，模板 origin 已移除\n'
  else
    printf 'Git 历史：已移除并分别重新初始化\n'
  fi
  printf '\n下一步：请安装 Seed FE MFA VS Code 扩展，并使用扩展完成项目配置生成和开发启动。\n'
  printf '%s\n' "$MFA_EXTENSION_URL"
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

  derive_project_names
  validate_target_directory

  if [[ "$INTERACTIVE_TERMINAL_OPEN" == true ]]; then
    confirm_interactive_configuration
  fi

  clone_templates
  apply_project_metadata
  configure_git_repositories
  publish_workspace
  print_result
}

main "$@"
