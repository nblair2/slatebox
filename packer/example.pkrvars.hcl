# Example build settings: `make image VARS=packer/my.pkrvars.hcl`.
# Every variable has a default (see variables.pkr.hcl); relative paths are
# relative to the packer/ directory.

accelerator = "kvm" # "tcg" without /dev/kvm (slow)
cpus        = 4
memory      = 8192
disk_size   = "20G"

admin_password = "slatebox"

map = "backbone"
# rj45_ifaces = "ethX=ens4"

content_source    = "scrape"
scrape_sites_file = "../config/scrape_sites.txt"
vmail_cfg_file    = "../config/vmail.cfg"
delegations_file  = "../config/delegations.dns"

# content_source       = "s3"
# s3_endpoint          = "https://s3.example.net"
# s3_bucket            = "topgen-content"
# s3_prefix            = "range1"
# s3_access_key_id     = "..."   # or PKR_VAR_s3_access_key_id in the environment
# s3_secret_access_key = "..."

ca_mode    = "self"
ca_subject = "/C=US/ST=PA/L=Pgh/O=CMU/OU=CERT/CN=topgen_ca"
# ca_mode       = "external"
# ca_cert_file  = "/path/to/ca.cer"
# ca_key_file   = "/path/to/ca.key"
# ca_chain_file = "/path/to/chain.pem"

crl_url = "http://topgen.info/topgen_ca.crl"

# build_proxy   = "http://10.0.2.2:3128"   # 10.0.2.2 = the build host under QEMU user networking
# build_ca_file = "/path/to/proxy-ca.pem"
