sudo swapoff -a
sudo kubeadm init --cri-socket /run/cri-dockerd.sock

#TODO add check that kube is running

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config





function kubeadm_reset() {
    sudo apt install ipvsadm

    sudo kubeadm reset --cri-socket /run/cri-dockerd.sock
    sudo iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
    sudo ipvsadm -C
}