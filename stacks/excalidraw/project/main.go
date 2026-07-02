package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

//go:embed static/*
var staticFiles embed.FS

type Drawing struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	Modified time.Time `json:"modified"`
	Size     int64     `json:"size"`
}

var dataDir string

func main() {
	dataDir = os.Getenv("DATA_DIR")
	if dataDir == "" {
		dataDir = "/data"
	}

	// Ensure data directory exists
	if err := os.MkdirAll(dataDir, 0755); err != nil {
		log.Fatalf("Failed to create data directory: %v", err)
	}

	http.HandleFunc("/", handleDashboard)
	http.HandleFunc("/api/drawings", handleListDrawings)
	http.HandleFunc("/api/drawings/", handleDrawing)
	http.HandleFunc("/api/user", handleUser)
	http.HandleFunc("/draw/", handleDraw)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Starting server on :%s with data dir: %s", port, dataDir)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

// getUsername extracts username from Authentik header, returns "anonymous" if not set
func getUsername(r *http.Request) string {
	username := r.Header.Get("X-Authentik-Username")
	if username == "" {
		username = "anonymous"
	}
	// Sanitize to prevent directory traversal
	username = filepath.Base(username)
	return username
}

var invalidNameChars = regexp.MustCompile(`[^a-zA-Z0-9-_]`)

// sanitizeName normalizes a user-supplied drawing name into a safe file ID
// (same charset the dashboard applies on create). Returns "" if nothing
// meaningful remains.
func sanitizeName(name string) string {
	name = strings.TrimSpace(name)
	name = strings.TrimSuffix(name, ".excalidraw")
	name = invalidNameChars.ReplaceAllString(name, "-")
	if strings.Trim(name, "-") == "" {
		return ""
	}
	return name
}

// getUserDataDir returns the data directory for a specific user and ensures it exists
func getUserDataDir(username string) string {
	userDir := filepath.Join(dataDir, username)
	if err := os.MkdirAll(userDir, 0755); err != nil {
		log.Printf("Warning: Failed to create user directory %s: %v", userDir, err)
	}
	return userDir
}

func handleDashboard(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, dashboardHTML)
}

func handleListDrawings(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	username := getUsername(r)
	userDataDir := getUserDataDir(username)

	files, err := os.ReadDir(userDataDir)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	var drawings []Drawing
	for _, f := range files {
		if f.IsDir() || !strings.HasSuffix(f.Name(), ".excalidraw") {
			continue
		}

		info, err := f.Info()
		if err != nil {
			continue
		}

		id := strings.TrimSuffix(f.Name(), ".excalidraw")
		drawings = append(drawings, Drawing{
			ID:       id,
			Name:     id,
			Modified: info.ModTime(),
			Size:     info.Size(),
		})
	}

	// Sort by modified time, newest first
	sort.Slice(drawings, func(i, j int) bool {
		return drawings[i].Modified.After(drawings[j].Modified)
	})

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(drawings)
}

func handleDrawing(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/api/drawings/")
	if id == "" {
		http.Error(w, "Missing drawing ID", http.StatusBadRequest)
		return
	}

	username := getUsername(r)
	userDataDir := getUserDataDir(username)

	// Sanitize ID to prevent directory traversal
	id = filepath.Base(id)
	filePath := filepath.Join(userDataDir, id+".excalidraw")

	switch r.Method {
	case http.MethodGet:
		data, err := os.ReadFile(filePath)
		if err != nil {
			if os.IsNotExist(err) {
				http.Error(w, "Drawing not found", http.StatusNotFound)
			} else {
				http.Error(w, err.Error(), http.StatusInternalServerError)
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(data)

	case http.MethodPut, http.MethodPost:
		data, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		if err := os.WriteFile(filePath, data, 0644); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "saved", "id": id})

	case http.MethodPatch:
		var req struct {
			Name string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Invalid JSON body", http.StatusBadRequest)
			return
		}
		newID := sanitizeName(req.Name)
		if newID == "" {
			http.Error(w, "Invalid name", http.StatusBadRequest)
			return
		}
		if _, err := os.Stat(filePath); err != nil {
			if os.IsNotExist(err) {
				http.Error(w, "Drawing not found", http.StatusNotFound)
			} else {
				http.Error(w, err.Error(), http.StatusInternalServerError)
			}
			return
		}
		if newID != id {
			newPath := filepath.Join(userDataDir, newID+".excalidraw")
			if _, err := os.Stat(newPath); err == nil {
				http.Error(w, "A drawing with that name already exists", http.StatusConflict)
				return
			}
			if err := os.Rename(filePath, newPath); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "renamed", "id": newID})

	case http.MethodDelete:
		if err := os.Remove(filePath); err != nil {
			if os.IsNotExist(err) {
				http.Error(w, "Drawing not found", http.StatusNotFound)
			} else {
				http.Error(w, err.Error(), http.StatusInternalServerError)
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "deleted", "id": id})

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

// handleUser returns the current authenticated user info
func handleUser(w http.ResponseWriter, r *http.Request) {
	username := getUsername(r)
	email := r.Header.Get("X-Authentik-Email")
	name := r.Header.Get("X-Authentik-Name")

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"username": username,
		"email":    email,
		"name":     name,
	})
}

func handleDraw(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/draw/")
	if id == "" {
		http.Error(w, "Missing drawing ID", http.StatusBadRequest)
		return
	}

	// Serve the static editor.html - the JS will parse the ID from the URL
	data, err := staticFiles.ReadFile("static/editor.html")
	if err != nil {
		http.Error(w, "Editor not found", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(data)
}

const dashboardHTML = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Excalidraw Library</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #1a1a2e;
            color: #eee;
            min-height: 100vh;
            padding: 2rem;
        }
        .container { max-width: 900px; margin: 0 auto; }
        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 2rem;
            padding-bottom: 1rem;
            border-bottom: 1px solid #333;
        }
        .header-left { display: flex; align-items: center; gap: 1rem; }
        h1 { font-size: 1.5rem; }
        .user-info {
            font-size: 0.9rem;
            color: #a29bfe;
            padding: 0.4rem 0.8rem;
            background: #252542;
            border-radius: 6px;
        }
        .btn {
            background: #6c5ce7;
            color: white;
            border: none;
            padding: 0.75rem 1.5rem;
            border-radius: 8px;
            cursor: pointer;
            font-size: 1rem;
            text-decoration: none;
            display: inline-block;
        }
        .btn:hover { background: #5b4cdb; }
        .btn-danger { background: #e74c3c; }
        .btn-danger:hover { background: #c0392b; }
        .btn-secondary { background: #3d3d5c; }
        .btn-secondary:hover { background: #4a4a70; }
        .btn-small { padding: 0.4rem 0.8rem; font-size: 0.85rem; }
        .drawings { display: grid; gap: 1rem; }
        .drawing {
            background: #252542;
            border-radius: 12px;
            padding: 1.25rem;
            display: flex;
            justify-content: space-between;
            align-items: center;
            transition: transform 0.1s, box-shadow 0.1s;
        }
        .drawing:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 12px rgba(0,0,0,0.3);
        }
        .drawing-info { flex: 1; }
        .drawing-name {
            font-size: 1.1rem;
            font-weight: 500;
            margin-bottom: 0.25rem;
            color: #fff;
            text-decoration: none;
        }
        .drawing-name:hover { color: #a29bfe; }
        .drawing-meta { font-size: 0.85rem; color: #888; }
        .drawing-actions { display: flex; gap: 0.5rem; }
        .empty {
            text-align: center;
            padding: 4rem 2rem;
            color: #666;
        }
        .modal {
            display: none;
            position: fixed;
            top: 0; left: 0; right: 0; bottom: 0;
            background: rgba(0,0,0,0.7);
            align-items: center;
            justify-content: center;
            z-index: 1000;
        }
        .modal.active { display: flex; }
        .modal-content {
            background: #252542;
            padding: 2rem;
            border-radius: 12px;
            width: 90%;
            max-width: 400px;
        }
        .modal h2 { margin-bottom: 1rem; }
        .modal input {
            width: 100%;
            padding: 0.75rem;
            border: 1px solid #444;
            border-radius: 8px;
            background: #1a1a2e;
            color: #fff;
            font-size: 1rem;
            margin-bottom: 1rem;
        }
        .modal-actions { display: flex; gap: 0.5rem; justify-content: flex-end; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="header-left">
                <h1>Excalidraw Library</h1>
                <span id="user-info" class="user-info">Loading...</span>
            </div>
            <button class="btn" onclick="showNewModal()">+ New Drawing</button>
        </header>
        <div id="drawings" class="drawings">
            <div class="empty">Loading...</div>
        </div>
    </div>

    <div id="modal" class="modal">
        <div class="modal-content">
            <h2 id="modal-title">New Drawing</h2>
            <input type="text" id="drawingName" placeholder="Drawing name..." autofocus>
            <div class="modal-actions">
                <button class="btn" style="background:#444" onclick="hideModal()">Cancel</button>
                <button class="btn" id="modal-confirm" onclick="confirmModal()">Create</button>
            </div>
        </div>
    </div>

    <script>
        async function loadUser() {
            try {
                const resp = await fetch('/api/user');
                const user = await resp.json();
                const el = document.getElementById('user-info');
                if (user.name) {
                    el.textContent = user.name;
                } else if (user.username) {
                    el.textContent = user.username;
                } else {
                    el.textContent = 'Guest';
                }
            } catch (e) {
                document.getElementById('user-info').textContent = 'Guest';
            }
        }

        function drawingRow(d) {
            var row = document.createElement('div');
            row.className = 'drawing';

            var info = document.createElement('div');
            info.className = 'drawing-info';
            var nameLink = document.createElement('a');
            nameLink.className = 'drawing-name';
            nameLink.href = '/draw/' + encodeURIComponent(d.id);
            nameLink.textContent = d.name;
            var meta = document.createElement('div');
            meta.className = 'drawing-meta';
            meta.textContent = 'Modified: ' + new Date(d.modified).toLocaleDateString() + ' ' +
                new Date(d.modified).toLocaleTimeString() + ' - ' + formatSize(d.size);
            info.appendChild(nameLink);
            info.appendChild(meta);

            var actions = document.createElement('div');
            actions.className = 'drawing-actions';
            var open = document.createElement('a');
            open.className = 'btn btn-small';
            open.href = '/draw/' + encodeURIComponent(d.id);
            open.textContent = 'Open';
            var rename = document.createElement('button');
            rename.className = 'btn btn-small btn-secondary';
            rename.textContent = 'Rename';
            rename.onclick = function() { showRenameModal(d.id); };
            var del = document.createElement('button');
            del.className = 'btn btn-small btn-danger';
            del.textContent = 'Delete';
            del.onclick = function() { deleteDrawing(d.id); };
            actions.appendChild(open);
            actions.appendChild(rename);
            actions.appendChild(del);

            row.appendChild(info);
            row.appendChild(actions);
            return row;
        }

        async function loadDrawings() {
            const resp = await fetch('/api/drawings');
            const drawings = await resp.json();
            const container = document.getElementById('drawings');
            container.replaceChildren();

            if (!drawings || drawings.length === 0) {
                var empty = document.createElement('div');
                empty.className = 'empty';
                empty.textContent = 'No drawings yet. Create your first one!';
                container.appendChild(empty);
                return;
            }

            drawings.forEach(function(d) {
                container.appendChild(drawingRow(d));
            });
        }

        function formatSize(bytes) {
            if (bytes < 1024) return bytes + ' B';
            if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
            return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
        }

        var modalAction = null; // invoked with the input value on confirm

        function showModal(title, confirmLabel, initialValue, action) {
            document.getElementById('modal-title').textContent = title;
            document.getElementById('modal-confirm').textContent = confirmLabel;
            var input = document.getElementById('drawingName');
            input.value = initialValue || '';
            modalAction = action;
            document.getElementById('modal').classList.add('active');
            input.focus();
            input.select();
        }

        function showNewModal() {
            showModal('New Drawing', 'Create', '', createDrawing);
        }

        function showRenameModal(id) {
            showModal('Rename Drawing', 'Rename', id, function(value) {
                renameDrawing(id, value);
            });
        }

        function hideModal() {
            document.getElementById('modal').classList.remove('active');
            document.getElementById('drawingName').value = '';
            modalAction = null;
        }

        function confirmModal() {
            if (modalAction) modalAction(document.getElementById('drawingName').value);
        }

        async function renameDrawing(id, newName) {
            newName = (newName || '').trim();
            if (!newName || newName === id) {
                hideModal();
                return;
            }
            var resp = await fetch('/api/drawings/' + encodeURIComponent(id), {
                method: 'PATCH',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name: newName })
            });
            if (resp.status === 409) {
                alert('A drawing with that name already exists.');
                return; // keep the modal open so the user can pick another name
            }
            if (!resp.ok) {
                alert('Rename failed: ' + await resp.text());
                return;
            }
            hideModal();
            loadDrawings();
        }

        async function createDrawing(name) {
            name = (name || '').trim();
            if (!name) {
                name = 'drawing-' + Date.now();
            }
            // Sanitize name
            name = name.replace(/[^a-zA-Z0-9-_]/g, '-');

            // Create empty drawing
            var emptyDrawing = {
                type: "excalidraw",
                version: 2,
                source: "excalidraw-library",
                elements: [],
                appState: { viewBackgroundColor: "#ffffff" }
            };

            await fetch('/api/drawings/' + name, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(emptyDrawing)
            });

            hideModal();
            window.location.href = '/draw/' + name;
        }

        async function deleteDrawing(id) {
            if (!confirm('Delete "' + id + '"?')) return;
            await fetch('/api/drawings/' + id, { method: 'DELETE' });
            loadDrawings();
        }

        document.getElementById('drawingName').addEventListener('keypress', function(e) {
            if (e.key === 'Enter') confirmModal();
        });

        document.getElementById('modal').addEventListener('click', function(e) {
            if (e.target.id === 'modal') hideModal();
        });

        loadUser();
        loadDrawings();
    </script>
</body>
</html>`

