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

  # cloud-init NoCloud seed: root logs in with admin_password, over SSH too.
  # The image keeps these settings; users: [] skips the default "ubuntu" user.
  cd_label = "cidata"
  cd_content = {
    "meta-data" = "instance-id: slatebox-build\nlocal-hostname: slatebox\n"
    "user-data" = <<-EOF
      #cloud-config
      users: []
      chpasswd:
        expire: false
        users:
          - {name: root, password: "${var.admin_password}", type: text}
      ssh_pwauth: true
      write_files:
        - path: /etc/ssh/sshd_config.d/10-slatebox.conf
          content: "PermitRootLogin yes\n"
    EOF
  }

  communicator     = "ssh"
  ssh_username     = "root"
  ssh_password     = var.admin_password
  ssh_timeout      = "15m"
  shutdown_command = "shutdown -P now"
}

build {
  sources = ["source.qemu.slatebox"]

  provisioner "ansible" {
    playbook_file = "${path.root}/ansible/playbook.yml"
    use_proxy     = true
    user          = "root"
    use_sftp      = true
    sftp_command  = "/usr/lib/openssh/sftp-server -e"
    ansible_env_vars = [
      "ANSIBLE_CONFIG=${abspath(path.root)}/ansible/ansible.cfg",
    ]
    extra_arguments = [
      "--extra-vars", jsonencode({
        ext_iface      = var.ext_iface
        scrape_sites   = var.scrape_sites
        scrape_depth   = var.scrape_depth
        scrape_timeout = var.scrape_timeout
        scrape_jobs    = var.scrape_jobs
      }),
    ]
  }
}
