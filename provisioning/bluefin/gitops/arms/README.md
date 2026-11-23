# Phase 4 edge arms

Run Pangolin first, then Envoy. The root Application watches `apps/`.
The home backend lives there permanently. Keep just one arm Application
there at a time because they share TCP and UDP port 443.

## Before enabling an arm

`../workloads/edge-pangolin/edge-pangolin.sops.yaml` and
`../workloads/edge-envoy/edge-envoy.sops.yaml` are committed **encrypted**
(2026-11-23) with the pilot age recipient (`.sops.yaml`, `stringData` only):
the pilot domain (`pilot.<production domain>`, E4), the staging ACME e-mail,
a fresh Pangolin server secret and Gerbil's `subnet_group` (production's
`100.89.137.0/20`, inside the range the tailnet policy keeps pilot nodes
out of). Edit them with
`env SOPS_AGE_KEY="$(pass-cli item view --vault-name bluefin-pilot --item-title sops-age-key --field note)" sops edit <file>`.
Argo CD decrypts them through KSOPS. Envoy's Kustomize build copies the
decrypted values into the Gateway, Issuer, Certificate, and routes.

For Pangolin, `/var/lib/pilot-edge/pangolin` must exist on the edge before
sync (`mise bluefin:pilot:edge-bootstrap` creates it); kubelet creates the
`config/` and `letsencrypt/` subPaths, and all three containers run as root
(checked on the rehearsal edge, 2026-11-23). The retained
local PV stores the database, Gerbil key, and staging ACME state. Keep this
directory for arm changes. Use a clean state path for the restore exercise
and rebind the PV/PVC to that path before startup. Restart the Deployment
after changing the Secret's app config or server secret so the subPath
mount and environment pick up the new values.

In Pangolin, complete first-run setup and create the public resources
`echo` and `transfer` under the pilot domain. Point them at the home fixture
Service `edge-backend` in `pilot-edge-backend`, HTTP port 8080, via its
cluster DNS. Set the health check to `/echo?msg=healthy` and configure the
resources for the same unauthenticated probe/load traffic as Envoy.
Use a separate Newt site on the home worker for the Gerbil function check.

Both arms can exercise netexec at `/echo?msg=probe`. For sustained
large-response measurements, the load tool fetches a static blob from a
separately supplied fixture on the same home worker, through the transfer
hostname in each arm. The checked-in routes initially point at netexec
for small responses. Before running the large-response gate, wire both
transfer routes to the blob fixture and verify its expected checksum.

For Envoy issuance and the renewal check, open TCP 80 by hand in both
the provider firewall and the `pilot-edge-acme-http` Cilium host policy.
Delete the policy and close the firewall rule after issuance and the
renewal check.

## Switch arms

1. Enable Pangolin first by moving `edge-pangolin.yaml` from `arms/` into
   `apps/` and pushing the change with its encrypted configuration.
2. When switching, move the live arm file back into `arms/`, push, and
   wait for the root to sync that revision. Root pruning is disabled, so
   removing the file alone leaves the live Application running.
3. Delete the live Application with cascade, for example
   `argocd app delete pilot-edge-pangolin --cascade --propagation-policy foreground`.
   Wait for the Application, its workload and arm-specific resources to
   disappear. For Envoy, also wait for the controller-generated proxy
   Deployment and pod to disappear.
4. On the edge, compare `sudo ss -lntup` with the pre-arm capture. Check
   that the departing arm has released TCP/UDP 443 and its other
   listeners, including Gerbil UDP 51820/21820 or Envoy TCP 80. Check
   that the departing arm's temporary host-policy allowances are gone.
5. Move the other Application file into `apps/` and push with its
   encrypted configuration.
