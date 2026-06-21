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

variable "deploy_repo" {
  description = "Git URL of this deploy repo (cloned onto the server for self-modification)"
  type        = string
  default     = "https://github.com/francescomucio/hermes-deploy.git"
}

variable "ollama_api_key" {
  description = "Ollama cloud API key"
  type        = string
  sensitive   = true
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
