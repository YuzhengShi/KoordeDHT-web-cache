variable "region" {
  description = "AWS region"
  default     = "us-west-2"
}

variable "instance_type" {
  description = "EC2 instance type"
  default     = "t3.micro"
}

variable "node_count" {
  description = "Number of Koorde nodes"
  default     = 8
}

variable "existing_instance_profile" {
  description = "Name of an existing IAM instance profile to use (optional). If not provided, a new role and profile will be created."
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID to deploy into (optional). If empty, uses default VPC."
  type        = string
  default     = ""
}
