#!/bin/bash
set -e

#########################################
# Kubespray 离线安装脚本
#
# 用途: 在没有互联网连接的环境中部署Kubernetes集群
# 要求:
#   1. 已经使用prepare脚本生成了离线资源包
#   2. 目标节点可以通过SSH访问
#   3. 本地机器可以访问目标节点
#
# 使用方法:
#   1. 修改用户配置区中的参数
#   2. 确保离线资源包已放置在指定位置
#   3. 运行脚本: ./install_offline_v1.sh
#
# 注意事项:
#   - 请确保所有目标节点都已正确配置网络和SSH访问
#   - 脚本将在目标节点上安装系统依赖包，请确保有足够的磁盘空间
#   - 部署过程可能需要较长时间，请耐心等待
#########################################

#########################################
# 用户配置区
#########################################

# Kubernetes集群节点IP地址配置
# CONTROL_PLANE_NODES数组中的IP地址将作为控制平面节点
# WORKER_NODES数组中的IP地址将作为工作节点
# 请根据实际环境修改这些IP地址
CONTROL_PLANE_NODES=("192.168.85.128" )
WORKER_NODES=()

# SSH连接密码
# 用于连接到目标节点的root用户密码
# 请根据实际环境修改此密码
SSH_PASSWORD="123456"

# 本地工作目录
# 用于存放Kubespray源码和离线资源包的本地目录
WORKDIR="/root/kubespray-offline"

# Kubespray版本
# 要使用的Kubespray版本号
KUBESPRAY_VERSION="v2.29.0"
K8S_VERSION="1.32.9"
# 远程工作目录
# 在目标节点上存放Kubespray源码和离线资源包的目录
REMOTE_WORKDIR="/root/kubespray-offline"

# 本地服务配置
# 本地镜像仓库和文件服务器的IP地址和端口
# 这些服务将在部署过程中启动，用于提供离线资源
LOCAL_REGISTRY_IP="192.168.85.161"
LOCAL_REGISTRY_PORT="5000"
LOCAL_FILE_SERVER_IP="192.168.85.161"
LOCAL_FILE_SERVER_PORT="8080"

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

# 检查目录是否存在
check_dir_exists() {
    if [ ! -d "$1" ]; then
        log_error "目录不存在: $1"
        return 1
    fi
    return 0
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

# SSH免密配置函数
setup_ssh_keyless() {
    log_info "=== 配置SSH免密登录 ==="

    # 生成SSH密钥对（如果不存在）
    if [ ! -f ~/.ssh/id_rsa ]; then
        log_info "生成SSH密钥对..."
        ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N "" -C "kubespray-offline@$(hostname)"
    fi

    # 获取公钥内容
    local public_key=$(cat ~/.ssh/id_rsa.pub)

    # 为目标节点配置SSH免密登录
    local all_nodes=("${CONTROL_PLANE_NODES[@]}" "${WORKER_NODES[@]}")

    for node_ip in "${all_nodes[@]}"; do
        log_info "为节点 ${node_ip} 配置SSH免密登录..."

        # 使用sshpass将公钥复制到远程节点
        sshpass -p "${SSH_PASSWORD}" ssh -o StrictHostKeyChecking=no root@${node_ip} "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

        # 检查公钥是否已存在
        local key_exists=$(sshpass -p "${SSH_PASSWORD}" ssh -o StrictHostKeyChecking=no root@${node_ip} "grep '${public_key}' ~/.ssh/authorized_keys || echo 'KEY_NOT_FOUND'")

        if [[ "$key_exists" == *"KEY_NOT_FOUND"* ]]; then
            # 添加公钥到authorized_keys
            echo "${public_key}" | sshpass -p "${SSH_PASSWORD}" ssh -o StrictHostKeyChecking=no root@${node_ip} "cat >> ~/.ssh/authorized_keys"
            sshpass -p "${SSH_PASSWORD}" ssh -o StrictHostKeyChecking=no root@${node_ip} "chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
            log_info "✅ 已为节点 ${node_ip} 配置SSH免密登录"
        else
            log_info "✅ 节点 ${node_ip} 已配置SSH免密登录"
        fi

        # 测试SSH连接
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@${node_ip} "echo 'SSH连接测试成功'"; then
            log_info "✅ SSH免密连接测试成功: ${node_ip}"
        else
            log_error "❌ SSH免密连接测试失败: ${node_ip}"
            return 1
        fi
    done

    log_info "SSH免密配置完成"
    return 0
}

#########################################
# 环境检查
#########################################
log_info "=== [1/9] 环境检查 ==="

# 检查Python版本
check_python_version() {
    # 检查特定版本范围 (3.10-3.13)
    for version in 3.13 3.12 3.11 3.10; do
        if command_exists python${version}; then
            # 检查版本是否满足要求
            local python_version=$(python${version} --version 2>&1 | cut -d' ' -f2)
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

# 检查必要命令（除了Python）
required_commands=("ssh" "scp" "sshpass")
for cmd in "${required_commands[@]}"; do
    if ! command_exists "$cmd"; then
        log_error "缺少必要命令: $cmd，请先安装"
        exit 1
    fi
done

# 检查Python版本
check_python_version
log_info "检测到Python版本: ${PYTHON_CMD}"

# 检查容器运行时
check_container_runtime

log_info "检测到容器运行时: ${CONTAINER_RUNTIME}"

# 检查工作目录
if ! check_dir_exists "${WORKDIR}"; then
    log_error "工作目录不存在: ${WORKDIR}"
    exit 1
fi

# 检查离线资源包
OFFLINE_PACKAGE="${WORKDIR}/kubespray-offline-${KUBESPRAY_VERSION}.tar.gz"
if ! check_file_exists "${OFFLINE_PACKAGE}"; then
    log_error "离线资源包不存在: ${OFFLINE_PACKAGE}"
    exit 1
fi

log_info "环境检查通过"

#########################################
# 2. SSH免密配置
#########################################
log_info "=== [2/9] SSH免密配置 ==="

if ! setup_ssh_keyless; then
    log_error "SSH免密配置失败"
    exit 1
fi

#########################################
# 3. 启动本地服务
#########################################
log_info "=== [3/9] 启动本地服务 ==="

cd ${WORKDIR}

# 解压离线资源包
log_info "解压离线资源包..."
tar xzf ${OFFLINE_PACKAGE}

#########################################
# 4. 注册容器镜像
#########################################
log_info "=== [4/9] 注册容器镜像 ==="

# 注册容器镜像到本地Registry
cd ${WORKDIR}/kubespray/contrib/offline

# 注册镜像
if [ -f "container-images.tar.gz" ]; then
    sudo ${CONTAINER_RUNTIME} load -i registry-latest.tar
    set +e
    sudo ${CONTAINER_RUNTIME} container inspect registry >/dev/null 2>&1
    if [ $? -ne 0 ]; then
      sudo ${CONTAINER_RUNTIME} run --restart=always -d -p "${LOCAL_REGISTRY_PORT}":"${LOCAL_REGISTRY_PORT}" --name registry registry:latest
    fi
    set -e
    export DESTINATION_REGISTRY="${LOCAL_REGISTRY_IP}:${LOCAL_REGISTRY_PORT}"

    if ./manage-offline-container-images.sh register; then
        log_info "容器镜像注册完成"
    else
        log_error "容器镜像注册失败"
        exit 1
    fi
else
    log_warn "未找到container-images.tar.gz，跳过镜像注册"
fi

cd ${WORKDIR}/kubespray

log_info "容器镜像注册完成"

# 启动本地文件服务器
log_info "启动本地文件服务器..."
if [ -d "contrib/offline/offline-files" ]; then
    # 从images.list中提取nginx镜像标签
    NGINX_IMAGE_TAG=""
    if [ -f "contrib/offline/temp/images.list" ]; then
        NGINX_IMAGE_TAG=$(grep "docker.io/library/nginx:" contrib/offline/temp/images.list | head -1 | awk -F'[/:]' '{print $4}')
    fi

    # 如果没有找到nginx镜像标签，则使用默认值
    if [ -z "$NGINX_IMAGE_TAG" ]; then
        NGINX_IMAGE_TAG="1.28.0-alpine"
        log_warn "未在images.list中找到nginx镜像，使用默认标签: $NGINX_IMAGE_TAG"
    else
        log_info "从images.list中提取到nginx镜像标签: $NGINX_IMAGE_TAG"
    fi

    # 检查nginx镜像是否已存在，如果不存在则从本地registry拉取
    if ! ${CONTAINER_RUNTIME} inspect nginx:${NGINX_IMAGE_TAG} >/dev/null 2>&1; then
        log_info "从本地registry拉取nginx镜像..."
        # 尝试从本地registry拉取nginx镜像
        ${CONTAINER_RUNTIME} pull localhost:${LOCAL_REGISTRY_PORT}/nginx:${NGINX_IMAGE_TAG} 2>/dev/null || {
            # 如果从registry拉取失败，则尝试直接拉取
            ${CONTAINER_RUNTIME} pull nginx:${NGINX_IMAGE_TAG} 2>/dev/null || {
                log_warn "无法拉取nginx镜像，可能无法启动文件服务器"
            }
        }
    fi

    # 启动nginx容器
    ${CONTAINER_RUNTIME} run -d -p ${LOCAL_FILE_SERVER_PORT}:80 --name nginx \
        -v ${WORKDIR}/kubespray/contrib/offline/offline-files:/usr/share/nginx/html/download \
        nginx:${NGINX_IMAGE_TAG} 2>/dev/null || {
        log_info "本地文件服务器已在运行"
    }
else
    log_warn "未找到offline-files目录，跳过文件服务器启动"
fi

#########################################
# 5. 配置inventory
#########################################
log_info "=== [5/9] 配置inventory ==="

cd ${WORKDIR}/kubespray

# 创建自定义inventory
if [ -d "inventory/mycluster" ]; then
    rm -rf inventory/mycluster
fi

cp -rf inventory/sample inventory/mycluster

# 生成 hosts.yaml
log_info "生成 hosts.yaml..."
cat > inventory/mycluster/hosts.yaml <<EOF
all:
  hosts:
EOF

# 添加控制平面节点配置
for i in "${!CONTROL_PLANE_NODES[@]}"; do
    NODE_NAME="node$((i+1))"
    NODE_IP="${CONTROL_PLANE_NODES[$i]}"
    cat >> inventory/mycluster/hosts.yaml <<EOF
    ${NODE_NAME}:
      ansible_host: ${NODE_IP}
      ip: ${NODE_IP}
EOF
done

# 添加工作节点配置
for i in "${!WORKER_NODES[@]}"; do
    NODE_INDEX=$(( ${#CONTROL_PLANE_NODES[@]} + i + 1 ))
    NODE_NAME="node${NODE_INDEX}"
    NODE_IP="${WORKER_NODES[$i]}"
    cat >> inventory/mycluster/hosts.yaml <<EOF
    ${NODE_NAME}:
      ansible_host: ${NODE_IP}
      ip: ${NODE_IP}
EOF
done

# 添加组配置
cat >> inventory/mycluster/hosts.yaml <<EOF
  children:
    kube_control_plane:
      hosts:
EOF

# 添加控制平面节点到kube_control_plane组
for i in "${!CONTROL_PLANE_NODES[@]}"; do
    NODE_NAME="node$((i+1))"
    echo "        ${NODE_NAME}:" >> inventory/mycluster/hosts.yaml
done

# 添加工作节点到kube_node组
cat >> inventory/mycluster/hosts.yaml <<EOF
    kube_node:
      hosts:
EOF

for i in "${!WORKER_NODES[@]}"; do
    NODE_INDEX=$(( ${#CONTROL_PLANE_NODES[@]} + i + 1 ))
    NODE_NAME="node${NODE_INDEX}"
    echo "        ${NODE_NAME}:" >> inventory/mycluster/hosts.yaml
done

# 添加etcd组配置（多节点etcd）
cat >> inventory/mycluster/hosts.yaml <<EOF
    etcd:
      hosts:
EOF

# 添加所有控制平面节点到etcd组
for i in "${!CONTROL_PLANE_NODES[@]}"; do
    NODE_NAME="node$((i+1))"
    echo "        ${NODE_NAME}:" >> inventory/mycluster/hosts.yaml
done

cat >> inventory/mycluster/hosts.yaml <<EOF
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
EOF

log_info "hosts.yaml 配置完成"

#########################################
# 6. 配置离线环境参数
#########################################
log_info "=== [6/9] 配置离线环境参数 ==="

# 创建离线配置文件
cat > inventory/mycluster/group_vars/all/offline.yml <<EOF
---
# 私有镜像仓库配置
registry_host: "${LOCAL_REGISTRY_IP}:${LOCAL_REGISTRY_PORT}"
files_repo: "http://${LOCAL_FILE_SERVER_IP}:${LOCAL_FILE_SERVER_PORT}"

# 镜像仓库覆盖配置
kube_image_repo: "{{ registry_host }}"
gcr_image_repo: "{{ registry_host }}"
github_image_repo: "{{ registry_host }}"
docker_image_repo: "{{ registry_host }}"
quay_image_repo: "{{ registry_host }}"

# 二进制文件下载URL配置
kubeadm_download_url: "{{ files_repo }}/dl.k8s.io/release/v{{ kube_version }}/bin/linux/{{ image_arch }}/kubeadm"
kubectl_download_url: "{{ files_repo }}/dl.k8s.io/release/v{{ kube_version }}/bin/linux/{{ image_arch }}/kubectl"
kubelet_download_url: "{{ files_repo }}/dl.k8s.io/release/v{{ kube_version }}/bin/linux/{{ image_arch }}/kubelet"
etcd_download_url: "{{ files_repo }}/github.com/etcd-io/etcd/releases/download/v{{ etcd_version }}/etcd-v{{ etcd_version }}-linux-{{ image_arch }}.tar.gz"
cni_download_url: "{{ files_repo }}/github.com/containernetworking/plugins/releases/download/v{{ cni_version }}/cni-plugins-linux-{{ image_arch }}-v{{ cni_version }}.tgz"
crictl_download_url: "{{ files_repo }}/github.com/kubernetes-sigs/cri-tools/releases/download/v{{ crictl_version }}/crictl-v{{ crictl_version }}-{{ ansible_system | lower }}-{{ image_arch }}.tar.gz"
calicoctl_download_url: "{{ files_repo }}/github.com/projectcalico/calico/releases/download/v{{ calico_ctl_version }}/calicoctl-linux-{{ image_arch }}"
calico_crds_download_url: "{{ files_repo }}/github.com/projectcalico/calico/archive/v{{ calico_version }}.tar.gz"
ciliumcli_download_url: "{{ files_repo }}/github.com/cilium/cilium-cli/releases/download/v{{ cilium_cli_version }}/cilium-linux-{{ image_arch }}.tar.gz"
helm_download_url: "{{ files_repo }}/get.helm.sh/helm-v{{ helm_version }}-linux-{{ image_arch }}.tar.gz"
runc_download_url: "{{ files_repo }}/github.com/opencontainers/runc/releases/download/v{{ runc_version }}/runc.{{ image_arch }}"
nerdctl_download_url: "{{ files_repo }}/github.com/containerd/nerdctl/releases/download/v{{ nerdctl_version }}/nerdctl-{{ nerdctl_version }}-{{ ansible_system | lower }}-{{ image_arch }}.tar.gz"
containerd_download_url: "{{ files_repo }}/github.com/containerd/containerd/releases/download/v{{ containerd_version }}/containerd-{{ containerd_version }}-linux-{{ image_arch }}.tar.gz"
cri_dockerd_download_url: "{{ files_repo }}/github.com/Mirantis/cri-dockerd/releases/download/v{{ cri_dockerd_version }}/cri-dockerd-{{ cri_dockerd_version }}.{{ image_arch }}.tgz"

# 系统包仓库配置（根据实际环境调整）
# 如果目标环境已经预装了系统依赖包，可以跳过系统包安装
skip_upstream_repo: true

# CentOS/Redhat/AlmaLinux 系统包仓库配置
# 用于离线安装系统依赖包
yum_repo: "http://${LOCAL_FILE_SERVER_IP}:${LOCAL_FILE_SERVER_PORT}/download/yum"

# Debian/Ubuntu 系统包仓库配置
# 用于离线安装系统依赖包
debian_repo: "http://${LOCAL_FILE_SERVER_IP}:${LOCAL_FILE_SERVER_PORT}/download/debian"
ubuntu_repo: "http://${LOCAL_FILE_SERVER_IP}:${LOCAL_FILE_SERVER_PORT}/download/ubuntu"

# Docker / Containerd 离线安装配置
docker_rh_repo_base_url: "{{ yum_repo }}/docker-ce"
docker_rh_repo_gpgkey: "{{ yum_repo }}/docker-ce/gpg"
containerd_rh_repo_base_url: "{{ yum_repo }}/containerd"
containerd_rh_repo_gpgkey: "{{ yum_repo }}/containerd/gpg"

docker_debian_repo_base_url: "{{ debian_repo }}/docker-ce"
docker_debian_repo_gpgkey: "{{ debian_repo }}/docker-ce/gpg"
containerd_debian_repo_base_url: "{{ debian_repo }}/containerd"
containerd_debian_repo_gpgkey: "{{ debian_repo }}/containerd/gpg"

docker_ubuntu_repo_base_url: "{{ ubuntu_repo }}/docker-ce"
docker_ubuntu_repo_gpgkey: "{{ ubuntu_repo }}/docker-ce/gpg"
containerd_ubuntu_repo_base_url: "{{ ubuntu_repo }}/containerd"
containerd_ubuntu_repo_gpgkey: "{{ ubuntu_repo }}/containerd/gpg"

# 容器运行时配置（根据实际环境调整）
# container_manager: containerd
EOF


cat > inventory/mycluster/group_vars/all/containerd.yml <<EOF
---
# Please see roles/container-engine/containerd/defaults/main.yml for more configuration options

# containerd_storage_dir: "/var/lib/containerd"
# containerd_state_dir: "/run/containerd"
# containerd_oom_score: 0

# containerd_default_runtime: "runc"
# containerd_snapshotter: "native"

# containerd_runc_runtime:
#   name: runc
#   type: "io.containerd.runc.v2"
#   engine: ""
#   root: ""

# containerd_additional_runtimes:
# Example for Kata Containers as additional runtime:
#   - name: kata
#     type: "io.containerd.kata.v2"
#     engine: ""
#     root: ""

# containerd_grpc_max_recv_message_size: 16777216
# containerd_grpc_max_send_message_size: 16777216

# Containerd debug socket location: unix or tcp format
# containerd_debug_address: ""

# Containerd log level
# containerd_debug_level: "info"

# Containerd logs format, supported values: text, json
# containerd_debug_format: ""

# Containerd debug socket UID
# containerd_debug_uid: 0

# Containerd debug socket GID
# containerd_debug_gid: 0

# containerd_metrics_address: ""

# containerd_metrics_grpc_histogram: false

# Registries defined within containerd.
containerd_registries_mirrors:
  - prefix: "192.168.85.161:5000"
    mirrors:
      - host: "http://192.168.85.161:5000"
        capabilities: ["pull", "resolve"]
        skip_verify: true


# containerd_max_container_log_line_size: 16384

# containerd_registry_auth:
#   - registry: 10.0.0.2:5000
#     username: user
#     password: pass

EOF

log_info "离线环境参数配置完成"

#########################################
# 7. 部署到目标节点
#########################################
log_info "=== [7/9] 部署到目标节点 ==="

# 激活Python虚拟环境
log_info "激活Python虚拟环境..."
source venv/bin/activate

# 安装离线Python依赖
log_info "安装离线Python依赖..."
if [ -d "${WORKDIR}/pip" ]; then
    pip3 install --no-index --find-links ${WORKDIR}/pip -r requirements.txt
else
    log_warn "未找到pip目录，跳过离线Python依赖安装"
fi

# 将离线资源分发到控制平面节点
for node_ip in "${CONTROL_PLANE_NODES[@]}"; do
    log_info "部署资源到控制平面节点: ${node_ip}"

    # 创建远程目录
    ssh -o StrictHostKeyChecking=no root@${node_ip} "mkdir -p ${REMOTE_WORKDIR}"

    # 传输离线资源包
    scp -o StrictHostKeyChecking=no ${OFFLINE_PACKAGE} root@${node_ip}:${REMOTE_WORKDIR}/

    # 在远程节点解压资源包
    ssh -o StrictHostKeyChecking=no root@${node_ip} "cd ${REMOTE_WORKDIR} && tar xzf kubespray-offline-${KUBESPRAY_VERSION}.tar.gz"

    # 检查并安装系统依赖包
    ssh -o StrictHostKeyChecking=no root@${node_ip} "
        if [ -f /etc/redhat-release ]; then
            # RedHat/CentOS 系统
            if command -v yum >/dev/null 2>&1; then
                # 检查RPM包目录是否存在且包含RPM文件
                if [ -d \"${REMOTE_WORKDIR}/rpm\" ] && [ -n \"\$(ls -A ${REMOTE_WORKDIR}/rpm/*.rpm 2>/dev/null)\" ]; then
                    echo '检测到RPM包，开始安装...'
                    # 安装EPEL仓库（如果需要）
                    if ! rpm -q epel-release >/dev/null 2>&1; then
                        echo '安装EPEL仓库...'
                        yum install -y epel-release 2>/dev/null || echo 'EPEL仓库安装失败，继续安装其他包'
                    fi
                    # 安装RPM包
                    yum install -y ${REMOTE_WORKDIR}/rpm/*.rpm && echo '✅ RPM包安装成功' || echo '❌ RPM包安装失败'
                else
                    echo '未找到RPM包，跳过安装'
                fi
            else
                echo '未找到yum命令，跳过RPM包安装'
            fi
        elif [ -f /etc/debian_version ]; then
            # Debian/Ubuntu 系统
            if command -v apt-get >/dev/null 2>&1; then
                # 检查DEB包目录是否存在且包含DEB文件
                if [ -d \"${REMOTE_WORKDIR}/deb\" ] && [ -n \"\$(ls -A ${REMOTE_WORKDIR}/deb/*.deb 2>/dev/null)\" ]; then
                    echo '检测到DEB包，开始安装...'
                    # 更新包列表
                    apt-get update 2>/dev/null || echo 'apt-get update失败，继续安装包'
                    # 安装DEB包
                    dpkg -i ${REMOTE_WORKDIR}/deb/*.deb && echo '✅ DEB包安装成功' || echo '❌ DEB包安装失败'
                    # 修复依赖关系
                    apt-get install -f -y 2>/dev/null || echo '依赖修复失败'
                else
                    echo '未找到DEB包，跳过安装'
                fi
            else
                echo '未找到apt-get命令，跳过DEB包安装'
            fi
        else
            echo '未知系统类型，跳过系统依赖包安装'
        fi
    "
done

# 将离线资源分发到工作节点
for node_ip in "${WORKER_NODES[@]}"; do
    log_info "部署资源到工作节点: ${node_ip}"

    # 创建远程目录
    ssh -o StrictHostKeyChecking=no root@${node_ip} "mkdir -p ${REMOTE_WORKDIR}"

    # 传输离线资源包
    scp -o StrictHostKeyChecking=no ${OFFLINE_PACKAGE} root@${node_ip}:${REMOTE_WORKDIR}/

    # 在远程节点解压资源包
    ssh -o StrictHostKeyChecking=no root@${node_ip} "cd ${REMOTE_WORKDIR} && tar xzf kubespray-offline-${KUBESPRAY_VERSION}.tar.gz"

    # 检查并安装系统依赖包
    ssh -o StrictHostKeyChecking=no root@${node_ip} "
        if [ -f /etc/redhat-release ]; then
            # RedHat/CentOS 系统
            if command -v yum >/dev/null 2>&1; then
                # 检查RPM包目录是否存在且包含RPM文件
                if [ -d \"${REMOTE_WORKDIR}/rpm\" ] && [ -n \"\$(ls -A ${REMOTE_WORKDIR}/rpm/*.rpm 2>/dev/null)\" ]; then
                    echo '检测到RPM包，开始安装...'
                    # 安装EPEL仓库（如果需要）
                    if ! rpm -q epel-release >/dev/null 2>&1; then
                        echo '安装EPEL仓库...'
                        yum install -y epel-release 2>/dev/null || echo 'EPEL仓库安装失败，继续安装其他包'
                    fi
                    # 安装RPM包
                    yum install -y ${REMOTE_WORKDIR}/rpm/*.rpm && echo '✅ RPM包安装成功' || echo '❌ RPM包安装失败'
                else
                    echo '未找到RPM包，跳过安装'
                fi
            else
                echo '未找到yum命令，跳过RPM包安装'
            fi
        elif [ -f /etc/debian_version ]; then
            # Debian/Ubuntu 系统
            if command -v apt-get >/dev/null 2>&1; then
                # 检查DEB包目录是否存在且包含DEB文件
                if [ -d \"${REMOTE_WORKDIR}/deb\" ] && [ -n \"\$(ls -A ${REMOTE_WORKDIR}/deb/*.deb 2>/dev/null)\" ]; then
                    echo '检测到DEB包，开始安装...'
                    # 更新包列表
                    apt-get update 2>/dev/null || echo 'apt-get update失败，继续安装包'
                    # 安装DEB包
                    dpkg -i ${REMOTE_WORKDIR}/deb/*.deb && echo '✅ DEB包安装成功' || echo '❌ DEB包安装失败'
                    # 修复依赖关系
                    apt-get install -f -y 2>/dev/null || echo '依赖修复失败'
                else
                    echo '未找到DEB包，跳过安装'
                fi
            else
                echo '未找到apt-get命令，跳过DEB包安装'
            fi
        else
            echo '未知系统类型，跳过系统依赖包安装'
        fi
        # 停止防火墙
        if systemctl list-unit-files | grep -q firewalld; then
            echo '关闭 firewalld...'
            systemctl stop firewalld 2>/dev/null || true
            systemctl disable firewalld 2>/dev/null || true
        fi
        if systemctl list-unit-files | grep -q ufw; then
            echo '关闭 ufw...'
            systemctl stop ufw 2>/dev/null || true
            systemctl disable ufw 2>/dev/null || true
        fi
        # SELinux 设置为 permissive
        if [ -f /etc/selinux/config ]; then
            echo '设置 SELinux 为 permissive...'
            setenforce 0 2>/dev/null || true
            sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        fi
        # 关闭 Swap
        echo '关闭 Swap...'
        swapoff -a
        sed -i '/swap/s/^/#/' /etc/fstab
    "
done

# 创建所有节点的主机名映射
log_info "创建所有节点的主机名映射..."
ALL_HOSTS=""
all_nodes_ips=("${CONTROL_PLANE_NODES[@]}" "${WORKER_NODES[@]}")

# 生成所有节点的主机名映射
for i in "${!all_nodes_ips[@]}"; do
    NODE_NAME="node$((i+1))"
    NODE_IP="${all_nodes_ips[$i]}"
    ALL_HOSTS="${ALL_HOSTS}${NODE_IP} ${NODE_NAME}\n"
done

# 在每个控制平面节点上更新 /etc/hosts
for node_ip in "${CONTROL_PLANE_NODES[@]}"; do
    log_info "更新控制平面节点 ${node_ip} 的 /etc/hosts 文件"
    ssh -o StrictHostKeyChecking=no root@${node_ip} "
        # 备份原始 /etc/hosts 文件
        cp /etc/hosts /etc/hosts.backup
        # 添加所有节点的主机名映射
        echo -e '${ALL_HOSTS}' >> /etc/hosts
    "
done

# 在每个工作节点上更新 /etc/hosts
for node_ip in "${WORKER_NODES[@]}"; do
    log_info "更新工作节点 ${node_ip} 的 /etc/hosts 文件"
    ssh -o StrictHostKeyChecking=no root@${node_ip} "
        # 备份原始 /etc/hosts 文件
        cp /etc/hosts /etc/hosts.backup
        # 添加所有节点的主机名映射
        echo -e '${ALL_HOSTS}' >> /etc/hosts
    "
done

log_info "资源部署完成"

#########################################
# 8. 执行Kubernetes部署
#########################################
log_info "=== [8/9] 执行Kubernetes部署 ==="

# 执行部署
log_info "开始部署Kubernetes集群..."
if ansible-playbook -i inventory/mycluster/hosts.yaml -b cluster.yml -e kube_version=${K8S_VERSION}; then
    log_info "✅ Kubernetes集群部署完成"
else
    log_error "Kubernetes集群部署失败"
    exit 1
fi

#########################################
# 9. 部署后验证
#########################################
log_info "=== [9/9] 部署后验证 ==="

# 在控制平面节点上验证集群状态
CONTROL_PLANE_IP="${CONTROL_PLANE_NODES[0]}"
log_info "在控制平面节点 ${CONTROL_PLANE_IP} 上验证集群状态..."

# 验证集群节点状态
ssh -o StrictHostKeyChecking=no root@${CONTROL_PLANE_IP} "
    echo '=== 检查节点状态 ==='
    if command -v kubectl >/dev/null 2>&1; then
        kubectl get nodes -o wide
    else
        # 如果kubectl未在PATH中，尝试使用默认位置
        if [ -f /usr/local/bin/kubectl ]; then
            /usr/local/bin/kubectl get nodes -o wide
        else
            echo '未找到kubectl命令'
        fi
    fi

    echo '=== 检查系统Pod状态 ==='
    if command -v kubectl >/dev/null 2>&1; then
        kubectl get pods -n kube-system
    elif [ -f /usr/local/bin/kubectl ]; then
        /usr/local/bin/kubectl get pods -n kube-system
    fi

    echo '=== 检查集群版本 ==='
    if command -v kubectl >/dev/null 2>&1; then
        kubectl version
    elif [ -f /usr/local/bin/kubectl ]; then
        /usr/local/bin/kubectl version
    fi
" || log_warn "无法连接到控制平面节点进行验证"

log_info "=== 离线部署完成 ==="
log_info "如需进一步验证，请在控制平面节点执行以下命令:"
log_info "  kubectl get nodes"
log_info "  kubectl get pods -n kube-system"
log_info "  kubectl version"