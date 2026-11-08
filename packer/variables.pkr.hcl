# --- VM / image -------------------------------------------------------------
variable "ubuntu_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
}
variable "ubuntu_image_checksum" {
  type    = string
  default = "file:https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS"
}
variable "accelerator" {
  type        = string
  default     = "kvm"
  description = "kvm, or tcg when /dev/kvm is unavailable (much slower)"
}
variable "cpus" {
  type    = number
  default = 4
}
variable "memory" {
  type    = number
  default = 8192
}
variable "disk_size" {
  type    = string
  default = "20G"
}
variable "output_dir" {
  type    = string
  default = "../build/image"
}
variable "vm_name" {
  type    = string
  default = "slatebox"
}
variable "admin_password" {
  type        = string
  default     = "slatebox"
  description = "password of the 'slatebox' login user (sudo)"
}

# --- greybox / CORE ---------------------------------------------------------
variable "core_version" {
  type    = string
  default = "9.2.1"
}
variable "map" {
  type        = string
  default     = "backbone"
  description = "vendor/greybox/share/maps/<map>.imn"
}
variable "rj45_ifaces" {
  type        = string
  default     = ""
  description = "map RJ45 placeholders to real NICs, e.g. \"ethX=ens4\""
}

# --- web content ------------------------------------------------------------
variable "content_source" {
  type    = string
  default = "scrape"
  validation {
    condition     = contains(["scrape", "s3"], var.content_source)
    error_message = "The content_source must be \"scrape\" or \"s3\"."
  }
}
variable "scrape_sites_file" {
  type    = string
  default = "../config/scrape_sites.txt"
}
variable "vmail_cfg_file" {
  type    = string
  default = "../config/vmail.cfg"
}
variable "delegations_file" {
  type    = string
  default = "../config/delegations.dns"
}
variable "s3_endpoint" {
  type    = string
  default = ""
}
variable "s3_bucket" {
  type    = string
  default = ""
}
variable "s3_prefix" {
  type    = string
  default = ""
}
variable "s3_region" {
  type    = string
  default = "us-east-1"
}
variable "s3_access_key_id" {
  type      = string
  default   = ""
  sensitive = true
}
variable "s3_secret_access_key" {
  type      = string
  default   = ""
  sensitive = true
}

# --- PKI --------------------------------------------------------------------
variable "ca_mode" {
  type    = string
  default = "self"
  validation {
    condition     = contains(["self", "external"], var.ca_mode)
    error_message = "The ca_mode must be \"self\" or \"external\"."
  }
}
variable "ca_subject" {
  type    = string
  default = "/C=US/ST=PA/L=Pgh/O=CMU/OU=CERT/CN=topgen_ca"
}
variable "ca_days" {
  type    = number
  default = 7300
}
variable "ca_cert_file" {
  type        = string
  default     = ""
  description = "external mode: PEM CA certificate"
}
variable "ca_key_file" {
  type        = string
  default     = ""
  description = "external mode: PEM CA private key"
}
variable "ca_chain_file" {
  type        = string
  default     = ""
  description = "external mode (optional): PEM chain up to the external root"
}
variable "crl_url" {
  type    = string
  default = "http://topgen.info/topgen_ca.crl"
}
variable "crl_days" {
  type    = number
  default = 3650
}

# --- build-time network -----------------------------------------------------
variable "build_proxy" {
  type        = string
  default     = ""
  description = "HTTPS (CONNECT) proxy used only during the build, e.g. http://10.0.2.2:3128"
}
variable "build_ca_file" {
  type        = string
  default     = ""
  description = "extra PEM CA bundle trusted only during the build (e.g. the proxy's CA)"
}
