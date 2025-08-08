#!/bin/bash
# Migration script to convert existing monolithic templates to modular structure
# This script helps transition from single large template files to organized per-app directories

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_ROLES_DIR="${1:-${SCRIPT_DIR}/../ansible/roles/k3s-apps}"
TEMPLATES_DIR="${ANSIBLE_ROLES_DIR}/templates"

echo "🔄 Migrating to modular template structure"
echo "========================================"
echo "📂 Templates directory: $TEMPLATES_DIR"
echo ""

# Function to split a monolithic template into modular parts
split_template() {
    local app_name="$1"
    local template_file="$2"
    
    echo "📦 Processing $app_name..."
    
    # Create app directory
    mkdir -p "${TEMPLATES_DIR}/${app_name}"
    
    # Extract different resource types from the monolithic template
    if [[ -f "$template_file" ]]; then
        echo "   📝 Splitting ${template_file##*/}..."
        
        # Use awk to split the file by resource type
        awk '
        BEGIN { 
            output_file = ""; 
            in_resource = 0; 
            content = ""; 
        }
        /^---$/ && NR > 1 {
            if (output_file != "" && content != "") {
                print content > output_file;
                close(output_file);
            }
            content = "";
            next;
        }
        /^# .*Namespace/ || /^kind: Namespace/ {
            output_file = "'${TEMPLATES_DIR}'/'${app_name}'/namespace.yaml.j2";
            content = "---\n";
        }
        /^# .*ConfigMap/ || /^kind: ConfigMap/ {
            output_file = "'${TEMPLATES_DIR}'/'${app_name}'/configmap.yaml.j2";
            content = "---\n";
        }
        /^# .*Secret/ || /^kind: Secret/ {
            output_file = "'${TEMPLATES_DIR}'/'${app_name}'/secrets.yaml.j2";
            content = "---\n";
        }
        /^# .*PersistentVolume/ || /^kind: PersistentVolume/ {
            output_file = "'${TEMPLATES_DIR}'/'${app_name}'/pv-pvc.yaml.j2";
            content = "---\n";
        }
        /^# .*Deployment/ || /^kind: Deployment/ {
            output_file = "'${TEMPLATES_DIR}'/'${app_name}'/deployment.yaml.j2";
            content = "---\n";
        }
        /^# .*Service/ || /^kind: Service/ {
            output_file = "'${TEMPLATES_DIR}'/'${app_name}'/service.yaml.j2";
            content = "---\n";
        }
        /^# .*Ingress/ || /^kind: Ingress/ {
            output_file = "'${TEMPLATES_DIR}'/'${app_name}'/ingress.yaml.j2";
            content = "---\n";
        }
        {
            if (output_file != "") {
                content = content $0 "\n";
            }
        }
        END {
            if (output_file != "" && content != "") {
                print content > output_file;
                close(output_file);
            }
        }
        ' "$template_file"
        
        echo "   ✅ Created modular templates in ${TEMPLATES_DIR}/${app_name}/"
        ls -la "${TEMPLATES_DIR}/${app_name}/" | sed 's/^/      /'
        
        # Backup original file
        mv "$template_file" "${template_file}.backup"
        echo "   💾 Original template backed up as ${template_file##*/}.backup"
    else
        echo "   ⚠️  Template file $template_file not found"
    fi
    echo ""
}

# Process existing templates
echo "🔍 Looking for existing monolithic templates..."

# Check for homepage
if [[ -f "${TEMPLATES_DIR}/homepage-hostpath.yaml.j2" ]]; then
    split_template "homepage" "${TEMPLATES_DIR}/homepage-hostpath.yaml.j2"
fi

# Check for bookstack (it's already split, but we can organize it better)
if [[ -f "${TEMPLATES_DIR}/bookstack-hostpath.yaml.j2" ]]; then
    split_template "bookstack" "${TEMPLATES_DIR}/bookstack-hostpath.yaml.j2"
fi

# Copy bookstack secrets to the new structure
if [[ -f "${TEMPLATES_DIR}/bookstack-secrets.yaml.j2" ]]; then
    echo "📦 Moving BookStack secrets..."
    mkdir -p "${TEMPLATES_DIR}/bookstack"
    mv "${TEMPLATES_DIR}/bookstack-secrets.yaml.j2" "${TEMPLATES_DIR}/bookstack/secrets.yaml.j2"
    echo "   ✅ Moved bookstack-secrets.yaml.j2 to bookstack/secrets.yaml.j2"
    echo ""
fi

echo "🎉 Migration complete!"
echo "==================="
echo ""
echo "📁 New structure:"
find "${TEMPLATES_DIR}" -name "*.j2" -type f | grep -E "(bookstack|homepage|common)/" | sort | sed 's/^/   /'
echo ""
echo "💾 Backup files created:"
find "${TEMPLATES_DIR}" -name "*.backup" -type f | sed 's/^/   /'
echo ""
echo "🔧 Next steps:"
echo "   1. Update your task files to use the new modular templates"
echo "   2. Test the deployments to ensure they work correctly"
echo "   3. Remove the .backup files once you're satisfied"
echo ""
echo "📖 Example task update:"
echo '   - name: Apply app namespace'
echo '     shell: kubectl apply -f -'
echo '     args:'
echo '       stdin: "{{ lookup('"'"'template'"'"', '"'"'myapp/namespace.yaml.j2'"'"') }}"'
