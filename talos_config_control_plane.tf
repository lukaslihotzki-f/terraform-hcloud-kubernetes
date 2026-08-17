locals {
  talos_allow_scheduling_on_control_planes = coalesce(var.cluster_allow_scheduling_on_control_planes, (local.worker_sum + local.cluster_autoscaler_max_sum) == 0)

  # Default anonymous authentication rules, matching the Talos-generated defaults.
  # Required for the anonymous health check probes of the kube-apiserver.
  kube_api_default_anonymous_auth = {
    enabled = true
    conditions = [
      { path = "/livez" },
      { path = "/readyz" },
      { path = "/healthz" },
    ]
  }

  # OIDC is configured via the structured AuthenticationConfiguration (jwt section):
  # Talos v1.14+ always runs the kube-apiserver with '--authentication-config', which
  # cannot be combined with the legacy 'oidc-*' flags.
  kube_api_oidc_authentication_configuration = {
    anonymous = local.kube_api_default_anonymous_auth
    jwt = [
      {
        issuer = {
          url       = var.oidc_issuer_url
          audiences = [var.oidc_client_id]
        }
        claimMappings = {
          username = {
            claim = var.oidc_username_claim
            # Parity with the 'oidc-username-prefix' flag default: usernames from
            # claims other than 'email' are prefixed with '<issuer-url>#'.
            prefix = var.oidc_username_claim == "email" ? "" : "${var.oidc_issuer_url}#"
          }
          groups = {
            claim  = var.oidc_groups_claim
            prefix = var.oidc_groups_prefix
          }
        }
      }
    ]
  }

  kube_api_authentication_configuration = (
    var.kube_api_authentication_config != null ? var.kube_api_authentication_config :
    var.oidc_enabled ? local.kube_api_oidc_authentication_configuration :
    null
  )

  # Kube API Server Authentication Configuration.
  # When set, it replaces the Talos default authentication configuration entirely.
  kube_api_authentication_config_patches = local.kube_api_authentication_configuration != null ? [
    {
      apiVersion    = "v1alpha1"
      kind          = "KubeAuthenticationConfig"
      configuration = local.kube_api_authentication_configuration
    }
  ] : []

  # Kubernetes control plane components (Talos v1.14+ multi-document style)
  kube_control_plane_component_patches = concat(
    [
      merge(
        {
          apiVersion    = "v1alpha1"
          kind          = "KubeAPIServerConfig"
          certExtraSANs = local.talos_certificate_san
          extraArgs = merge(
            { "enable-aggregator-routing" = true },
            var.kube_api_extra_args
          )
        },
        var.kubernetes_apiserver_image != null ? {
          image = "${var.kubernetes_apiserver_image}:${var.kubernetes_version}"
        } : {}
      ),
      merge(
        {
          apiVersion = "v1alpha1"
          kind       = "KubeControllerManagerConfig"
          extraArgs = {
            "cloud-provider" = "external"
            "bind-address"   = "0.0.0.0"
          }
        },
        var.kubernetes_controller_manager_image != null ? {
          image = "${var.kubernetes_controller_manager_image}:${var.kubernetes_version}"
        } : {}
      ),
      merge(
        {
          apiVersion = "v1alpha1"
          kind       = "KubeSchedulerConfig"
          extraArgs = {
            "bind-address" = "0.0.0.0"
          }
        },
        var.kubernetes_scheduler_image != null ? {
          image = "${var.kubernetes_scheduler_image}:${var.kubernetes_version}"
        } : {}
      ),
      merge(
        {
          apiVersion = "v1alpha1"
          kind       = "KubeProxyConfig"
          enabled    = !var.cilium_kube_proxy_replacement_enabled
        },
        var.kubernetes_proxy_image != null ? {
          image = "${var.kubernetes_proxy_image}:${var.kubernetes_version}"
        } : {}
      ),
      # Cilium is used as the CNI, remove the default Flannel deployment
      {
        apiVersion = "v1alpha1"
        kind       = "KubeFlannelCNIConfig"
        "$patch"   = "delete"
      }
    ],
    [
      for plugin in var.kube_api_admission_control : {
        apiVersion    = "v1alpha1"
        kind          = "KubeAdmissionControlConfig"
        name          = plugin.name
        configuration = plugin.configuration
      }
    ],
    local.kube_api_authentication_config_patches
  )

  # Kubernetes Manifests for Talos
  talos_inline_manifests = concat(
    [local.hcloud_secret_manifest],
    local.cilium_manifest != null ? [local.cilium_manifest] : [],
    local.talos_ccm_manifest != null ? [local.talos_ccm_manifest] : [],
    local.hcloud_ccm_manifest != null ? [local.hcloud_ccm_manifest] : [],
    local.hcloud_csi_manifest != null ? [local.hcloud_csi_manifest] : [],
    local.talos_backup_manifest != null ? [local.talos_backup_manifest] : [],
    local.longhorn_manifest != null ? [local.longhorn_manifest] : [],
    local.metrics_server_manifest != null ? [local.metrics_server_manifest] : [],
    local.cert_manager_manifest != null ? [local.cert_manager_manifest] : [],
    local.cert_manager_webhook_hetzner_manifest != null ? [local.cert_manager_webhook_hetzner_manifest] : [],
    local.ingress_nginx_manifest != null ? [local.ingress_nginx_manifest] : [],
    local.cluster_autoscaler_manifest != null ? [local.cluster_autoscaler_manifest] : [],
    var.talos_extra_inline_manifests != null ? var.talos_extra_inline_manifests : [],
    local.rbac_manifest != null ? [local.rbac_manifest] : [],
    local.oidc_manifest != null ? [local.oidc_manifest] : []
  )
  talos_manifests = concat(
    var.prometheus_operator_crds_enabled ? [
      "https://github.com/prometheus-operator/prometheus-operator/releases/download/${var.prometheus_operator_crds_version}/stripped-down-crds.yaml"
    ] : [],
    var.gateway_api_crds_enabled ? [
      "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_crds_version}/${var.gateway_api_crds_release_channel}-install.yaml"
    ] : [],
    var.talos_extra_remote_manifests != null ? var.talos_extra_remote_manifests : []
  )

  # Control Plane Config
  control_plane_talos_config_patches = {
    for name, node in hcloud_server.control_plane : name => concat(
      [
        {
          machine = {
            nodeLabels = merge(
              local.talos_allow_scheduling_on_control_planes ? { "node.kubernetes.io/exclude-from-external-load-balancers" = { "$patch" = "delete" } } : {},
              local.control_plane_nodepools_map[node.labels.nodepool].labels,
              { "nodeid" = tostring(node.id) }
            )
            nodeAnnotations = local.control_plane_nodepools_map[node.labels.nodepool].annotations
            nodeTaints = {
              for taint in local.control_plane_nodepools_map[node.labels.nodepool].taints : taint.key => "${taint.value}:${taint.effect}"
            }
            kubelet = {
              extraConfig = merge(
                {
                  registerWithTaints = local.control_plane_nodepools_map[node.labels.nodepool].taints
                  systemReserved = {
                    cpu               = "250m"
                    memory            = "300Mi"
                    ephemeral-storage = "1Gi"
                  }
                  kubeReserved = {
                    cpu               = "250m"
                    memory            = "350Mi"
                    ephemeral-storage = "1Gi"
                  }
                },
                var.kubernetes_kubelet_extra_config
              )
            }
            features = {
              kubernetesTalosAPIAccess = {
                enabled = true
                allowedRoles = [
                  "os:reader",
                  "os:etcd:backup"
                ]
                allowedKubernetesNamespaces = ["kube-system"]
              }
            }
          }
          cluster = {
            allowSchedulingOnControlPlanes = local.talos_allow_scheduling_on_control_planes
            coreDNS = {
              disabled = !var.talos_coredns_enabled
            }
            etcd = merge(
              {
                advertisedSubnets = [hcloud_network_subnet.control_plane.ip_range]
                extraArgs = {
                  "listen-metrics-urls" = "http://0.0.0.0:2381"
                }
              },
              var.kubernetes_etcd_image != null ? {
                image = var.kubernetes_etcd_image
              } : {}
            )
            adminKubeconfig = {
              certLifetime = "87600h"
            }
            inlineManifests = local.talos_inline_manifests
            externalCloudProvider = {
              enabled   = true
              manifests = local.talos_manifests
            }
          }
        },
        {
          apiVersion = "v1alpha1"
          kind       = "HostnameConfig"
          hostname   = name
          auto       = "off"
        }
      ],
      local.kube_control_plane_component_patches,
      local.control_plane_public_vip_ipv4_enabled ? [{
        apiVersion = "v1alpha1"
        kind       = "HCloudVIPConfig"
        name       = local.control_plane_public_vip_ipv4
        link       = local.talos_public_link_name
        apiToken   = var.hcloud_token
      }] : [],
      var.control_plane_private_vip_ipv4_enabled ? [{
        apiVersion = "v1alpha1"
        kind       = "HCloudVIPConfig"
        name       = local.control_plane_private_vip_ipv4
        link       = local.talos_private_link_name
        apiToken   = var.hcloud_token
      }] : []
    )
  }
}

data "talos_machine_configuration" "control_plane" {
  for_each = toset(keys(hcloud_server.control_plane))

  talos_version      = var.talos_version
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.kube_api_url_internal
  kubernetes_version = var.kubernetes_version
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  docs               = false
  examples           = false

  config_patches = concat(
    [for patch in local.talos_cloud_config_patches : yamlencode(patch)],
    [for patch in local.control_plane_talos_config_patches[each.key] : yamlencode(patch)],
    [for patch in var.control_plane_config_patches : yamlencode(patch)]
  )
}
