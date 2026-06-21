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

## Done

- [x] Terraform setup on Hetzner
- [x] Ollama cloud integration
- [x] Discord bot (Claudiano)
- [x] Researcher profile (Barbero)
- [x] Email reading via himalaya (multi-account)
- [x] Timezone configuration
- [x] Deploy key for self-modification (git push)
- [x] Self-management: Claudiano can edit profiles, copy to live, commit and push
- [x] Deploy repo mounted in container
- [x] README with fork workflow, troubleshooting, model guide
- [x] Dual-gateway fix (s6 + CMD conflict)
- [x] Dashboard tunnel (port 9119)
- [x] R2 remote state (Cloudflare EU bucket)
