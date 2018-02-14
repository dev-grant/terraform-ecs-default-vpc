provider "aws" {
  region     = "${var.region}"
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
}

resource "aws_key_pair" "dev" {
  key_name   = "dev-key"
  public_key = "${file("mykey.pub")}"
}

resource "aws_ecs_cluster" "cluster" {
  name = "${var.cluster_name}"
}

resource "aws_iam_role" "cluster_instance" {
  name = "awsDockerClusterInstanceRole"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "cluster_instance_ssm" {
  role       = "${aws_iam_role.cluster_instance.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}

resource "aws_iam_role_policy_attachment" "cluster_instance_ecs" {
  role       = "${aws_iam_role.cluster_instance.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "docker" {
  name = "awsDockerClusterInstanceProfile"
  role = "${aws_iam_role.cluster_instance.name}"
}

resource "aws_iam_role" "cluster_service" {
  name = "awsDockerClusterServiceRole"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ecs.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "cluster_service" {
  role       = "${aws_iam_role.cluster_service.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceRole"
}

# security groups (free) instead of vpc (NAT $30/mo)

resource "aws_default_vpc" "default" {
  tags {
    Name = "Default VPC"
  }
}

resource "aws_default_subnet" "default_1a" {
  availability_zone = "us-east-1a"
}

resource "aws_default_subnet" "default_1c" {
  availability_zone = "us-east-1c"
}

resource "aws_default_subnet" "default_1d" {
  availability_zone = "us-east-1d"
}

resource "aws_security_group" "docker_alb" {
  name        = "aws-docker-alb-sg"
  description = "security group for aws docker load balancer"
  vpc_id      = "${aws_default_vpc.default.id}"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "docker_instances" {
  name        = "aws-docker-instances-sg"
  description = "security group for aws docker cluster instances"
  vpc_id      = "${aws_default_vpc.default.id}"

  ingress {
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = ["${aws_security_group.docker_alb.id}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# launch stuff

data "template_file" "launch_init" {
  template = "${file("ecs_setup.tpl")}"

  vars {
    cluster_name = "${aws_ecs_cluster.cluster.name}"
  }
}

resource "aws_launch_configuration" "docker" {
  name = "aws-docker-cluster-launch-config"

  image_id             = "${var.ami}"
  instance_type        = "${var.instance_type}"
  iam_instance_profile = "${aws_iam_instance_profile.docker.name}"
  user_data            = "${data.template_file.launch_init.rendered}"
  security_groups      = ["${aws_security_group.docker_instances.id}"]
  key_name             = "${aws_key_pair.dev.key_name}"
}

# autoscaling
resource "aws_autoscaling_group" "docker_asg" {
  name                 = "aws-docker-cluster-scaling-group"
  availability_zones   = ["us-east-1a", "us-east-1c", "us-east-1d"]
  launch_configuration = "${aws_launch_configuration.docker.name}"
  min_size             = 0
  max_size             = 2
  desired_capacity     = 1

  tag {
    key                 = "Name"
    value               = "AWS Docker Cluster Instance"
    propagate_at_launch = true
  }
}

# application load balancer
resource "aws_alb" "alb" {
  name            = "aws-docker-cluster-alb"
  internal        = false
  security_groups = ["${aws_security_group.docker_alb.id}"]
  subnets         = ["${aws_default_subnet.default_1a.id}", "${aws_default_subnet.default_1c.id}", "${aws_default_subnet.default_1d.id}"]
}

resource "aws_alb_listener" "http" {
  load_balancer_arn = "${aws_alb.alb.arn}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.default.id}"
    type             = "forward"
  }
}

resource "aws_alb_target_group" "default" {
  name     = "aws-docker-cluster-targets"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "${aws_default_vpc.default.id}"

  health_check {
    path     = "/health-alb"
    protocol = "HTTP"
  }
}

output "alb_target_group_arn" {
  value = "${aws_alb_target_group.default.arn}"
}

output "cluster" {
  value = "${aws_ecs_cluster.cluster.name}"
}

variable "cluster_name" {
  default = "main-cluster"
}

# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI_launch_latest.html
variable "ami" {
  default = "ami-5e414e24"
}

variable "instance_type" {
  default = "t2.micro"
}

variable "region" {
  default = "us-east-1"
}

variable "access_key" {}
variable "secret_key" {}
