########################################
# Wazuh Manager (Amazon Linux 2023)
########################################

resource "aws_instance" "wazuh" {
  ami                         = var.linux_ami_id
  instance_type               = "m7i-flex.large"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.wazuh_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm.name
  user_data_replace_on_change = true

  depends_on = [
    time_sleep.wait_for_iam,
    aws_s3_object.userdata,
  ]

  user_data = templatefile("${local.userdata_dir}/bootstrap.sh.tpl", {
    s3_bucket     = var.userdata_bucket
    timezone      = var.timezone
    wazuh_version = var.wazuh_version
    wazuh_branch  = local.wazuh_branch

    # Only the payloads this instance actually consumes. Each entry is
    # "key => md5", so editing windows.ps1 does NOT churn this instance.
    payloads = {
      for k, v in local.userdata_hashes : k => v
      if contains(["linux-setup.sh", "wazuh-setup.sh", "wazuh-local-rules.xml"], k)
    }
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = local.wazuh_ec2_name }

  # Uncomment to stop a newer Amazon Linux release from forcing a rebuild:
  # lifecycle {
  #   ignore_changes = [ami]
  # }
}

########################################
# Windows SOC Endpoint (Server 2022)
########################################

resource "aws_instance" "windows_endpoint" {
  ami                         = local.windows_ami_id
  instance_type               = "c7i-flex.large"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.windows_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm.name
  user_data_replace_on_change = true

  depends_on = [
    time_sleep.wait_for_iam,
    aws_s3_object.userdata,
  ]

    user_data = templatefile("${local.userdata_dir}/windows-bootstrap.ps1.tpl", {
      s3_bucket        = var.userdata_bucket
      wazuh_manager_ip = aws_instance.wazuh.private_ip
      wazuh_version    = var.wazuh_version
      wazuh_agent_msi  = local.wazuh_agent_msi
      ami_unpinned     = local.windows_ami_unpinned

      # Windows-side provisioning payload only.
      payloads = {
        for k, v in local.userdata_hashes : k => v
        if k == "windows.ps1"
      }
    })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = 60
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = local.windows_ec2_name }
}
