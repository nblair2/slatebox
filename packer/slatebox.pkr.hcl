packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1"
    }
  }
}

source "qemu" "slatebox" {
  iso_url          = var.ubuntu_image_url
  iso_checksum     = var.ubuntu_image_checksum
  disk_image       = true
  format           = "qcow2"
  disk_size        = var.disk_size
  disk_compression = true
  accelerator      = var.accelerator
  cpu_model        = var.accelerator == "kvm" ? "host" : "max"
  cpus             = var.cpus
  memory           = var.memory
  headless         = true
  output_directory = var.output_dir
  vm_name          = "${var.vm_name}.qcow2"

  # cloud-init NoCloud seed: creates the login user that Packer also builds with
  cd_label = "cidata"
  cd_content = {
    "meta-data" = "instance-id: slatebox-build\nlocal-hostname: slatebox\n"
    "user-data" = <<-EOF
      #cloud-config
      users:
        - name: slatebox
          groups: [sudo]
          shell: /bin/bash
          sudo: "ALL=(ALL) NOPASSWD:ALL"
          lock_passwd: false
          plain_text_passwd: "${var.admin_password}"
      ssh_pwauth: true
    EOF
  }

  communicator = "ssh"
  ssh_username = "slatebox"
  ssh_password = var.admin_password
  ssh_timeout  = "60m"
  # 90-finalize.sh removes passwordless sudo
  shutdown_command = "echo '${var.admin_password}' | sudo -S shutdown -P now"
}

locals {
  repo = "${path.root}/.."
  env = [
    "CORE_VERSION=${var.core_version}",
    "MAP=${var.map}",
    "RJ45_IFACES=${var.rj45_ifaces}",
    "CONTENT_SOURCE=${var.content_source}",
    "S3_ENDPOINT=${var.s3_endpoint}",
    "S3_BUCKET=${var.s3_bucket}",
    "S3_PREFIX=${var.s3_prefix}",
    "S3_REGION=${var.s3_region}",
    "S3_ACCESS_KEY_ID=${var.s3_access_key_id}",
    "S3_SECRET_ACCESS_KEY=${var.s3_secret_access_key}",
    "CA_MODE=${var.ca_mode}",
    "CA_SUBJECT=${var.ca_subject}",
    "CA_DAYS=${var.ca_days}",
    "CRL_URL=${var.crl_url}",
    "CRL_DAYS=${var.crl_days}",
    "BUILD_PROXY=${var.build_proxy}",
    # build_proxy is an HTTPS (CONNECT) proxy; plain HTTP goes direct
    "https_proxy=${var.build_proxy}",
    "HTTPS_PROXY=${var.build_proxy}",
  ]
}

build {
  sources = ["source.qemu.slatebox"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/slatebox/src /tmp/slatebox/config /tmp/slatebox/ca"]
  }

  provisioner "file" {
    sources = [
      "${local.repo}/install.sh",
      "${local.repo}/vendor",
      "${local.repo}/patches",
      "${local.repo}/src",
      "${local.repo}/config",
    ]
    destination = "/tmp/slatebox/src/"
  }

  provisioner "file" {
    source      = var.scrape_sites_file
    destination = "/tmp/slatebox/config/scrape_sites.txt"
  }
  provisioner "file" {
    source      = var.vmail_cfg_file
    destination = "/tmp/slatebox/config/vmail.cfg"
  }
  provisioner "file" {
    source      = var.delegations_file
    destination = "/tmp/slatebox/config/delegations.dns"
  }

  provisioner "file" {
    content     = var.build_ca_file != "" ? file(var.build_ca_file) : ""
    destination = "/tmp/slatebox/build-ca.crt"
  }
  provisioner "file" {
    content     = var.ca_mode == "external" ? file(var.ca_cert_file) : ""
    destination = "/tmp/slatebox/ca/ca.cer"
  }
  provisioner "file" {
    content     = var.ca_mode == "external" ? file(var.ca_key_file) : ""
    destination = "/tmp/slatebox/ca/ca.key"
  }
  provisioner "file" {
    content     = var.ca_chain_file != "" ? file(var.ca_chain_file) : ""
    destination = "/tmp/slatebox/ca/chain.pem"
  }

  provisioner "shell" {
    scripts          = [for f in sort(fileset(path.root, "provision/*.sh")) : "${path.root}/${f}"]
    environment_vars = local.env
    execute_command  = "sudo {{ .Vars }} bash {{ .Path }}"
  }
}
