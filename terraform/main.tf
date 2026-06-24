terraform {
  required_version = ">= 1.5"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }

  backend "s3" {
    bucket = "hermes-tfstate"
    key    = "terraform.tfstate"
    region = "auto"

    endpoints = {
      s3 = "https://7cadc6a3832ed2aa72c806180287146f.eu.r2.cloudflarestorage.com"
    }

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
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
    deploy_public_key = var.deploy_public_key
  })

  # Backup before destroy — uses ssh-agent (deploy key must be loaded)
  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue
    inline = [
      "if command -v rclone &> /dev/null && [ -f /usr/local/bin/hermes-backup ]; then echo '=== Pre-destroy backup ===' && /usr/local/bin/hermes-backup && echo '=== Backup complete ==='; else echo 'Backup not configured, skipping'; fi"
    ]
    connection {
      type  = "ssh"
      host  = self.ipv4_address
      user  = "root"
      agent = true
    }
  }
}

# Render config files with secrets (gitignored)
resource "local_file" "deploy_env" {
  filename        = "${path.module}/.rendered/hermes-deploy.env"
  file_permission = "0600"
  content         = <<-EOF
    HERMES_IMAGE_TAG=${var.hermes_image_tag}
    DEPLOY_REPO=${var.deploy_repo}
    DEPLOY_KEY=${jsonencode(var.deploy_key)}
    USER_TIMEZONE=${var.user_timezone}
    OLLAMA_API_KEY=${var.ollama_api_key}
    OLLAMA_MODEL=${var.ollama_model}
    DISCORD_BOT_TOKEN=${var.discord_bot_token}
    DISCORD_ALLOWED_USERS=${var.discord_allowed_users}
    EMAIL_ADDRESS=${length(var.email_accounts) > 0 ? var.email_accounts[0].email : ""}
    EMAIL_PASSWORD=${length(var.email_accounts) > 0 ? var.email_accounts[0].password : ""}
    PROFILE_DISCORD_TOKENS='${jsonencode(var.profile_discord_tokens)}'
    R2_ACCESS_KEY_ID=${var.r2_access_key_id}
    R2_SECRET_ACCESS_KEY=${var.r2_secret_access_key}
    R2_ENDPOINT=${var.r2_endpoint}
  EOF
}

resource "local_file" "deploy_key_file" {
  filename        = "${path.module}/.rendered/deploy_key"
  file_permission = "0600"
  content         = var.deploy_key
}

resource "local_file" "himalaya_config" {
  filename        = "${path.module}/.rendered/himalaya-config.toml"
  file_permission = "0600"
  content = templatefile("${path.module}/himalaya.toml.tftpl", {
    email_accounts = var.email_accounts
  })
}

# Hermes setup: clone repos, pull image, configure
resource "null_resource" "hermes_setup" {
  triggers = {
    server_id   = hcloud_server.hermes.id
    env_hash    = local_file.deploy_env.content_sha256
    script_hash = filesha256("${path.module}/scripts/setup-hermes.sh")
  }

  connection {
    type        = "ssh"
    host        = hcloud_server.hermes.ipv4_address
    user        = "root"
    private_key = var.deploy_key
  }

  provisioner "remote-exec" {
    inline = ["cloud-init status --wait || true"]
  }

  provisioner "file" {
    source      = local_file.deploy_env.filename
    destination = "/tmp/hermes-deploy.env"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/setup-hermes.sh"
    destination = "/tmp/setup-hermes.sh"
  }

  provisioner "remote-exec" {
    inline = ["chmod +x /tmp/setup-hermes.sh && /tmp/setup-hermes.sh"]
  }

  # Restore from R2 backup (fresh deploy gets latest data)
  provisioner "file" {
    source      = "${path.module}/scripts/restore-backup.sh"
    destination = "/tmp/restore-backup.sh"
  }

  provisioner "remote-exec" {
    inline = ["chmod +x /tmp/restore-backup.sh && /tmp/restore-backup.sh"]
  }
}

# Profile deployment: SOUL.md, himalaya config
resource "null_resource" "hermes_profiles" {
  triggers = {
    server_id     = hcloud_server.hermes.id
    profiles_hash = sha256(join("", [
      file("${path.module}/../profiles/default/SOUL.md"),
      file("${path.module}/../profiles/bruno-barbieri/SOUL.md"),
      file("${path.module}/../profiles/calvino/SOUL.md"),
      file("${path.module}/../profiles/cannavacciuolo/SOUL.md"),
      file("${path.module}/../profiles/coder/SOUL.md"),
      file("${path.module}/../profiles/researcher/SOUL.md"),
      local_file.himalaya_config.content_sha256,
    ]))
  }

  depends_on = [null_resource.hermes_setup]

  connection {
    type        = "ssh"
    host        = hcloud_server.hermes.ipv4_address
    user        = "root"
    private_key = var.deploy_key
  }

  provisioner "file" {
    source      = local_file.deploy_env.filename
    destination = "/tmp/hermes-deploy.env"
  }

  provisioner "file" {
    source      = local_file.himalaya_config.filename
    destination = "/tmp/himalaya-config.toml"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/deploy-profiles.sh"
    destination = "/tmp/deploy-profiles.sh"
  }

  provisioner "remote-exec" {
    inline = ["chmod +x /tmp/deploy-profiles.sh && /tmp/deploy-profiles.sh"]
  }
}

# R2 backup: every 30 min sync of Hermes data to Cloudflare R2
resource "null_resource" "hermes_backups" {
  triggers = {
    server_id   = hcloud_server.hermes.id
    script_hash = filesha256("${path.module}/scripts/setup-backups.sh")
  }

  depends_on = [null_resource.hermes_setup]

  connection {
    type        = "ssh"
    host        = hcloud_server.hermes.ipv4_address
    user        = "root"
    private_key = var.deploy_key
  }

  provisioner "file" {
    source      = local_file.deploy_env.filename
    destination = "/tmp/hermes-deploy.env"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/setup-backups.sh"
    destination = "/tmp/setup-backups.sh"
  }

  provisioner "remote-exec" {
    inline = ["chmod +x /tmp/setup-backups.sh && /tmp/setup-backups.sh"]
  }
}
