variable "hetzner_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key to authorize on the server"
  type        = string
}


variable "server_type" {
  description = "Hetzner server type (e.g. cx23, cx33)"
  type        = string
  default     = "cx33"
}

variable "location" {
  description = "Hetzner datacenter location (nbg1, fsn1, hel1, ash)"
  type        = string
  default     = "nbg1"
}

variable "user_timezone" {
  description = "User's timezone for scheduling and display (e.g. Europe/Berlin). Server stays UTC internally."
  type        = string
  default     = "Europe/Berlin"
}

variable "deploy_repo" {
  description = "Git URL of this deploy repo (cloned onto the server for self-modification)"
  type        = string
  default     = "git@github.com:francescomucio/hermes-deploy.git"
}

variable "ollama_api_key" {
  description = "Ollama cloud API key"
  type        = string
  sensitive   = true
}

variable "cursor_api_key" {
  description = "Cursor CLI (agent) API key, for headless coding-agent access via the terminal tool"
  type        = string
  sensitive   = true
  default     = ""
}

variable "kitt_github_token" {
  description = "GitHub token for the coder (Kitt) profile — distinct identity from bruno_github_token so PR author != PR reviewer"
  type        = string
  sensitive   = true
  default     = ""
}

variable "bruno_github_token" {
  description = "GitHub token for the bruno-barbieri profile — distinct identity from kitt_github_token so PR reviewer != PR author"
  type        = string
  sensitive   = true
  default     = ""
}

variable "hermes_image_tag" {
  description = "Docker image tag for nousresearch/hermes-agent (e.g. v2026.9.14, latest)"
  type        = string
  default     = "v2026.9.14"
}

variable "ollama_model" {
  description = "Ollama model to use"
  type        = string
  default     = "deepseek-v4.1-flash"
}

variable "discord_bot_token" {
  description = "Discord bot token"
  type        = string
  sensitive   = true
  default     = ""
}

variable "discord_allowed_users" {
  description = "Comma-separated Discord user IDs allowed to interact with the bot"
  type        = string
  default     = ""
}

variable "profile_discord_tokens" {
  description = "Discord bot tokens per profile (profile name → token)"
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "deploy_key" {
  description = "SSH private key for pushing to the deploy repo from the server"
  type        = string
  sensitive   = true
  default     = ""
}

variable "deploy_public_key" {
  description = "SSH public key corresponding to deploy_key (for server authorized_keys)"
  type        = string
  default     = ""
}

variable "r2_access_key_id" {
  description = "Cloudflare R2 access key for backups"
  type        = string
  sensitive   = true
  default     = ""
}

variable "r2_secret_access_key" {
  description = "Cloudflare R2 secret key for backups"
  type        = string
  sensitive   = true
  default     = ""
}

variable "r2_endpoint" {
  description = "Cloudflare R2 S3 endpoint URL"
  type        = string
  default     = "https://7cadc6a3832ed2aa72c806180287146f.eu.r2.cloudflarestorage.com"
}

variable "reddit_username" {
  description = "Reddit account username for Camofox-based browser login (research/Barbero use)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "reddit_password" {
  description = "Reddit account password for Camofox-based browser login (research/Barbero use)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "blind_username" {
  description = "Blind (teamblind.com) account email for Camofox-based browser login (research/Barbero use)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "blind_password" {
  description = "Blind (teamblind.com) account password for Camofox-based browser login (research/Barbero use)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "dario_api_key" {
  description = "Key Hermes sends to the local dario proxy (non-Claude subscriptions/backends only; Claude auth is disabled). Optional — dario is not installed when unset. Generate with `openssl rand -hex 32`."
  type        = string
  sensitive   = true
  default     = ""
}

variable "camofox_api_key" {
  description = "Bearer token that unlocks Camofox's POST /sessions/:userId/cookies cookie-import endpoint (disabled/403 when unset). Optional — generate with `openssl rand -hex 32`."
  type        = string
  sensitive   = true
  default     = ""
}

variable "force_restore" {
  description = <<-EOT
    Force restore-backup.sh to pull the full R2 backup even on an already-
    provisioned server. Default false: routine applies (token/config/script
    changes) skip the multi-minute rclone restore, since it's only actually
    needed on a genuinely fresh server. Set via CLI for a one-off
    (`terraform apply -var="force_restore=true"`) rather than in tfvars —
    leaving it true there would force a restore on every future apply too.
  EOT
  type        = bool
  default     = false
}

variable "email_accounts" {
  description = "Email accounts for himalaya IMAP reading"
  type = list(object({
    name      = string
    email     = string
    password  = string
    imap_host = string
    default   = optional(bool, false)
  }))
  sensitive = true
  default   = []
}

variable "umami_hostname" {
  description = "Public hostname for the self-hosted Umami (e.g. stats.untitleddata.company). Optional — Umami is not installed when unset. Served through the Cloudflare Tunnel \"hermes\"; tunnel and DNS record are managed here, in the zone formed by the last two labels of the hostname."
  type        = string
  default     = ""
}

variable "umami_app_secret" {
  description = "Umami APP_SECRET. Keep the value from the previous install when migrating — it signs share links and login tokens."
  type        = string
  sensitive   = true
  default     = ""
}

variable "umami_hash_salt" {
  description = "Umami HASH_SALT (legacy v2 salt, still read for session hashes). Keep the previous install's value when migrating."
  type        = string
  sensitive   = true
  default     = ""
}

variable "umami_db_password" {
  description = "Password of the local Umami Postgres. Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token for Terraform (created by hand): Account → Cloudflare Tunnel Edit; Zone → DNS Edit + Zone Read on the managed zones"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (same account as the R2 buckets)"
  type        = string
  default     = "7cadc6a3832ed2aa72c806180287146f"
}

variable "github_runners" {
  description = <<-EOT
    Self-hosted GitHub Actions runners on the VPS (scripts/setup-runner.sh), for private repos only.
    name => { url = "https://github.com/ORG" (org runner) or "https://github.com/OWNER/REPO" (repo runner),
    token = fine-grained PAT, created by hand: org "Self-hosted runners: Read and write" or repo "Administration: Read and write" }.
    Empty = no runners.
  EOT
  type = map(object({
    url   = string
    token = string
  }))
  sensitive = true
  default   = {}
}
