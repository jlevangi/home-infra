#!/usr/bin/env python3
"""Generate the n8n workflow that feeds the health ingester.

The workflow is deliberately thin: list every file in the Health Sync folders,
ask the ingester which ones it still needs, download only those, and POST them.
All parsing, dedup and schema knowledge lives in the ingester, so a naming
change upstream can no longer silently drop a metric.

Output is committed so the workflow is reviewable and restorable; n8n's own
database is otherwise the only copy.
"""

import json
import pathlib

INGESTER = "http://health-ingester.health-archive.svc.cluster.local"
DRIVE_CREDS = {"googleDriveOAuth2Api": {"id": "cX1eVebTaIrIk4b6", "name": "Google Drive account"}}

FOLDERS = {
    "Health Sync Steps": "113y4ZIRKmbBm96Uo_lPVpTjkVu7zXulY",
    "Health Sync Heart rate": "10IkFt7tAl_m0CZpp7d3ienTQrJrdH3uq",
    "Health Sync Sleep": "1VVACpLXTpR1ilnpnnzQf7TYcAqyaiGx0",
    "Health Sync Energy burned": "1iWCZXxnMKqDep0gnmZgIVozMJGZZ9bun",
    "Health Sync Activities": "1CMrcyqBCvGR8a0niDh2IZMo4MrmNWFXl",
    "Health Sync Weight": "10TadE9PkwqJ3av9jc7ghzv8Bkvx5axGF",
    "Health Sync Oxygen saturation": "19vi1YNxIc13e8lEVO3vIfok6bfOJCs2e",
}

LOAD_FOLDERS_JS = f"""// Folder ids are stable Health Sync export destinations.
const folders = {json.dumps(FOLDERS, indent=2)};
return [{{ json: {{ folders }} }}];
"""

SPLIT_FOLDERS_JS = """const folders = Object.entries($input.first().json.folders);
return folders.map(([folderName, folderId]) => ({ json: { folderName, folderId } }));
"""

SELECT_NEEDED_JS = f"""// Ask the ingester which files it still needs. It answers from its own
// ledger, so a file that previously parsed to zero observations is retried --
// that is exactly the backlog this rewrite exists to recover.
const INGESTER = '{INGESTER}';

const folders = $('Load Folders').first().json.folders;
const nameByFolderId = new Map(Object.entries(folders).map(([name, id]) => [id, name]));

const candidates = $input.all().map(item => {{
  const file = item.json;
  const folderId = (file.parents || [])[0] || '';
  return {{
    file_id: file.id,
    version_key: String(file.version ?? ''),
    file_name: file.name || '',
    folder_id: folderId,
    folder_name: nameByFolderId.get(folderId) || '',
    modified_time: file.modifiedTime || '',
    md5_checksum: file.md5Checksum || '',
  }};
}}).filter(c => c.file_id);

if (candidates.length === 0) return [];

const response = await this.helpers.httpRequest({{
  method: 'POST',
  url: INGESTER + '/files/filter',
  body: {{ files: candidates }},
  json: true,
}});

const wanted = new Set((response.needed || []).map(n => `${{n.file_id}}\\u0000${{n.version_key}}`));
const selected = candidates.filter(c => wanted.has(`${{c.file_id}}\\u0000${{c.version_key}}`));

// Cap each run. The initial backlog is thousands of files that previously
// parsed to nothing; draining it in one execution would blow n8n's timeout
// and hammer the Drive API. At 15-minute intervals this still clears in hours,
// and steady-state runs are far below the cap.
const MAX_FILES_PER_RUN = 250;
return selected.slice(0, MAX_FILES_PER_RUN).map(c => ({{ json: c }}));
"""

SEND_JS = f"""// One POST per file. Failures are returned rather than thrown so a single
// unreadable export cannot abort the whole run.
const INGESTER = '{INGESTER}';
const meta = $json;

let buffer;
try {{
  buffer = await this.helpers.getBinaryDataBuffer(0, 'data');
}} catch (error) {{
  return {{ json: {{ ...meta, status: 'no-binary', error: String(error) }} }};
}}

try {{
  const result = await this.helpers.httpRequest({{
    method: 'POST',
    url: INGESTER + '/ingest',
    body: {{ ...meta, content_base64: buffer.toString('base64') }},
    json: true,
  }});
  return {{ json: {{ ...meta, status: 'ok', ...result }} }};
}} catch (error) {{
  return {{ json: {{ ...meta, status: 'error', error: String(error).slice(0, 300) }} }};
}}
"""


def code_node(name, js, position, mode=None):
    params = {"jsCode": js}
    if mode:
        params["mode"] = mode
    return {
        "parameters": params,
        "id": name.lower().replace(" ", "-"),
        "name": name,
        "type": "n8n-nodes-base.code",
        "typeVersion": 2,
        "position": position,
    }


workflow = {
    "id": "healthArchIngV2a",
    "name": "Health Archive Ingest v2",
    "nodes": [
        {
            "parameters": {"rule": {"interval": [{"field": "cronExpression", "expression": "*/15 * * * *"}]}},
            "id": "every-15-minutes",
            "name": "Every 15 Minutes",
            "type": "n8n-nodes-base.scheduleTrigger",
            "typeVersion": 1.2,
            "position": [-260, 0],
        },
        code_node("Load Folders", LOAD_FOLDERS_JS, [-40, 0]),
        code_node("Split Folders", SPLIT_FOLDERS_JS, [180, 0]),
        {
            "parameters": {
                "resource": "fileFolder",
                "searchMethod": "query",
                # No name predicate: Health Sync's naming varies by upstream
                # source and a name filter is what hid entire metrics before.
                "queryString": "mimeType != 'application/vnd.google-apps.folder'",
                "returnAll": True,
                "filter": {
                    "folderId": {"__rl": True, "mode": "id", "value": "={{ $json.folderId }}"},
                    "whatToSearch": "files",
                    "includeTrashed": False,
                },
                "options": {"fields": ["id", "name", "version", "modifiedTime", "md5Checksum", "parents"]},
            },
            "id": "list-files",
            "name": "List Files",
            "type": "n8n-nodes-base.googleDrive",
            "typeVersion": 3,
            "position": [400, 0],
            "credentials": DRIVE_CREDS,
        },
        code_node("Select Needed Files", SELECT_NEEDED_JS, [620, 0]),
        {
            "parameters": {"operation": "download", "fileId": "={{ $json.file_id }}", "options": {}},
            "id": "download-file",
            "name": "Download File",
            "type": "n8n-nodes-base.googleDrive",
            "typeVersion": 2,
            "position": [840, 0],
            "credentials": DRIVE_CREDS,
            "onError": "continueRegularOutput",
        },
        code_node("Send To Ingester", SEND_JS, [1060, 0], mode="runOnceForEachItem"),
    ],
    "connections": {
        "Every 15 Minutes": {"main": [[{"node": "Load Folders", "type": "main", "index": 0}]]},
        "Load Folders": {"main": [[{"node": "Split Folders", "type": "main", "index": 0}]]},
        "Split Folders": {"main": [[{"node": "List Files", "type": "main", "index": 0}]]},
        "List Files": {"main": [[{"node": "Select Needed Files", "type": "main", "index": 0}]]},
        "Select Needed Files": {"main": [[{"node": "Download File", "type": "main", "index": 0}]]},
        "Download File": {"main": [[{"node": "Send To Ingester", "type": "main", "index": 0}]]},
    },
    "settings": {"executionOrder": "v1"},
}

out = pathlib.Path(__file__).parent / "health-archive-ingest-v2.json"
out.write_text(json.dumps([workflow], indent=2) + "\n")
print(f"wrote {out} ({len(workflow['nodes'])} nodes)")
