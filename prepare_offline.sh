#!/bin/bash
set -e

#########################################
# 用户配置区
#########################################

WORKDIR="/root/kubespray-offline"
KUBESPRAY_VERSION="v2.29.0"
K8S_VERSION="1.32.9"
MAX_RETRY_ATTEMPTS=3
PARALLEL_JOBS=5

#########################################
# 工具函数
#########################################

# 日志函数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查文件是否存在
check_file_exists() {
    if [ ! -f "$1" ]; then
        log_error "文件不存在: $1"
        return 1
    fi
    return 0
}

# 重试函数
retry() {
    local retries=$1
    local command="${@:2}"
    local attempt=1

    while [ $attempt -le $retries ]; do
        log_info "执行命令 (尝试 $attempt/$retries): $command"
        if eval "$command"; then
            return 0
        else
            log_warn "命令执行失败 (尝试 $attempt/$retries)"
            if [ $attempt -lt $retries ]; then
                sleep $((attempt * 2))
            fi
            attempt=$((attempt + 1))
        fi
    done

    log_error "命令执行失败，已达到最大重试次数: $command"
    return 1
}

# 检查支持的容器运行时
check_container_runtime() {

    if command_exists docker; then
        # 检查Docker服务是否运行
        if docker info >/dev/null 2>&1; then
            CONTAINER_RUNTIME="docker"
            return 0
        else
            log_warn "Docker命令存在但服务未运行，尝试其他运行时"
        fi
    fi

    if command_exists ctr; then
        # 检查containerd是否可用
        if ctr version >/dev/null 2>&1; then
            CONTAINER_RUNTIME="containerd"
            return 0
        else
            log_warn "ctr命令存在但不可用"
        fi
    fi



    if command_exists podman; then
        # 检查Podman是否可用
        if podman info >/dev/null 2>&1; then
            CONTAINER_RUNTIME="podman"
            return 0
        else
            log_warn "Podman命令存在但不可用，尝试其他运行时"
        fi
    fi

    if command_exists nerdctl; then
        # 检查nerdctl是否可用
        if nerdctl version >/dev/null 2>&1; then
            CONTAINER_RUNTIME="nerdctl"
            return 0
        else
            log_warn "nerdctl命令存在但不可用，尝试其他运行时"
        fi
    fi

    log_error "未找到可用的容器运行时 (docker, podman, nerdctl, containerd)"
    return 1
}

# 检查Python版本
check_python_version() {
    # 检查特定版本范围 (3.10-3.13)
    for version in 3.13 3.12 3.11 3.10; do
        if command_exists python${version}; then
            # 检查版本是否满足要求
            local python_version=$(python${version} --version 2>&1 | cut -d' ' -f2)
            log_info "检测到Python版本: $python_version"
            # 设置全局变量存储版本号
            PYTHON_CMD="python${version}"
            return 0
        fi
    done

    # 检查通用python3命令
    if command_exists python3; then
        local python_version=$(python3 --version 2>&1 | cut -d' ' -f2)
        # 提取主版本号和次版本号（只保留前两位）
        local major_version=$(echo $python_version | cut -d'.' -f1)
        local minor_version=$(echo $python_version | cut -d'.' -f2)
        local short_version="${major_version}.${minor_version}"

        # 检查版本是否在3.10-3.13范围内
        if [ "$major_version" -eq 3 ] && [ "$minor_version" -ge 10 ] && [ "$minor_version" -le 13 ]; then
            log_info "检测到Python版本: $python_version"
            # 设置全局变量存储版本号
            PYTHON_CMD="python${short_version}"
            return 0
        else
            log_warn "检测到Python版本 $python_version，不在要求的3.10-3.13范围内"
        fi
    fi

    log_error "未找到符合要求的Python版本 (3.10-3.13)"
    return 1
}

# 清理函数
cleanup() {
    log_info "清理临时文件和资源..."
    # 可以在这里添加清理逻辑
    # 例如：删除临时目录、停止临时容器等
}

# 信号处理
trap cleanup EXIT

#########################################
# 环境检查
#########################################
log_info "=== [0/8] 环境检查 ==="

check_container_runtime
check_python_version

# 检查必要命令
required_commands=("git" "curl")
for cmd in "${required_commands[@]}"; do
    if ! command_exists "$cmd"; then
        log_error "缺少必要命令: $cmd，请先安装"
        exit 1
    fi
done

# 检查工作目录
mkdir -p ${WORKDIR}/{images,pip,rpm,deb}
log_info "工作目录已创建: ${WORKDIR}"

log_info "环境检查通过"

#########################################
# 1. 拉取 Kubespray 源码
#########################################
log_info "=== [1/8] 拉取 Kubespray 源码 ==="

if [ ! -d "${WORKDIR}/kubespray" ]; then
    log_info "克隆 Kubespray 源码..."
    if ! retry $MAX_RETRY_ATTEMPTS "git clone -b ${KUBESPRAY_VERSION} https://github.com/kubernetes-sigs/kubespray.git ${WORKDIR}/kubespray"; then
        log_error "克隆 Kubespray 源码失败"
        exit 1
    fi
else
    log_info "源码已存在，尝试更新..."
    cd ${WORKDIR}/kubespray
    if ! retry $MAX_RETRY_ATTEMPTS "git fetch --all"; then
        log_warn "获取最新代码失败，继续使用现有代码"
    else
        if ! git checkout ${KUBESPRAY_VERSION}; then
            log_warn "切换到版本 ${KUBESPRAY_VERSION} 失败"
        fi
        if ! git pull || true; then
            log_warn "更新代码失败，继续使用现有代码"
        fi
    fi
fi

cd ${WORKDIR}/kubespray

#########################################
# 2. 创建 Python 虚拟环境并下载依赖
#########################################
log_info "=== [2/8] 创建 Python 虚拟环境并下载依赖 ${PYTHON_CMD} ==="

if [ ! -d "venv" ]; then
    log_info "创建 Python 虚拟环境..."

    if ! ${PYTHON_CMD} -m venv venv; then
        log_error "创建 Python 虚拟环境失败"
        exit 1
    fi
fi

log_info "激活虚拟环境并安装依赖..."
if ! source venv/bin/activate; then
    log_error "激活虚拟环境失败"
    exit 1
fi

# 验证虚拟环境是否激活
if [ -z "$VIRTUAL_ENV" ]; then
    log_warn "虚拟环境可能未正确激活"
fi

if ! check_file_exists "requirements.txt"; then
    log_error "requirements.txt 文件不存在"
    exit 1
fi

# 安装依赖
if ! retry $MAX_RETRY_ATTEMPTS "pip install -r requirements.txt"; then
    log_error "安装 Python 依赖失败"
    exit 1
fi

# 下载依赖包
if ! retry $MAX_RETRY_ATTEMPTS "pip download -r requirements.txt -d ${WORKDIR}/pip"; then
    log_error "下载 Python 依赖包失败"
    exit 1
fi

#########################################
# 3. 跳过 inventory 初始化
#########################################
log_info "=== [3/8] 跳过 inventory 初始化 ==="
log_info "inventory 初始化将在部署阶段进行"

#########################################
# 4. 生成镜像和文件清单并下载
#########################################
log_info "=== [4/8] 生成镜像和文件清单并下载 ==="

# 使用 Kubespray 官方方法生成镜像和文件清单
if check_file_exists "contrib/offline/generate_list.sh"; then
    log_info "使用 Kubespray 官方脚本生成镜像和文件清单..."

    # 确保 contrib/offline/temp 目录存在
    mkdir -p contrib/offline/temp

    # 执行 Kubespray 官方脚本生成镜像和文件清单，传入指定版本的inventory
    if bash contrib/offline/generate_list.sh -e kube_version=${K8S_VERSION} ; then
        # 检查生成的清单文件
        if [ -s "contrib/offline/temp/images.list" ]; then
            log_info "成功生成镜像清单: $(wc -l < contrib/offline/temp/images.list) 个镜像"
            # 设置环境变量指向镜像清单文件
            export IMAGES_FROM_FILE="${WORKDIR}/kubespray/contrib/offline/temp/images.list"
            cd ${WORKDIR}/kubespray/contrib/offline
            # 执行官方脚本创建镜像tar包
            if sh ./manage-offline-container-images.sh create; then
                log_info "✅ 成功使用官方脚本创建镜像tar包"
                # 验证镜像包是否创建成功
                if [ -f "container-images.tar.gz" ]; then
                    log_info "容器镜像包验证通过"
                else
                    log_warn "容器镜像包可能未正确创建"
                fi
            else
                log_error "官方脚本执行失败"
            fi
            sudo ${CONTAINER_RUNTIME} save -o registry-latest.tar registry:latest
            cd ${WORKDIR}/kubespray
        else
            log_warn "未生成有效的镜像清单"
        fi
        if [ -s "contrib/offline/temp/files.list" ]; then
            log_info "成功生成文件清单: $(wc -l < contrib/offline/temp/files.list) 个文件"
            # 设置环境变量指向文件清单文件
            export FILES_LIST="${WORKDIR}/kubespray/contrib/offline/temp/files.list"
            export NO_HTTP_SERVER="true"  # 不启动HTTP服务器
            cd ${WORKDIR}/kubespray/contrib/offline
            # 执行官方脚本下载文件
            if sh ./manage-offline-files.sh; then
                log_info "✅ 成功使用官方脚本下载文件"
                # 验证文件是否下载成功
                if [ -d "offline-files" ] && [ -n "$(ls -A offline-files)" ]; then
                    log_info "离线文件下载验证通过"
                else
                    log_warn "离线文件可能未正确下载"
                fi
            else
                log_error "官方脚本执行失败"
            fi
            cd ${WORKDIR}/kubespray
        else
            log_warn "未生成有效的文件清单"
        fi
    else
        log_error "Kubespray 官方脚本执行失败"
    fi
else
    log_warn "未找到 Kubespray 官方的 generate_list.sh 脚本"
fi

#########################################
# 5. 下载系统依赖包
#########################################
log_info "=== [5/8] 下载系统依赖包 ==="

# 初始化依赖包目录状态
DEB_PACKAGES_DOWNLOADED=false
RPM_PACKAGES_DOWNLOADED=false

if [ -f /etc/debian_version ]; then
    log_info "检测到 Debian/Ubuntu 系统"
    if command_exists apt-get; then
        if retry $MAX_RETRY_ATTEMPTS "apt-get update"; then
            mkdir -p /tmp/apt-cache
            if retry $MAX_RETRY_ATTEMPTS "apt-get install --download-only -y python3 python3-pip conntrack socat ebtables ethtool ipset ipvsadm chrony nfs-common curl rsync tar unzip xfsprogs libseccomp2 gnupg"; then
                if [ -d "/var/cache/apt/archives" ]; then
                    cp /var/cache/apt/archives/*.deb ${WORKDIR}/deb/ 2>/dev/null || true
                    if [ -n "$(ls -A ${WORKDIR}/deb/*.deb 2>/dev/null)" ]; then
                        DEB_PACKAGES_DOWNLOADED=true
                        log_info "Debian/Ubuntu 依赖包下载完成"
                    else
                        log_warn "未找到下载的 Debian/Ubuntu 依赖包"
                    fi
                else
                    log_warn "未找到 apt 缓存目录"
                fi
            else
                log_error "下载 Debian/Ubuntu 依赖包失败"
            fi
        else
            log_error "更新 apt 包列表失败"
        fi
    else
        log_warn "apt-get 命令不存在，跳过 Debian/Ubuntu 依赖包下载"
    fi
elif [ -f /etc/redhat-release ]; then
    log_info "检测到 RedHat/CentOS 系统"
    if command_exists yum; then
        # 安装EPEL仓库以获取更多包
        if ! rpm -q epel-release >/dev/null 2>&1; then
            if retry $MAX_RETRY_ATTEMPTS "yum install -y epel-release"; then
                log_info "EPEL仓库安装完成"
            else
                log_warn "EPEL仓库安装失败，某些包可能无法下载"
            fi
        fi

        # 下载完整的RPM包列表
        if retry $MAX_RETRY_ATTEMPTS "yum install --downloadonly --downloaddir=${WORKDIR}/rpm -y python3 python3-pip conntrack-tools socat ebtables ethtool ipset ipvsadm chrony nfs-utils curl rsync tar unzip xfsprogs device-mapper-libs libseccomp nss openssl"; then
            if [ -n "$(ls -A ${WORKDIR}/rpm/*.rpm 2>/dev/null)" ]; then
                RPM_PACKAGES_DOWNLOADED=true
                log_info "RedHat/CentOS 依赖包下载完成"
            else
                log_warn "未找到下载的 RedHat/CentOS 依赖包"
            fi
        else
            log_error "下载 RedHat/CentOS 依赖包失败"
        fi
    else
        log_warn "yum 命令不存在，跳过 RedHat/CentOS 依赖包下载"
    fi
else
    log_warn "未知系统类型，跳过系统依赖包下载"
fi

#########################################
# 6. 创建离线部署说明文档
#########################################
log_info "=== [6/8] 创建离线部署说明文档 ==="

cat > ${WORKDIR}/OFFLINE_DEPLOYMENT_GUIDE.md <<EOF
# Kubespray 离线部署指南

## 离线资源包说明

本离线资源包包含部署 Kubernetes 集群所需的所有资源：

1. Kubespray 源码 (${KUBESPRAY_VERSION})
2. Python 虚拟环境及依赖包
3. 容器镜像包 (container-images.tar.gz)
4. 二进制文件 (通过 manage-offline-files.sh 下载)
5. 系统依赖包 (RPM/DEB)

## 部署步骤

1. 将此离线资源包传输到目标离线环境
2. 解压资源包: \`tar xzf kubespray-offline-${KUBESPRAY_VERSION}.tar.gz\`
3. 根据实际环境修改 inventory 配置
4. 启动本地镜像仓库和文件服务器
5. 执行部署脚本

## 目录结构

\`\`\`
kubespray-offline/
├── kubespray/                 # Kubespray 源码
├── pip/                       # Python 依赖包
├── rpm/                       # RedHat/CentOS 系统依赖包
├── deb/                       # Debian/Ubuntu 系统依赖包
├── offline-files.tar.gz       # 二进制文件压缩包
└── container-images.tar.gz    # 容器镜像包
└── registry-latest.tar        # 容器镜像包(docker registry)
\`\`\`

## 注意事项

1. 确保目标环境已安装必要的基础软件 (Python, SSH等)
2. 根据目标环境的操作系统类型安装对应的系统依赖包
3. 部署前请检查 inventory 配置是否符合实际环境
EOF

log_info "离线部署说明文档已创建: ${WORKDIR}/OFFLINE_DEPLOYMENT_GUIDE.md"

#########################################
# 7. 打包离线资源
#########################################
log_info "=== [7/8] 打包离线资源 ==="

cd ${WORKDIR}

# 创建打包列表
package_list="kubespray pip"


if [ "$RPM_PACKAGES_DOWNLOADED" = true ] && [ -n "$(ls -A rpm/*.rpm 2>/dev/null)" ]; then
    package_list="$package_list rpm"
    log_info "包含 RPM 依赖包"
fi

if [ "$DEB_PACKAGES_DOWNLOADED" = true ] && [ -n "$(ls -A deb/*.deb 2>/dev/null)" ]; then
    package_list="$package_list deb"
    log_info "包含 DEB 依赖包"
fi

# 添加部署说明文档
if [ -f "OFFLINE_DEPLOYMENT_GUIDE.md" ]; then
    package_list="$package_list OFFLINE_DEPLOYMENT_GUIDE.md"
    log_info "包含部署说明文档"
fi

# 打包
package_name="kubespray-offline-${KUBESPRAY_VERSION}.tar.gz"
if tar czf "$package_name" $package_list; then
    log_info "✅ 离线资源包已生成: ${WORKDIR}/$package_name"
    # 显示打包内容统计
    log_info "打包内容统计:"
    log_info "  - Kubespray 源码: $(du -sh kubespray | cut -f1)"
    log_info "  - Python 依赖: $(du -sh pip | cut -f1)"
    if [ -f "kubespray/contrib/offline/container-images.tar.gz" ]; then
        log_info "  - 容器镜像包: $(du -sh kubespray/contrib/offline/container-images.tar.gz | cut -f1)"
    fi
    if [ -f "kubespray/contrib/offline/offline-files.tar.gz" ]; then
        log_info "  - 离线文件压缩包: $(du -sh kubespray/contrib/offline/offline-files.tar.gz | cut -f1)"
    fi
    if [ "$RPM_PACKAGES_DOWNLOADED" = true ]; then
        log_info "  - RPM 依赖包: $(du -sh rpm | cut -f1)"
    fi
    if [ "$DEB_PACKAGES_DOWNLOADED" = true ]; then
        log_info "  - DEB 依赖包: $(du -sh deb | cut -f1)"
    fi
else
    log_error "打包离线资源失败"
    exit 1
fi

#########################################
# 8. 清理临时文件
#########################################
log_info "=== [8/8] 离线资源准备完成 ==="
log_info "离线安装包已生成: ${WORKDIR}/$package_name"
log_info "部署说明文档: ${WORKDIR}/OFFLINE_DEPLOYMENT_GUIDE.md"