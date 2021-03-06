###################################
## Declare environment variables ##
###################################
variable "GC_PROJECT_ID" {}
variable "IMAGE" {}
variable "AWS_SECRET_ACCESS_KEY" {}
variable "AWS_STORAGE_BUCKET_NAME" {}
variable "AWS_ACCESS_KEY_ID" {}
variable "AWS_STORAGE_BUCKET_ARN1" {}
variable "AWS_STORAGE_BUCKET_ARN2" {}


#############################
## Provision AWS S3 bucket ##
#############################
provider "aws" {
  region = "eu-west-2"
  access_key = var.AWS_ACCESS_KEY_ID
  secret_key = var.AWS_SECRET_ACCESS_KEY
}

resource "aws_s3_bucket" "bucket" {
  bucket = var.AWS_STORAGE_BUCKET_NAME
  acl = "public-read-write"
  force_destroy = true
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET"]
    allowed_origins = ["*"]
    max_age_seconds = 3000
  }
  policy =<<POLICY
{
  "Version":"2012-10-17",
  "Statement":[{
    "Sid":"PublicReadGetObject",
    "Effect":"Allow",
    "Principal": "*",
    "Action":["s3:GetObject"],
    "Resource":[
      "${var.AWS_STORAGE_BUCKET_ARN1}",
      "${var.AWS_STORAGE_BUCKET_ARN2}"
    ]
  }]
}
POLICY
}


##########################################################
## Provision PSQL instance and database on Google Cloud ##
##########################################################
provider "google" {
  project = "${var.GC_PROJECT_ID}"
  region      = var.region
##  credentials = file("credentials.json")
}

## Use the Google Secret Manager API for the database secrets
data "google_secret_manager_secret_version" "database_instance_name" {
  secret  = "database_instance_name"
  version = "1"
}

data "google_secret_manager_secret_version" "database_name" {
  secret  = "database_name"
  version = "1"
}

data "google_secret_manager_secret_version" "database_user" {
  secret  = "database_user"
  version = "1"
}

data "google_secret_manager_secret_version" "database_password" {
  secret  = "database_password"
  version = "1"
}

# Create a SQL instance and a PSQL database with user/password
resource "google_sql_database_instance" "myinstance" {
  name = data.google_secret_manager_secret_version.database_instance_name.secret_data
  region = var.region
  database_version = "POSTGRES_11"

  settings {
    tier = "db-f1-micro"
  }
}

resource "google_sql_user" "users" {
  name     = data.google_secret_manager_secret_version.database_user.secret_data
  instance = google_sql_database_instance.myinstance.name
  password = data.google_secret_manager_secret_version.database_password.secret_data
}

resource "google_sql_database" "database" {
  name     = data.google_secret_manager_secret_version.database_name.secret_data
  instance = google_sql_database_instance.myinstance.name
}


###########################################
## Run the container on Google Cloud Run ##
###########################################

## The container uses a GCR image created during the Github workflow (the previous step)
resource "google_cloud_run_service" "website" {
  name     = "${var.IMAGE}"
  location = var.location
  depends_on = [aws_s3_bucket.bucket, google_sql_database.database]
  template {
    spec {
      containers {
        image = "gcr.io/${var.GC_PROJECT_ID}/${var.IMAGE}"
      }
    }
    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale"      = "1000"
        "run.googleapis.com/cloudsql-instances" = "${var.GC_PROJECT_ID}:${var.region}:${data.google_secret_manager_secret_version.database_instance_name.secret_data}"
        "run.googleapis.com/client-name"        = "terraform"
      }
    }
  }
  traffic {
    percent         = 100
    latest_revision = true
  }
}

data "google_iam_policy" "noauth" {
  binding {
    role = "roles/run.invoker"
    members = [
      "allUsers",
    ]
  }
}

resource "google_cloud_run_service_iam_policy" "noauth" {
  location    = google_cloud_run_service.website.location
  project     = google_cloud_run_service.website.project
  service     = google_cloud_run_service.website.name
  policy_data = data.google_iam_policy.noauth.policy_data
}


## This outputs the container URL
output "url" {
  value = google_cloud_run_service.website.status[0].url
}