// Lodestone Management Console Frontend Application Logic

let currentTab = 'overview';
let activeDbTable = 'Rooms';
let pollInterval = null;
let pollingRateMs = 3000;
let roomsData = [];
let serversData = [];
let lastLogId = 0;
let allLogs = [];
let activeConsoleRoom = '';

// DOM Element References
const elements = {
  navItems: document.querySelectorAll('.nav-item'),
  tabPanes: document.querySelectorAll('.tab-pane'),
  pageTitle: document.getElementById('page-title'),
  pageSubtitle: document.getElementById('page-subtitle'),
  selectPollingRate: document.getElementById('select-polling-rate'),
  btnRefresh: document.getElementById('btn-refresh'),
  btnClearCache: document.getElementById('btn-clear-cache'),
  btnDownloadTemplates: document.getElementById('btn-download-templates'),
  qbtnClearCache: document.getElementById('qbtn-clear-cache'),
  qbtnDownloadTemplates: document.getElementById('qbtn-download-templates'),
  btnDownloadTemplatesApworlds: document.getElementById('btn-download-templates-apworlds'),
  qbtnRefreshAll: document.getElementById('qbtn-refresh-all'),
  searchRooms: document.getElementById('search-rooms'),
  
  // Overview Stats
  statActiveRooms: document.getElementById('stat-active-rooms'),
  statTotalRooms: document.getElementById('stat-total-rooms'),
  statConnectedUsers: document.getElementById('stat-connected-users'),
  statTotalUsers: document.getElementById('stat-total-users'),
  statActiveServers: document.getElementById('stat-active-servers'),
  statLockedSessions: document.getElementById('stat-locked-sessions'),
  vitalUptime: document.getElementById('vital-uptime'),
  vitalNode: document.getElementById('vital-node'),
  vitalMemory: document.getElementById('vital-memory'),
  vitalApworlds: document.getElementById('vital-apworlds'),

  // Badges
  badgeRooms: document.getElementById('badge-rooms'),
  badgeServers: document.getElementById('badge-servers'),
  badgeApworlds: document.getElementById('badge-apworlds'),

  // Tables
  roomsTableBody: document.getElementById('rooms-table-body'),
  serversTableBody: document.getElementById('servers-table-body'),
  apworldsTableBody: document.getElementById('apworlds-table-body'),
  dbTableHead: document.getElementById('db-table-head'),
  dbTableBody: document.getElementById('db-table-body'),
  dbTabBtns: document.querySelectorAll('.db-tab-btn'),
  dbSearchInput: document.getElementById('db-search-input'),
  dbRowCount: document.getElementById('db-row-count'),
  btnExportCsv: document.getElementById('btn-export-csv'),

  // AP Servers & Console
  consoleRoomSelect: document.getElementById('console-room-select'),
  consoleViewport: document.getElementById('console-viewport'),
  consoleForm: document.getElementById('console-form'),
  consoleInput: document.getElementById('console-input'),
  btnClearConsole: document.getElementById('btn-clear-console'),
  quickChips: document.querySelectorAll('.quick-chips .chip-btn'),

  // Live System Logs
  logFilterSource: document.getElementById('log-filter-source'),
  logSearchInput: document.getElementById('log-search-input'),
  chkLogAutoscroll: document.getElementById('chk-log-autoscroll'),
  btnCopyLogs: document.getElementById('btn-copy-logs'),
  btnClearSyslogs: document.getElementById('btn-clear-syslogs'),
  syslogsViewport: document.getElementById('syslogs-viewport'),

  // APWorld Upload
  dropzone: document.getElementById('apworld-dropzone'),
  fileInput: document.getElementById('apworld-file-input'),
  btnBrowseApworld: document.getElementById('btn-browse-apworld'),
  uploadProgress: document.getElementById('upload-progress'),
  progressFill: document.getElementById('progress-fill'),
  uploadStatusText: document.getElementById('upload-status-text'),

  // Player Moderation Modal
  playerModal: document.getElementById('player-modal'),
  modalRoomTitle: document.getElementById('modal-room-title'),
  modalPlayerList: document.getElementById('modal-player-list'),
  modalCloseBtn: document.getElementById('modal-close-btn'),

  // Code / Viewer Modal
  viewerModal: document.getElementById('viewer-modal'),
  viewerModalTitle: document.getElementById('viewer-modal-title'),
  viewerModalContent: document.getElementById('viewer-modal-content'),
  viewerModalCloseBtn: document.getElementById('viewer-modal-close-btn'),
  btnCopyViewer: document.getElementById('btn-copy-viewer'),
  btnDownloadViewer: document.getElementById('btn-download-viewer'),

  // Purge Modal
  btnPurgeAll: document.getElementById('btn-purge-all'),
  qbtnPurgeAll: document.getElementById('qbtn-purge-all'),
  purgeModal: document.getElementById('purge-modal'),
  purgeModalCloseBtn: document.getElementById('purge-modal-close-btn'),
  btnCancelPurge: document.getElementById('btn-cancel-purge'),
  btnConfirmPurge: document.getElementById('btn-confirm-purge'),
  chkPurgeApworlds: document.getElementById('chk-purge-apworlds'),

  // Toast
  toastContainer: document.getElementById('toast-container')
};

// Titles map for tabs
const tabTitles = {
  overview: { title: 'System Overview', subtitle: 'Real-time telemetry and orchestrator vitals' },
  rooms: { title: 'Rooms & Sessions Manager', subtitle: 'Manage active multiworld lobbies, seeds, and session locks' },
  servers: { title: 'Archipelago MultiServer & Console', subtitle: 'Running AP servers, port bindings, and live command terminal' },
  logs: { title: 'Live System Logs', subtitle: 'Real-time stream of server events, seed generations, and MultiServer output' },
  apworlds: { title: 'Custom APWorld Packages', subtitle: 'Upload, toggle, and inspect custom game world definitions' },
  database: { title: 'Database Explorer', subtitle: 'Inspect and search raw SQLite database records with CSV export' }
};

// Initialize Application
document.addEventListener('DOMContentLoaded', () => {
  setupNavigation();
  setupEventListeners();
  setupDropzone();
  setupHotkeys();
  
  // Initial data fetch
  refreshAllData();
  fetchLogs();

  // Start polling telemetry
  setupPolling();
});

// Setup Polling Manager
function setupPolling() {
  if (pollInterval) clearInterval(pollInterval);
  if (pollingRateMs > 0) {
    pollInterval = setInterval(() => {
      refreshAllData();
      fetchLogs();
    }, pollingRateMs);
  }
}

// Setup Keyboard Shortcuts
function setupHotkeys() {
  window.addEventListener('keydown', (e) => {
    // Ignore hotkeys when typing in inputs
    if (['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement?.tagName)) {
      if (e.key === 'Escape') {
        document.activeElement.blur();
      }
      return;
    }

    if (e.key === 'Escape') {
      closeAllModals();
    } else if (e.key === 'r' || e.key === 'R') {
      e.preventDefault();
      refreshAllData();
      showToast('Telemetry refreshed', 'info');
    } else if (e.key >= '1' && e.key <= '6') {
      const tabs = ['overview', 'rooms', 'servers', 'logs', 'apworlds', 'database'];
      const idx = parseInt(e.key, 10) - 1;
      if (tabs[idx]) switchTab(tabs[idx]);
    }
  });
}

function closeAllModals() {
  if (elements.playerModal) elements.playerModal.style.display = 'none';
  if (elements.viewerModal) elements.viewerModal.style.display = 'none';
  if (elements.purgeModal) elements.purgeModal.style.display = 'none';
}

// Setup Tab Navigation
function setupNavigation() {
  elements.navItems.forEach(item => {
    item.addEventListener('click', () => {
      const targetTab = item.getAttribute('data-tab');
      if (targetTab) switchTab(targetTab);
    });
  });

  // DB Table Tab Buttons
  elements.dbTabBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      elements.dbTabBtns.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      activeDbTable = btn.getAttribute('data-dbtable');
      fetchDBTable(activeDbTable);
    });
  });
}

function switchTab(targetTab) {
  elements.navItems.forEach(i => i.classList.remove('active'));
  elements.tabPanes.forEach(p => p.classList.remove('active'));

  const navItem = document.querySelector(`.nav-item[data-tab="${targetTab}"]`);
  const pane = document.getElementById(`tab-${targetTab}`);

  if (navItem) navItem.classList.add('active');
  if (pane) pane.classList.add('active');

  currentTab = targetTab;

  if (tabTitles[targetTab]) {
    elements.pageTitle.textContent = tabTitles[targetTab].title;
    elements.pageSubtitle.textContent = tabTitles[targetTab].subtitle;
  }

  refreshCurrentTab();
}

// Setup Event Listeners
function setupEventListeners() {
  // Polling rate changer
  elements.selectPollingRate.addEventListener('change', () => {
    pollingRateMs = parseInt(elements.selectPollingRate.value, 10);
    setupPolling();
    showToast(pollingRateMs > 0 ? `Auto-refresh set to ${pollingRateMs / 1000}s` : 'Auto-refresh paused', 'info');
  });

  elements.btnRefresh.addEventListener('click', () => {
    refreshAllData();
    fetchLogs();
    showToast('Telemetry refreshed successfully', 'info');
  });

  elements.btnClearCache.addEventListener('click', clearCache);
  if (elements.qbtnClearCache) elements.qbtnClearCache.addEventListener('click', clearCache);

  const handleDownloadTemplates = (e) => {
    downloadYamlTemplates(e.currentTarget);
  };
  if (elements.btnDownloadTemplates) elements.btnDownloadTemplates.addEventListener('click', handleDownloadTemplates);
  if (elements.qbtnDownloadTemplates) elements.qbtnDownloadTemplates.addEventListener('click', handleDownloadTemplates);
  if (elements.btnDownloadTemplatesApworlds) elements.btnDownloadTemplatesApworlds.addEventListener('click', handleDownloadTemplates);
  if (elements.qbtnRefreshAll) elements.qbtnRefreshAll.addEventListener('click', () => {
    refreshAllData();
    showToast('Vitals refreshed', 'info');
  });

  // Purge All Modal Openers
  const openPurgeModal = () => {
    if (elements.chkPurgeApworlds) elements.chkPurgeApworlds.checked = false;
    if (elements.purgeModal) elements.purgeModal.style.display = 'flex';
  };
  if (elements.btnPurgeAll) elements.btnPurgeAll.addEventListener('click', openPurgeModal);
  if (elements.qbtnPurgeAll) elements.qbtnPurgeAll.addEventListener('click', openPurgeModal);

  // Purge Modal Closers & Confirmation
  if (elements.purgeModalCloseBtn) elements.purgeModalCloseBtn.addEventListener('click', closeAllModals);
  if (elements.btnCancelPurge) elements.btnCancelPurge.addEventListener('click', closeAllModals);
  if (elements.btnConfirmPurge) elements.btnConfirmPurge.addEventListener('click', purgeAllData);

  // Search input in rooms
  elements.searchRooms.addEventListener('input', renderRoomsTable);

  // Modal Closers
  elements.modalCloseBtn.addEventListener('click', closeAllModals);
  if (elements.viewerModalCloseBtn) elements.viewerModalCloseBtn.addEventListener('click', closeAllModals);

  window.addEventListener('click', (e) => {
    if (e.target === elements.playerModal || e.target === elements.purgeModal || e.target === elements.viewerModal) {
      closeAllModals();
    }
  });

  // Viewer Modal Copy
  if (elements.btnCopyViewer) {
    elements.btnCopyViewer.addEventListener('click', () => {
      navigator.clipboard.writeText(elements.viewerModalContent.textContent || '');
      showToast('Content copied to clipboard', 'success');
    });
  }

  // AP Server Console Handlers
  if (elements.consoleRoomSelect) {
    elements.consoleRoomSelect.addEventListener('change', () => {
      activeConsoleRoom = elements.consoleRoomSelect.value;
      renderConsoleLogs();
    });
  }

  if (elements.btnClearConsole) {
    elements.btnClearConsole.addEventListener('click', () => {
      elements.consoleViewport.innerHTML = `<div class="log-line" style="color: var(--text-muted); font-style: italic;">Console screen cleared.</div>`;
    });
  }

  if (elements.consoleForm) {
    elements.consoleForm.addEventListener('submit', (e) => {
      e.preventDefault();
      sendConsoleCommand(elements.consoleInput.value);
    });
  }

  elements.quickChips.forEach(chip => {
    chip.addEventListener('click', () => {
      const cmd = chip.getAttribute('data-cmd');
      if (cmd) {
        elements.consoleInput.value = cmd;
        sendConsoleCommand(cmd);
      }
    });
  });

  // Live Logs Filters & Controls
  if (elements.logFilterSource) elements.logFilterSource.addEventListener('change', renderSyslogs);
  if (elements.logSearchInput) elements.logSearchInput.addEventListener('input', renderSyslogs);
  if (elements.btnClearSyslogs) {
    elements.btnClearSyslogs.addEventListener('click', async () => {
      if (!confirm('Clear all logs in the server buffer?')) return;
      try {
        await fetch('/api/admin/logs', { method: 'DELETE' });
        allLogs = [];
        lastLogId = 0;
        renderSyslogs();
        showToast('Logs cleared', 'info');
      } catch (err) {
        showToast(`Failed to clear logs: ${err.message}`, 'error');
      }
    });
  }
  if (elements.btnCopyLogs) {
    elements.btnCopyLogs.addEventListener('click', () => {
      const text = allLogs.map(l => `[${l.timestamp.slice(11, 19)}] [${l.source.toUpperCase()}${l.roomCode ? ` ${l.roomCode}` : ''}] ${l.message}`).join('\n');
      navigator.clipboard.writeText(text);
      showToast('Visible logs copied to clipboard', 'success');
    });
  }

  // Database Search & CSV Export
  if (elements.dbSearchInput) elements.dbSearchInput.addEventListener('input', () => fetchDBTable(activeDbTable));
  if (elements.btnExportCsv) {
    elements.btnExportCsv.addEventListener('click', () => {
      window.location.href = `/api/admin/db?table=${activeDbTable}&format=csv`;
    });
  }
}

let consecutiveFailures = 0;
const statusTextEl = document.getElementById('system-status-text');
const vitalsChipEl = document.getElementById('vitals-chip');

function setConnectionStatus(connected, detail) {
  if (connected) {
    consecutiveFailures = 0;
    if (statusTextEl) statusTextEl.textContent = 'Backend Active';
    if (vitalsChipEl) {
      vitalsChipEl.classList.remove('offline');
      vitalsChipEl.style.borderColor = '';
    }
  } else {
    consecutiveFailures++;
    if (statusTextEl) statusTextEl.textContent = detail || 'Reconnecting...';
    if (vitalsChipEl) {
      vitalsChipEl.classList.add('offline');
      vitalsChipEl.style.borderColor = 'var(--accent-red)';
    }
  }
}

// Refresh all telemetry data
async function refreshAllData() {
  try {
    await Promise.all([
      fetchOverview(),
      fetchRooms(),
      fetchServers(),
      fetchAPWorlds()
    ]);
    setConnectionStatus(true);

    if (currentTab === 'database') {
      fetchDBTable(activeDbTable);
    }
  } catch (err) {
    setConnectionStatus(false, 'Connection Lost (Retrying...)');
  }
}

function refreshCurrentTab() {
  switch (currentTab) {
    case 'overview': fetchOverview(); break;
    case 'rooms': fetchRooms(); break;
    case 'servers': fetchServers(); renderConsoleLogs(); break;
    case 'logs': fetchLogs(); renderSyslogs(); break;
    case 'apworlds': fetchAPWorlds(); break;
    case 'database': fetchDBTable(activeDbTable); break;
  }
}

// 1. Overview Telemetry
async function fetchOverview() {
  try {
    const res = await fetch('/api/admin/overview');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();

    const { stats, uptimeSeconds, memoryUsage, nodeVersion } = data;

    elements.statActiveRooms.textContent = stats.activeRooms;
    elements.statTotalRooms.textContent = `${stats.totalRooms} total created rooms`;
    elements.statConnectedUsers.textContent = stats.connectedUsers;
    elements.statTotalUsers.textContent = `${stats.totalUsers} total players registered`;
    elements.statActiveServers.textContent = stats.activeServersCount;
    elements.statLockedSessions.textContent = stats.lockedSessions;

    elements.badgeRooms.textContent = stats.activeRooms;
    elements.badgeServers.textContent = stats.activeServersCount;
    elements.badgeApworlds.textContent = stats.apWorldCount;

    // Vitals
    elements.vitalUptime.textContent = formatUptime(uptimeSeconds);
    elements.vitalNode.textContent = nodeVersion;
    const heapMb = (memoryUsage.heapUsed / (1024 * 1024)).toFixed(1);
    elements.vitalMemory.textContent = `${heapMb} MB`;
    elements.vitalApworlds.textContent = stats.apWorldCount;
  } catch (err) {
    console.error('Failed to fetch overview vitals:', err);
  }
}

// 2. Fetch Rooms
async function fetchRooms() {
  try {
    const res = await fetch('/api/admin/rooms');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    roomsData = data.rooms || [];
    renderRoomsTable();
  } catch (err) {
    console.error('Failed to fetch rooms data:', err);
    if (consecutiveFailures >= 3 || roomsData.length === 0) {
      elements.roomsTableBody.innerHTML = `<tr><td colspan="7" class="loading-cell">Failed to load room data: ${err.message}</td></tr>`;
    }
  }
}

function renderRoomsTable() {
  const query = elements.searchRooms.value.toLowerCase().trim();
  const filtered = roomsData.filter(r => 
    r.code.toLowerCase().includes(query) || 
    (r.players && r.players.some(p => p.name.toLowerCase().includes(query)))
  );

  if (filtered.length === 0) {
    elements.roomsTableBody.innerHTML = `<tr><td colspan="7" class="loading-cell">No rooms found.</td></tr>`;
    return;
  }

  elements.roomsTableBody.innerHTML = filtered.map(room => {
    // Seed status pill & asset actions
    let seedSection = getStatusPill(room.seed_status);
    let seedActionButtons = '';

    if (room.seed_status === 'done') {
      seedActionButtons = `
        <div style="display: flex; gap: 0.35rem; margin-top: 0.35rem;">
          <a href="/api/admin/rooms/${room.code}/download/seed" class="btn btn-secondary btn-sm" title="Download generated multiworld seed ZIP">
            📥 Seed
          </a>
          <button class="btn btn-secondary btn-sm btn-view-spoiler" data-code="${room.code}" title="View or download spoiler log">
            📜 Spoiler
          </button>
          <button class="btn btn-secondary btn-sm btn-regenerate" data-code="${room.code}" title="Re-generate seed archive from player YAMLs">
            🔁
          </button>
        </div>
      `;
    } else if (room.seed_status === 'generating') {
      seedActionButtons = `<small class="text-muted" style="display: block; margin-top: 0.25rem;">Building multiworld...</small>`;
    } else {
      seedActionButtons = `
        <div style="display: flex; gap: 0.35rem; margin-top: 0.35rem;">
          <button class="btn btn-secondary btn-sm btn-view-genlog" data-code="${room.code}" title="Inspect generation log / error traceback">
            ⚠️ Log
          </button>
          <button class="btn btn-secondary btn-sm btn-regenerate" data-code="${room.code}" title="Trigger seed generation">
            🔁 Generate
          </button>
        </div>
      `;
    }

    // Server Section
    let serverSection = '';
    if (room.isServerRunning) {
      serverSection = `
        <div>
          <span class="code-tag copyable btn-copy-connect" data-connect="/connect localhost:${room.serverPort}" title="Click to copy connect command">:${room.serverPort} 📋</span>
          <div style="display: flex; gap: 0.35rem; margin-top: 0.35rem;">
            <button class="btn btn-warning btn-sm btn-kill-server" data-code="${room.code}" title="Stop AP MultiServer process">⏹️ Stop</button>
            <button class="btn btn-secondary btn-sm btn-open-terminal" data-code="${room.code}" title="Switch to Terminal for this server">⚡ Console</button>
          </div>
        </div>
      `;
    } else if (room.seed_status === 'done') {
      serverSection = `
        <div>
          <span class="status-pill idle">Stopped</span>
          <div style="margin-top: 0.35rem;">
            <button class="btn btn-primary btn-sm btn-start-server" data-code="${room.code}" title="Start Archipelago Central MultiServer">▶️ Start Server</button>
          </div>
        </div>
      `;
    } else {
      serverSection = `<span class="text-muted">Not ready</span>`;
    }

    // Lock text
    const lockText = room.locked_by 
      ? `<span class="status-pill locked" title="Locked at ${new Date(room.locked_at).toLocaleTimeString()}">🔒 ${escapeHtml(room.locked_by)}</span>` 
      : `<span class="status-pill idle">Unlocked</span>`;

    const playerList = JSON.stringify(room.players).replace(/"/g, '&quot;');

    return `
      <tr>
        <td>
          <strong class="code-tag copyable btn-copy-code" data-code="${room.code}" title="Click to copy room code">${escapeHtml(room.code)}</strong>
        </td>
        <td><span class="status-pill ${room.status === 'active' ? 'active' : 'idle'}">${escapeHtml(room.status)}</span></td>
        <td>
          ${seedSection}
          ${seedActionButtons}
        </td>
        <td>${serverSection}</td>
        <td>
          <button class="btn btn-secondary btn-sm btn-view-players" data-code="${room.code}" data-players="${playerList}">
            👥 ${room.players ? room.players.length : 0} Players
          </button>
        </td>
        <td>
          ${lockText}
          ${room.locked_by ? `<div style="margin-top: 0.35rem;"><button class="btn btn-secondary btn-sm btn-unlock-session" data-code="${room.code}" title="Force Unlock Save">🔓 Unlock</button></div>` : ''}
        </td>
        <td>
          <div class="action-buttons" style="display: flex; gap: 0.35rem;">
            <button class="btn btn-danger btn-sm btn-delete-room" data-code="${room.code}" title="Delete Room & Files">🗑️ Delete</button>
          </div>
        </td>
      </tr>
    `;
  }).join('');

  attachRoomTableEvents();
}

function attachRoomTableEvents() {
  // Copy Room Code
  document.querySelectorAll('.btn-copy-code').forEach(btn => {
    btn.addEventListener('click', () => {
      const code = btn.getAttribute('data-code');
      navigator.clipboard.writeText(code);
      showToast(`Copied room code "${code}"`, 'success');
    });
  });

  // Copy connect command
  document.querySelectorAll('.btn-copy-connect').forEach(btn => {
    btn.addEventListener('click', () => {
      const cmd = btn.getAttribute('data-connect');
      navigator.clipboard.writeText(cmd);
      showToast(`Copied: "${cmd}"`, 'success');
    });
  });

  // View Players Modal
  document.querySelectorAll('.btn-view-players').forEach(btn => {
    btn.addEventListener('click', () => {
      const code = btn.getAttribute('data-code');
      const players = JSON.parse(btn.getAttribute('data-players'));
      openPlayerModal(code, players);
    });
  });

  // View Spoiler
  document.querySelectorAll('.btn-view-spoiler').forEach(btn => {
    btn.addEventListener('click', () => viewSpoiler(btn.getAttribute('data-code')));
  });

  // View Generation Log
  document.querySelectorAll('.btn-view-genlog').forEach(btn => {
    btn.addEventListener('click', () => viewGenLog(btn.getAttribute('data-code')));
  });

  // Re-generate Seed
  document.querySelectorAll('.btn-regenerate').forEach(btn => {
    btn.addEventListener('click', () => regenerateSeed(btn.getAttribute('data-code')));
  });

  // Start Server
  document.querySelectorAll('.btn-start-server').forEach(btn => {
    btn.addEventListener('click', () => startServer(btn.getAttribute('data-code')));
  });

  // Kill Server
  document.querySelectorAll('.btn-kill-server').forEach(btn => {
    btn.addEventListener('click', () => killServer(btn.getAttribute('data-code')));
  });

  // Switch to Terminal for server
  document.querySelectorAll('.btn-open-terminal').forEach(btn => {
    btn.addEventListener('click', () => {
      const code = btn.getAttribute('data-code');
      switchTab('servers');
      if (elements.consoleRoomSelect) {
        elements.consoleRoomSelect.value = code;
        activeConsoleRoom = code;
        renderConsoleLogs();
      }
    });
  });

  // Unlock Session
  document.querySelectorAll('.btn-unlock-session').forEach(btn => {
    btn.addEventListener('click', () => unlockSession(btn.getAttribute('data-code')));
  });

  // Delete Room
  document.querySelectorAll('.btn-delete-room').forEach(btn => {
    btn.addEventListener('click', () => deleteRoom(btn.getAttribute('data-code')));
  });
}

// 3. Fetch Active Servers & Terminal Console
async function fetchServers() {
  try {
    const res = await fetch('/api/admin/servers');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    serversData = data.servers || [];

    // Update Console dropdown options
    updateConsoleRoomSelect();

    if (serversData.length === 0) {
      elements.serversTableBody.innerHTML = `<tr><td colspan="6" class="loading-cell">No Archipelago MultiServer processes currently active.</td></tr>`;
      return;
    }

    elements.serversTableBody.innerHTML = serversData.map(srv => `
      <tr>
        <td><strong class="code-tag">${escapeHtml(srv.roomCode)}</strong></td>
        <td><span class="code-tag copyable btn-copy-connect" data-connect="/connect localhost:${srv.port}" title="Click to copy connect command">:${srv.port} 📋</span></td>
        <td><span class="vital-value">${srv.pid || 'N/A'}</span></td>
        <td><small class="code-tag" style="font-size: 0.75rem;">${escapeHtml(srv.saveFilePath)}</small></td>
        <td><span class="status-pill active">Running</span></td>
        <td>
          <button class="btn btn-danger btn-sm btn-kill-server" data-code="${srv.roomCode}" title="Stop MultiServer">
            ⏹️ Stop Process
          </button>
        </td>
      </tr>
    `).join('');

    document.querySelectorAll('#servers-table-body .btn-kill-server').forEach(btn => {
      btn.addEventListener('click', () => killServer(btn.getAttribute('data-code')));
    });

    document.querySelectorAll('#servers-table-body .btn-copy-connect').forEach(btn => {
      btn.addEventListener('click', () => {
        const cmd = btn.getAttribute('data-connect');
        navigator.clipboard.writeText(cmd);
        showToast(`Copied: "${cmd}"`, 'success');
      });
    });
  } catch (err) {
    console.error('Failed to fetch AP servers:', err);
  }
}

function updateConsoleRoomSelect() {
  if (!elements.consoleRoomSelect) return;
  const currentVal = elements.consoleRoomSelect.value;
  const activeCodes = serversData.map(s => s.roomCode);

  elements.consoleRoomSelect.innerHTML = `<option value="">Select Running AP Server...</option>` +
    activeCodes.map(code => `<option value="${code}">${code} (Port ${serversData.find(s => s.roomCode === code)?.port})</option>`).join('');

  if (activeCodes.includes(currentVal)) {
    elements.consoleRoomSelect.value = currentVal;
    activeConsoleRoom = currentVal;
  } else if (activeCodes.length > 0 && !activeConsoleRoom) {
    elements.consoleRoomSelect.value = activeCodes[0];
    activeConsoleRoom = activeCodes[0];
  }
}

async function sendConsoleCommand(cmd) {
  if (!cmd || !cmd.trim()) return;
  const roomCode = elements.consoleRoomSelect ? elements.consoleRoomSelect.value : activeConsoleRoom;
  if (!roomCode) {
    showToast('Please select an active AP Server above to send commands to.', 'error');
    return;
  }

  try {
    const res = await fetch(`/api/admin/servers/${roomCode}/command`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ command: cmd })
    });

    if (res.ok) {
      elements.consoleInput.value = '';
      fetchLogs();
      renderConsoleLogs();
    } else {
      const err = await res.json();
      showToast(`Command error: ${err.error}`, 'error');
    }
  } catch (err) {
    showToast(`Error sending command: ${err.message}`, 'error');
  }
}

function renderConsoleLogs() {
  if (!elements.consoleViewport) return;
  const roomCode = activeConsoleRoom || (elements.consoleRoomSelect ? elements.consoleRoomSelect.value : '');
  if (!roomCode) {
    elements.consoleViewport.innerHTML = `<div class="log-line" style="color: var(--text-muted); font-style: italic;">Select an active Archipelago server above to monitor output and execute console commands.</div>`;
    return;
  }

  const roomLogs = allLogs.filter(l => l.roomCode === roomCode || (l.message && l.message.includes(roomCode)));
  if (roomLogs.length === 0) {
    elements.consoleViewport.innerHTML = `<div class="log-line" style="color: var(--text-muted);">No logs received yet for room ${roomCode}.</div>`;
    return;
  }

  elements.consoleViewport.innerHTML = roomLogs.map(l => formatLogLine(l)).join('');
  elements.consoleViewport.scrollTop = elements.consoleViewport.scrollHeight;
}

// 4. Live System Logs
async function fetchLogs() {
  try {
    const res = await fetch(`/api/admin/logs?since=${lastLogId}`);
    if (!res.ok) return;
    const data = await res.json();
    if (data.logs && data.logs.length > 0) {
      allLogs = allLogs.concat(data.logs);
      if (allLogs.length > 1000) allLogs = allLogs.slice(allLogs.length - 1000);
      lastLogId = data.lastId;

      renderSyslogs();
      if (currentTab === 'servers') renderConsoleLogs();
    }
  } catch (err) {
    console.error('Failed to fetch logs:', err);
  }
}

function renderSyslogs() {
  if (!elements.syslogsViewport) return;
  const sourceFilter = elements.logFilterSource ? elements.logFilterSource.value : 'all';
  const query = elements.logSearchInput ? elements.logSearchInput.value.toLowerCase().trim() : '';

  let filtered = allLogs;
  if (sourceFilter !== 'all') {
    filtered = filtered.filter(l => l.source === sourceFilter);
  }
  if (query) {
    filtered = filtered.filter(l => l.message.toLowerCase().includes(query) || (l.roomCode && l.roomCode.toLowerCase().includes(query)));
  }

  if (filtered.length === 0) {
    elements.syslogsViewport.innerHTML = `<div class="log-line" style="color: var(--text-muted);">No logs matching current filters.</div>`;
    return;
  }

  elements.syslogsViewport.innerHTML = filtered.map(l => formatLogLine(l)).join('');

  if (elements.chkLogAutoscroll && elements.chkLogAutoscroll.checked) {
    elements.syslogsViewport.scrollTop = elements.syslogsViewport.scrollHeight;
  }
}

function formatLogLine(log) {
  const time = log.timestamp ? log.timestamp.slice(11, 19) : '--:--:--';
  const badgeClass = log.source || 'system';
  const roomTag = log.roomCode ? ` [${escapeHtml(log.roomCode)}]` : '';

  return `
    <div class="log-line">
      <span class="log-time">${time}</span>
      <span class="log-badge ${badgeClass}">${badgeClass}${roomTag}</span>
      <span class="log-msg">${escapeHtml(log.message)}</span>
    </div>
  `;
}

// 5. Custom APWorlds
async function fetchAPWorlds() {
  try {
    const res = await fetch('/api/admin/custom-worlds');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const files = data.files || [];

    if (files.length === 0) {
      elements.apworldsTableBody.innerHTML = `<tr><td colspan="6" class="loading-cell">No custom .apworld packages installed.</td></tr>`;
      return;
    }

    elements.apworldsTableBody.innerHTML = files.map(file => {
      const statusPill = file.isEnabled
        ? `<span class="status-pill done">Enabled</span>`
        : `<span class="status-pill disabled">Disabled</span>`;

      const toggleText = file.isEnabled ? '⏸️ Disable' : '▶️ Enable';

      return `
        <tr>
          <td><strong>🎮 ${escapeHtml(file.worldName || file.filename)}</strong></td>
          <td><code style="font-size: 0.8rem;">${escapeHtml(file.filename)}</code></td>
          <td>${statusPill}</td>
          <td>${(file.sizeBytes / 1024).toFixed(1)} KB</td>
          <td>${new Date(file.modifiedAt).toLocaleString()}</td>
          <td>
            <div style="display: flex; gap: 0.35rem;">
              <button class="btn btn-secondary btn-sm btn-toggle-apworld" data-file="${escapeHtml(file.filename)}">
                ${toggleText}
              </button>
              <a href="/api/admin/custom-worlds/${encodeURIComponent(file.filename)}/download" class="btn btn-secondary btn-sm" title="Download package">
                📥
              </a>
              <button class="btn btn-danger btn-sm btn-delete-apworld" data-file="${escapeHtml(file.filename)}" title="Delete package">
                🗑️
              </button>
            </div>
          </td>
        </tr>
      `;
    }).join('');

    document.querySelectorAll('.btn-toggle-apworld').forEach(btn => {
      btn.addEventListener('click', () => toggleAPWorld(btn.getAttribute('data-file')));
    });

    document.querySelectorAll('.btn-delete-apworld').forEach(btn => {
      btn.addEventListener('click', () => deleteAPWorld(btn.getAttribute('data-file')));
    });
  } catch (err) {
    console.error('Failed to fetch apworlds:', err);
  }
}

async function toggleAPWorld(filename) {
  try {
    const res = await fetch(`/api/admin/custom-worlds/${encodeURIComponent(filename)}/toggle`, { method: 'POST' });
    if (res.ok) {
      const data = await res.json();
      showToast(data.isEnabled ? `Enabled ${data.newFilename}` : `Disabled ${data.newFilename}`, 'success');
      fetchAPWorlds();
      fetchOverview();
    } else {
      const err = await res.json();
      showToast(`Toggle failed: ${err.error}`, 'error');
    }
  } catch (err) {
    showToast(`Toggle error: ${err.message}`, 'error');
  }
}

// 6. Database Explorer
async function fetchDBTable(tableName) {
  try {
    elements.dbTableHead.innerHTML = '';
    elements.dbTableBody.innerHTML = `<tr><td class="loading-cell">Loading ${tableName}...</td></tr>`;

    const searchQuery = elements.dbSearchInput ? elements.dbSearchInput.value.trim() : '';
    const res = await fetch(`/api/admin/db?table=${tableName}&search=${encodeURIComponent(searchQuery)}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const rows = data.rows || [];

    if (elements.dbRowCount) {
      elements.dbRowCount.textContent = `${rows.length} of ${data.totalCount || rows.length} rows`;
    }

    if (rows.length === 0) {
      elements.dbTableBody.innerHTML = `<tr><td class="loading-cell">Table ${tableName} has no matching records.</td></tr>`;
      return;
    }

    const keys = Object.keys(rows[0]);
    elements.dbTableHead.innerHTML = `<tr>${keys.map(k => `<th>${escapeHtml(k)}</th>`).join('')}</tr>`;

    elements.dbTableBody.innerHTML = rows.map(row => `
      <tr>
        ${keys.map(k => {
          let val = row[k];
          if (val === null || val === undefined) val = '<em style="color: var(--text-muted);">null</em>';
          else if (typeof val === 'object') val = escapeHtml(JSON.stringify(val));
          else val = escapeHtml(String(val));
          return `<td>${val}</td>`;
        }).join('')}
      </tr>
    `).join('');
  } catch (err) {
    console.error(`Failed to fetch database table ${tableName}:`, err);
    elements.dbTableBody.innerHTML = `<tr><td class="loading-cell">Failed to load table: ${err.message}</td></tr>`;
  }
}

// Action Handlers
async function startServer(roomCode) {
  try {
    const res = await fetch(`/api/admin/rooms/${roomCode}/start-server`, { method: 'POST' });
    if (res.ok) {
      showToast(`Started MultiServer for room ${roomCode}`, 'success');
      refreshAllData();
    } else {
      const err = await res.json();
      showToast(`Start failed: ${err.error}`, 'error');
    }
  } catch (err) {
    showToast(`Error: ${err.message}`, 'error');
  }
}

async function regenerateSeed(roomCode) {
  if (!confirm(`Re-generate multiworld seed for room ${roomCode}? This will rebuild the seed archive and restart the central server.`)) return;
  showToast(`Generating seed for room ${roomCode}...`, 'info');
  try {
    const res = await fetch(`/api/admin/rooms/${roomCode}/regenerate`, { method: 'POST' });
    if (res.ok) {
      showToast(`Successfully regenerated seed for room ${roomCode}!`, 'success');
      refreshAllData();
    } else {
      const err = await res.json();
      showToast(`Generation failed: ${err.error}`, 'error');
      refreshAllData();
    }
  } catch (err) {
    showToast(`Error: ${err.message}`, 'error');
    refreshAllData();
  }
}

async function viewSpoiler(roomCode) {
  try {
    const res = await fetch(`/api/admin/rooms/${roomCode}/download/spoiler?view=true`);
    if (!res.ok) {
      const err = await res.json();
      return showToast(`Failed to load spoiler: ${err.error}`, 'error');
    }
    const data = await res.json();
    openViewerModal(`Spoiler Log (${roomCode})`, data.content, `/api/admin/rooms/${roomCode}/download/spoiler`, `${roomCode}_Spoiler.txt`);
  } catch (err) {
    showToast(`Error: ${err.message}`, 'error');
  }
}

async function viewGenLog(roomCode) {
  try {
    const res = await fetch(`/api/admin/rooms/${roomCode}/generation-log`);
    if (!res.ok) {
      const err = await res.json();
      return showToast(`Failed to load generation log: ${err.error}`, 'error');
    }
    const data = await res.json();
    openViewerModal(`Generation Log (${roomCode})`, data.content, null, `${roomCode}_generation.log`);
  } catch (err) {
    showToast(`Error: ${err.message}`, 'error');
  }
}

async function viewPlayerYaml(roomCode, playerId, playerName) {
  try {
    const res = await fetch(`/api/admin/rooms/${roomCode}/players/${playerId}/yaml`);
    if (!res.ok) {
      const err = await res.json();
      return showToast(`Failed to load YAML: ${err.error}`, 'error');
    }
    const data = await res.json();
    openViewerModal(`Player YAML: ${playerName} (${roomCode})`, data.yaml, `/api/admin/rooms/${roomCode}/players/${playerId}/yaml?download=true`, `${playerName}.yaml`);
  } catch (err) {
    showToast(`Error: ${err.message}`, 'error');
  }
}

function openViewerModal(title, content, downloadUrl, filename) {
  if (!elements.viewerModal) return;
  elements.viewerModalTitle.textContent = title;
  elements.viewerModalContent.textContent = content || '(Empty file)';

  if (downloadUrl) {
    elements.btnDownloadViewer.style.display = 'inline-flex';
    elements.btnDownloadViewer.href = downloadUrl;
    elements.btnDownloadViewer.download = filename || 'download';
  } else {
    elements.btnDownloadViewer.style.display = 'none';
  }

  elements.viewerModal.style.display = 'flex';
}

async function clearCache() {
  try {
    const res = await fetch('/api/cache/clear', { method: 'POST' });
    if (res.ok) {
      showToast('Archipelago cache successfully cleared!', 'success');
      refreshAllData();
    } else {
      showToast('Failed to clear cache', 'error');
    }
  } catch (err) {
    showToast(`Error: ${err.message}`, 'error');
  }
}

async function downloadYamlTemplates(btn) {
  if (btn) {
    btn.disabled = true;
    btn.style.opacity = '0.7';
  }
  showToast('Preparing YAML templates archive (standard + custom)...', 'info');

  try {
    const res = await fetch('/api/admin/yaml-templates/download');
    if (!res.ok) {
      const err = await res.json().catch(() => ({ error: 'Download failed' }));
      throw new Error(err.error || 'Failed to download templates');
    }
    const blob = await res.blob();
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'yaml_templates.zip';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    window.URL.revokeObjectURL(url);
    showToast('YAML templates package downloaded!', 'success');
  } catch (err) {
    showToast(`Error downloading templates: ${err.message}`, 'error');
  } finally {
    if (btn) {
      btn.disabled = false;
      btn.style.opacity = '1';
    }
  }
}

async function purgeAllData() {
  const includeCustomWorlds = elements.chkPurgeApworlds ? elements.chkPurgeApworlds.checked : false;
  closeAllModals();

  try {
    const res = await fetch('/api/admin/purge-all', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ includeCustomWorlds })
    });

    if (res.ok) {
      const data = await res.json();
      showToast(data.message || 'All server data deleted successfully!', 'success');
      allLogs = [];
      lastLogId = 0;
      refreshAllData();
      renderSyslogs();
    } else {
      const err = await res.json();
      showToast(`Purge failed: ${err.error}`, 'error');
    }
  } catch (err) {
    showToast(`Purge error: ${err.message}`, 'error');
  }
}

async function killServer(roomCode) {
  if (!confirm(`Stop Archipelago server process for room ${roomCode}?`)) return;
  try {
    const res = await fetch(`/api/admin/rooms/${roomCode}/kill`, { method: 'POST' });
    if (res.ok) {
      showToast(`Terminated AP Server for room ${roomCode}`, 'success');
      refreshAllData();
    } else {
      const err = await res.json();
      showToast(`Error: ${err.error}`, 'error');
    }
  } catch (err) {
    showToast(`Error: ${err.message}`, 'error');
  }
}

async function unlockSession(roomCode) {
  if (!confirm(`Force unlock save session lock for room ${roomCode}?`)) return;
  try {
    const res = await fetch(`/api/admin/rooms/${roomCode}/unlock`, { method: 'POST' });
    if (res.ok) {
      showToast(`Unlocked session for room ${roomCode}`, 'success');
      refreshAllData();
    } else {
      const err = await res.json();
      showToast(`Error: ${err.error}`, 'error');
    }
  } catch (err) {
    showToast(`Error: ${err.message}`, 'error');
  }
}

async function deleteRoom(roomCode) {
  if (!confirm(`WARNING: Are you sure you want to delete room ${roomCode}? This will remove all connected players, generated seeds, and MultiServer processes.`)) return;
  try {
    const res = await fetch(`/api/admin/rooms/${roomCode}`, { method: 'DELETE' });
    if (res.ok) {
      showToast(`Deleted room ${roomCode}`, 'success');
      refreshAllData();
    } else {
      const err = await res.json();
      showToast(`Error: ${err.error}`, 'error');
    }
  } catch (err) {
    showToast(`Error: ${err.message}`, 'error');
  }
}

async function deleteAPWorld(filename) {
  if (!confirm(`Delete custom world file ${filename}?`)) return;
  try {
    const res = await fetch(`/api/admin/custom-worlds/${encodeURIComponent(filename)}`, { method: 'DELETE' });
    if (res.ok) {
      showToast(`Deleted ${filename}`, 'success');
      fetchAPWorlds();
      fetchOverview();
    } else {
      const err = await res.json();
      showToast(`Error: ${err.error}`, 'error');
    }
  } catch (err) {
    showToast(`Error: ${err.message}`, 'error');
  }
}

// Upload APWorld Handling
function setupDropzone() {
  const { dropzone, fileInput, btnBrowseApworld } = elements;

  btnBrowseApworld.addEventListener('click', () => fileInput.click());

  dropzone.addEventListener('dragover', (e) => {
    e.preventDefault();
    dropzone.classList.add('dragover');
  });

  dropzone.addEventListener('dragleave', () => {
    dropzone.classList.remove('dragover');
  });

  dropzone.addEventListener('drop', (e) => {
    e.preventDefault();
    dropzone.classList.remove('dragover');
    if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
      uploadAPWorldFile(e.dataTransfer.files[0]);
    }
  });

  fileInput.addEventListener('change', () => {
    if (fileInput.files && fileInput.files.length > 0) {
      uploadAPWorldFile(fileInput.files[0]);
    }
  });
}

async function uploadAPWorldFile(file) {
  if (!file.name.endsWith('.apworld')) {
    return showToast('Invalid file: Only .apworld files are accepted', 'error');
  }

  const formData = new FormData();
  formData.append('file', file);

  elements.uploadProgress.style.display = 'block';
  elements.progressFill.style.width = '30%';
  elements.uploadStatusText.textContent = `Uploading ${file.name}...`;

  try {
    elements.progressFill.style.width = '70%';
    const res = await fetch('/api/admin/custom-worlds/upload', {
      method: 'POST',
      body: formData
    });

    elements.progressFill.style.width = '100%';

    if (res.ok) {
      showToast(`Successfully uploaded ${file.name}`, 'success');
      setTimeout(() => {
        elements.uploadProgress.style.display = 'none';
        elements.progressFill.style.width = '0%';
      }, 1000);
      fetchAPWorlds();
      fetchOverview();
    } else {
      const err = await res.json();
      showToast(`Upload failed: ${err.error}`, 'error');
      elements.uploadProgress.style.display = 'none';
    }
  } catch (err) {
    showToast(`Upload error: ${err.message}`, 'error');
    elements.uploadProgress.style.display = 'none';
  }
}

// Player Moderation Modal Helper
function openPlayerModal(roomCode, players) {
  elements.modalRoomTitle.textContent = `Players in Room ${roomCode}`;
  
  if (!players || players.length === 0) {
    elements.modalPlayerList.innerHTML = `<p class="text-muted">No connected or registered players in this room.</p>`;
  } else {
    elements.modalPlayerList.innerHTML = `
      <ul style="list-style: none; display: flex; flex-direction: column; gap: 0.75rem;">
        ${players.map(p => `
          <li style="display: flex; align-items: center; justify-content: space-between; padding: 0.85rem 1rem; background: var(--bg-dark); border-radius: var(--radius-md); border: 1px solid var(--border-color); flex-wrap: wrap; gap: 0.75rem;">
            <div>
              <strong style="font-size: 1rem;">${escapeHtml(p.name)}</strong>
              ${p.isHost ? '<span class="status-pill active" style="font-size: 0.7rem; margin-left: 0.35rem;">HOST</span>' : ''}
              <br>
              <small class="text-muted">Games: ${p.games && p.games.length > 0 ? p.games.join(', ') : 'None selected'}</small>
            </div>
            
            <div style="display: flex; gap: 0.5rem; align-items: center; flex-wrap: wrap;">
              <span class="status-pill ${p.isConnected ? 'active' : 'idle'}">${p.isConnected ? 'Online' : 'Offline'}</span>
              <span class="status-pill ${p.isReady ? 'done' : 'idle'}">${p.isReady ? 'Ready' : 'Not Ready'}</span>

              <button class="btn btn-secondary btn-sm btn-view-player-yaml" data-code="${roomCode}" data-id="${p.id}" data-name="${escapeHtml(p.name)}" title="Inspect Player YAML">
                📄 YAML
              </button>

              <button class="btn btn-secondary btn-sm btn-toggle-ready" data-code="${roomCode}" data-id="${p.id}" data-ready="${!p.isReady}" title="Toggle Ready status">
                ${p.isReady ? 'Unready' : 'Ready'}
              </button>

              ${!p.isHost ? `
                <button class="btn btn-secondary btn-sm btn-make-host" data-code="${roomCode}" data-id="${p.id}" title="Transfer Host to this player">
                  👑 Host
                </button>
              ` : ''}

              <button class="btn btn-danger btn-sm btn-kick-player" data-code="${roomCode}" data-id="${p.id}" data-name="${escapeHtml(p.name)}" title="Disconnect & Kick player">
                ❌ Kick
              </button>
            </div>
          </li>
        `).join('')}
      </ul>
    `;

    // Attach Player Moderation Listeners
    elements.modalPlayerList.querySelectorAll('.btn-view-player-yaml').forEach(btn => {
      btn.addEventListener('click', () => {
        viewPlayerYaml(btn.getAttribute('data-code'), btn.getAttribute('data-id'), btn.getAttribute('data-name'));
      });
    });

    elements.modalPlayerList.querySelectorAll('.btn-toggle-ready').forEach(btn => {
      btn.addEventListener('click', async () => {
        const code = btn.getAttribute('data-code');
        const id = btn.getAttribute('data-id');
        const ready = btn.getAttribute('data-ready') === 'true';
        try {
          const res = await fetch(`/api/admin/rooms/${code}/players/${id}/ready`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ready })
          });
          if (res.ok) {
            showToast(`Updated player ready state`, 'success');
            await fetchRooms();
            const updatedRoom = roomsData.find(r => r.code === code);
            if (updatedRoom) openPlayerModal(code, updatedRoom.players);
          }
        } catch (e) {
          showToast(`Error: ${e.message}`, 'error');
        }
      });
    });

    elements.modalPlayerList.querySelectorAll('.btn-make-host').forEach(btn => {
      btn.addEventListener('click', async () => {
        const code = btn.getAttribute('data-code');
        const id = btn.getAttribute('data-id');
        try {
          const res = await fetch(`/api/admin/rooms/${code}/players/${id}/host`, { method: 'POST' });
          if (res.ok) {
            showToast(`Host transferred successfully`, 'success');
            await fetchRooms();
            const updatedRoom = roomsData.find(r => r.code === code);
            if (updatedRoom) openPlayerModal(code, updatedRoom.players);
          }
        } catch (e) {
          showToast(`Error: ${e.message}`, 'error');
        }
      });
    });

    elements.modalPlayerList.querySelectorAll('.btn-kick-player').forEach(btn => {
      btn.addEventListener('click', async () => {
        const code = btn.getAttribute('data-code');
        const id = btn.getAttribute('data-id');
        const name = btn.getAttribute('data-name');
        if (!confirm(`Are you sure you want to kick "${name}" from room ${code}?`)) return;
        try {
          const res = await fetch(`/api/admin/rooms/${code}/players/${id}/kick`, { method: 'POST' });
          if (res.ok) {
            showToast(`Kicked "${name}" from room ${code}`, 'success');
            await fetchRooms();
            const updatedRoom = roomsData.find(r => r.code === code);
            if (updatedRoom) openPlayerModal(code, updatedRoom.players);
          }
        } catch (e) {
          showToast(`Error: ${e.message}`, 'error');
        }
      });
    });
  }

  elements.playerModal.style.display = 'flex';
}

// Helpers
function getStatusPill(status) {
  switch (status) {
    case 'done': return `<span class="status-pill done">Done</span>`;
    case 'generating': return `<span class="status-pill generating">Generating</span>`;
    case 'error': return `<span class="status-pill error">Error</span>`;
    default: return `<span class="status-pill idle">Idle</span>`;
  }
}

function formatUptime(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) return `${h}h ${m}m ${s}s`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function showToast(message, type = 'info') {
  const toast = document.createElement('div');
  toast.className = `toast toast-${type}`;
  toast.innerHTML = `
    <span>${type === 'success' ? '✅' : type === 'error' ? '❌' : 'ℹ️'}</span>
    <span>${escapeHtml(message)}</span>
  `;

  elements.toastContainer.appendChild(toast);

  setTimeout(() => {
    toast.style.opacity = '0';
    toast.style.transition = 'opacity 0.3s ease';
    setTimeout(() => toast.remove(), 300);
  }, 3500);
}
