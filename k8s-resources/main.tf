terraform {
  backend "gcs" {
    prefix = "crocus/k8s-resources"
  }
}

locals {
  env = substr(var.project_id, -3, -1)
}

variable "project_id" {
  type        = string
  description = "Project ID to deploy resources in."
}

locals {
  k8s_config = try(yamldecode(file("${var.project_id}.yaml")), {})
}

data "google_client_config" "provider" {}

data "google_container_cluster" "k8s" {
  project  = var.project_id
  name     = "bde-gke-dsprecs-${local.env}"
  location = "europe-west2"
}

provider "kubernetes" {
  host  = "https://${data.google_container_cluster.k8s.endpoint}"
  token = data.google_client_config.provider.access_token
  cluster_ca_certificate = base64decode(
    data.google_container_cluster.k8s.master_auth[0].cluster_ca_certificate,
  )
}

module "stackdriver" {
  source     = "gcs::https://www.googleapis.com/storage/v1/bde-tf-modules-prd/gcp_stackdriver//"
  project_id = var.project_id
}

module "service_accounts" {
  for_each            = local.k8s_config["cron"]
  source              = "terraform-google-modules/kubernetes-engine/google//modules/workload-identity"
  use_existing_gcp_sa = lookup(each.value, "service_account", null) != null
  name                = lookup(each.value, "service_account", "sa-k8s-${each.key}")
  namespace           = lookup(each.value, "namespace", "default")
  k8s_sa_name         = "sa-k8s-${each.key}"
  project_id          = var.project_id
  roles               = lookup(each.value, "roles", [])
  version             = "~> 21.2"
}

resource "kubernetes_cron_job_v1" "cron_jobs" {
  for_each = local.k8s_config["cron"]
  metadata {
    name      = each.key
    namespace = module.service_accounts[each.key].k8s_service_account_namespace
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 10
    schedule                      = each.value["schedule"]
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 10
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            service_account_name = module.service_accounts[each.key].k8s_service_account_name
            container {
              name              = each.key
              image             = "gcr.io/${var.project_id}/${each.value["image"]}:${lookup(each.value, "image-tag", "latest")}"
              image_pull_policy = "Always"
              env {
                name  = "GOOGLE_CLOUD_PROJECT"
                value = var.project_id
              }
              env {
                name  = "GCP_PROJECT"
                value = var.project_id
              }
              dynamic "resources" {
                for_each = lookup(each.value, "resources", null) != null ? [1] : []
                content {
                  limits = {
                    cpu               = each.value.resources.cpu
                    memory            = each.value.resources.memory
                    ephemeral-storage = each.value.resources.storage
                  }
                  requests = {
                    cpu               = each.value.resources.cpu
                    memory            = each.value.resources.memory
                    ephemeral-storage = each.value.resources.storage
                  }
                }
              }
              security_context {
                allow_privilege_escalation = false
                privileged                 = false
                read_only_root_filesystem  = false
                run_as_non_root            = false
                capabilities {
                  add  = []
                  drop = ["NET_RAW"]
                }
              }
            }
            security_context {
              run_as_non_root     = false
              supplemental_groups = []
              seccomp_profile {
                type = "RuntimeDefault"
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      metadata[0].annotations["autopilot.gke.io/resource-adjustment"],
      spec[0].job_template[0].metadata[0].annotations["autopilot.gke.io/resource-adjustment"],
    ]
  }
}

resource "google_monitoring_alert_policy" "cron_alert_policy" {
  for_each              = local.k8s_config["cron"]
  display_name          = "${each.key}-cron-alert-policy"
  project               = var.project_id
  notification_channels = module.stackdriver.notifications
  enabled               = true
  combiner              = "OR"
  alert_strategy {
    auto_close = "86400s"
    notification_rate_limit {
      period = "900s"
    }
  }
  conditions {
    display_name = "${each.key}-cronjob-failed"
    condition_matched_log {
      filter = <<-EOF
          jsonPayload.reason="BackoffLimitExceeded"
          resource.type="k8s_cluster"
          resource.labels.cluster_name="bde-gke-dsprecs-${local.env}"
          resource.labels.location="europe-west2"
          jsonPayload.involvedObject.kind="Job"
          jsonPayload.metadata.name=~"^${each.key}-"
        EOF
    }
  }
}
