output "output_time_ist" {
  description = "Execution timestamp formatted in IST (+5h 30m). Impure: changes on every plan."
  value       = formatdate("YYYY-MM-DD hh:mm:ss 'IST'", timeadd(timestamp(), "5.5h"))
}

########################################
# Wazuh manager
########################################

output "wazuh_private_ip" {
  description = "Private IP the Windows agent enrolls against."
  value       = aws_instance.wazuh.private_ip
}

output "wazuh_public_ip" {
  description = "Public IP for the Wazuh dashboard (https://<ip>:443)."
  value       = aws_instance.wazuh.public_ip
}

output "wazuh_id" {
  description = "EC2 instance ID of the Wazuh manager (for SSM Session Manager)."
  value       = aws_instance.wazuh.id
}

output "wazuh_dashboard_url" {
  description = "Convenience URL for the dashboard."
  value       = "https://${aws_instance.wazuh.public_ip}:443"
}

########################################
# Windows endpoint
########################################

output "windows_private_ip" {
  description = "Private IP of the Windows endpoint."
  value       = aws_instance.windows_endpoint.private_ip
}

output "windows_public_ip" {
  description = "Public IP of the Windows endpoint (RDP target for the simulation)."
  value       = aws_instance.windows_endpoint.public_ip
}

output "windows_id" {
  description = "EC2 instance ID of the Windows endpoint (for SSM Session Manager)."
  value       = aws_instance.windows_endpoint.id
}

########################################
# Pinning helpers
########################################

output "resolved_windows_ami_id" {
  description = <<-EOT
    The Windows AMI actually in use. On first apply this comes from the SSM
    latest-AMI parameter. Copy it into terraform.tfvars as windows_ami_id to
    pin the instance and stop re-applies from replacing it.
  EOT
  value       = aws_instance.windows_endpoint.ami
  sensitive   = true
}

output "resolved_amazon_linux_ami_id" {
  description = "The Amazon Linux 2023 AMI in use, for the same pinning purpose."
  value       = aws_instance.wazuh.ami
}

########################################
# Versions in effect
########################################

output "wazuh_versions" {
  description = "Manager and agent versions, guaranteed to match by construction."
  value = {
    version     = var.wazuh_version
    branch      = local.wazuh_branch
    agent_msi   = local.wazuh_agent_msi
    manager_url = "https://packages.wazuh.com/${local.wazuh_branch}/wazuh-install.sh"
  }
}

output "my_current_public_ip" {
  description = "Local public IP fetched during the run; used to scope dashboard access."
  value       = chomp(data.http.my_public_ip.response_body)
}
