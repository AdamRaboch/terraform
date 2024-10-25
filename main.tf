provider "aws" {
  region = "us-east-1"
}

# VPC Module
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name   = "my-demo-vpc"
  cidr   = "10.10.0.0/16"

    azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.10.1.0/24", "10.10.2.0/24"]
  public_subnets  = ["10.10.101.0/24", "10.10.102.0/24"]

  enable_nat_gateway  = true
  single_nat_gateway  = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# Security Group for Jenkins EC2 instance
resource "aws_security_group" "jenkins_sg" {
  name        = "jenkins-sg"
  description = "Security group for Jenkins EC2 instance"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
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

# EC2 Instance for Jenkins
resource "aws_instance" "jenkins_master" {
  ami                    = "ami-0ce4a9b15766b97ce"
  instance_type          = "t3.small"
  key_name               = "linuxED"
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.jenkins_sg.id]
  associate_public_ip_address = true
  iam_instance_profile   = aws_iam_instance_profile.ec2_admin_profile.name

  root_block_device {
    volume_size = 20
    volume_type = "gp2"
  }

  tags = {
    Name = "Jenkins-Master"
  }
}

# Elastic IP for Jenkins
resource "aws_eip" "jenkins_eip" {
  domain = "vpc"
}

# Associate the Elastic IP with Jenkins EC2 instance
resource "aws_eip_association" "eip_association" {
  instance_id   = aws_instance.jenkins_master.id
  allocation_id = aws_eip.jenkins_eip.id
}

# IAM Role for EC2 Admin
resource "aws_iam_role" "ec2_admin_role" {
  name = "EC2-Admin"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

# IAM Instance Profile for EC2 Admin
resource "aws_iam_instance_profile" "ec2_admin_profile" {
  name = "EC2-Admin"
  role = aws_iam_role.ec2_admin_role.name
}

# Attach EC2 FullAccess policy to the role
resource "aws_iam_policy_attachment" "ec2_admin_policy" {
  name       = "EC2AdminPolicyAttach"
  roles      = [aws_iam_role.ec2_admin_role.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

# IAM Role for EKS Cluster
resource "aws_iam_role" "eks_role" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      },
    ]
  })
}

# Attach EKS Cluster Policy to the role
resource "aws_iam_role_policy_attachment" "eks_policy" {
  role       = aws_iam_role.eks_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# IAM Role for EKS Node Group
resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

# Attach necessary policies for EKS Node Group
resource "aws_iam_policy_attachment" "eks_node_policy" {
  name       = "EKSNodePolicyAttach"
  roles      = [aws_iam_role.eks_node_role.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_policy_attachment" "eks_cni_policy" {
  name       = "EKSCniPolicyAttach"
  roles      = [aws_iam_role.eks_node_role.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_policy_attachment" "eks_registry_policy" {
  name       = "EKSRegistryPolicyAttach"
  roles      = [aws_iam_role.eks_node_role.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Security Group for EKS Cluster
resource "aws_security_group" "eks_sg" {
  vpc_id = module.vpc.vpc_id
  name   = "eks-sg"

  ingress {
    from_port   = 443
    to_port     = 443
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

# Create EKS Cluster
resource "aws_eks_cluster" "this" {
  name     = "my-terra-cluster"
  role_arn = aws_iam_role.eks_role.arn

  vpc_config {
        # Add cluster endpoint access settings here
    endpoint_public_access  = true
    endpoint_private_access = true
    subnet_ids          = module.vpc.private_subnets
    security_group_ids  = [aws_security_group.eks_sg.id]


  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_policy
  ]
}

# Wait for the EKS Cluster to be active
resource "null_resource" "wait_for_cluster" {
  depends_on = [
    aws_eks_cluster.this
  ]

  provisioner "local-exec" {
    command = "aws eks wait cluster-active --name ${aws_eks_cluster.this.name} --region us-east-1"
  }
}

# Create EKS Node Group
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "terra-eks"
  node_role_arn   = aws_iam_role.eks_node_role.arn  # Updated to use the new node role
  subnet_ids      = module.vpc.private_subnets

  depends_on = [
    null_resource.wait_for_cluster
  ]

  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 1
  }

  instance_types = ["t3.small"]

  tags = {
    Name = "terra-eks"
  }
}

# Output the cluster endpoint
output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

# Output the cluster kubeconfig command
output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region us-east-1"
}
