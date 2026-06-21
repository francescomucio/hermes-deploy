# TODO

## Next

- **R2 backup for Hermes data** — cron job to sync `~/.hermes` to the `hermes-backups` R2 bucket. Disaster recovery if the volume is lost.
- **docker-compose.override.yml improvements** — currently idempotent but could be cleaner. Consider versioning it in the deploy repo instead of generating in the setup script.
- **Update README** — reflect new architecture (pre-built image, volume, split scripts)

## Ideas

- Pre-built image caching / pinning to a specific version tag
- Cloudflare Tunnel for dashboard access without SSH
- Additional messaging integrations (Telegram, Slack)
- Automated Hermes updates (pull latest image, restart)

## Done

- [x] Terraform setup on Hetzner
- [x] Ollama cloud integration (deepseek-v4-flash)
- [x] Discord bot (Claudiano)
- [x] Researcher profile (Barbero)
- [x] Email reading via himalaya (multi-account)
- [x] Timezone configuration
- [x] Deploy key for self-modification (git push from Claudiano)
- [x] Self-management: Claudiano can edit profiles, copy to live, commit and push
- [x] Deploy repo mounted in container
- [x] README with fork workflow, troubleshooting, model guide
- [x] Dual-gateway fix (s6 + CMD conflict)
- [x] Dashboard on port 9119
- [x] R2 remote state (Cloudflare EU bucket)
- [x] Hetzner volume for persistent data
- [x] Terraform refactor: minimal cloud-init + remote-exec scripts
- [x] Pre-built Docker image from Docker Hub (deploy ~3 min vs ~12 min)
- [x] Clean deploy verified: single terraform apply works end-to-end
