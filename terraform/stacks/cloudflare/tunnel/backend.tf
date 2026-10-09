terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket       = "home-infra-terraform-state"
    key          = "cloudflare/tunnel/terraform.tfstate"
    region       = "auto"
    encrypt      = true
    use_lockfile = true
    endpoints = {
      s3 = "https://e0e043685655b3d2d63201a6c84fc409.r2.cloudflarestorage.com"
    }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
