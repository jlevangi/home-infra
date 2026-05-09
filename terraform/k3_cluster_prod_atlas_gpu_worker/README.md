# Atlas GPU Worker

This Terraform stack creates a single dedicated K3s worker VM on `atlas` for
the Quadro P4000 passthrough path used by Jellyfin and Plex.

## Purpose

- Keep the existing three prod workers focused on Longhorn storage.
- Add a dedicated GPU worker with passthrough-ready VM settings.
- Leave the live storage worker topology unchanged.

## Preconditions

- `atlas` has already been prepared for GPU passthrough.
- The Quadro P4000 functions are bound to `vfio-pci`.
- The `debian12-server-template` cloud-init template exists on `atlas`.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

After the VM is created, run the normal cluster deployment workflow:

```bash
../../scripts/deploy-k3s-cluster.sh --prod
```
