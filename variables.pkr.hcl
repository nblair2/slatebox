variable "ubuntu_image_url" {
  type        = string
  default     = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
  description = "Ubuntu 26.04 cloud image"
}

variable "ubuntu_image_checksum" {
  type    = string
  default = "file:https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS"
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory" {
  type        = number
  default     = 8192
  description = "MiB"
}

variable "disk_size" {
  type        = string
  default     = "40G"
  description = "virtual size; the qcow2 is sparse"
}

variable "output_dir" {
  type        = string
  default     = "build/image"
  description = "receives slatebox.qcow2"
}

variable "admin_password" {
  type        = string
  default     = "slatebox"
  description = "password of the 'slatebox' sudo user"
}

variable "ext_iface" {
  type        = string
  default     = "ens4"
  description = "host NIC bridged into the map's RJ45 node (12.0.0.0/24)"
}

variable "scrape_sites" {
  type        = list(string)
  default     = ["https://www.cmu.edu"]
  description = "sites mirrored into the image"

  validation {
    condition     = alltrue([for s in var.scrape_sites : can(regex("^https?://", s))])
    error_message = "Each scrape_sites entry must start with http:// or https://."
  }
}

variable "scrape_depth" {
  type        = number
  default     = 3
  description = "link depth per site"
}

variable "scrape_timeout" {
  type        = string
  default     = "60m"
  description = "time limit per site (coreutils timeout); a partial mirror is kept"
}
