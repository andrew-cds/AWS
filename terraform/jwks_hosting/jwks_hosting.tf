terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# 1. Configured for Canada Central (Montreal)
provider "aws" {
  region = "ca-central-1" 
}

# 2. Define your applications and their local file mappings
variable "apps_and_jwks" {
  type = map(string)
  default = {
    "rpsim"   = "rpsim/jwks.json"   # maps to: /app-one/.well-known/jwks
    # "app-two"   = "jwks-two.json"   # maps to: /app-two/.well-known/jwks
    # "marketing" = "jwks-mktg.json"  # maps to: /marketing/.well-known/jwks
  }
}

# 3. Private S3 Bucket (Data resides physically in Canada Central)
resource "aws_s3_bucket" "jwks_bucket" {
  bucket        = "can-central-multi-app-jwks-storage"
  force_destroy = true
}

# 4. Block All Public Access to S3 (Well-Architected Security Requirement)
resource "aws_s3_bucket_public_access_block" "jwks_bucket_privacy" {
  bucket = aws_s3_bucket.jwks_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 5. Dynamic multi-file upload loop
resource "aws_s3_object" "jwks_files" {
  for_each = var.apps_and_jwks

  bucket       = aws_s3_bucket.jwks_bucket.id
  key          = "${each.key}/.well-known/jwks"
  source       = each.value
  content_type = "application/json"
}

# 6. CloudFront Origin Access Control (OAC)
resource "aws_cloudfront_origin_access_control" "jwks_oac" {
  name                              = "multi-app-jwks-oac"
  description                       = "Allows CloudFront to access private Canadian S3 jwks bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 7. CloudFront Distribution
resource "aws_cloudfront_distribution" "jwks_distribution" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudFront distribution for Canadian multi-app JWKS"
  default_root_object = ""

  origin {
    domain_name              = aws_s3_bucket.jwks_bucket.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.jwks_bucket.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.jwks_oac.id
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.jwks_bucket.id}"

    # Forces CloudFront to bypass edge caching entirely (TTL = 0)
    # Uses the managed AWS "CachingDisabled" policy
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

    viewer_protocol_policy = "redirect-to-https" # Forces HTTPS
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# 8. Bucket Policy allowing CloudFront OAC to read files
resource "aws_s3_bucket_policy" "allow_cloudfront_oac" {
  bucket = aws_s3_bucket.jwks_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipalReadOnly"
        Effect    = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.jwks_bucket.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.jwks_distribution.arn
          }
        }
      }
    ]
  })
}

# Outputs to grab your live URLs instantly
output "all_jwks_urls" {
  value = {
    for app, file in var.apps_and_jwks : 
    app => "https://${aws_cloudfront_distribution.jwks_distribution.domain_name}/${app}/.well-known/jwks"
  }
  description = "The exact production URLs to fetch the JWKS file for each application"
}
