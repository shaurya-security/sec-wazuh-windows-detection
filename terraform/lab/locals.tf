locals {

  ########################################
  # Naming
  ########################################

  owner    = var.owner
  vpc_name = "${local.owner}-vpc"
  igw_name = "${local.owner}-igw"

  subnet_name        = "${local.owner}-subnet"
  public_subnet_name = "${local.subnet_name}-public"

  rtb_name        = "${local.owner}-rtb"
  public_rtb_name = "${local.rtb_name}-public"

  sg_name         = local.sg_name_base
  sg_name_base    = "${local.owner}-sg"
  wazuh_sg_name   = "${local.sg_name_base}-wazuh"
  windows_sg_name = "${local.sg_name_base}-windows"

  ec2_name         = "${local.owner}-instance"
  wazuh_ec2_name   = "${local.ec2_name}-wazuh"
  windows_ec2_name = "${local.ec2_name}-windows-soc"

  bad_actor_ip = "${chomp(data.http.my_public_ip.response_body)}/32"

  ########################################
  # Wazuh versions (single source of truth)
  ########################################

  # "4.14.0" -> "4.14" for the manager installer URL
  wazuh_branch = join(".", slice(split(".", var.wazuh_version), 0, 2))

  # "4.14.0" + "1" -> "wazuh-agent-4.14.0-1.msi"
  wazuh_agent_msi = "wazuh-agent-${var.wazuh_version}-${var.wazuh_agent_msi_revision}.msi"

  ########################################
  # Userdata payloads uploaded to S3
  #
  # Everything under userdata/ EXCEPT *.tpl files, which are rendered
  # inline by Terraform rather than fetched at boot. New scripts dropped
  # into userdata/ are picked up automatically with no changes to s3.tf.
  # (The attack simulation lives in /simulation and is run from the operator's
  # workstation, not shipped to the instances.)
  ########################################

  userdata_dir = "${path.module}/userdata"

  userdata_objects = {
    for f in fileset(local.userdata_dir, "**/*") : f => "${local.userdata_dir}/${f}"
    if !endswith(f, ".tpl")
  }

  # Per-file MD5s, keyed by S3 key. Used downstream so a change to a Linux
  # script does not needlessly replace the Windows box, and vice versa.
  userdata_hashes = {
    for k, p in local.userdata_objects : k => filemd5(p)
  }
}
