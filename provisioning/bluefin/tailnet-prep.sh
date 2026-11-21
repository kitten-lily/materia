#!/bin/bash
# Bluefin pilot (#179) Phase 2: host Tailscale before Kubernetes.
# Installed as /etc/bluefin-pilot/tailnet-prep by `mise bluefin:pilot:render
# --topology tailnet`, which substitutes the @…@ placeholders.
# Design: specs/plans/bluefin-server-pilot-phase2.md ("Node bootstrap").
set -euo pipefail

role='@ROLE@'            # control-plane | node
host='@HOST@'            # this node's hostname and tailnet device name
cp_fqdn='@CP_FQDN@'      # bluefin-pilot-cp.<tailnet>.ts.net
cred="${CREDENTIALS_DIRECTORY:-/nonexistent}/pilot.tailscale-authkey"

log() { echo "pilot-tailnet-prep: $*"; }

# 1. Wait for the tailscale sysext (fetched and merged on first boot).
for _ in $(seq 1 120); do [ -x /usr/bin/tailscale ] && break; sleep 5; done
[ -x /usr/bin/tailscale ] || { log "tailscale sysext not merged after 10 min"; exit 1; }
systemctl start tailscaled.service

# 2. Log in once; later boots reconnect from the saved state and prefs.
connected() { tailscale ip -4 >/dev/null 2>&1; }
for _ in $(seq 1 15); do connected && break; sleep 2; done
if ! connected; then
  [ -s "$cred" ] || { log "credential pilot.tailscale-authkey missing; cannot log in"; exit 1; }
  log "logging in as ${host} (tag:bluefin-pilot, netfilter off)"
  tailscale up --auth-key="file:${cred}" --advertise-tags=tag:bluefin-pilot \
    --netfilter-mode=off --hostname="${host}" --accept-dns=true
fi
ts_ip=""
for _ in $(seq 1 60); do ts_ip="$(tailscale ip -4 2>/dev/null | head -n1)"; [ -n "$ts_ip" ] && break; sleep 2; done
[ -n "$ts_ip" ] || { log "no tailnet IPv4 after login"; exit 1; }
log "tailnet IPv4 ${ts_ip}"

# 3. MagicDNS must resolve the control plane before kubelet or join need it.
for _ in $(seq 1 60); do getent hosts "$cp_fqdn" >/dev/null && break; sleep 2; done
getent hosts "$cp_fqdn" >/dev/null || { log "MagicDNS does not resolve ${cp_fqdn}"; exit 1; }
log "${cp_fqdn} resolves to $(getent hosts "$cp_fqdn" | cut -d' ' -f1)"

# 4. kubelet's node IP is the tailnet address (rewritten every boot).
# /etc/default does not exist on Bluefin's factory /etc.
mkdir -p /etc/default
printf 'KUBELET_EXTRA_ARGS=--node-ip=%s\n' "$ts_ip" > /etc/default/kubelet

# 5. Control plane, before the first init only: endpoint, SANs, advertise
#    address, and Cilium's API address (no DNS needed before CoreDNS runs).
if [ "$role" = control-plane ] && [ ! -e /etc/kubernetes/admin.conf ]; then
  mkdir -p /etc/kubernetes/bluefin
  cat > /etc/kubernetes/bluefin/init.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${ts_ip}
  bindPort: 6443
nodeRegistration:
  name: ${host}
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: bluefin
kubernetesVersion: v1.35.10
imageRepository: registry.k8s.io
controlPlaneEndpoint: ${cp_fqdn}:6443
apiServer:
  certSANs:
  - ${cp_fqdn}
  - ${host}
  - ${ts_ip}
networking:
  dnsDomain: cluster.local
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
controllerManager:
  extraArgs:
  - name: flex-volume-plugin-dir
    value: /var/lib/kubelet/volumeplugins
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
EOF
  sha256sum /etc/kubernetes/bluefin/init.yaml > /run/pilot-init-yaml.sha256
  log "wrote init.yaml (endpoint ${cp_fqdn}:6443, advertise ${ts_ip})"
  conf=/etc/bluefin/homelab.conf
  [ -f "$conf" ] || { log "$conf missing"; exit 1; }
  sed -i '/^HOMELAB_K8S_SERVICE_HOST=/d' "$conf"
  # The template may end without a newline; never glue onto its last line.
  [ -z "$(tail -c1 "$conf")" ] || echo >> "$conf"
  printf 'HOMELAB_K8S_SERVICE_HOST=%s\n' "$ts_ip" >> "$conf"
fi
log "done"
