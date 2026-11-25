variable "network" {
  description = "The Dash network this serves. It prefixes every name, as the existing resources are named: mainnet-dash-core, testnet-quorum-tg."
  type        = string

  validation {
    condition     = contains(["mainnet", "testnet"], var.network)
    error_message = "The network must be \"mainnet\" or \"testnet\": the Core ports and dash.conf are known for these two only."
  }
}

variable "region" {
  description = "Region of everything here except DNS and the CloudFront distribution, which are global."
  type        = string
}

# --- Where it sits ---

variable "vpc_id" {
  description = "The shared VPC."
  type        = string
}

variable "vpc_cidr" {
  description = "The VPC's address range. Core accepts RPC from it (rpcallowip in dash.conf); the security groups narrow that down."
  type        = string
}

variable "host_subnet_id" {
  description = "Private subnet for the Core backend and the quorum server."
  type        = string
}

variable "efs_subnet_ids" {
  description = "Private subnets that get a mount target for Core's file system, keyed by any stable name."
  type        = map(string)
}

variable "efs_replica_region" {
  description = "Region EFS keeps a replica of Core's file system in, or null for no replica."
  type        = string
  default     = null
}

variable "bastion_security_group_id" {
  description = "Security group of the bastion: the only source allowed to SSH to the two hosts."
  type        = string
}

# --- Hosts ---

variable "ami_id" {
  description = "Image for a new host. Running hosts ignore it."
  type        = string
}

variable "key_name" {
  description = "EC2 key pair for the ubuntu user."
  type        = string
}

variable "core_private_ip" {
  description = "Fixed private address of the Core backend. The quorum server's configuration names it, so a rebuilt backend must come back on the same address."
  type        = string
}

variable "core_version" {
  description = "Dash Core release a new backend installs at first boot, for example \"23.1.8\". Running hosts ignore it: they are upgraded by hand. Never set it below the version that last wrote the data directory."
  type        = string
}

variable "core_conf_extra" {
  description = "Extra dash.conf lines for a new, empty file system. An existing dash.conf is never rewritten."
  type        = list(string)
  default     = []
}

variable "core_rpc_extra_cidrs" {
  description = "Address ranges allowed to reach Core's RPC port in addition to the quorum server. Empty unless the live group already has such a rule."
  type        = list(string)
  default     = []
}

variable "quorum_server_version" {
  description = "Release tag of dashpay/quorum-list-server a new quorum server installs at first boot, for example \"v0.8.0\". Running hosts ignore it."
  type        = string
}

# --- Load balancer ---

variable "alb_security_group_id" {
  description = "Security group of the shared load balancer: the only source allowed to reach the quorum server's port."
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name of the shared load balancer. It is the CloudFront distribution's origin."
  type        = string
}

variable "listener_arn" {
  description = "The load balancer's HTTPS listener. This network adds one rule to it."
  type        = string
}

variable "listener_rule_priority" {
  description = "Priority of this network's rule on the shared listener. Other services have rules there too: pick a free number."
  type        = number
}

variable "serving_instance_id" {
  description = "Instance registered in the target group. Leave null for this module's own quorum server; set it when another host serves instead."
  type        = string
  default     = null
}

# --- Public name ---

variable "zone_id" {
  description = "Route 53 zone for the public name."
  type        = string
}

variable "zone_name" {
  description = "Name of that zone, without a trailing dot. The public name is quorums.<network>.<zone_name>."
  type        = string
}

variable "cdn_certificate_arn" {
  description = "ACM certificate in us-east-1 for the CloudFront distribution. It must cover the public name."
  type        = string
}

variable "cdn_template_body" {
  description = "The CloudFormation template that makes the CloudFront distribution, as text."
  type        = string
}
