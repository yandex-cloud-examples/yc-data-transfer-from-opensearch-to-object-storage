# Infrastructure for the Yandex Managed Service for OpenSearch, Object Storage, and Data Transfer
#
# RU: https://cloud.yandex/ru/docs/data-transfer/tutorials/opensearch-to-object-storage
# EN: https://cloud.yandex/en/docs/data-transfer/tutorials/opensearch-to-object-storage
#
# Configure the parameters of the source claster, target backet and transfer:

locals {
  folder_id    = "" # Your cloud folder ID, same as for provider
  mos_version  = "" # Desired version of the Opensearch. For available versions, see the documentation main page: https://yandex.cloud/en/docs/managed-opensearch/.
  mos_password = "" # OpenSearch admin's password
  bucket_name  = "" # Name of an Object Storage bucket. Must be unique in the Cloud

  # Specify these settings ONLY AFTER the cluster and bucket are created. Then run the "terraform apply" command again.
  # You should set up the endpoints using the GUI to obtain their IDs
  source_endpoint_id = "" # Set the source endpoint ID
  target_endpoint_id = "" # Set the target endpoint ID
  transfer_enabled   = 0  # Set to 1 to enable the transfer

  # The following settings are predefined. Change them only if necessary.
  network_name        = "network"                               # Name of the network
  subnet_name         = "subnet-a"                              # Name of the subnet
  security_group_name = "security-group"                        # Name of the security group
  mos_cluster_name    = "opensearch-cluster"                    # Name of the OpenSearch cluster
  sa_name             = "sa-for-transfer"                       # Name of the service account
  transfer_name       = "opensearch-to-object-storage-transfer" # Name of the transfer from the Managed Service for OpenSearch cluster to the Object Storage bucket
}

resource "yandex_vpc_network" "network" {
  description = "Network for Managed Service for OpenSearch cluster and Object Storage bucket"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["10.1.0.0/16"]
}

resource "yandex_vpc_security_group" "security-group" {
  description = "Security group for the Managed Service for OpenSearch cluster and Object Storage bucket"
  name        = local.security_group_name
  network_id  = yandex_vpc_network.network.id

  ingress {
    description    = "The rule allows connections to the Managed Service for OpenSearch cluster from the Internet"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "The rule allows connections to the Managed Service for OpenSearch cluster from the Internet with Dashboards"
    protocol       = "TCP"
    port           = 9200
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "The rule allows all outgoing traffic"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# Infrastructure for the Managed Service for OpenSearch cluster

resource "yandex_mdb_opensearch_cluster" "opensearch-cluster" {
  description        = "Managed Service for OpenSearch cluster"
  name               = local.mos_cluster_name
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  security_group_ids = [yandex_vpc_security_group.security-group.id]

  config {

    version        = local.mos_version
    admin_password = local.mos_password

    opensearch {
      node_groups {
        name             = "opensearch-group"
        assign_public_ip = true
        hosts_count      = 1
        zone_ids         = ["ru-central1-a"]
        subnet_ids       = [yandex_vpc_subnet.subnet-a.id]
        roles            = ["DATA", "MANAGER"]
        resources {
          resource_preset_id = "s2.micro"  # 2 vCPU, 8 GB RAM
          disk_size          = 10737418240 # Bytes
          disk_type_id       = "network-ssd"
        }
      }
    }

    dashboards {
      node_groups {
        name             = "dashboards-group"
        assign_public_ip = true
        hosts_count      = 1
        zone_ids         = ["ru-central1-a"]
        subnet_ids       = [yandex_vpc_subnet.subnet-a.id]
        resources {
          resource_preset_id = "s2.micro"  # 2 vCPU, 8 GB RAM
          disk_size          = 10737418240 # Bytes
          disk_type_id       = "network-ssd"
        }
      }
    }
  }

  maintenance_window {
    type = "ANYTIME"
  }
}

# Create a service account to manage buckets
resource "yandex_iam_service_account" "sa-for-transfer" {
  description = "A service account to manage buckets"
  folder_id   = local.folder_id
  name        = local.sa_name
}

# Grant permission to the service account
resource "yandex_resourcemanager_folder_iam_member" "storage-editor" {
  folder_id = local.folder_id
  role      = "storage.editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa-for-transfer.id}"
}

# Create a static key for the service account
resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  description        = "Static access key for Object Storage"
  service_account_id = yandex_iam_service_account.sa-for-transfer.id
}

# Use the static key to create a bucket
resource "yandex_storage_bucket" "obj-storage-bucket" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  bucket     = local.bucket_name
}

# Create transfer
resource "yandex_datatransfer_transfer" "opensearch-to-object-storage-transfer" {
  description = "Transfer from the Managed Service for OpenSearch cluster to the Object Storage bucket"
  count       = local.transfer_enabled
  name        = local.transfer_name
  source_id   = local.source_endpoint_id
  target_id   = local.target_endpoint_id
  type        = "SNAPSHOT_ONLY" # Copy all data from the source
}