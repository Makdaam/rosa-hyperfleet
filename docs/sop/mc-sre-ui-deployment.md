# MC SRE UI Deployment

The MC SRE UI provides path-based HTTPS access to ArgoCD and Prometheus on each
Management Cluster via an ALB in the Regional Cluster account.

## Architecture

```
Browser
  -> RC ALB (OIDC auth, path-based routing)
     /{mc_id}/argocd/*     -> MC NLB (Elastic IPs, internet-facing)
     /{mc_id}/prometheus/* ->        -> ArgoCD / Prometheus pods
```

The MC NLB restricts ingress to the RC VPC NAT Gateway EIPs so only traffic
from the RC ALB can reach it.

## Two-pass deployment for new environments

For **existing environments**, the RC NAT Gateway EIPs pre-exist before this
feature is enabled. The MC pipeline runs first (it reads the pre-existing EIPs
and creates the MC NLB), then the RC pipeline runs and picks up the MC NLB EIPs.
No special sequencing is required.

For **new environments** where both `enable_mc_sre_ui` and `enable_rc_mc_sre_ui`
are enabled from the start, a two-pass deployment is required because the RC and
MC pipelines run concurrently:

| Pass | RC pipeline                                                                                         | MC pipeline                                                                            |
| ---- | --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| 1    | Creates VPC and NAT Gateway EIPs. RC ALB is created with no MC targets (MC NLB EIPs not yet known). | Reads RC NAT Gateway EIPs. Creates MC NLB with EIPs. Writes MC EIPs to RC account SSM. |
| 2    | Reads MC NLB EIPs from SSM. RC ALB target groups populated. SRE UI becomes accessible.              | No action needed.                                                                      |

Pass 2 is triggered by any subsequent RC pipeline run (e.g., the next code push
to main). It does not require manual intervention.

## Security guarantees during deployment

The MC NLB security group is configured with the correct RC NAT Gateway EIP
restrictions **from the moment it is created**. The MC buildspec reads the RC
NAT Gateway EIPs before applying Terraform (using the same retry loop that reads
RHOBS and OIDC outputs). The NLB is never open to the internet.

| State         | MC NLB internet-accessible?       | RC ALB has targets? | SRE UI accessible? |
| ------------- | --------------------------------- | ------------------- | ------------------ |
| Before pass 1 | N/A                               | N/A                 | No                 |
| After pass 1  | No (EIP-restricted from creation) | No                  | No                 |
| After pass 2  | No                                | Yes                 | Yes                |

The window between pass 1 and pass 2 represents a period where the feature is
not yet functional — not a period where it is insecure.

## Implications if only pass 1 completes

If the RC pipeline fails or is not triggered after pass 1:

- The MC NLB exists and is EIP-restricted (secure).
- The RC ALB either does not exist (`enable_rc_mc_sre_ui` was not set) or exists
  with no targets (if it was enabled but MC EIPs were not yet in SSM).
- The SRE UI URLs return 503 (no healthy targets).
- No data is exposed and no security boundary is violated.

To complete the deployment, trigger the RC pipeline again once the MC pipeline
has successfully written its EIPs to SSM. Verify the SSM parameter exists before
re-running the RC pipeline:

```sh
aws ssm get-parameter \
  --name "/infra/mc01/sre-mc-eips" \
  --region us-east-1 \
  --profile rrp-regional-int
```

If the parameter is missing, the MC pipeline did not complete pass 1 successfully.
Check the MC pipeline logs and re-run if needed.

## Enabling for integration

The following configuration enables the MC SRE UI for the integration environment.
OIDC requires a client registration — see
[`docs/sre-ui-oidc-setup.md`](../../rosa-hyperfleet-internal/docs/sre-ui-oidc-setup.md)
in `rosa-hyperfleet-internal` for the process.

```yaml
# config/integration/defaults.yaml
regional_cluster:
  enable_mc_sre_ui: true # enable on each MC (MC pipeline)
  enable_rc_mc_sre_ui: true # enable RC ALB (RC pipeline, pass 2)
  rc_mc_sre_ui_prefix: "mc" # hostname: mc.sre.us-east-1.int0.rosa.devshift.net
  enable_rc_mc_sre_ui_oidc: true
  rc_mc_sre_ui_oidc_client_id: "rrp-mc-sre-int-us-east-1"
```

The OIDC client secret is stored in Secrets Manager in the RC account at
`mc-sre-ui/oidc-client-secret`.
