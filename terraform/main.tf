terraform {
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

resource "hcloud_volume" "hermes_data" {
  name     = "hermes-data"
  size     = 10
  location = var.location
  format   = "ext4"
}

resource "hcloud_server" "hermes" {
  name        = "hermes"
  server_type = var.server_type
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.hermes.id]
  firewall_ids = [hcloud_firewall.hermes.id]

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    volume_id         = hcloud_volume.hermes_data.id
    deploy_public_key = var.deploy_public_key
  })
}

resource "hcloud_volume_attachment" "hermes_data" {
  volume_id = hcloud_volume.hermes_data.id
  server_id = hcloud_server.hermes.id
  automount = true
}

# Render config files with secrets (gitignored)
resource "local_file" "deploy_env" {
  filename        = "${path.module}/.rendered/hermes-deploy.env"
  file_permission = "0600"
  content         = <<-EOF
    DEPLOY_REPO=${var.deploy_repo}
    DEPLOY_KEY=${jsonencode(var.deploy_key)}
    USER_TIMEZONE=${var.user_timezone}
    OLLAMA_API_KEY=${var.ollama_api_key}
    OLLAMA_MODEL=${var.ollama_model}
    DISCORD_BOT_TOKEN=${var.discord_bot_token}
    DISCORD_ALLOWED_USERS=${var.discord_allowed_users}
    EMAIL_ADDRESS=${length(var.email_accounts) > 0 ? var.email_accounts[0].email : ""}
    EMAIL_PASSWORD=${length(var.email_accounts) > 0 ? var.email_accounts[0].password : ""}
  EOF
}

resource "local_file" "himalaya_config" {
  filename        = "${path.module}/.rendered/himalaya-config.toml"
  file_permission = "0600"
  content = templatefile("${path.module}/himalaya.toml.tftpl", {
    email_accounts = var.email_accounts
  })
}

# Hermes setup: clone repos, build Docker, configure
resource "null_resource" "hermes_setup" {
  triggers = {
    server_id = hcloud_server.hermes.id
    env_hash  = local_file.deploy_env.content_sha256
    script_hash = filesha256("${path.module}/scripts/setup-hermes.sh")
  }

  depends_on = [hcloud_volume_attachment.hermes_data]

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
}

# Profile deployment: SOUL.md, himalaya config
resource "null_resource" "hermes_profiles" {
  triggers = {
    server_id     = hcloud_server.hermes.id
    profiles_hash = sha256(join("", [
      file("${path.module}/../profiles/default/SOUL.md"),
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
