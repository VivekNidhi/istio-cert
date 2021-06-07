# Terraform state is stored in Terraform Enterprise
terraform {
  backend "remote" {
    hostname     = "terraform-enterprise.platform.nwminfra.net"
    organization = "nwm-proving-v2"

    workspaces {
      # backend configuration cannot contain interpolations so we have to hardcode the env name - rather than using ${var.env} - here
      name = "prv1-pe-sandbox-resources"
    }
  }
}

data "terraform_remote_state" "project" {
  backend = "remote"

  config = {
    hostname     = "terraform-enterprise.platform.nwminfra.net"
    organization = local.tfe_organization
    workspaces = {
      name = local.tfe_project_workspace
    }
  }
}

provider "vault" {

  auth_login {
    path = "auth/approle/login"

    parameters = {
      role_id   = var.vault_approle
      secret_id = var.vault_approle_secret
    }
  }
}

data "vault_generic_secret" "resource_editor" {
  path = "proving/gcp/token/${var.env}-pe-sandbox-editor"
}

provider "google" {
  access_token = data.vault_generic_secret.resource_editor.data["token"]
  project      = data.terraform_remote_state.project.outputs.project_id
  region       = "europe-west2"
}

# beta provider required for gke
provider "google-beta" {
  access_token = data.vault_generic_secret.resource_editor.data["token"]
  project      = data.terraform_remote_state.project.outputs.project_id
  region       = "europe-west2"
}

locals {
  tfe_organization       = "nwm-proving-v2"
  tfe_project_workspace  = "prv1-pe-sandbox-project"
  region                 = "europe-west2"
  master_ipv4_cidr_block = "10.124.233.144/28"
  cluster_ip_range_name  = "shd-private1-sn-prv1-gke-pod-euw2"
  services_ip_range_name = "shd-private1-sn-prv1-gke-srv-euw2"
  shared_vpc_subnet      = "shd-private1-prv1-euw2"
}

module "gke" {
  source                 = "git::https://gitlab.platform.nwminfra.net/tfe-shared-modules/terraform-gcp-gke-cluster.git?ref=v1.20.1"
  application            = var.application
  cmdb_id                = var.cmdb_id
  cost_center            = var.cost_center
  owner                  = var.owner
  env                    = var.env
  tfe_organization       = local.tfe_organization
  tfe_project_workspace  = local.tfe_project_workspace
  cluster_ip_range_name  = local.cluster_ip_range_name
  services_ip_range_name = local.services_ip_range_name
  master_ipv4_cidr_block = local.master_ipv4_cidr_block
  max_pods_per_node      = 32
  machine_type           = var.machine_type
  data_classification    = var.data_classification
  min_master_version     = "1.17.17-gke.3700"
  node_version           = "1.17.17-gke.3700"
  flux_branch            = "NWMPE-9735-Istio-mTLS-using-vault-intergration-cert-manager"
  node_count             = 1
  cluster_operators      = ["nwm-gcp-pe-developers@natwestmarkets.com"]
}


module "nginx_ingress_controller" {
  source                = "git::https://gitlab.platform.nwminfra.net/tfe-shared-modules/terraform-gcp-reserved-ip-address.git?ref=v0.5.0"
  env                   = var.env
  cmdb_id               = var.cmdb_id
  application           = var.application
  owner                 = var.owner
  cost_center           = var.cost_center
  app_name              = var.application
  purpose               = "nginx-ingress-controller"
  shared_vpc_subnet     = local.shared_vpc_subnet
  shared_vpc_project_id = data.terraform_remote_state.project.outputs.shared_vpc_project_id
}

module "dns_recordset" {
  source          = "git::https://gitlab.platform.nwminfra.net/tfe-shared-modules/terraform-gcp-cloud-dns.git?ref=v1.0.0"
  host_project_id = data.terraform_remote_state.project.outputs.shared_vpc_project_id
  zone_name       = "${var.env}-proj-${var.application}-private-zone"
  module_enabled  = true

  record_type = "A"

  record_names = [
    "*.l7", # wildcard DNS record for the nginx ingress controller
  ]

  record_data = [
    {
      rrdatas = "${module.nginx_ingress_controller.address}"
      ttl     = 300
    },
  ]
}

resource "vault_pki_secret_backend_role" "default" {
  backend             = "proving/pki" // ${var.folder}/pki
  name                = "prv1_dot_gke_dot_gcp_dot_nwminfra_dot_net"
  allow_subdomains                   = true
  allow_glob_domains                 = true
  allow_ip_sans                      = true
  enforce_hostnames                  = false
  require_cn                         = false
  server_flag                        = true
  client_flag                        = true
  basic_constraints_valid_for_non_ca = true
  use_csr_sans                       = true
  allow_any_name                     = true
  ou                                 = ["Platform Engineering",]
  organization                       = ["Natwest Markets",]
  country                            = ["GB",]
  street_address                     = ["England",]
  locality                           = ["London",]
  use_csr_common_name                = true


  allowed_domains = [
    "cert-manager-istio-csr.cert-manager.svc",
    "prv.example.gcp.nwminfra.net",
    "istiod.istio-system.svc",
  ]
  allowed_uri_sans = [
    "*.prv.example.gcp.nwminfra.net",
    "system:serviceaccount:cert-manager:cert-manager-istio-csr" ,
    "cert-manager-istio-csr.cert-manager.svc",     
    "spiffe://cluster.local/ns/*"
  ]

   allowed_other_sans = [
     "*",
   ]

  key_usage           = ["CertSign"]
}

# Used for testing if cert-manager has configured correctly against Vault
resource "vault_kubernetes_auth_backend_role" "default" {
  backend                          = "kubernetes/${module.gke.cluster_name}-cluster"
  role_name                        = "cert-manager"
  bound_service_account_names      = ["*"]
  bound_service_account_namespaces = ["cert-manager"]
  token_ttl                        = 3600
  token_policies                   = ["proving-pki-signer"]
}

# Used for istio cert signing
resource "vault_kubernetes_auth_backend_role" "istio" {
  backend                          = "kubernetes/${module.gke.cluster_name}-cluster"
  role_name                        = "istio-system"
  bound_service_account_names      = ["*"]
  bound_service_account_namespaces = ["istio-system"]
  token_ttl                        = 3600
  token_policies                   = ["proving-pki-signer"]
}
