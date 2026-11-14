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
  disk_discard     = "unmap"
  accelerator      = "kvm"
  cpu_model        = "host"
  cpus             = var.cpus
  memory           = var.memory
  headless         = true
  output_directory = var.output_dir
  vm_name          = "slatebox.qcow2"
  # full boot and cloud-init console, kept for CI
  qemuargs = [["-serial", "file:serial-build.log"]]

  # cloud-init NoCloud seed: creates the user Packer logs in as
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
  ssh_timeout  = "15m"
  # provision.sh removes passwordless sudo
  shutdown_command = "echo '${var.admin_password}' | sudo -S shutdown -P now"
}

build {
  sources = ["source.qemu.slatebox"]

  # uploads to /tmp/files
  provisioner "file" {
    source      = "${path.root}/files"
    destination = "/tmp/"
  }

  provisioner "shell" {
    script          = "${path.root}/scripts/provision.sh"
    execute_command = "sudo {{ .Vars }} bash {{ .Path }}"
    environment_vars = [
      "EXT_IFACE=${var.ext_iface}",
      "SCRAPE_SITES=${join(" ", var.scrape_sites)}",
      "SCRAPE_DEPTH=${var.scrape_depth}",
      "SCRAPE_TIMEOUT=${var.scrape_timeout}",
    ]
  }
}
