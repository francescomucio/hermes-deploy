# TODO

## Next: Terraform refactor (safe redeploy)

Must be done in this order:

1. **Add Hetzner volume** — new `hcloud_volume` resource for persistent data (~€0.50/month for 10GB). This is a new resource, doesn't destroy anything.
2. **Migrate existing data** — copy `~/.hermes` to the volume on the running server.
3. **Refactor cloud-init** — split into:
   - Minimal `user_data` (just Docker install — rarely changes, no server rebuild)
   - `null_resource` with `remote-exec` for Hermes setup (clone, build, configure)
   - `null_resource` with `remote-exec` for profile deployment (symlinks, SOUL.md)
4. **Test redeploy** — `terraform apply` to validate. Server rebuilds but data survives on the volume.

## Blocked

- **R2 remote state** — Cloudflare TLS cert provisioning is broken (not just us, multiple accounts affected). Config is ready in `main.tf` (commented out). Uncomment and run `terraform init -migrate-state` when resolved.

## Done

- [x] Terraform setup on Hetzner
- [x] Ollama cloud integration
- [x] Discord bot (Claudiano)
- [x] Researcher profile (Barbero)
- [x] Email reading via himalaya (multi-account)
- [x] Timezone configuration
- [x] Deploy key for self-modification (git push)
- [x] Profile symlinks (repo edits are instantly live)
- [x] Deploy repo mounted in container
- [x] README with fork workflow, troubleshooting, model guide
- [x] Dual-gateway fix (s6 + CMD conflict)
- [x] Dashboard tunnel (port 9119)
