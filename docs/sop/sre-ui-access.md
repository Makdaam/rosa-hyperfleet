# SRE UI Access — Integration Environment

Browser-based access to SRE UI tools for the integration environment via
dedicated ALBs. Two ALBs are deployed:

- **RC SRE UI ALB** — Grafana, ArgoCD (RC), Prometheus (RC), and Thanos on the
  Regional Cluster.
- **MC SRE UI ALB** — ArgoCD and Prometheus on each Management Cluster,
  accessible via path-based routing on a single hostname.

## Prerequisites

1. **Red Hat VPN** — required for the corporate proxy to function.
2. **Browser proxy configured** — traffic to `*.sre.us-east-1.int0.rosa.devshift.net`
   must route through `squid.corp.redhat.com:3128`. See
   [Browser proxy configuration](#browser-proxy-configuration) below.
3. **Red Hat employee account** — authentication via Red Hat SSO
   (`auth.stage.redhat.com`).

## RC SRE UI URLs

| Tool       | URL                                                     | Purpose                      |
| ---------- | ------------------------------------------------------- | ---------------------------- |
| Grafana    | https://grafana.sre.us-east-1.int0.rosa.devshift.net    | Metrics dashboards and logs  |
| ArgoCD     | https://argocd.sre.us-east-1.int0.rosa.devshift.net     | GitOps application status    |
| Prometheus | https://prometheus.sre.us-east-1.int0.rosa.devshift.net | Raw metric queries (RC)      |
| Thanos     | https://thanos.sre.us-east-1.int0.rosa.devshift.net     | Aggregated metrics (RC + MC) |

## MC SRE UI URLs

MC services are accessible on a single hostname with path-based routing. Replace
`{mc_id}` with the management cluster identifier (e.g. `mc01`, `mc02`).

| Tool       | URL                                                                 | Purpose                        |
| ---------- | ------------------------------------------------------------------- | ------------------------------ |
| ArgoCD     | https://mc.sre.us-east-1.int0.rosa.devshift.net/{mc_id}/argocd/     | GitOps status for MC workloads |
| Prometheus | https://mc.sre.us-east-1.int0.rosa.devshift.net/{mc_id}/prometheus/ | Raw metric queries (per-MC)    |

## Authentication

On first visit the browser redirects to Red Hat SSO. Authenticate with your Red
Hat credentials or via Kerberos SSO. Sessions last 8 hours.

All tools on both ALBs require SSO authentication. The MC SRE UI ALB uses a
single OIDC client for the entire `mc.sre.*` hostname — authentication carries
across all MC paths in the same browser session.

## Access levels

| Tool          | Access level after login |
| ------------- | ------------------------ |
| RC Grafana    | Read-only (Viewer)       |
| RC ArgoCD     | Read-only                |
| RC Prometheus | Read-only                |
| RC Thanos     | Read-only                |
| MC ArgoCD     | Read-only                |
| MC Prometheus | Read-only                |

## Browser proxy configuration

Both ALBs only accept traffic from Red Hat corporate proxy egress IPs. Configure
your browser to proxy `*.sre.us-east-1.int0.rosa.devshift.net` through
`squid.corp.redhat.com:3128`. The proxy is only reachable from the Red Hat VPN.

### Chrome — ZeroOmega

Install [ZeroOmega](https://chromewebstore.google.com/detail/proxy-switchyomega-3-zero/pfnededegaaopdmhkdmcofjmoldfiped)
from the Chrome Web Store.

1. Open the ZeroOmega options panel.
2. Create a new proxy profile named **hyperfleet-sre**:
   - Protocol: `HTTP`
   - Server: `squid.corp.redhat.com`
   - Port: `3128`
3. In the **Auto Switch** profile add a condition:
   - Condition type: `Host wildcard`
   - Condition details: `*.sre.us-east-1.int0.rosa.devshift.net`
   - Profile: `hyperfleet-sre`
4. Click **Apply changes** and activate the **Auto Switch** profile.

### Firefox — FoxyProxy

Install [FoxyProxy](https://addons.mozilla.org/firefox/addon/foxyproxy-standard/).

1. Open FoxyProxy options → **Proxies** → **Add**.
2. Configure the proxy:
   - Title: `hyperfleet-sre`
   - Type: `HTTP`
   - Hostname: `squid.corp.redhat.com`
   - Port: `3128`
3. Under **URL Patterns** add:
   - Pattern: `*.sre.us-east-1.int0.rosa.devshift.net`
   - Type: `Wildcard`
4. Save and enable FoxyProxy.

## Troubleshooting

**500 after SSO redirect** — The ALB cannot reach the OIDC provider
(`auth.stage.redhat.com`) to complete the token exchange. Ensure you are
connected to the Red Hat VPN and the corporate proxy is active.

**503 Service Unavailable** — The target group has no healthy targets. For RC
tools, check TargetGroupBindings and pod health on the RC cluster
(`make int-bastion-rc`). For MC tools, also verify the MC NLB is healthy and
that the RC ALB target groups have been populated (see
[mc-sre-ui-deployment.md](mc-sre-ui-deployment.md)).

**Proxy connection refused** — You are not connected to the Red Hat VPN.
Connect to VPN and retry.

**MC URL returns 404** — The path prefix may not match a deployed MC ID.
Confirm the correct `{mc_id}` value (e.g. `mc01`) and that the MC SRE UI has
completed both deployment passes (see [mc-sre-ui-deployment.md](mc-sre-ui-deployment.md)).
