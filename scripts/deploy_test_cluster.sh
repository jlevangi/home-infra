#!/bin/bash

# Deploy test cluster using Terraform with auto-approve

cd terraform/k3_3node_test_cluster

echo "Deploying test cluster with Terraform..."
terraform apply --auto-approve