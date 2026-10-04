# Retain workers 2/3 powered off as rollback; do not reduce vm_count until
# their retained VM disks are separately approved for deletion.
# Worker 1 inherits the former three workers' combined CPU and RAM.
locals {
  atlas_worker_overrides = {
    "0" = { cpu_cores = 36, memory = 73728 }
    "1" = { start_at_node_boot = false, vm_state = "stopped" }
    "2" = { start_at_node_boot = false, vm_state = "stopped" }
  }
}
