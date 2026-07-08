variable "org_name" {
	type    = string
	default = "vinorg"
}

variable "location" {
	type    = string
	default = "southindia"
}

variable "location_short" {
	type    = string
	default = "sin"
}

variable "common_tags" {
	type    = map(string)
	default = {}
}
