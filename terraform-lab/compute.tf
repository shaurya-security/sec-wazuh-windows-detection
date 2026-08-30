
resource "aws_instance" "wazuh" {

  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "m7i-flex.large"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.wazuh_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm.name
  user_data_replace_on_change = true

  depends_on = [
    time_sleep.wait_for_iam,
    aws_s3_object.common_sh,
    aws_s3_object.wazuh_sh
  ]

  user_data = templatefile("${path.module}/userdata/s3-bootstrap.sh.tpl", {
    s3_bucket   = "shaurya-terraform-userdata-2026"
    script_name = "wazuh.sh"
    common_hash = filemd5("${path.module}/userdata/common.sh")
    script_hash = filemd5("${path.module}/userdata/wazuh.sh")
    timezone    = "Asia/Kolkata"
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

}



resource "aws_instance" "windows_endpoint" {
  ami                         = data.aws_ssm_parameter.windows_2022_ami.value
  instance_type               = "c7i-flex.large"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.windows_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm.name
  user_data_replace_on_change = true

  depends_on = [
    time_sleep.wait_for_iam,
    aws_s3_object.windows_ps1
  ]


  user_data = templatefile("${path.module}/userdata/windows-bootstrap.ps1.tpl", {
    wazuh_manager_ip = aws_instance.wazuh.private_ip
    windows_hash     = filemd5("${path.module}/userdata/windows.ps1")
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted = true
  }

  tags = {
    Name = "${local.ec2_name}-windows-soc"
  }
}
