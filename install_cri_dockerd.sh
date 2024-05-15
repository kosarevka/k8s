#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

sudo apt update
sudo apt install git wget curl


function install_cri_dockerd() {
    if [[ ! -s "/usr/local/bin/cri-dockerd" ]]; then
        echo "Starting cri-dockerd installation"

        VER=$(curl -s https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest|grep tag_name | cut -d '"' -f 4|sed 's/v//g')
        echo $VER

        wget https://github.com/Mirantis/cri-dockerd/releases/download/v${VER}/cri-dockerd-${VER}.arm64.tgz
        cri-dockerd-${VER}.arm64.tgz

        sudo tar -xvzf cri-dockerd-${VER}.arm64.tgz
        sudo mv cri-dockerd/cri-dockerd /usr/local/bin/
        
        echo "cri-dockered installation complete"
        echo "cri-dockerd" --version
    else
        echo "cri-dockerd already installed"
    fi

    "cri-dockerd" --version || {
        echo "Error: cri-dockerd not installed"
        exit 1
    }
}

function set_up_systemd_for_cri-dockerd() {
    echo "Setting up systemd units for cri-dockerd..."
    wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.service
    wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.socket
    sudo mv cri-docker.socket cri-docker.service /etc/systemd/system/
    sudo sed -i -e 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,' /etc/systemd/system/cri-docker.service
    echo "Set up complete"
}

function run_cri-dockerd() {
    echo "Starting the cri-docker.service"
    sudo systemctl daemon-reload
    sudo systemctl enable cri-docker.service
    sudo systemctl enable --now cri-docker.socket    

    echo "Service status: "
    systemctl status cri-docker.socket
}




CRI_SOCK="unix:///var/run/cri-dockerd.sock"
KUBEADM_FLAGS_ENV="/var/lib/kubelet/kubeadm-flags.env"

SERVICE_NAME="cri-docker.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
TAR_NAME="cri-dockerd.tar.gz"
TAR_PATH="${TMPDIR:-/tmp/}/install-cri-dockerd"
BIN_NAME=""
BIN_PATH=
OLD_FLAGS=$(cat "${KUBEADM_FLAGS_ENV}")

function check_container_runtime_of_kubelet() {
    if [[ "${OLD_FLAGS}" =~ "--container-runtime=remote" ]]; then
        echo cat "${KUBEADM_FLAGS_ENV}"
        cat "${KUBEADM_FLAGS_ENV}"
        echo "The container runtime is already set to remote"
        echo "Please check the container runtime of kubelet"
        exit 1
    fi
}

function start_cri_dockerd() {
    source "${KUBEADM_FLAGS_ENV}"
    cat <<EOF >"${SERVICE_PATH}"
[Unit]
Description=CRI Interface for Docker Application Container Engine
Documentation=https://docs.mirantis.com
After=network-online.target firewalld.service docker.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/cri-dockerd --cri-dockerd-root-directory=/var/lib/dockershim --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/opt/cni/bin --container-runtime-endpoint ${CRI_SOCK} ${KUBELET_KUBEADM_ARGS}
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always

StartLimitBurst=3

StartLimitInterval=60s

LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity

TasksMax=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
    systemctl status --no-pager "${SERVICE_NAME}" || {
        echo "Failed to start cri-dockerd"
        exit 1
    }

    echo "crictl --runtime-endpoint "${CRI_SOCK}" ps"
    crictl --runtime-endpoint "${CRI_SOCK}" ps
}

function configure_kubelet() {
    NEW_FLAGS=$(echo "${OLD_FLAGS%\"*} --container-runtime=remote --container-runtime-endpoint=${CRI_SOCK}\"")

    case "${FORCE}" in
    [yY][eE][sS] | [yY])
        : # Skip
        ;;
    *)

        echo "============== The original kubeadm-flags.env =============="
        echo cat "${KUBEADM_FLAGS_ENV}"
        cat "${KUBEADM_FLAGS_ENV}"
        echo "================ Configure kubelet ========================="
        echo "cp ${KUBEADM_FLAGS_ENV} ${KUBEADM_FLAGS_ENV}.bak"
        echo "cat <<EOF > ${KUBEADM_FLAGS_ENV}"
        echo "${NEW_FLAGS}"
        echo "EOF"
        echo "systemctl daemon-reload"
        echo "systemctl restart kubelet"
        echo "============================================================"
        echo "Please double check the configuration of kubelet"
        echo "Next will execute the that command"
        echo "If you don't need this prompt process, please run:"
        echo "    FORCE=y $0"
        echo "============================================================"

        read -r -p "Are you sure? [y/n] " response
        case "$response" in
        [yY][eE][sS] | [yY])
            : # Skip
            ;;
        *)
            echo "You no enter 'y', so abort install now"
            echo "but the cri-dockerd is installed and running"
            echo "if need is uninstall the cri-dockerd please run:"
            echo "   systemctl stop ${SERVICE_NAME}"
            echo "   systemctl disable ${SERVICE_NAME}"
            echo "   rm ${SERVICE_PATH}"
            echo "   rm ${BIN_PATH}/${BIN_NAME}"
            exit 1
            ;;
        esac
        ;;
    esac

    cp "${KUBEADM_FLAGS_ENV}" "${KUBEADM_FLAGS_ENV}.bak"
    cat <<EOF >${KUBEADM_FLAGS_ENV}
${NEW_FLAGS}
EOF
    systemctl daemon-reload
    systemctl restart kubelet
}

function main() {
    install_cri_dockerd
    set_up_systemd_for_cri-dockerd
    run_cri-dockerd
}

main