output "output_time_ist-----" {
  description = "Execution timestamp formatted in IST (+5h 30m)"
  value       = formatdate("YYYY-MM-DD hh:mm:ss 'IST'", timeadd(timestamp(), "5.5h"))
}


output "wazuh_private_ip----" {
  value = aws_instance.wazuh.private_ip
}

output "wazuh_public_ip-----" {
  value = aws_instance.wazuh.public_ip
}

output "wazuh_id------------" {
  value = aws_instance.wazuh.id
}


output "my_current_public_ip" {
  value       = chomp(data.http.my_public_ip.response_body)
  description = "The local public IP address fetched dynamically during terraform run."
}



output "windows_private_ip--" {
  value = aws_instance.windows_endpoint.private_ip
}

output "windows_public_ip---" {
  value = aws_instance.windows_endpoint.public_ip
}


output "windows_id----------" {
  value = aws_instance.windows_endpoint.id
}
