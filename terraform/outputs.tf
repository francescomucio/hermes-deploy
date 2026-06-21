output "server_ip" {
  description = "Public IP of the Hermes server"
  value       = hcloud_server.hermes.ipv4_address
}

output "ssh_command" {
  description = "SSH command to connect to the server"
  value       = "ssh root@${hcloud_server.hermes.ipv4_address}"
}

output "dashboard_tunnel" {
  description = "SSH tunnel command to access the Hermes dashboard locally"
  value       = "ssh -L 9119:127.0.0.1:9119 root@${hcloud_server.hermes.ipv4_address}"
}

output "volume_id" {
  description = "Hetzner volume ID for persistent data"
  value       = hcloud_volume.hermes_data.id
}
