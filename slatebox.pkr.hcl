packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1.1"
    }
  }
}

source "qemu" "slatebox" {
  iso_url          = var.ubuntu_image_url
  iso_checksum     = var.ubuntu_image_checksum
  disk_image       = true
  disk_size        = var.disk_size
  disk_compression = true
  disk_discard     = "unmap"
  accelerator      = "kvm"
  cpu_model        = "host"
  cpus             = var.cpus
  memory           = var.memory
  headless         = true
  output_directory = "output"
  vm_name          = "slatebox.qc2"
  # full boot and cloud-init console, kept for CI
  qemuargs = [["-serial", "file:serial-build.log"]]

  cd_label = "cidata"
  cd_content = {
    "meta-data" = "instance-id: slatebox-build\nlocal-hostname: slatebox\n"
    "user-data" = templatefile("${path.root}/cloud-init.yml.pkrtpl", { admin_password = var.admin_password })
  }

  ssh_username     = "root"
  ssh_password     = var.admin_password
  ssh_timeout      = "15m"
  shutdown_command = "shutdown -P now"
}

build {
  sources = ["source.qemu.slatebox"]

  provisioner "ansible" {
    playbook_file = "${path.root}/ansible/playbook.yml"
    user          = "root"
    use_sftp      = true
    sftp_command  = "/usr/lib/openssh/sftp-server -e"
    ansible_env_vars = [
      "ANSIBLE_CONFIG=${abspath(path.root)}/ansible/ansible.cfg",
    ]
    extra_arguments = [
      "--verbose",
      "--extra-vars", jsonencode({
        scrape_sites     = var.scrape_sites
        scrape_depth     = var.scrape_depth
        scrape_timeout   = var.scrape_timeout
        scrape_jobs      = var.scrape_jobs
        scrape_site_jobs = var.scrape_site_jobs
        mail_sites       = var.mail_sites
        overlay_dir      = var.overlay_dir == "" ? "" : abspath(var.overlay_dir)
      }),
    ]
  }
}
