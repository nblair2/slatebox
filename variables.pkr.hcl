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
  description = "receives slatebox.qc2"
}

variable "admin_password" {
  type        = string
  default     = "slatebox"
  description = "root's password (console and SSH)"
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
  default     = 1
  description = "link depth per site"

  validation {
    condition     = var.scrape_depth >= 1
    error_message = "The scrape_depth must be at least 1."
  }
}

variable "scrape_timeout" {
  type        = string
  default     = "60m"
  description = "time limit for the whole scrape (coreutils timeout); sites still running keep a partial mirror"
}

variable "scrape_jobs" {
  type        = number
  default     = 8
  description = "goscrape processes at once (only scrape_depth >= 2 or several sites use more than one)"

  validation {
    condition     = var.scrape_jobs >= 1
    error_message = "The scrape_jobs value must be at least 1."
  }
}

variable "overlay_dir" {
  type        = string
  default     = ""
  description = "directory copied onto / after topgen's files are installed, before the CA, scrape and mail setup; empty for none"
}
