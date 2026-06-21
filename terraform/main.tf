terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }

  # Uncomment when Cloudflare R2 TLS cert is provisioned, then run:
  #   terraform init -migrate-state
  # backend "s3" {
  #   bucket = "hermes-tfstate"
  #   key    = "terraform.tfstate"
  #   region = "auto"
  #
  #   endpoints = {
  #     s3 = "https://7cadc6a3832ed2aa72c806180287146f.eu.r2.cloudflarestorage.com"
  #   }
  #
  #   skip_credentials_validation = true
  #   skip_requesting_account_id  = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   skip_s3_checksum            = true
  #   use_path_style              = true
  # }
}

provider "hcloud" {
  token = var.hetzner_token
}

resource "hcloud_ssh_key" "hermes" {
  name       = "hermes-key"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "hermes" {
  name = "hermes-firewall"

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "hermes" {
  name        = "hermes"
  server_type = var.server_type
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.hermes.id]
  firewall_ids = [hcloud_firewall.hermes.id]

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    deploy_repo           = var.deploy_repo
    user_timezone         = var.user_timezone
    ollama_api_key        = var.ollama_api_key
    ollama_model          = var.ollama_model
    discord_bot_token     = var.discord_bot_token
    discord_allowed_users = var.discord_allowed_users
    email_address         = length(var.email_accounts) > 0 ? var.email_accounts[0].email : ""
    email_password        = length(var.email_accounts) > 0 ? var.email_accounts[0].password : ""
    himalaya_config = templatefile("${path.module}/himalaya.toml.tftpl", {
      email_accounts = var.email_accounts
    })
  })
}
