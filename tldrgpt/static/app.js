const state = {
  conversations: [],
  selectedId: null,
  polling: null,
};

const els = {
  sourceMeta: document.querySelector("#sourceMeta"),
  searchInput: document.querySelector("#searchInput"),
  conversationList: document.querySelector("#conversationList"),
  conversationTitle: document.querySelector("#conversationTitle"),
  conversationFrame: document.querySelector("#conversationFrame"),
  emptyConversation: document.querySelector("#emptyConversation"),
  summaryPane: document.querySelector("#summaryPane"),
  emptySummary: document.querySelector("#emptySummary"),
  tagRow: document.querySelector("#tagRow"),
  statusBadge: document.querySelector("#statusBadge"),
  analyzeButton: document.querySelector("#analyzeButton"),
  analyzeAllButton: document.querySelector("#analyzeAllButton"),
  refreshButton: document.querySelector("#refreshButton"),
  viewJsonButton: document.querySelector("#viewJsonButton"),
  jsonModal: document.querySelector("#jsonModal"),
  jsonModalSubtitle: document.querySelector("#jsonModalSubtitle"),
  jsonViewer: document.querySelector("#jsonViewer"),
  closeJsonButton: document.querySelector("#closeJsonButton"),
};

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  if (!response.ok) {
    throw new Error(`Request failed: ${response.status}`);
  }
  return response.json();
}

function statusIcon(status) {
  if (status === "analyzed") return "✅";
  if (status === "warning") return "⚠️";
  if (status === "analyzing") return "◌";
  return "";
}

function statusLabel(status) {
  if (status === "analyzed") return "Analyzed";
  if (status === "warning") return "Serialized";
  if (status === "analyzing") return "Analyzing";
  return "New";
}

function filteredConversations() {
  const query = els.searchInput.value.trim().toLowerCase();
  if (!query) return state.conversations;
  return state.conversations.filter((item) => {
    const haystack = [item.title, ...(item.tags || [])].join(" ").toLowerCase();
    return haystack.includes(query);
  });
}

function renderList() {
  const rows = filteredConversations();
  els.conversationList.innerHTML = "";

  if (!rows.length) {
    const empty = document.createElement("div");
    empty.className = "p-4 text-sm text-zinc-500";
    empty.textContent = "No conversations found.";
    els.conversationList.append(empty);
    return;
  }

  for (const item of rows) {
    const row = document.createElement("div");
    row.className = `conversation-row ${item.id === state.selectedId ? "active" : ""}`;

    const button = document.createElement("button");
    button.className = "min-w-0 text-left";
    button.type = "button";
    button.addEventListener("click", () => selectConversation(item.id));

    const title = document.createElement("div");
    title.className = "conversation-title";
    title.textContent = `${statusIcon(item.status)} ${item.title}`.trim();
    button.append(title);

    if (item.tags?.length) {
      const tags = document.createElement("div");
      tags.className = "conversation-tags";
      for (const tag of item.tags.slice(0, 3)) {
        const pill = document.createElement("span");
        pill.className = "tag-pill";
        pill.textContent = tag;
        tags.append(pill);
      }
      button.append(tags);
    }

    const deleteButton = document.createElement("button");
    deleteButton.className = "delete-button";
    deleteButton.type = "button";
    deleteButton.title = "Soft delete conversation";
    deleteButton.setAttribute("aria-label", `Soft delete ${item.title}`);
    deleteButton.textContent = "🗑️";
    deleteButton.addEventListener("click", async (event) => {
      event.stopPropagation();
      await deleteConversation(item.id);
    });

    row.append(button, deleteButton);
    els.conversationList.append(row);
  }
}

function renderHeader(item) {
  els.conversationTitle.textContent = item?.title || "Select a conversation";
  els.tagRow.innerHTML = "";
  els.statusBadge.className = "hidden rounded-full px-2 py-1 text-xs font-medium";
  els.statusBadge.textContent = "";

  if (!item) {
    els.analyzeButton.disabled = true;
    els.viewJsonButton.disabled = true;
    return;
  }

  els.analyzeButton.disabled = item.status === "analyzing";
  els.viewJsonButton.disabled = false;
  els.statusBadge.className = `rounded-full px-2 py-1 text-xs font-medium status-badge-${item.status}`;
  els.statusBadge.textContent = statusLabel(item.status);

  for (const tag of item.tags || []) {
    const pill = document.createElement("span");
    pill.className = "tag-pill border-emerald-500/30 text-emerald-200";
    pill.textContent = tag;
    els.tagRow.append(pill);
  }
}

async function selectConversation(id) {
  state.selectedId = id;
  const item = state.conversations.find((entry) => entry.id === id);
  renderList();
  renderHeader(item);
  els.emptyConversation.style.display = "none";
  els.conversationFrame.src = `/api/conversations/${encodeURIComponent(id)}/html`;
  await loadAnalysis(id);
}

async function loadAnalysis(id) {
  const analysis = await api(`/api/conversations/${encodeURIComponent(id)}/analysis`);
  if (analysis.html) {
    els.summaryPane.innerHTML = analysis.html;
    els.emptySummary.style.display = "none";
  } else if (analysis.error) {
    els.summaryPane.innerHTML = `<p class="text-amber-200">${escapeHtml(analysis.error)}</p>`;
    els.emptySummary.style.display = "none";
  } else {
    els.summaryPane.innerHTML = "";
    els.emptySummary.style.display = "flex";
  }
}

async function loadConversations() {
  const data = await api("/api/conversations");
  state.conversations = data.conversations;
  renderList();

  const selected = state.conversations.find((item) => item.id === state.selectedId);
  renderHeader(selected);
  if (selected) {
    await loadAnalysis(selected.id);
  }

  const hasRunning = state.conversations.some((item) => item.status === "analyzing") || data.scan.running;
  setPolling(hasRunning);
}

function setPolling(active) {
  if (active && !state.polling) {
    state.polling = window.setInterval(loadConversations, 2500);
  }
  if (!active && state.polling) {
    window.clearInterval(state.polling);
    state.polling = null;
  }
}

async function analyzeSelected() {
  if (!state.selectedId) return;
  els.analyzeButton.disabled = true;
  await api(`/api/conversations/${encodeURIComponent(state.selectedId)}/analyze`, { method: "POST" });
  await loadConversations();
  setPolling(true);
}

async function analyzeAll() {
  els.analyzeAllButton.disabled = true;
  try {
    await api("/api/analyze-all", { method: "POST" });
    await loadConversations();
    setPolling(true);
  } finally {
    els.analyzeAllButton.disabled = false;
  }
}

async function deleteConversation(id) {
  await api(`/api/conversations/${encodeURIComponent(id)}`, { method: "DELETE" });
  if (state.selectedId === id) {
    state.selectedId = null;
    els.conversationFrame.removeAttribute("src");
    els.emptyConversation.style.display = "flex";
    els.summaryPane.innerHTML = "";
    els.emptySummary.style.display = "flex";
    closeJsonModal();
  }
  await loadConversations();
}

async function viewSelectedJson() {
  if (!state.selectedId) return;

  const selected = state.conversations.find((item) => item.id === state.selectedId);
  els.jsonModalSubtitle.textContent = selected?.title || state.selectedId;
  els.jsonViewer.textContent = "Loading...";
  openJsonModal();

  try {
    const data = await api(`/api/conversations/${encodeURIComponent(state.selectedId)}/json`);
    els.jsonViewer.textContent = JSON.stringify(data, null, 2);
  } catch (error) {
    els.jsonViewer.textContent = error.message;
  }
}

function openJsonModal() {
  els.jsonModal.classList.remove("hidden");
}

function closeJsonModal() {
  els.jsonModal.classList.add("hidden");
}

async function refresh() {
  await api("/api/scan", { method: "POST" });
  await loadConversations();
}

async function loadHealth() {
  const health = await api("/api/health");
  const count = health.scan.count;
  if (health.backendAvailable) {
    els.sourceMeta.textContent = `${health.model} · ${count} files`;
  } else {
    const missing = health.backend === "openai" ? "Local API unavailable" : "Codex CLI missing";
    els.sourceMeta.textContent = `${missing} · ${count} files`;
  }
}

function escapeHtml(value) {
  const div = document.createElement("div");
  div.textContent = value;
  return div.innerHTML;
}

els.searchInput.addEventListener("input", renderList);
els.analyzeButton.addEventListener("click", analyzeSelected);
els.analyzeAllButton.addEventListener("click", analyzeAll);
els.refreshButton.addEventListener("click", refresh);
els.viewJsonButton.addEventListener("click", viewSelectedJson);
els.closeJsonButton.addEventListener("click", closeJsonModal);
els.jsonModal.addEventListener("click", (event) => {
  if (event.target === els.jsonModal) closeJsonModal();
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") closeJsonModal();
});
els.analyzeButton.disabled = true;
els.viewJsonButton.disabled = true;

loadHealth().catch(console.error);
loadConversations().catch(console.error);
