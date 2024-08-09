variable "project_name" {
    type = string
    default = "expense"
}
variable "environment" {
    default = "dev"
}
variable "common_tags" {
    default = {
        project = "expense"
        environment = "dev" 
        component = "frontend"
        terraform = true
    }
}
variable "zone_name" {
    default = "muvva.online"
}
variable "app_version" {

}