sudo systemctl stop docker || true
sudo systemctl stop podman || true

sudo dnf remove -y docker-ce docker-ce-cli docker-ce-rootless-extras \
    docker-buildx-plugin docker-compose-plugin containerd.io \
    docker-scan-plugin podman podman-docker

sudo rm -rf /var/lib/docker
sudo rm -rf /var/lib/containerd
sudo rm -rf /etc/docker
sudo rm -f /usr/bin/docker /usr/bin/dockerd /usr/lib/systemd/system/docker.service
sudo rm -rf /usr/libexec/docker
which docker || echo "✅ docker 已清除"
sudo dnf localinstall -y *.rpm
sudo systemctl daemon-reload
sudo systemctl enable docker
sudo systemctl start docker
