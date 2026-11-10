// The item probe: ImGui's test-engine hooks (IMGUI_ENABLE_TEST_ENGINE),
// implemented to record every item submitted in a frame — its id, label,
// window and rectangle (clipped to what shows) — so a test harness can
// find widgets by label and click them as a person would (app:ui's
// probe.odin reads this). Off until fire_probe_enable(true).
#include "imgui.h"
#include "imgui_internal.h"

#include <string.h>

struct Fire_Probe_Item {
	ImGuiID id;
	unsigned int status; // ImGuiItemStatusFlags
	float x0, y0, x1, y1; // the visible part, in screen points
	char window[64];
	char label[128];
};

static ImVector<Fire_Probe_Item> probe_items;   // this frame so far
static ImVector<Fire_Probe_Item> probe_last;    // the last whole frame
static bool probe_on = false;

// Labels that came before their item (a tab gives its label first).
struct Fire_Probe_Early { ImGuiID id; char label[128]; };
static Fire_Probe_Early probe_early[16];
static int probe_early_next = 0;

extern "C" void fire_probe_enable(bool on) {
	probe_on = on;
	if (GImGui) GImGui->TestEngineHookItems = on;
}

// Call once a frame, before NewFrame: what was recorded becomes the last frame's.
extern "C" void fire_probe_frame(void) {
	probe_last.swap(probe_items);
	probe_items.resize(0);
	if (GImGui) GImGui->TestEngineHookItems = probe_on;
}

extern "C" int fire_probe_count(void) { return probe_last.Size; }

extern "C" bool fire_probe_get(int i, Fire_Probe_Item* out) {
	if (i < 0 || i >= probe_last.Size) return false;
	*out = probe_last[i];
	return true;
}

static Fire_Probe_Item* probe_find(ImGuiID id) {
	for (int i = probe_items.Size - 1; i >= 0 && i >= probe_items.Size - 8; i--)
		if (probe_items[i].id == id) return &probe_items[i];
	return NULL;
}

void ImGuiTestEngineHook_ItemAdd(ImGuiContext* ctx, ImGuiID id, const ImRect& bb, const ImGuiLastItemData* item_data) {
	if (!probe_on || id == 0) return;
	// A window registering itself (no item data): its whole rectangle, with
	// its name for a label. A test means its tab or title, which come too.
	if (!item_data) return;
	ImGuiWindow* w = ctx->CurrentWindow;
	ImRect r = bb;
	if (w) r.ClipWith(w->ClipRect);
	if (r.Min.x >= r.Max.x || r.Min.y >= r.Max.y) return; // scrolled or clipped away
	Fire_Probe_Item it;
	memset(&it, 0, sizeof(it));
	it.id = id;
	it.status = item_data ? (unsigned int)item_data->StatusFlags : 0;
	it.x0 = r.Min.x; it.y0 = r.Min.y; it.x1 = r.Max.x; it.y1 = r.Max.y;
	for (int i = 0; i < 16; i++) {
		if (probe_early[i].id == id) {
			memcpy(it.label, probe_early[i].label, sizeof(it.label));
			probe_early[i].id = 0;
			break;
		}
	}
	if (w) {
		// The window's name up to "###" (a docked panel's is "Title###id").
		const char* n = w->Name;
		const char* hash = strstr(n, "###");
		size_t len = hash ? (size_t)(hash - n) : strlen(n);
		if (hash && hash[3]) { n = hash + 3; len = strlen(n); } // prefer the stable id after ###
		if (len >= sizeof(it.window)) len = sizeof(it.window) - 1;
		memcpy(it.window, n, len);
	}
	probe_items.push_back(it);
}

void ImGuiTestEngineHook_ItemInfo(ImGuiContext* ctx, ImGuiID id, const char* label, ImGuiItemStatusFlags flags) {
	(void)ctx;
	if (!probe_on || !label) return;
	Fire_Probe_Item* it = probe_find(id);
	if (!it) {
		// Not added yet: keep it for when it is.
		Fire_Probe_Early* e = &probe_early[probe_early_next];
		probe_early_next = (probe_early_next + 1) % 16;
		e->id = id;
		strncpy(e->label, label, sizeof(e->label) - 1);
		e->label[sizeof(e->label) - 1] = 0;
		return;
	}
	strncpy(it->label, label, sizeof(it->label) - 1);
	it->status |= (unsigned int)flags;
}

void ImGuiTestEngineHook_Log(ImGuiContext*, const char*, ...) {}

const char* ImGuiTestEngine_FindItemDebugLabel(ImGuiContext*, ImGuiID id) {
	for (int i = 0; i < probe_last.Size; i++)
		if (probe_last[i].id == id && probe_last[i].label[0]) return probe_last[i].label;
	return NULL;
}

// Names an item the app draws itself (an InvisibleButton with a "##"
// label): the last item submitted gets `label`.
extern "C" void fire_probe_name_last(const char* label) {
	if (!probe_on || !GImGui || !label) return;
	ImGuiContext& g = *GImGui;
	Fire_Probe_Item* it = probe_find(g.LastItemData.ID);
	if (!it) {
		// Not added (e.g. a Dummy): record it from the last item's rect.
		ImRect r = g.LastItemData.Rect;
		if (g.CurrentWindow) r.ClipWith(g.CurrentWindow->ClipRect);
		if (r.Min.x >= r.Max.x || r.Min.y >= r.Max.y) return;
		int before = probe_items.Size;
		ImGuiTestEngineHook_ItemAdd(&g, g.LastItemData.ID ? g.LastItemData.ID : ImHashStr(label), g.LastItemData.Rect, &g.LastItemData);
		if (probe_items.Size == before) return;
		it = &probe_items.back();
	}
	strncpy(it->label, label, sizeof(it->label) - 1);
}

// Labels item `id` before it is drawn (for widgets that don't give ImGui
// a label: a combo).
extern "C" void fire_probe_label_id(ImGuiID id, const char* label) {
	if (!probe_on || !GImGui) return;
	ImGuiTestEngineHook_ItemInfo(GImGui, id, label, 0);
}
