#!/bin/bash

# Scrutiny Collector 飞牛应用 - 多架构打包脚本
# 支持 x86 (amd64) 和 arm (arm64) 架构
# 使用 fnpack 官方工具打包

set -e

# 配置
SCRUTINY_VERSION="1.23.2"
FNPACK_VERSION="1.2.1"

# Collector 下载 URL 模板
COLLECTOR_URL_AMD64="https://github.com/Starosdev/scrutiny/releases/download/v${SCRUTINY_VERSION}/scrutiny-collector-metrics-linux-amd64"
COLLECTOR_URL_ARM64="https://github.com/Starosdev/scrutiny/releases/download/v${SCRUTINY_VERSION}/scrutiny-collector-metrics-linux-arm64"

# fnpack 下载 URL（根据当前系统自动选择）
detect_fnpack_url() {
    local os arch
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux)  os="linux" ;;
        *)      log_error "不支持的操作系统: $(uname -s)"; exit 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)   arch="amd64" ;;
        aarch64|arm64)  arch="arm64" ;;
        *)              log_error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
    echo "https://static2.fnnas.com/fnpack/fnpack-${FNPACK_VERSION}-${os}-${arch}"
}

# 脚本所在目录（即项目根目录）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FNPACK="${SCRIPT_DIR}/fnpack"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查并安装 fnpack
ensure_fnpack() {
    if [ -f "${FNPACK}" ]; then
        log_info "fnpack 已存在: ${FNPACK}"
        return
    fi

    local url
    url=$(detect_fnpack_url)
    log_info "下载 fnpack: ${url}"
    curl -fsSL "${url}" -o "${FNPACK}"
    chmod +x "${FNPACK}"
    log_info "fnpack 下载完成"
}

# 检查依赖
check_dependencies() {
    log_info "检查依赖..."

    if ! command -v curl &> /dev/null; then
        log_error "curl 未安装"
        exit 1
    fi

    ensure_fnpack
    log_info "依赖检查通过"
}

# 校验二进制文件有效性
verify_binary() {
    local file=$1
    if [ ! -f "$file" ]; then
        return 1
    fi
    # 检查文件大小 > 1MB（collector 二进制通常数 MB）
    local size
    size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
    if [ "$size" -lt 1048576 ]; then
        log_warn "文件异常：$(basename "$file") 仅 ${size} 字节"
        return 1
    fi
    # 检查 ELF 魔数（Linux 可执行文件）
    if ! head -c4 "$file" 2>/dev/null | grep -q "ELF"; then
        log_warn "文件异常：$(basename "$file") 不是有效的 ELF 二进制"
        return 1
    fi
    return 0
}

# 下载 Collector 二进制
download_collector() {
    local arch=$1
    local url=$2
    local filename="scrutiny-collector-metrics-linux-${arch}"

    log_info "下载 Scrutiny Collector ${SCRUTINY_VERSION} (${arch})..."

    # 使用缓存但校验有效性
    if [ -f "/tmp/${filename}" ] && verify_binary "/tmp/${filename}"; then
        log_info "使用已验证的缓存: /tmp/${filename}"
    else
        rm -f "/tmp/${filename}"
        log_info "下载: ${url}"
        curl -fsSL "${url}" -o "/tmp/${filename}"
        if ! verify_binary "/tmp/${filename}"; then
            log_error "下载的文件校验失败: /tmp/${filename}"
            rm -f "/tmp/${filename}"
            exit 1
        fi
    fi

    # 复制到 app/bin
    mkdir -p "${SCRIPT_DIR}/app/bin"
    cp "/tmp/${filename}" "${SCRIPT_DIR}/app/bin/scrutiny-collector-metrics"
    chmod +x "${SCRIPT_DIR}/app/bin/scrutiny-collector-metrics"

    log_info "Collector 二进制已就位: app/bin/scrutiny-collector-metrics"
}

# 更新 manifest 平台和版本
update_manifest() {
    local platform=$1

    log_info "更新 manifest: platform=${platform}, version=${SCRUTINY_VERSION}"

    local manifest="${SCRIPT_DIR}/manifest"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/^platform[[:space:]]*=.*/platform              = ${platform}/" "${manifest}"
        sed -i '' "s/^version[[:space:]]*=.*/version               = ${SCRUTINY_VERSION}/" "${manifest}"
    else
        sed -i "s/^platform[[:space:]]*=.*/platform              = ${platform}/" "${manifest}"
        sed -i "s/^version[[:space:]]*=.*/version               = ${SCRUTINY_VERSION}/" "${manifest}"
    fi
}

# 构建单个架构
build_arch() {
    local arch=$1       # amd64 / arm64
    local platform=$2   # x86 / arm（fnOS manifest 中的值）
    local url=$3

    log_info "=========================================="
    log_info "构建 ${arch} (${platform}) 版本"
    log_info "=========================================="

    # 下载并安装二进制
    download_collector "${arch}" "${url}"

    # 更新 manifest
    update_manifest "${platform}"

    # 使用 fnpack 打包
    log_info "使用 fnpack 打包..."
    cd "${SCRIPT_DIR}"
    ${FNPACK} build

    # 重命名输出文件以区分架构
    local output_file="${SCRIPT_DIR}/starosdev.scrutiny.collector.fpk"
    local target_file="${SCRIPT_DIR}/starosdev.scrutiny.collector_${SCRUTINY_VERSION}_${platform}.fpk"

    if [ -f "${output_file}" ]; then
        mv "${output_file}" "${target_file}"
        log_info "打包完成: $(basename "${target_file}")"
        ls -lh "${target_file}"
    else
        log_error "打包失败，未找到输出文件"
        exit 1
    fi

    echo ""
}

# 清理
cleanup() {
    log_info "清理临时文件..."
    rm -f "${SCRIPT_DIR}/app/bin/scrutiny-collector-metrics"
}

# 显示帮助
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  all       构建所有架构 (x86 + arm)"
    echo "  amd64     仅构建 x86 (amd64)"
    echo "  arm64     仅构建 arm (arm64)"
    echo "  clean     清理缓存和临时文件"
    echo "  help      显示帮助"
    echo ""
    echo "示例:"
    echo "  $0 all       # 构建双架构"
    echo "  $0 amd64     # 仅构建 x86"
    echo "  $0 arm64     # 仅构建 arm"
    echo ""
}

# 主函数
main() {
    local target=${1:-"all"}

    case "$target" in
        all)
            check_dependencies
            build_arch "amd64" "x86" "${COLLECTOR_URL_AMD64}"
            build_arch "arm64" "arm" "${COLLECTOR_URL_ARM64}"
            cleanup
            log_info "=========================================="
            log_info "所有架构打包完成！"
            log_info "=========================================="
            ls -lh "${SCRIPT_DIR}"/starosdev.scrutiny.collector_*.fpk
            ;;
        amd64|x86)
            check_dependencies
            build_arch "amd64" "x86" "${COLLECTOR_URL_AMD64}"
            cleanup
            ;;
        arm64|arm)
            check_dependencies
            build_arch "arm64" "arm" "${COLLECTOR_URL_ARM64}"
            cleanup
            ;;
        clean)
            cleanup
            rm -f /tmp/scrutiny-collector-metrics-linux-*
            rm -f "${SCRIPT_DIR}"/starosdev.scrutiny.collector*.fpk
            log_info "清理完成"
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            log_error "未知选项: $target"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
