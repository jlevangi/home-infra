#!/bin/bash

# Deploy test cluster using Terraform with auto-approve
# First destroys existing cluster, then applies fresh deployment

pushd ../terraform/k3_3node_test_cluster

echo "Destroying existing test cluster with Terraform..."
terraform destroy --auto-approve

echo "Deploying test cluster with Terraform..."
terraform apply --auto-approve

popd