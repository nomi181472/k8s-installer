# k8s-installer

This repository contains scripts to install a single-plane Kubernetes cluster (master + workers), with optional NVIDIA GPU Operator support.

**Step 3 — Multi-Node (master + workers)**

- On the master node (run as root), initialize the cluster. Use the script in the `step-3-multi-node` folder and pass the API IP to advertise:

```bash
sudo bash step-3-multi-node/install-kube-single-plane.sh --api-ip <master-IP>
```

- After the master script finishes it generates `/root/worker-join.sh`. Copy that file to each worker (replace `<master-IP>` with your master node address):

```bash
scp root@<master-IP>:/root/worker-join.sh ~/
```

- On each worker node, run the join script as root:

```bash
sudo bash worker-join.sh
```

Notes:

- The worker join token is generated with a limited TTL (24h by default). If it expires, regenerate a join command on the master with:

```bash
sudo kubeadm token create --print-join-command
```

- The master install script file is named `install-kube-single-plane.sh` (in `step-3-multi-node`). The script header references `install-kube-master.sh` as a usage example — both refer to the same install flow. Use the path shown above to run the script from the repository root.

See the scripts in `step-3-multi-node` for more advanced options (`--pod-cidr`, `--k8s-version`, `--token-file`, etc.).
