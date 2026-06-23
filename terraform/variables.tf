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
  description = "Hetzner server type (e.g. cx22, cpx11)"
  type        = string
  default     = "cx22"
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

variable "hermes_image_tag" {
  description = "Docker image tag for nousresearch/hermes-agent (e.g. v2026.6.19, latest)"
  type        = string
  default     = "v2026.6.19"
}

variable "ollama_model" {
  description = "Ollama model to use"
  type        = string
  default     = "deepseek-v4-flash"
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
