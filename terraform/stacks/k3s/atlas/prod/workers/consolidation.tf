# Workers 2/3 (VMs 103/105) were retired and deleted after replica evacuation.
# Worker 1 inherits the former three workers' combined CPU and RAM.
locals {
  atlas_worker_overrides = {
    "0" = { cpu_cores = 36, memory = 73728 }
  }
}
