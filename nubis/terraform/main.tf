module "worker" {
  source            = "github.com/nubisproject/nubis-terraform//worker?ref=v2.0.0"
  region            = "${var.region}"
  environment       = "${var.environment}"
  account           = "${var.account}"
  service_name      = "${var.service_name}"
  purpose           = "webserver"
  ami               = "${var.ami}"
  elb               = "${module.load_balancer.name}"
  ssh_key_file      = "${var.ssh_key_file}"
  ssh_key_name      = "${var.ssh_key_name}"
  nubis_sudo_groups = "${var.nubis_sudo_groups}"
  nubis_user_groups = "${var.nubis_user_groups}"
  instance_type     = "m3.medium"
  health_check_type = "ELB"     # EC2 or ELB
  min_instances	    = 3
  
}

module "load_balancer" {
  source       = "github.com/nubisproject/nubis-terraform//load_balancer?ref=v2.0.0"
  region       = "${var.region}"
  environment  = "${var.environment}"
  account      = "${var.account}"
  service_name = "${var.service_name}"
  health_check_target = "HTTP:80/?redirect=0"
  ssl_cert_name_prefix = "${var.service_name}"
  health_check_timeout = 5
  idle_timeout = 300
}

module "dns" {
  source       = "github.com/nubisproject/nubis-terraform//dns?ref=v2.0.0"
  region       = "${var.region}"
  environment  = "${var.environment}"
  account      = "${var.account}"
  service_name = "${var.service_name}"
  target       = "${module.load_balancer.address}"
}

module "database" {
  source                 = "github.com/nubisproject/nubis-terraform//database?ref=v2.0.0"
  region                 = "${var.region}"
  environment            = "${var.environment}"
  account                = "${var.account}"
  monitoring             = true
  service_name           = "${var.service_name}"
  client_security_groups = "${module.worker.security_group}"
  allocated_storage      = 20
  multi_az               = true
  instance_class         = "db.t2.medium"
}

module "cache" {
  source                 = "github.com/nubisproject/nubis-terraform//cache?ref=develop"
  region                 = "${var.region}"
  environment            = "${var.environment}"
  account                = "${var.account}"
  service_name           = "${var.service_name}"
  client_security_groups = "${module.worker.security_group}"
}

module "storage" {
  source                 = "github.com/nubisproject/nubis-terraform//storage?ref=v2.0.0"
  region                 = "${var.region}"
  environment            = "${var.environment}"
  account                = "${var.account}"
  service_name           = "${var.service_name}"
  storage_name           = "${var.service_name}"
  client_security_groups = "${module.worker.security_group}"
}

module "mail" {
  source       = "github.com/nubisproject/nubis-terraform//mail?ref=develop"
  region       = "${var.region}"
  environment  = "${var.environment}"
  account      = "${var.account}"
  service_name = "${var.service_name}"
}
