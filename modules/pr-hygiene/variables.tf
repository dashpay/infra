variable "name" {
  description = "Name for the host and everything belonging to it. Also the value of the Service tag the deploy role is limited to."
  type        = string
  default     = "pr-hygiene"
}

variable "hostname" {
  description = "Public host name. The service's URL is https://<hostname>, with no trailing slash."
  type        = string
}

variable "zone_id" {
  description = "Route 53 zone that holds the host name."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "A public subnet. The data volume is created in its availability zone."
  type        = string
}

variable "ipam_pool_id" {
  description = "IPAM pool of owned public addresses the Elastic IP is taken from."
  type        = string
}

variable "instance_type" {
  description = "An ARM64 type: the image is built for linux/arm64."
  type        = string
  default     = "t4g.small"
}

variable "data_volume_size" {
  description = "Size of the volume that holds the database, in GiB. The service expects well under 1."
  type        = number
  default     = 10
}

variable "backup_retention_days" {
  description = "Days a daily backup is kept. A backup still holds what an opt-out or account deletion removed, so never longer than 13 months (the service's README, Backup)."
  type        = number
  default     = 90

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 395
    error_message = "Between 7 and 395 days."
  }
}

variable "github_oidc_provider_arn" {
  type = string
}

variable "github_repository" {
  description = "owner/name of the repository whose workflow builds and deploys the image."
  type        = string
}

variable "github_environment" {
  description = "The GitHub environment the deploy job runs in. Restrict it to the protected branch in the repository's settings: that restriction is what keeps other branches from deploying."
  type        = string
}
